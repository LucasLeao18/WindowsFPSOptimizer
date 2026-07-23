#requires -Version 5.1

Set-StrictMode -Version Latest

function ConvertTo-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
}

function Test-PathContainsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        while ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
            $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
        }
        return $false
    }
    catch { return $true }
}

function Get-SafeCleanupRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        $env:TEMP,
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path $env:WINDIR 'Temp'),
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $normalized = ConvertTo-NormalizedFullPath $candidate
            if (-not $roots.Contains($normalized)) { $roots.Add($normalized) }
        }
        catch { }
    }
    return $roots.ToArray()
}

function Test-SafeCleanupPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try { $full = ConvertTo-NormalizedFullPath $Path } catch { return $false }
    if ((Test-Path -LiteralPath $full) -and (Test-PathContainsReparsePoint -Path $full)) { return $false }
    foreach ($blockedRaw in @((Get-OptimizerContext).Config.Safety.BlockedFileRoots)) {
        try {
            $blocked = ConvertTo-NormalizedFullPath $blockedRaw
            if ($full.Equals($blocked, [StringComparison]::OrdinalIgnoreCase) -or
                $full.StartsWith($blocked + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        catch { }
    }
    foreach ($root in Get-SafeCleanupRoots) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-VolumeStorageType {
    param([Parameter(Mandatory = $true)][char]$DriveLetter)

    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.DeviceId -eq [string]$disk.Number) -or ([string]$_.FriendlyName -eq [string]$disk.FriendlyName)
        } | Select-Object -First 1
        $media = if ($physical) { [string]$physical.MediaType } else { 'Unspecified' }
        $bus = if ($physical) { [string]$physical.BusType } else { [string]$disk.BusType }
        $type = if ($bus -eq 'NVMe') { 'NVMe' } elseif ($media -eq 'SSD') { 'SSD' } elseif ($media -eq 'HDD') { 'HDD' } else { 'Desconhecido' }
        return [pscustomobject]@{ Type = $type; MediaType = $media; BusType = $bus; DiskNumber = [int]$disk.Number; Model = [string]$disk.FriendlyName }
    }
    catch {
        return [pscustomobject]@{ Type = 'Desconhecido'; MediaType = 'Unspecified'; BusType = ''; DiskNumber = -1; Model = '' }
    }
}

function Get-StorageInventory {
    [CmdletBinding()]
    param()

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter)) {
        $type = Get-VolumeStorageType -DriveLetter ([char]$volume.DriveLetter)
        $size = [double]$volume.Size
        $free = [double]$volume.SizeRemaining
        $items.Add([pscustomobject]@{
            Drive = ([string]$volume.DriveLetter + ':')
            Label = [string]$volume.FileSystemLabel
            FileSystem = [string]$volume.FileSystem
            HealthStatus = [string]$volume.HealthStatus
            Type = $type.Type
            MediaType = $type.MediaType
            BusType = $type.BusType
            Model = $type.Model
            SizeGB = [math]::Round($size / 1GB, 2)
            FreeGB = [math]::Round($free / 1GB, 2)
            FreePercent = if ($size -gt 0) { [math]::Round(($free / $size) * 100, 1) } else { 0 }
        })
    }
    return @($items | Sort-Object Drive)
}

function Get-CleanupFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7,
        [string]$Filter = '*'
    )

    if (-not (Test-SafeCleanupPath -Path $Root) -or -not (Test-Path -LiteralPath $Root)) { return @() }
    $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)
    $files = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push((ConvertTo-NormalizedFullPath $Root))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) {
                if (Test-SafeCleanupPath -Path $item.FullName) { $pending.Push($item.FullName) }
            }
            elseif ($item.Name -like $Filter -and $item.LastWriteTime -lt $cutoff -and
                (Test-SafeCleanupPath -Path $item.FullName)) { $files.Add($item) }
        }
    }
    return $files.ToArray()
}

