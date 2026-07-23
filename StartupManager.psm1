#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-StartupRegistryLocations {
    return @(
        [pscustomobject]@{ Scope = 'Usuario'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; RequiresAdmin = $false },
        [pscustomobject]@{ Scope = 'Computador'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; RequiresAdmin = $true },
        [pscustomobject]@{ Scope = 'Computador 32-bit'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; RequiresAdmin = $true }
    )
}

function ConvertTo-StartupId {
    param([string]$SourceType, [string]$Location, [string]$Name)
    $raw = "$SourceType|$Location|$Name"
    $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Resolve-StartupExecutable {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Command, [string]$ShortcutPath)

    if ($ShortcutPath -and [IO.Path]::GetExtension($ShortcutPath) -ieq '.lnk') {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($ShortcutPath)
            return [Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath)
        }
        catch { return '' }
    }
    if (-not $Command) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($expanded -match '^\s*"([^"]+\.exe)"') { return $matches[1] }
    if ($expanded -match '^\s*([^\s]+\.exe)') { return $matches[1] }
    return ''
}

function Get-StartupPublisher {
    param([string]$ExecutablePath)
    if (-not $ExecutablePath -or -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) { return '' }
    try { return [Diagnostics.FileVersionInfo]::GetVersionInfo($ExecutablePath).CompanyName }
    catch { return '' }
}

function Test-ProtectedStartupItem {
    param([string]$Name, [string]$Command, [string]$ExecutablePath, [string]$Publisher)
    $joined = "$Name $Command $ExecutablePath $Publisher"
    if ($joined -match '(?i)(SecurityHealthSystray|WindowsDefender|MSASCuiL|Windows Security)') { return $true }
    if (Get-Command Test-ProtectedProcessMetadata -ErrorAction SilentlyContinue) {
        return Test-ProtectedProcessMetadata -Name $Name -Description $Command -Company $Publisher -Path $ExecutablePath
    }
    foreach ($pattern in @((Get-OptimizerContext).Config.Safety.ProtectedProcessPatterns)) {
        try { if ($joined -match [string]$pattern) { return $true } } catch { }
    }
    return $false
}

function Get-StartupImpactEstimate {
    param([string]$Name, [string]$Command, [bool]$Protected)
    if ($Protected) { return 'Sistema/protegido' }
    $joined = "$Name $Command"
    if ($joined -match '(?i)(update|updater|launcher|helper|assistant|tray)') { return 'Medio (heuristica)' }
    return 'Desconhecido'
}

function Get-DisabledStartupState {
    $path = Join-Path (Get-OptimizerContext).StateRoot 'startup-disabled.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { return @() }
}

function Save-DisabledStartupState {
    param([object[]]$Items)
    $path = Join-Path (Get-OptimizerContext).StateRoot 'startup-disabled.json'
    if (-not (Get-OptimizerContext).Simulation) {
        if (@($Items).Count -eq 0) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
            return
        }
        Save-OptimizerJsonFile -Path $path -InputObject @($Items) | Out-Null
    }
}

function Update-DisabledStartupStateForRestoredBackupEntry {
    <# Funcao pura: remove somente o registro correspondente ao item restaurado. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)]$Entry
    )

    $type = [string]$Entry.Type
    if ($type -notin @('StartupRegistry', 'StartupFile')) {
        throw "Tipo de backup de inicializacao invalido: $type"
    }
    $id = [string]$Entry.Id
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Entrada de inicializacao sem identificador.' }
    return @($Items | Where-Object { [string]$_.Id -ne $id })
}

function Sync-StartupStateAfterBackupRestore {
    <#
        Chamado pelo BackupManager somente depois de Restored/AlreadyRestored.
        Assim, uma restauracao generica nao deixa o item aparecendo como desativado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Restored', 'AlreadyRestored')][string]$Status
    )

    $items = @(Get-DisabledStartupState)
    $remaining = @(Update-DisabledStartupStateForRestoredBackupEntry -Items $items -Entry $Entry)
    if ($remaining.Count -eq $items.Count) {
        return [pscustomobject]@{ Changed = $false; Status = $Status; Id = [string]$Entry.Id }
    }
    Save-DisabledStartupState -Items $remaining
    return [pscustomobject]@{ Changed = $true; Status = $Status; Id = [string]$Entry.Id }
}

