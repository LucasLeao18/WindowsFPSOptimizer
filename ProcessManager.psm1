#requires -Version 5.1

Set-StrictMode -Version Latest

function Assert-ProcessBackupTransaction {
    <#
        Toda alteracao real deste modulo deve ocorrer dentro da transacao aberta por
        Invoke-OptimizerOperation. A simulacao nao grava backup porque nao modifica o
        Windows.
    #>
    [CmdletBinding()]
    param()

    if ((Get-OptimizerContext).Simulation) { return $true }
    foreach ($commandName in @('Add-OptimizerBackupEntry', 'Get-CurrentOptimizerBackup')) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "BackupManager nao esta carregado; alteracao bloqueada ($commandName ausente)."
        }
    }
    if (-not (Get-CurrentOptimizerBackup)) {
        throw 'Nenhuma transacao de backup esta ativa; alteracao bloqueada.'
    }
    return $true
}

function Add-RequiredProcessBackupEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowNull()]$Original,
        [Parameter(Mandatory = $true)][AllowNull()]$Applied,
        [hashtable]$Metadata = @{}
    )

    if ((Get-OptimizerContext).Simulation) { return }
    Assert-ProcessBackupTransaction | Out-Null
    Add-OptimizerBackupEntry -Type $Type -Id $Id -Original $Original -Applied $Applied `
        -Metadata $Metadata | Out-Null
}

function Assert-RestorablePageFileSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    if (-not [bool]$Snapshot.Available -or [string]$Snapshot.Source -ne 'CIM') {
        throw 'A configuracao completa do arquivo de paginacao nao pode ser lida por CIM; alteracao bloqueada para preservar a restauracao.'
    }
    if (-not [bool]$Snapshot.AutomaticManagedPagefile) {
        $settings = @($Snapshot.Settings)
        if ($settings.Count -eq 0) {
            throw 'O Windows informou paginacao manual, mas nenhuma configuracao original foi obtida; alteracao bloqueada.'
        }
        foreach ($setting in $settings) {
            $name = [string]$setting.Name
            $initial = [int64]$setting.InitialSizeMB
            $maximum = [int64]$setting.MaximumSizeMB
            if ($name -notmatch '^[A-Za-z]:\\pagefile\.sys$' -or $initial -lt 0 -or
                $maximum -lt $initial -or $maximum -gt [uint32]::MaxValue) {
                throw "Configuracao original de paginacao invalida ou incompleta: $name"
            }
        }
    }
    return $true
}

function Test-CustomPageFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$InitialSizeMB,
        [Parameter(Mandatory = $true)][int]$MaximumSizeMB
    )

    if (-not [bool]$State.Available -or [string]$State.Source -ne 'CIM' -or
        [bool]$State.AutomaticManagedPagefile) { return $false }
    $settings = @($State.Settings)
    if ($settings.Count -ne 1) { return $false }
    return ([string]$settings[0].Name -ieq $Path -and
        [int64]$settings[0].InitialSizeMB -eq $InitialSizeMB -and
        [int64]$settings[0].MaximumSizeMB -eq $MaximumSizeMB)
}

function Assert-PageFileFreeSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$InitialSizeMB
    )

    $root = [IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'Unidade do arquivo de paginacao invalida.' }
    $drive = New-Object IO.DriveInfo($root)
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'O arquivo de paginacao personalizado exige uma unidade local fixa e pronta.'
    }
    # Preserva no minimo 2 GiB; em discos grandes, reserva 5%, limitada a 20 GiB.
    $percentageReserve = [double]$drive.TotalSize * 0.05
    $reserveBytes = [int64][math]::Max(2GB, [math]::Min(20GB, $percentageReserve))
    $requiredBytes = ([int64]$InitialSizeMB * 1MB) + $reserveBytes
    if ([int64]$drive.AvailableFreeSpace -lt $requiredBytes) {
        $requiredGB = [math]::Round($requiredBytes / 1GB, 1)
        $availableGB = [math]::Round([double]$drive.AvailableFreeSpace / 1GB, 1)
        throw "Espaco livre insuficiente. Necessario: $requiredGB GB (incluindo reserva); disponivel: $availableGB GB."
    }
    return $true
}

function Get-ProcessSafetyConfiguration {
    $context = Get-OptimizerContext
    return @($context.Config.Safety.ProtectedProcesses)
}

function Test-ProtectedProcessMetadata {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Description,
        [string]$Company,
        [string]$Path
    )

    $baseName = if ($Name) { [IO.Path]::GetFileNameWithoutExtension($Name) } else { '' }
    if ((Get-ProcessSafetyConfiguration) -contains $baseName) { return $true }
    $context = Get-OptimizerContext
    $patterns = @()
    if ($context.Config.Safety.ContainsKey('ProtectedProcessPatterns')) {
        $patterns = @($context.Config.Safety.ProtectedProcessPatterns)
    }
    $metadata = "$baseName $Description $Company $Path"
    foreach ($pattern in $patterns) {
        try { if ($metadata -match [string]$pattern) { return $true } } catch { }
    }
    return $false
}

function Test-CriticalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [string]$Name,
        [string]$Description,
        [string]$Company,
        [string]$Path
    )

    if ($Id -in @(0, 4, $PID)) { return $true }
    if (Test-ProtectedProcessMetadata -Name $Name -Description $Description -Company $Company -Path $Path) { return $true }
    try {
        $process = Get-Process -Id $Id -ErrorAction Stop
        if ($process.SessionId -eq 0) { return $true }
        if (-not $Path) { try { $Path = [string]$process.Path } catch { } }
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            try {
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
                if (-not $Description) { $Description = [string]$version.FileDescription }
                if (-not $Company) { $Company = [string]$version.CompanyName }
            }
            catch { }
        }
        if (Test-ProtectedProcessMetadata -Name $process.ProcessName -Description $Description -Company $Company -Path $Path) { return $true }
    }
    catch { return $true }
    return $false
}

function Get-MemoryStatus {
    [CmdletBinding()]
    param()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize * 1KB
        $available = [double]$os.FreePhysicalMemory * 1KB
        $used = [math]::Max([double]0, $total - $available)
        return [pscustomobject]@{
            TotalBytes     = [int64]$total
            UsedBytes      = [int64]$used
            AvailableBytes = [int64]$available
            UsedPercent    = if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { 0 }
            TotalGB        = [math]::Round($total / 1GB, 2)
            UsedGB         = [math]::Round($used / 1GB, 2)
            AvailableGB    = [math]::Round($available / 1GB, 2)
        }
    }
    catch {
        # WMI/CIM pode ser bloqueado por politicas corporativas. ComputerInfo usa a
        # API local do Windows e mantem a tela de diagnostico funcional sem elevacao.
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
            $computerInfo = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
            $total = [double]$computerInfo.TotalPhysicalMemory
            $available = [double]$computerInfo.AvailablePhysicalMemory
            $used = [math]::Max([double]0, $total - $available)
            return [pscustomobject]@{
                TotalBytes = [int64]$total
                UsedBytes = [int64]$used
                AvailableBytes = [int64]$available
                UsedPercent = if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { 0 }
                TotalGB = [math]::Round($total / 1GB, 2)
                UsedGB = [math]::Round($used / 1GB, 2)
                AvailableGB = [math]::Round($available / 1GB, 2)
            }
        }
        catch { throw "Nao foi possivel consultar a memoria por CIM nem pela API local: $($_.Exception.Message)" }
    }
}

function Get-ProcessInventory {
    <#
        Win32_PerfFormattedData_PerfProc_Process fornece uma amostra pronta de CPU e
        I/O sem depender dos nomes localizados de Get-Counter. DiskMBps representa
        bytes de I/O por segundo do processo, nao percentual fisico do disco.
    #>
    [CmdletBinding()]
    param([string]$Search = '')

    $perfById = @{}
    try {
        Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
            Where-Object { $_.IDProcess -gt 0 } | ForEach-Object { $perfById[[int]$_.IDProcess] = $_ }
    }
    catch { }

    $cimById = @{}
    try {
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object { $cimById[[int]$_.ProcessId] = $_ }
    }
    catch { }

    $protected = Get-ProcessSafetyConfiguration
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($Search -and $process.ProcessName -notlike "*$Search*") { continue }
        $id = [int]$process.Id
        $perf = if ($perfById.ContainsKey($id)) { $perfById[$id] } else { $null }
        $cim = if ($cimById.ContainsKey($id)) { $cimById[$id] } else { $null }
        $path = $null
        $description = ''
        $company = ''
        try {
            $path = if ($cim -and $cim.ExecutablePath) { [string]$cim.ExecutablePath } else { [string]$process.Path }
            if ($path -and (Test-Path -LiteralPath $path)) {
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
                $description = [string]$version.FileDescription
                $company = [string]$version.CompanyName
            }
        }
        catch { }
        $startTime = $null
        try { $startTime = $process.StartTime.ToString('o') } catch { }
        $sessionId = -1
        try { $sessionId = [int]$process.SessionId } catch { }
        $isProtected = ($id -in @(0, 4, $PID)) -or ($protected -contains $process.ProcessName) -or `
            ($sessionId -eq 0) -or (Test-ProtectedProcessMetadata -Name $process.ProcessName `
                -Description $description -Company $company -Path $path)
        $cpu = if ($perf) { [double]$perf.PercentProcessorTime } else { 0 }
        $io = if ($perf) { [double]$perf.IODataBytesPersec } else { 0 }
        $result.Add([pscustomobject]@{
            Id             = $id
            Name           = $process.ProcessName
            Description    = $description
            Company        = $company
            Path           = $path
            CommandLine    = if ($cim) { [string]$cim.CommandLine } else { '' }
            CpuPercent     = [math]::Round($cpu, 1)
            MemoryMB       = [math]::Round(([double]$process.WorkingSet64 / 1MB), 1)
            PrivateMB      = [math]::Round(([double]$process.PrivateMemorySize64 / 1MB), 1)
            DiskMBps       = [math]::Round(($io / 1MB), 2)
            SessionId      = $sessionId
            StartTime      = $startTime
            IsProtected    = $isProtected
            ProtectionText = if ($isProtected) { 'Protegido pelo sistema/aplicativo' } else { 'Pode ser selecionado com cautela' }
        })
    }
    return @($result | Sort-Object -Property MemoryMB -Descending)
}

function Get-TopMemoryApplications {
    [CmdletBinding()]
    param([ValidateRange(1, 100)][int]$Top = 15)
    return @(Get-ProcessInventory | Sort-Object MemoryMB -Descending | Select-Object -First $Top)
}

function Get-ProcessListState {
    [CmdletBinding()]
    param()

    $path = Join-Path (Get-OptimizerContext).StateRoot 'process-lists.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Allowed = @(); CloseBeforeGame = @() }
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{ Allowed = @($state.Allowed); CloseBeforeGame = @($state.CloseBeforeGame) }
    }
    catch { return [pscustomobject]@{ Allowed = @(); CloseBeforeGame = @() } }
}

function Set-ProcessListState {
    [CmdletBinding()]
    param(
        [string[]]$Allowed = @(),
        [string[]]$CloseBeforeGame = @()
    )

    Assert-OptimizerMutationAllowed -Operation 'Salvar listas de processos' | Out-Null
    $protected = Get-ProcessSafetyConfiguration
    $allowedSafe = @($Allowed | Where-Object {
        $_ -and ($protected -notcontains [IO.Path]::GetFileNameWithoutExtension($_)) -and
        -not (Test-ProtectedProcessMetadata -Name $_)
    } | Sort-Object -Unique)
    $closeSafe = @($CloseBeforeGame | Where-Object {
        $_ -and ($protected -notcontains [IO.Path]::GetFileNameWithoutExtension($_)) -and
        -not (Test-ProtectedProcessMetadata -Name $_) -and ($allowedSafe -notcontains $_)
    } | Sort-Object -Unique)
    $state = [ordered]@{ UpdatedAt = (Get-Date).ToString('o'); Allowed = $allowedSafe; CloseBeforeGame = $closeSafe }
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]$state }
    Save-OptimizerJsonFile -Path (Join-Path (Get-OptimizerContext).StateRoot 'process-lists.json') -InputObject $state | Out-Null
    return [pscustomobject]$state
}

function Stop-SelectedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$Id,
        [string]$ExpectedStartTime,
        [switch]$AllowRestart
    )

    return Invoke-OptimizerOperation -Name "Encerrar processo $Id" -Risk 'Moderado' -ScriptBlock {
        $process = Get-Process -Id $Id -ErrorAction Stop
        if (Test-CriticalProcess -Id $Id -Name $process.ProcessName) {
            throw "O processo $($process.ProcessName) e protegido e nao pode ser encerrado."
        }
        if ($ExpectedStartTime) {
            $actual = $process.StartTime.ToString('o')
            if ($actual -ne $ExpectedStartTime) { throw 'O PID foi reutilizado; atualize a lista antes de continuar.' }
        }
        $path = $null
        try { $path = $process.Path } catch { }
        $original = [pscustomobject]@{
            Id = $Id; Name = $process.ProcessName; StartTime = $process.StartTime.ToString('o')
            Path = $path; Running = $true; AllowRestart = [bool]$AllowRestart
        }
        Add-RequiredProcessBackupEntry -Type 'Process' -Id ("{0}|{1}" -f $Id, $original.StartTime) `
            -Original $original -Applied ([pscustomobject]@{ Running = $false }) `
            -Metadata @{ Reversibility = 'BestEffort' }
        if ((Get-OptimizerContext).Simulation) {
            Write-OptimizerLog -Name "Encerrar $($process.ProcessName)" -Category 'Processos' `
                -OldValue 'Running' -NewValue 'Stopped' -Result 'Simulated' | Out-Null
            return [pscustomobject]@{ Name = $process.ProcessName; Id = $Id; Result = 'Simulated' }
        }
        Stop-Process -Id $Id -ErrorAction Stop
        Start-Sleep -Milliseconds 150
        if (Get-Process -Id $Id -ErrorAction SilentlyContinue) { throw 'O processo continuou em execucao.' }
        Write-OptimizerLog -Name "Encerrar $($process.ProcessName)" -Category 'Processos' `
            -OldValue 'Running' -NewValue 'Stopped' -Result 'Success' | Out-Null
        return [pscustomobject]@{ Name = $process.ProcessName; Id = $Id; Result = 'Success' }
    }
}

function Stop-ConfiguredGameProcesses {
    [CmdletBinding()]
    param([switch]$AllowRestart)

    $state = Get-ProcessListState
    $targets = @($state.CloseBeforeGame)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-ProcessInventory)) {
        if ($targets -contains $item.Name -and -not $item.IsProtected) {
            try { $results.Add((Stop-SelectedProcess -Id $item.Id -ExpectedStartTime $item.StartTime -AllowRestart:$AllowRestart)) }
            catch {
                $results.Add([pscustomobject]@{ Name = $item.Name; Id = $item.Id; Result = 'Error'; Error = $_.Exception.Message })
            }
        }
    }
    return $results.ToArray()
}

function Set-SelectedProcessPriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [ValidateSet('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')][string]$Priority = 'AboveNormal',
        [string]$ExpectedStartTime
    )

    return Invoke-OptimizerOperation -Name "Prioridade de processo $Id" -Risk 'Moderado' -ScriptBlock {
        $process = Get-Process -Id $Id -ErrorAction Stop
        if (Test-CriticalProcess -Id $Id -Name $process.ProcessName) { throw 'Processo protegido.' }
        if ($ExpectedStartTime -and $process.StartTime.ToString('o') -ne $ExpectedStartTime) { throw 'PID reutilizado.' }
        $before = [string]$process.PriorityClass
        if ($before -eq $Priority) { return [pscustomobject]@{ Changed = $false; Priority = $before } }
        Add-RequiredProcessBackupEntry -Type 'ProcessPriority' -Id ("{0}|{1}" -f $Id, $process.StartTime.ToString('o')) `
            -Original ([pscustomobject]@{ Id = $Id; StartTime = $process.StartTime.ToString('o'); Priority = $before }) `
            -Applied ([pscustomobject]@{ Priority = $Priority })
        if (-not (Get-OptimizerContext).Simulation) {
            $priorityValue = [Enum]::Parse([Diagnostics.ProcessPriorityClass], $Priority, $true)
            $process.PriorityClass = [Diagnostics.ProcessPriorityClass]$priorityValue
            $process.Refresh()
            if ([string]$process.PriorityClass -ne $Priority) { throw 'Nao foi possivel verificar a prioridade.' }
        }
        Write-OptimizerLog -Name "Prioridade de $($process.ProcessName)" -Category 'Processos' `
            -OldValue $before -NewValue $Priority -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) | Out-Null
        return [pscustomobject]@{ Changed = $true; Before = $before; Priority = $Priority }
    }
}