function Get-SafeCleanupEstimate {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7,
        [ValidateSet('UserTemp', 'WindowsTemp', 'DirectXCache', 'Thumbnails', 'UserWER', 'MachineWERArchive', 'MachineWERQueue')]
        [string[]]$Categories
    )

    $definitions = @(
        [pscustomobject]@{ Id = 'UserTemp'; Name = 'Temporarios do usuario'; Root = $env:TEMP; Age = $MinimumAgeDays; Filter = '*' },
        [pscustomobject]@{ Id = 'WindowsTemp'; Name = 'Temporarios do Windows'; Root = (Join-Path $env:WINDIR 'Temp'); Age = $MinimumAgeDays; Filter = '*' },
        [pscustomobject]@{ Id = 'DirectXCache'; Name = 'Cache de shaders DirectX'; Root = (Join-Path $env:LOCALAPPDATA 'D3DSCache'); Age = 0; Filter = '*' },
        [pscustomobject]@{ Id = 'Thumbnails'; Name = 'Cache de miniaturas'; Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Age = 0; Filter = 'thumbcache_*.db' },
        [pscustomobject]@{ Id = 'UserWER'; Name = 'Relatorios de erro do usuario'; Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER'); Age = 30; Filter = '*' },
        [pscustomobject]@{ Id = 'MachineWERArchive'; Name = 'Relatorios de erro arquivados'; Root = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Age = 30; Filter = '*' },
        [pscustomobject]@{ Id = 'MachineWERQueue'; Name = 'Relatorios de erro em fila'; Root = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'); Age = 30; Filter = '*' }
    )
    if ($Categories -and $Categories.Count -gt 0) {
        $definitions = @($definitions | Where-Object { $_.Id -in $Categories })
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($definition in $definitions) {
        $files = @(Get-CleanupFiles -Root $definition.Root -MinimumAgeDays $definition.Age -Filter $definition.Filter)
        $bytes = if ($files.Count -gt 0) { [double](($files | Measure-Object -Property Length -Sum).Sum) } else { [double]0 }
        $result.Add([pscustomobject]@{
            Id = $definition.Id; Name = $definition.Name; Root = $definition.Root
            FileCount = $files.Count; Bytes = [int64]$bytes; SizeMB = [math]::Round($bytes / 1MB, 2)
            Reversible = $false
        })
    }
    return $result.ToArray()
}

function Remove-SafeCleanupFiles {
    param([object[]]$Files, [string]$Category)

    $deleted = 0
    $bytes = [int64]0
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($Files)) {
        if (Test-OptimizerCancellation) { break }
        if (-not (Test-SafeCleanupPath -Path $file.FullName)) {
            $errors.Add("Caminho bloqueado: $($file.FullName)")
            continue
        }
        try {
            if (-not (Get-OptimizerContext).Simulation) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
            $deleted++
            $bytes += [int64]$file.Length
        }
        catch { $errors.Add("$($file.FullName): $($_.Exception.Message)") }
    }
    return [pscustomobject]@{ Category = $Category; DeletedFiles = $deleted; DeletedBytes = $bytes; Errors = $errors.ToArray() }
}

function Invoke-SafeCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('UserTemp', 'WindowsTemp', 'DirectXCache', 'Thumbnails', 'UserWER', 'MachineWERArchive', 'MachineWERQueue')]
        [string[]]$Categories,
        [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { throw 'A limpeza e irreversivel e exige confirmacao explicita.' }
    $requiresAdmin = @($Categories | Where-Object { $_ -in @('WindowsTemp', 'MachineWERArchive', 'MachineWERQueue') }).Count -gt 0
    return Invoke-OptimizerOperation -Name 'Limpeza segura de arquivos temporarios' -Risk 'Moderado' `
        -RequiresAdministrator:$requiresAdmin -ScriptBlock {
        $map = @{
            UserTemp = @{ Root = $env:TEMP; Age = $MinimumAgeDays; Filter = '*' }
            WindowsTemp = @{ Root = (Join-Path $env:WINDIR 'Temp'); Age = $MinimumAgeDays; Filter = '*' }
            DirectXCache = @{ Root = (Join-Path $env:LOCALAPPDATA 'D3DSCache'); Age = 0; Filter = '*' }
            Thumbnails = @{ Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Age = 0; Filter = 'thumbcache_*.db' }
            UserWER = @{ Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER'); Age = 30; Filter = '*' }
            MachineWERArchive = @{ Root = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Age = 30; Filter = '*' }
            MachineWERQueue = @{ Root = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'); Age = 30; Filter = '*' }
        }
        $results = New-Object System.Collections.Generic.List[object]
        foreach ($category in $Categories) {
            $definition = $map[$category]
            $files = @(Get-CleanupFiles -Root $definition.Root -MinimumAgeDays $definition.Age -Filter $definition.Filter)
            $estimate = if ($files.Count -gt 0) { [int64](($files | Measure-Object Length -Sum).Sum) } else { [int64]0 }
            if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
                Add-OptimizerBackupEntry -Type 'Irreversible' -Id "Cleanup:$category" `
                    -Original ([pscustomobject]@{ Files = $files.Count; Bytes = $estimate }) `
                    -Applied ([pscustomobject]@{ Deleted = $true }) `
                    -Metadata @{ Reason = 'Caches/temporarios nao podem ser restaurados' } | Out-Null
            }
            $results.Add((Remove-SafeCleanupFiles -Files $files -Category $category))
        }
        $totalBytes = if ($results.Count -gt 0) { [int64](($results.ToArray() | Measure-Object DeletedBytes -Sum).Sum) } else { [int64]0 }
        Write-OptimizerLog -Name 'Limpeza de temporarios e caches' -Category 'Armazenamento' `
            -OldValue '' -NewValue @{ Categories = $Categories; DeletedBytes = $totalBytes } `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) | Out-Null
        return $results.ToArray()
    }
}