function Get-StartupItems {
    [CmdletBinding()]
    param([switch]$IncludeDisabled)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($location in Get-StartupRegistryLocations) {
        if (-not (Test-Path -LiteralPath $location.Path)) { continue }
        $key = Get-Item -LiteralPath $location.Path -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        foreach ($name in @($key.GetValueNames())) {
            if (-not $name) { continue }
            $command = [string]$key.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $executable = Resolve-StartupExecutable -Command $command
            $publisher = Get-StartupPublisher $executable
            $protected = Test-ProtectedStartupItem -Name $name -Command $command -ExecutablePath $executable -Publisher $publisher
            $items.Add([pscustomobject]@{
                Id = ConvertTo-StartupId 'Registry' $location.Path $name
                Name = $name; SourceType = 'Registry'; Scope = $location.Scope; Location = $location.Path
                Command = $command; ExecutablePath = $executable; Publisher = $publisher
                Impact = Get-StartupImpactEstimate $name $command $protected
                IsEnabled = $true; IsProtected = $protected; RequiresAdmin = [bool]$location.RequiresAdmin
            })
        }
    }

    $folders = @(
        [pscustomobject]@{ Scope = 'Usuario'; Path = [Environment]::GetFolderPath('Startup'); RequiresAdmin = $false },
        [pscustomobject]@{ Scope = 'Todos os usuarios'; Path = [Environment]::GetFolderPath('CommonStartup'); RequiresAdmin = $true }
    )
    foreach ($folder in $folders) {
        if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -File -ErrorAction SilentlyContinue)) {
            $executable = Resolve-StartupExecutable -Command '' -ShortcutPath $file.FullName
            $publisher = Get-StartupPublisher $executable
            $protected = Test-ProtectedStartupItem -Name $file.BaseName -Command $file.FullName -ExecutablePath $executable -Publisher $publisher
            $items.Add([pscustomobject]@{
                Id = ConvertTo-StartupId 'StartupFolder' $folder.Path $file.Name
                Name = $file.BaseName; SourceType = 'StartupFolder'; Scope = $folder.Scope; Location = $folder.Path
                Command = $file.FullName; ExecutablePath = $executable; Publisher = $publisher
                Impact = Get-StartupImpactEstimate $file.BaseName $file.FullName $protected
                IsEnabled = $true; IsProtected = $protected; RequiresAdmin = [bool]$folder.RequiresAdmin
            })
        }
    }

    if ($IncludeDisabled) {
        foreach ($disabled in @(Get-DisabledStartupState)) {
            $items.Add([pscustomobject]@{
                Id = [string]$disabled.Id; Name = [string]$disabled.Name; SourceType = [string]$disabled.SourceType
                Scope = [string]$disabled.Scope; Location = [string]$disabled.Location
                Command = [string]$disabled.Command; ExecutablePath = [string]$disabled.ExecutablePath
                Publisher = [string]$disabled.Publisher; Impact = [string]$disabled.Impact
                IsEnabled = $false; IsProtected = $false; RequiresAdmin = [bool]$disabled.RequiresAdmin
            })
        }
    }
    return @($items | Sort-Object -Property @{ Expression = 'IsEnabled'; Descending = $true }, Name)
}

function Disable-StartupItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)

    $item = @(Get-StartupItems | Where-Object Id -eq $Id | Select-Object -First 1)
    if (-not $item) { throw 'Item de inicializacao nao encontrado ou ja desativado.' }
    $item = $item[0]
    if ($item.IsProtected) { throw 'Este item pertence a lista protegida do sistema.' }
    return Invoke-OptimizerOperation -Name "Desativar inicializacao: $($item.Name)" -Risk 'Moderado' `
        -RequiresAdministrator:$item.RequiresAdmin -ScriptBlock {
        $disabledItems = New-Object System.Collections.Generic.List[object]
        foreach ($existing in @(Get-DisabledStartupState)) { $disabledItems.Add($existing) }
        if ($item.SourceType -eq 'Registry') {
            Assert-SafeRegistryPath -Path $item.Location
            $before = Get-RegistryValueState -Path $item.Location -Name $item.Name
            if (-not $before.ValueExisted) { throw 'O valor de inicializacao nao existe mais.' }
            if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
                Add-OptimizerBackupEntry -Type 'StartupRegistry' -Id $item.Id -Original $before `
                    -Applied ([pscustomobject]@{ ValueExisted = $false }) -Metadata @{ Name = $item.Name; Scope = $item.Scope } | Out-Null
            }
            if (-not (Get-OptimizerContext).Simulation) {
                Remove-ItemProperty -LiteralPath $item.Location -Name $item.Name -Force -ErrorAction Stop
            }
            $disabledRecord = [pscustomobject]@{
                Id = $item.Id; Name = $item.Name; SourceType = $item.SourceType; Scope = $item.Scope
                Location = $item.Location; Command = $item.Command; ExecutablePath = $item.ExecutablePath
                Publisher = $item.Publisher; Impact = $item.Impact; RequiresAdmin = $item.RequiresAdmin
                Original = $before; DisabledAt = (Get-Date).ToString('o')
            }
        }
        else {
            $source = [string]$item.Command
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'O atalho de inicializacao nao existe mais.' }
            if ((Get-OptimizerContext).Simulation) {
                # A simulacao nao inicia uma transacao nem cria pastas. O destino e
                # apenas descritivo e permanece dentro da raiz gerenciada de backup.
                $targetFolder = Join-Path (Get-OptimizerContext).BackupRoot 'simulation-startup-files'
                $target = Join-Path $targetFolder (([guid]::NewGuid().ToString('N')) + [IO.Path]::GetExtension($source))
            }
            else {
                $backup = Get-CurrentOptimizerBackup
                if (-not $backup) { throw 'Nao ha transacao de backup ativa.' }
                $targetFolder = Join-Path $backup.FolderPath 'startup-files'
                if (-not (Test-Path -LiteralPath $targetFolder)) { New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null }
                $target = Join-Path $targetFolder (([guid]::NewGuid().ToString('N')) + [IO.Path]::GetExtension($source))
            }
            if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
                Add-OptimizerBackupEntry -Type 'StartupFile' -Id $item.Id `
                    -Original ([pscustomobject]@{ Path = $source; Exists = $true }) `
                    -Applied ([pscustomobject]@{ Path = $target; Exists = $true }) `
                    -Metadata @{ Name = $item.Name; Scope = $item.Scope } | Out-Null
            }
            if (-not (Get-OptimizerContext).Simulation) { Move-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop }
            $disabledRecord = [pscustomobject]@{
                Id = $item.Id; Name = $item.Name; SourceType = $item.SourceType; Scope = $item.Scope
                Location = $item.Location; Command = $item.Command; ExecutablePath = $item.ExecutablePath
                Publisher = $item.Publisher; Impact = $item.Impact; RequiresAdmin = $item.RequiresAdmin
                OriginalPath = $source; BackupPath = $target; DisabledAt = (Get-Date).ToString('o')
            }
        }
        $disabledItems.Add($disabledRecord)
        Save-DisabledStartupState -Items $disabledItems.ToArray()
        Write-OptimizerLog -Name "Desativar startup $($item.Name)" -Category 'Inicializacao' `
            -OldValue 'Enabled' -NewValue 'Disabled' -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) | Out-Null
        return [pscustomobject]@{ Id = $item.Id; Name = $item.Name; Changed = $true }
    }
}