function Get-PageFileConfiguration {
    [CmdletBinding()]
    param()

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $settings = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; InitialSizeMB = [int]$_.InitialSize; MaximumSizeMB = [int]$_.MaximumSize }
        })
        $usage = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; AllocatedMB = [int]$_.AllocatedBaseSize; CurrentUsageMB = [int]$_.CurrentUsage; PeakUsageMB = [int]$_.PeakUsage }
        })
        return [pscustomobject]@{
            Available = $true
            Source = 'CIM'
            AutomaticManagedPagefile = [bool]$computer.AutomaticManagedPagefile
            Settings = $settings
            Usage = $usage
            Error = ''
        }
    }
    catch {
        # Leitura conservadora para ambientes onde WMI foi bloqueado. Ela nunca e
        # usada para gravacao: alteracoes continuam exigindo CIM e administrador.
        $cimError = $_.Exception.Message
        $settings = @()
        $automatic = $null
        try {
            $raw = @((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' `
                -Name PagingFiles -ErrorAction Stop).PagingFiles)
            $settings = @($raw | ForEach-Object {
                $parts = @(([string]$_) -split '\s+' | Where-Object { $_ })
                [pscustomobject]@{
                    Name = if ($parts.Count -gt 0) { $parts[0] } else { '' }
                    InitialSizeMB = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
                    MaximumSizeMB = if ($parts.Count -gt 2) { [int]$parts[2] } else { 0 }
                }
            })
            $automatic = ($settings.Count -eq 0 -or @($settings | Where-Object {
                ([string]$_.Name).StartsWith('?') -or ($_.InitialSizeMB -eq 0 -and $_.MaximumSizeMB -eq 0)
            }).Count -gt 0)
        }
        catch { }
        return [pscustomobject]@{
            Available = ($null -ne $automatic)
            Source = 'RegistryFallback'
            AutomaticManagedPagefile = $automatic
            Settings = $settings
            Usage = @()
            Error = $cimError
        }
    }
}