function Clear-RecycleBinSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter, [switch]$Confirmed)

    if (-not $Confirmed) { throw 'Esvaziar a Lixeira e irreversivel e exige confirmacao.' }
    return Invoke-OptimizerOperation -Name "Esvaziar Lixeira de $DriveLetter`:" -Risk 'Agressivo' -ScriptBlock {
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'Irreversible' -Id "RecycleBin:$DriveLetter" -Original @{} `
                -Applied @{ Cleared = $true } -Metadata @{ Reason = 'Lixeira nao e restauravel pelo aplicativo' } | Out-Null
        }
        if (-not (Get-OptimizerContext).Simulation) { Clear-RecycleBin -DriveLetter $DriveLetter -Force -ErrorAction Stop }
        return [pscustomobject]@{ Drive = "$DriveLetter`:"; Cleared = $true }
    }
}

function Invoke-VolumeOptimizationSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter)

    $inventory = @(Get-StorageInventory | Where-Object Drive -eq "$DriveLetter`:")
    if (-not $inventory) { throw 'Volume nao encontrado.' }
    $volume = $inventory[0]
    if ($volume.Type -eq 'Desconhecido') { throw 'Tipo de midia desconhecido; a otimizacao foi bloqueada.' }
    return Invoke-OptimizerOperation -Name "Otimizar volume $DriveLetter`: ($($volume.Type))" `
        -Risk 'Moderado' -RequiresAdministrator -ScriptBlock {
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'Irreversible' -Id "OptimizeVolume:$DriveLetter" -Original @{ Type = $volume.Type } `
                -Applied @{ Optimized = $true } -Metadata @{ Reason = 'TRIM/desfragmentacao nao possui undo' } | Out-Null
        }
        if (-not (Get-OptimizerContext).Simulation) {
            if ($volume.Type -in @('SSD', 'NVMe')) {
                Optimize-Volume -DriveLetter $DriveLetter -ReTrim -Verbose -ErrorAction Stop | Out-Null
            }
            elseif ($volume.Type -eq 'HDD') {
                Optimize-Volume -DriveLetter $DriveLetter -Defrag -Verbose -ErrorAction Stop | Out-Null
            }
        }
        return [pscustomobject]@{ Drive = "$DriveLetter`:"; Type = $volume.Type; Method = if ($volume.Type -eq 'HDD') { 'Defrag' } else { 'ReTrim' } }
    }
}

function Invoke-ComponentCleanupSafe {
    [CmdletBinding()]
    param([switch]$Confirmed)

    if (-not $Confirmed) { throw 'A limpeza de componentes substituidos e irreversivel e exige confirmacao.' }
    return Invoke-OptimizerOperation -Name 'Limpeza de componentes obsoletos' -Risk 'Agressivo' `
        -RequiresAdministrator -ScriptBlock {
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'Irreversible' -Id 'DISM:StartComponentCleanup' -Original @{} `
                -Applied @{ Completed = $true } -Metadata @{ Reason = 'Componentes substituidos removidos nao sao restauraveis'; ResetBase = $false } | Out-Null
        }
        Invoke-SafeNativeCommand -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup') `
            -Description 'DISM StartComponentCleanup' -RequiresAdministrator -Mutating | Out-Null
        return [pscustomobject]@{ Completed = $true; ResetBaseUsed = $false }
    }
}