function Restore-StartupItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$Force)

    $allDisabled = @(Get-DisabledStartupState)
    $record = @($allDisabled | Where-Object Id -eq $Id | Select-Object -First 1)
    if (-not $record) { return [pscustomobject]@{ Status = 'NoChange'; Id = $Id } }
    $record = $record[0]
    Assert-OptimizerMutationAllowed -RequiresAdministrator:$record.RequiresAdmin -Operation 'Restaurar inicializacao' | Out-Null
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]@{ Status = 'Simulated'; Id = $Id } }

    if ($record.SourceType -eq 'Registry') {
        $original = $record.Original
        $current = Get-RegistryValueState -Path $original.Path -Name $original.Name
        if ($current.ValueExisted -and -not $Force) {
            if ((Compare-OptimizerValue $current.Value $original.Value) -and $current.Kind -eq $original.Kind) {
                $status = 'NoChange'
            }
            else { return [pscustomobject]@{ Status = 'Conflict'; Id = $Id; Current = $current; Original = $original } }
        }
        else {
            if (-not (Test-Path -LiteralPath $original.Path)) { New-Item -Path $original.Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $original.Path -Name $original.Name -Value $original.Value `
                -PropertyType $original.Kind -Force -ErrorAction Stop | Out-Null
            $status = 'Restored'
        }
    }
    else {
        if (Test-Path -LiteralPath $record.OriginalPath) {
            if (-not $Force) { return [pscustomobject]@{ Status = 'Conflict'; Id = $Id; Reason = 'O caminho original ja existe.' } }
        }
        if (-not (Test-Path -LiteralPath $record.BackupPath -PathType Leaf)) {
            return [pscustomobject]@{ Status = 'Failed'; Id = $Id; Reason = 'Arquivo de backup nao encontrado.' }
        }
        Move-Item -LiteralPath $record.BackupPath -Destination $record.OriginalPath -Force:$Force -ErrorAction Stop
        $status = 'Restored'
    }
    Save-DisabledStartupState -Items @($allDisabled | Where-Object Id -ne $Id)
    Write-OptimizerLog -Name "Restaurar startup $($record.Name)" -Category 'Inicializacao' `
        -OldValue 'Disabled' -NewValue 'Enabled' -Result 'Restored' | Out-Null
    return [pscustomobject]@{ Status = $status; Id = $Id; Name = $record.Name }
}

function Restore-AllStartupItems {
    [CmdletBinding()]
    param([switch]$Force)
    $results = foreach ($record in @(Get-DisabledStartupState)) {
        try { Restore-StartupItem -Id $record.Id -Force:$Force }
        catch { [pscustomobject]@{ Status = 'Failed'; Id = $record.Id; Error = $_.Exception.Message } }
    }
    return @($results)
}

function Restore-StartupRegistryBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)
    return Restore-StartupItem -Id ([string]$Entry.Id) -Force:$Force
}

function Restore-StartupFileBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)
    return Restore-StartupItem -Id ([string]$Entry.Id) -Force:$Force
}

Export-ModuleMember -Function Get-StartupItems, Disable-StartupItem, Restore-StartupItem,
    Restore-AllStartupItems, Restore-StartupRegistryBackupEntry, Restore-StartupFileBackupEntry,
    Get-DisabledStartupState, Sync-StartupStateAfterBackupRestore