function Set-AutomaticPageFile {
    [CmdletBinding()]
    param()

    return Invoke-OptimizerOperation -Name 'Gerenciamento automatico do arquivo de paginacao' `
        -Risk 'Seguro' -RequiresAdministrator -RequiresRestart -ScriptBlock {
        $before = Get-PageFileConfiguration
        if ($before.AutomaticManagedPagefile) { return [pscustomobject]@{ Changed = $false; State = $before } }
        if (-not (Get-OptimizerContext).Simulation) {
            Assert-RestorablePageFileSnapshot -Snapshot $before | Out-Null
        }
        Add-RequiredProcessBackupEntry -Type 'PageFile' -Id 'MachinePageFile' -Original $before `
            -Applied ([pscustomobject]@{ AutomaticManagedPagefile = $true }) `
            -Metadata @{ RequiresRestart = $true }
        if (-not (Get-OptimizerContext).Simulation) {
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop | Out-Null
        }
        $after = if ((Get-OptimizerContext).Simulation) { $null } else { Get-PageFileConfiguration }
        if ($after) {
            Assert-RestorablePageFileSnapshot -Snapshot $after | Out-Null
            if (-not [bool]$after.AutomaticManagedPagefile) {
                throw 'O gerenciamento automatico nao foi confirmado apos a alteracao.'
            }
        }
        Write-OptimizerLog -Name 'Arquivo de paginacao automatico' -Category 'Memoria' `
            -OldValue $before.AutomaticManagedPagefile -NewValue $true `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) -RequiresRestart $true | Out-Null
        return [pscustomobject]@{
            Changed = $true; RequiresRestart = $true; State = $after
            Result = $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' })
        }
    }
}

function Set-CustomPageFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z]:\\pagefile\.sys$')][string]$Path,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 1048576)][int]$InitialSizeMB,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 1048576)][int]$MaximumSizeMB
    )

    if ($MaximumSizeMB -lt $InitialSizeMB) { throw 'O tamanho maximo deve ser maior ou igual ao inicial.' }
    $memory = Get-MemoryStatus
    if ($MaximumSizeMB -gt ($memory.TotalGB * 1024 * 4)) {
        throw 'O tamanho maximo excede quatro vezes a memoria fisica e foi bloqueado.'
    }
    return Invoke-OptimizerOperation -Name 'Configurar arquivo de paginacao' -Risk 'Agressivo' `
        -RequiresAdministrator -RequiresRestart -ScriptBlock {
        $before = Get-PageFileConfiguration
        if (-not (Get-OptimizerContext).Simulation) {
            Assert-RestorablePageFileSnapshot -Snapshot $before | Out-Null
        }
        if (Test-CustomPageFileState -State $before -Path $Path `
                -InitialSizeMB $InitialSizeMB -MaximumSizeMB $MaximumSizeMB) {
            return [pscustomobject]@{ Changed = $false; Result = 'Skipped'; State = $before }
        }
        Assert-PageFileFreeSpace -Path $Path -InitialSizeMB $InitialSizeMB | Out-Null
        Add-RequiredProcessBackupEntry -Type 'PageFile' -Id 'MachinePageFile' -Original $before `
            -Applied ([pscustomobject]@{ AutomaticManagedPagefile = $false; Settings = @(@{ Name = $Path; InitialSizeMB = $InitialSizeMB; MaximumSizeMB = $MaximumSizeMB }) }) `
            -Metadata @{ RequiresRestart = $true }
        if (-not (Get-OptimizerContext).Simulation) {
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop | Out-Null
            $existing = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop)
            foreach ($setting in $existing) { Remove-CimInstance -InputObject $setting -ErrorAction Stop }
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                Name = $Path; InitialSize = [uint32]$InitialSizeMB; MaximumSize = [uint32]$MaximumSizeMB
            } -ErrorAction Stop | Out-Null
        }
        $after = if ((Get-OptimizerContext).Simulation) { $null } else { Get-PageFileConfiguration }
        if ($after -and -not (Test-CustomPageFileState -State $after -Path $Path `
                -InitialSizeMB $InitialSizeMB -MaximumSizeMB $MaximumSizeMB)) {
            throw 'A configuracao personalizada nao corresponde ao estado solicitado apos a alteracao.'
        }
        Write-OptimizerLog -Name 'Arquivo de paginacao personalizado' -Category 'Memoria' `
            -OldValue $before -NewValue @{ Path = $Path; Initial = $InitialSizeMB; Maximum = $MaximumSizeMB } `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) -RequiresRestart $true | Out-Null
        return [pscustomobject]@{
            Changed = $true; RequiresRestart = $true; State = $after
            Result = $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' })
        }
    }
}