function Get-IntegrityStatePath {
    return Join-Path (Get-OptimizerContext).StateRoot 'integrity-status.json'
}

function Get-IntegrityCommandInterpretation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SFC', 'DISM')][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)]$CommandResult
    )

    $text = @($CommandResult.Output) -join "`n"
    $healthy = $null
    $outcome = 'Unknown'
    $evidence = 'A saida localizada nao correspondeu a uma regra conservadora.'
    if ($Tool -eq 'SFC') {
        if ($Mode -eq 'ScanNow' -and $text -match '(?i)(found corrupt files and successfully repaired them|encontrou arquivos corrompidos.*reparou.*(sucesso|\u00eaxito))') {
            $outcome = 'RepairedNeedsVerification'; $evidence = 'SFC informou reparo; execute nova verificacao antes de considerar saudavel.'
        }
        elseif ($text -match '(?i)(did not find any integrity violations|n\u00e3o encontrou nenhuma viola\u00e7\u00e3o de integridade)') {
            $healthy = $true; $outcome = 'Healthy'; $evidence = 'SFC: nenhuma violacao de integridade.'
        }
        elseif ($text -match '(?i)(found corrupt files|encontrou arquivos corrompidos|encontrou ficheiros danificados)') {
            $healthy = $false; $outcome = 'CorruptionDetected'; $evidence = 'SFC: arquivos corrompidos foram informados.'
        }
        elseif ($text -match '(?i)(could not perform the requested operation|n\u00e3o p\u00f4de executar a opera\u00e7\u00e3o solicitada)') {
            $outcome = 'Incomplete'; $evidence = 'SFC nao concluiu a verificacao.'
        }
    }
    else {
        if ($text -match '(?i)(no component store corruption detected|nenhuma corrup\u00e7\u00e3o.*reposit\u00f3rio de componentes|reposit\u00f3rio de componentes n\u00e3o.*corrompido)') {
            $healthy = $true; $outcome = 'Healthy'; $evidence = 'DISM: nenhuma corrupcao do repositorio detectada.'
        }
        elseif ($Mode -eq 'RestoreHealth' -and $text -match '(?i)(restore operation completed successfully|opera\u00e7\u00e3o de restaura\u00e7\u00e3o.*conclu\u00edda.*(sucesso|\u00eaxito))') {
            $outcome = 'RepairedNeedsVerification'; $evidence = 'DISM informou reparo; execute ScanHealth antes de considerar saudavel.'
        }
        elseif ($text -match '(?i)(component store is repairable|component store is corrupted|reposit\u00f3rio de componentes.*(repar|corromp)|corrup\u00e7\u00e3o.*reposit\u00f3rio de componentes)') {
            $healthy = $false; $outcome = 'CorruptionDetected'; $evidence = 'DISM: corrupcao ou estado reparavel informado.'
        }
    }
    return [pscustomobject]@{
        Healthy = $healthy; Outcome = $outcome; Evidence = $evidence
        ExitCode = [int]$CommandResult.ExitCode; Simulated = [bool]$CommandResult.Simulated
    }
}

function Save-IntegrityCheckState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SFC', 'DISM')][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)]$Interpretation
    )

    $context = Get-OptimizerContext
    if ([bool]$context.Simulation -or [bool]$context.ReadOnly -or [bool]$Interpretation.Simulated) { return }
    $path = Get-IntegrityStatePath
    $checks = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($raw.Checks) {
                foreach ($property in $raw.Checks.PSObject.Properties) { $checks[$property.Name] = $property.Value }
            }
        }
        catch { $checks = @{} }
    }
    $checks[$Tool] = [ordered]@{
        Tool = $Tool; Mode = $Mode; CheckedAtUtc = [datetime]::UtcNow.ToString('o')
        Healthy = $Interpretation.Healthy; Outcome = [string]$Interpretation.Outcome
        Evidence = [string]$Interpretation.Evidence; ExitCode = [int]$Interpretation.ExitCode
    }
    Save-OptimizerJsonFile -Path $path -InputObject ([ordered]@{ SchemaVersion = 1; Checks = $checks }) | Out-Null
}

function Get-IntegrityAssessmentFromChecks {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Checks = @(),
        [datetime]$NowUtc = ([datetime]::UtcNow),
        [ValidateRange(1, 3650)][int]$ValidityDays = 30
    )

    $summaries = New-Object System.Collections.Generic.List[object]
    foreach ($check in @($Checks)) {
        $timestamp = [datetime]::MinValue
        $validTimestamp = [datetime]::TryParse([string]$check.CheckedAtUtc, [ref]$timestamp)
        if ($validTimestamp) { $timestamp = $timestamp.ToUniversalTime() }
        $ageDays = if ($validTimestamp) { ($NowUtc.ToUniversalTime() - $timestamp).TotalDays } else { [double]::PositiveInfinity }
        $healthyProperty = $check.PSObject.Properties['Healthy']
        $healthy = if ($healthyProperty) { $healthyProperty.Value } else { $null }
        $summaries.Add([pscustomobject]@{
            Tool = [string]$check.Tool; Mode = [string]$check.Mode; CheckedAtUtc = [string]$check.CheckedAtUtc
            Healthy = $healthy; Outcome = [string]$check.Outcome; Evidence = [string]$check.Evidence
            ExitCode = [int]$check.ExitCode
            AgeDays = $(if ($validTimestamp) { [math]::Round($ageDays, 2) } else { $null })
            IsFresh = ($validTimestamp -and $ageDays -ge -0.01 -and $ageDays -le $ValidityDays)
        })
    }
    $all = @($summaries | Sort-Object CheckedAtUtc -Descending)
    $fresh = @($all | Where-Object IsFresh)
    $freshFalse = @($fresh | Where-Object { $null -ne $_.Healthy -and -not [bool]$_.Healthy })
    $freshUnknown = @($fresh | Where-Object { $null -eq $_.Healthy })
    $healthy = $null
    $reason = ''
    $source = $null
    if ($freshFalse.Count -gt 0) {
        $healthy = $false; $source = $freshFalse[0]
        $reason = 'Uma verificacao vigente informou corrupcao ou estado reparavel.'
    }
    elseif ($fresh.Count -eq 0) {
        $reason = if ($all.Count -gt 0) { "Resultados anteriores expiraram apos $ValidityDays dias." } else { 'Nenhuma verificacao registrada.' }
    }
    elseif ($freshUnknown.Count -gt 0) {
        $source = $freshUnknown[0]
        $reason = 'A verificacao vigente mais recente foi inconclusiva ou exige nova verificacao apos reparo.'
    }
    else {
        $healthy = $true; $source = $fresh[0]
    }
    return [pscustomobject]@{
        Healthy = $healthy; Reason = $reason; AssessmentSource = $source
        LastCheck = $(if ($all.Count -gt 0) { $all[0] } else { $null })
        Checks = $all; FreshCount = $fresh.Count; StaleCount = @($all | Where-Object { -not $_.IsFresh }).Count
        ValidityDays = $ValidityDays
    }
}

function Get-IntegrityCheckState {
    [CmdletBinding()]
    param()

    $path = Get-IntegrityStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Available = $false; Healthy = $null; LastCheck = $null; Checks = @(); Reason = 'Nenhuma verificacao registrada.' }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $checks = @($raw.Checks.PSObject.Properties | ForEach-Object { $_.Value })
        $assessment = Get-IntegrityAssessmentFromChecks -Checks $checks -ValidityDays 30
        return [pscustomobject]@{
            Available = $true; Healthy = $assessment.Healthy
            LastCheck = $assessment.LastCheck; AssessmentSource = $assessment.AssessmentSource
            Checks = $assessment.Checks; Reason = $assessment.Reason
            FreshCount = $assessment.FreshCount; StaleCount = $assessment.StaleCount
            ValidityDays = $assessment.ValidityDays
        }
    }
    catch {
        return [pscustomobject]@{ Available = $false; Healthy = $null; LastCheck = $null; Checks = @(); Reason = $_.Exception.Message }
    }
}