function Restore-PageFileBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    Assert-OptimizerMutationAllowed -RequiresAdministrator -Operation 'Restaurar arquivo de paginacao' | Out-Null
    $original = $Entry.Original
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]@{ Status = 'Simulated'; Type = 'PageFile' } }
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = [bool]$original.AutomaticManagedPagefile } -ErrorAction Stop | Out-Null
    if (-not [bool]$original.AutomaticManagedPagefile) {
        foreach ($setting in @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop)) {
            Remove-CimInstance -InputObject $setting -ErrorAction Stop
        }
        foreach ($setting in @($original.Settings)) {
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                Name = [string]$setting.Name
                InitialSize = [uint32]$setting.InitialSizeMB
                MaximumSize = [uint32]$setting.MaximumSizeMB
            } -ErrorAction Stop | Out-Null
        }
    }
    return [pscustomobject]@{ Status = 'Restored'; Type = 'PageFile'; RequiresRestart = $true }
}

function Restore-ProcessPriorityBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    $original = $Entry.Original
    $process = Get-Process -Id ([int]$original.Id) -ErrorAction SilentlyContinue
    if (-not $process) { return [pscustomobject]@{ Status = 'NoChange'; Reason = 'Processo encerrado' } }
    try {
        if ($process.StartTime.ToString('o') -ne [string]$original.StartTime) { return [pscustomobject]@{ Status = 'Conflict'; Reason = 'PID reutilizado' } }
        if (-not (Get-OptimizerContext).Simulation) {
            $priorityValue = [Enum]::Parse([Diagnostics.ProcessPriorityClass], [string]$original.Priority, $true)
            $process.PriorityClass = [Diagnostics.ProcessPriorityClass]$priorityValue
        }
        return [pscustomobject]@{ Status = 'Restored'; Type = 'ProcessPriority' }
    }
    catch { return [pscustomobject]@{ Status = 'Failed'; Error = $_.Exception.Message } }
}

function Restore-ProcessBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    # A restauracao de processo precisa validar hash e usar um broker confirmado
    # como nao elevado. Essas garantias pertencem ao BackupManager; este handler
    # legado nunca inicia executaveis diretamente (sobretudo com o app elevado).
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]@{ Status = 'Simulated' } }
    return [pscustomobject]@{
        Status = 'RequiresValidatedBackupManager'
        Reason = 'Use Restore-OptimizerBackup para validar manifesto, hash e integridade do processo antes do reinicio.'
    }
}

Export-ModuleMember -Function Get-MemoryStatus, Get-ProcessInventory, Get-TopMemoryApplications,
    Test-CriticalProcess, Test-ProtectedProcessMetadata, Get-ProcessListState, Set-ProcessListState, Stop-SelectedProcess,
    Stop-ConfiguredGameProcesses, Set-SelectedProcessPriority, Get-PageFileConfiguration,
    Set-AutomaticPageFile, Set-CustomPageFile, Restore-PageFileBackupEntry,
    Restore-ProcessPriorityBackupEntry, Restore-ProcessBackupEntry