function Invoke-SystemFileCheck {
    [CmdletBinding()]
    param([ValidateSet('VerifyOnly', 'ScanNow')][string]$Mode = 'VerifyOnly')

    $arguments = if ($Mode -eq 'VerifyOnly') { @('/verifyonly') } else { @('/scannow') }
    return Invoke-OptimizerOperation -Name "SFC $Mode" -Risk $(if ($Mode -eq 'ScanNow') { 'Moderado' } else { 'Seguro' }) `
        -RequiresAdministrator -ScriptBlock {
        if ($Mode -eq 'ScanNow' -and (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue)) {
            Add-OptimizerBackupEntry -Type 'Irreversible' -Id 'SFC:ScanNow' -Original @{} -Applied @{ RepairAttempted = $true } `
                -Metadata @{ Reason = 'Reparos SFC nao possuem undo item a item' } | Out-Null
        }
        $commandResult = Invoke-SafeNativeCommand -FilePath 'sfc.exe' -ArgumentList $arguments -Description "SFC $Mode" `
            -RequiresAdministrator -Mutating:($Mode -eq 'ScanNow') -SuccessExitCodes @(0, 1, 2, 3)
        $interpretation = Get-IntegrityCommandInterpretation -Tool SFC -Mode $Mode -CommandResult $commandResult
        Save-IntegrityCheckState -Tool SFC -Mode $Mode -Interpretation $interpretation
        return [pscustomobject]@{ Command = $commandResult; Integrity = $interpretation }
    }
}

function Invoke-DismHealthCheck {
    [CmdletBinding()]
    param(
        [ValidateSet('CheckHealth', 'ScanHealth', 'RestoreHealth')][string]$Mode = 'ScanHealth',
        [string]$Source,
        [switch]$Confirmed
    )

    if ($Mode -eq 'RestoreHealth') {
        if (-not $Confirmed) { throw 'DISM RestoreHealth exige confirmacao explicita.' }
        if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
            throw 'Para manter a operacao offline, RestoreHealth exige uma fonte local valida.'
        }
    }
    $arguments = @('/Online', '/Cleanup-Image', "/$Mode")
    if ($Mode -eq 'RestoreHealth') { $arguments += "/Source:$Source"; $arguments += '/LimitAccess' }
    return Invoke-OptimizerOperation -Name "DISM $Mode" -Risk $(if ($Mode -eq 'RestoreHealth') { 'Moderado' } else { 'Seguro' }) `
        -RequiresAdministrator -ScriptBlock {
        if ($Mode -eq 'RestoreHealth' -and (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue)) {
            Add-OptimizerBackupEntry -Type 'Irreversible' -Id 'DISM:RestoreHealth' -Original @{} `
                -Applied @{ RepairAttempted = $true; Source = $Source } -Metadata @{ Reason = 'Reparos DISM nao possuem undo item a item' } | Out-Null
        }
        $commandResult = Invoke-SafeNativeCommand -FilePath 'dism.exe' -ArgumentList $arguments -Description "DISM $Mode" `
            -RequiresAdministrator -Mutating:($Mode -eq 'RestoreHealth') -SuccessExitCodes @(0)
        $interpretation = Get-IntegrityCommandInterpretation -Tool DISM -Mode $Mode -CommandResult $commandResult
        Save-IntegrityCheckState -Tool DISM -Mode $Mode -Interpretation $interpretation
        return [pscustomobject]@{ Command = $commandResult; Integrity = $interpretation }
    }
}

function Invoke-DiskScan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter)

    return Invoke-SafeNativeCommand -FilePath 'chkdsk.exe' -ArgumentList @("$DriveLetter`:", '/scan') `
        -Description "CHKDSK /scan $DriveLetter`:" -RequiresAdministrator -SuccessExitCodes @(0, 1, 2, 3)
}

Export-ModuleMember -Function Get-StorageInventory, Test-SafeCleanupPath, Get-SafeCleanupEstimate,
    Invoke-SafeCleanup, Clear-RecycleBinSafe, Invoke-VolumeOptimizationSafe,
    Invoke-ComponentCleanupSafe, Get-IntegrityCheckState, Invoke-SystemFileCheck,
    Invoke-DismHealthCheck, Invoke-DiskScan
