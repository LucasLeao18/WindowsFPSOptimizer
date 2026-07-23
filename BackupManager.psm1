#requires -Version 5.1

Set-StrictMode -Version Latest

$script:BackupSchemaVersion = 1
$script:CurrentBackup = $null
$script:BackupMutexName = 'Local\WindowsFPSOptimizer.Backup'
$script:MutationMutexName = 'Global\WindowsFPSOptimizer.Mutation'
$script:AllowedEntryTypes = @(
    'RegistryValue', 'Service', 'ScheduledTask', 'PowerPlan', 'PowerSetting',
    'StartupRegistry', 'StartupFile', 'PageFile', 'ProcessPriority',
    'GameSession', 'FileMove', 'SystemParameter', 'Process', 'Appx',
    'CleanupManifest', 'Irreversible'
)
$script:AllowedServicePatterns = @(
    '^Spooler$', '^Fax$', '^bthserv$', '^BluetoothUserService_[A-Za-z0-9]+$',
    '^MapsBroker$', '^lfsvc$', '^TabletInputService$', '^WbioSrvc$',
    '^RetailDemo$', '^XblAuthManager$', '^XblGameSave$', '^XboxGipSvc$',
    '^XboxNetApiSvc$', '^PrintNotify$', '^PrintWorkflowUserSvc_[A-Za-z0-9]+$',
    '^OneSyncSvc_[A-Za-z0-9]+$'
)
$script:AllowedScheduledTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\PcaPatchDbTask',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
    '\Microsoft\Windows\Maps\MapsToastTask',
    '\Microsoft\Windows\Maps\MapsUpdateTask'
)
$script:BlockedRegistryPattern = '(?i)(\\Tcpip6?(\\|$)|\\Winsock|\\Dnscache|\\NetworkList|\\NetworkProvider|\\Internet Settings|\\FirewallPolicy|\\QoS|\\Teredo|\\WcmSvc|\\NlaSvc)'
$script:AllowedRegistryEntries = @(
    'HKCU:\Software\Microsoft\GameBar|AutoGameModeEnabled',
    'HKLM:\Software\Policies\Microsoft\Windows\GameDVR|AllowGameDVR',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|EnableTransparency',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer|DisableThumbnails',
    'HKCU:\Software\Policies\Microsoft\Windows\CloudContent|DisableTailoredExperiencesWithDiagnosticData',
    'HKCU:\Software\Policies\Microsoft\Windows\CloudContent|DisableThirdPartySuggestions',
    'HKLM:\Software\Policies\Microsoft\Windows\AdvertisingInfo|DisabledByGroupPolicy',
    'HKLM:\Software\Policies\Microsoft\Windows\System|EnableActivityFeed',
    'HKLM:\Software\Policies\Microsoft\Windows\System|PublishUserActivities',
    'HKLM:\Software\Policies\Microsoft\Windows\System|UploadUserActivities',
    'HKLM:\Software\Policies\Microsoft\Windows\DataCollection|AllowTelemetry',
    'HKLM:\Software\Policies\Microsoft\Windows\CloudContent|DisableSoftLanding',
    'HKLM:\Software\Policies\Microsoft\Windows\CloudContent|DisableWindowsConsumerFeatures',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_IrisRecommendations'
)
$script:AllowedStartupRegistryPaths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)

function Get-BackupPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function ConvertTo-BackupHashtable {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-BackupHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @($InputObject | ForEach-Object { ConvertTo-BackupHashtable -InputObject $_ })
        return ,$items
    }
    if ($InputObject.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-BackupHashtable -InputObject $property.Value
        }
        return $result
    }
    return $InputObject
}

function Copy-BackupValue {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    $json = $Value | ConvertTo-Json -Depth 50 -Compress
    return ConvertTo-BackupHashtable -InputObject ($json | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-CanonicalBackupValue {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [guid]) { return $Value.ToString('D').ToLowerInvariant() }
    if ($Value -is [string] -or $Value.GetType().IsValueType) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $ordered[$key] = ConvertTo-CanonicalBackupValue -Value $Value[$key]
        }
        return $ordered
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @($Value | ForEach-Object { ConvertTo-CanonicalBackupValue -Value $_ })
        return ,$items
    }
    if ($Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $ordered = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
            $ordered[$property.Name] = ConvertTo-CanonicalBackupValue -Value $property.Value
        }
        return $ordered
    }
    return $Value
}

function Test-BackupValueEqual {
    [CmdletBinding()]
    param([AllowNull()]$Left, [AllowNull()]$Right)

    $leftJson = ConvertTo-CanonicalBackupValue -Value $Left | ConvertTo-Json -Depth 50 -Compress
    $rightJson = ConvertTo-CanonicalBackupValue -Value $Right | ConvertTo-Json -Depth 50 -Compress
    return ($leftJson -ceq $rightJson)
}

function Write-BackupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$OldValue,
        [AllowNull()]$NewValue,
        [ValidateSet('Success', 'Skipped', 'Simulated', 'Warning', 'Error', 'Info', 'Restored')]
        [string]$Result = 'Info',
        [string]$ErrorMessage = '',
        [string]$Level = 'Information',
        [bool]$RequiresRestart = $false,
        [hashtable]$Details
    )

    $command = Get-Command Write-OptimizerLog -ErrorAction SilentlyContinue
    if ($command) {
        $profile = ''
        try { $profile = [string](Get-OptimizerContext).CurrentProfile } catch { }
        Write-OptimizerLog -Name $Name -Category 'Backup' -OldValue $OldValue -NewValue $NewValue `
            -Result $Result -ErrorMessage $ErrorMessage -RequiresRestart $RequiresRestart `
            -Profile $profile -Level $Level -Details $Details | Out-Null
    }
}

function Invoke-WithBackupMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $mutex = $null
    $acquired = $false
    try {
        $created = $false
        $mutex = New-Object System.Threading.Mutex($false, $script:BackupMutexName, [ref]$created)
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw 'Tempo esgotado ao aguardar acesso ao manifesto de backup.' }
        return & $ScriptBlock
    }
    finally {
        if ($mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch { }
            }
            $mutex.Dispose()
        }
    }
}

function Enter-OptimizerBackupMutex {
    [CmdletBinding()]
    param([ValidateRange(1, 300)][int]$TimeoutSeconds = 30)

    $mutex = $null
    $acquired = $false
    try {
        $created = $false
        $mutex = New-Object System.Threading.Mutex($false, $script:BackupMutexName, [ref]$created)
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Tempo esgotado ao aguardar acesso exclusivo ao backup.' }
        return [pscustomobject]@{ Mutex = $mutex; Acquired = $true }
    }
    catch {
        if (-not $acquired -and $mutex) { $mutex.Dispose() }
        throw
    }
}

function Exit-OptimizerBackupMutex {
    [CmdletBinding()]
    param([AllowNull()]$Handle)

    if ($null -eq $Handle) { return }
    $mutex = Get-BackupPropertyValue $Handle 'Mutex'
    if ($mutex) {
        if ([bool](Get-BackupPropertyValue $Handle 'Acquired' $false)) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

function Enter-OptimizerMutationMutex {
    [CmdletBinding()]
    param([ValidateRange(1, 300)][int]$TimeoutSeconds = 30)

    $mutex = $null
    $name = $script:MutationMutexName
    try {
        $created = $false
        $mutex = New-Object System.Threading.Mutex($false, $name, [ref]$created)
    }
    catch {
        $name = 'Local\WindowsFPSOptimizer.Mutation'
        $created = $false
        $mutex = New-Object System.Threading.Mutex($false, $name, [ref]$created)
    }

    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            $mutex.Dispose()
            throw 'Outra operacao de alteracao ou restauracao esta em andamento.'
        }
        return [pscustomobject]@{ Mutex = $mutex; Acquired = $true; Name = $name }
    }
    catch {
        if (-not $acquired -and $mutex) { $mutex.Dispose() }
        throw
    }
}

function Exit-OptimizerMutationMutex {
    [CmdletBinding()]
    param([AllowNull()]$Handle)

    if ($null -eq $Handle) { return }
    $mutex = Get-BackupPropertyValue -InputObject $Handle -Name 'Mutex'
    $acquired = [bool](Get-BackupPropertyValue -InputObject $Handle -Name 'Acquired' -Default $false)
    if ($mutex) {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

function Get-BackupContext {
    [CmdletBinding()]
    param()

    $command = Get-Command Get-OptimizerContext -ErrorAction SilentlyContinue
    if (-not $command) { throw 'Core.psm1 deve ser importado e inicializado antes do BackupManager.' }
    return Get-OptimizerContext
}

function Get-CurrentBackupPointerPath {
    [CmdletBinding()]
    param()

    $context = Get-BackupContext
    return Join-Path $context.StateRoot 'current-backup.json'
}

function Write-AtomicUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    $tempPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    $encoding = New-Object System.Text.UTF8Encoding($true)
    try {
        [IO.File]::WriteAllText($tempPath, $Content, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($tempPath, $Path, $null, $true)
            }
            catch {
                Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
            }
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-BackupManifestHashPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$HashPath
    )

    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $HashPath -PathType Leaf)) { return $false }
    try {
        foreach ($itemPath in @($JsonPath, $HashPath)) {
            $item = Get-Item -LiteralPath $itemPath -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $expected = (Get-Content -LiteralPath $HashPath -Raw -ErrorAction Stop).Trim()
        if ($expected -notmatch '^[A-Fa-f0-9]{64}$') { return $false }
        return ((Get-FileHash -LiteralPath $JsonPath -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $expected)
    }
    catch { return $false }
}

function Write-BackupManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $Manifest['UpdatedAtUtc'] = [datetime]::UtcNow.ToString('o')
    if ([string](Get-BackupPropertyValue $Manifest 'Status' '') -eq 'InProgress') {
        $Manifest['HeartbeatAtUtc'] = [datetime]::UtcNow.ToString('o')
    }
    $Manifest['ManifestPath'] = $ManifestPath
    $Manifest['RootPath'] = Split-Path -Parent $ManifestPath
    $Manifest['FolderPath'] = $Manifest['RootPath']
    $json = $Manifest | ConvertTo-Json -Depth 50
    $directory = Split-Path -Parent $ManifestPath
    $hashPath = Join-Path $directory 'manifest.sha256'
    if (Test-BackupManifestHashPair -JsonPath $ManifestPath -HashPath $hashPath) {
        $recoveryDirectory = Join-Path $directory 'manifest-recovery'
        if (-not (Test-Path -LiteralPath $recoveryDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $recoveryDirectory -Force -ErrorAction Stop | Out-Null
        }
        $recoveryItem = Get-Item -LiteralPath $recoveryDirectory -Force -ErrorAction Stop
        if (($recoveryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A pasta de recuperacao do manifesto e um ponto de nova analise.'
        }
        $recoveryId = '{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'), [guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $recoveryDirectory ($recoveryId + '.json')) -ErrorAction Stop
        Copy-Item -LiteralPath $hashPath -Destination (Join-Path $recoveryDirectory ($recoveryId + '.sha256')) -ErrorAction Stop
    }
    Write-AtomicUtf8File -Path $ManifestPath -Content $json
    $hash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    Write-AtomicUtf8File -Path $hashPath -Content $hash

    $recoveryDirectory = Join-Path $directory 'manifest-recovery'
    if (-not (Test-Path -LiteralPath $recoveryDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $recoveryDirectory -Force -ErrorAction Stop | Out-Null
    }
    $recoveryItem = Get-Item -LiteralPath $recoveryDirectory -Force -ErrorAction Stop
    if (($recoveryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A pasta de recuperacao do manifesto e um ponto de nova analise.'
    }
    $checkpointId = '{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'), [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $recoveryDirectory ($checkpointId + '.json')) -ErrorAction Stop
    Copy-Item -LiteralPath $hashPath -Destination (Join-Path $recoveryDirectory ($checkpointId + '.sha256')) -ErrorAction Stop

    if (Test-Path -LiteralPath $recoveryDirectory -PathType Container) {
        $oldRecoveries = @(Get-ChildItem -LiteralPath $recoveryDirectory -Filter '*.json' -File -Force -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -Skip 5)
        foreach ($old in $oldRecoveries) {
            $oldHash = [IO.Path]::ChangeExtension($old.FullName, '.sha256')
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $oldHash -PathType Leaf) { Remove-Item -LiteralPath $oldHash -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Read-BackupManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [switch]$SkipIntegrityCheck
    )

    $resolved = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Manifesto nao encontrado: $ManifestPath"
    }
    $readPath = $resolved
    if (-not $SkipIntegrityCheck) {
        $directory = Split-Path -Parent $resolved
        $hashPath = Join-Path $directory 'manifest.sha256'
        if (-not (Test-BackupManifestHashPair -JsonPath $resolved -HashPath $hashPath)) {
            $recoveryDirectory = Join-Path $directory 'manifest-recovery'
            $recovered = $null
            if (Test-Path -LiteralPath $recoveryDirectory -PathType Container) {
                $recoveryItem = Get-Item -LiteralPath $recoveryDirectory -Force -ErrorAction Stop
                if (($recoveryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    foreach ($candidate in @(Get-ChildItem -LiteralPath $recoveryDirectory -Filter '*.json' -File -Force -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                        if (($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $candidateHash = [IO.Path]::ChangeExtension($candidate.FullName, '.sha256')
                        if (Test-BackupManifestHashPair -JsonPath $candidate.FullName -HashPath $candidateHash) {
                            $recovered = $candidate.FullName
                            break
                        }
                    }
                }
            }
            if (-not $recovered) { throw "Falha de integridade no manifesto e nenhuma copia de recuperacao valida foi encontrada: $resolved" }
            $readPath = $recovered
        }
    }
    try {
        $raw = Get-Content -LiteralPath $readPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Manifesto JSON invalido: $($_.Exception.Message)"
    }
    $manifest = ConvertTo-BackupHashtable -InputObject $raw
    $manifest['ManifestPath'] = $resolved
    $manifest['RootPath'] = Split-Path -Parent $resolved
    if ($readPath -ne $resolved) { $manifest['RecoveredFromPath'] = $readPath }
    return $manifest
}

function Write-CurrentBackupPointer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest)

    $pointer = [ordered]@{
        TransactionId = [string]$Manifest['TransactionId']
        ManifestPath  = [string]$Manifest['ManifestPath']
        UpdatedAtUtc  = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicUtf8File -Path (Get-CurrentBackupPointerPath) -Content ($pointer | ConvertTo-Json -Depth 5)
}

function Remove-CurrentBackupPointer {
    [CmdletBinding()]
    param([string]$TransactionId)

    $path = Get-CurrentBackupPointerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ($TransactionId) {
        try {
            $pointer = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ([string]$pointer.TransactionId -ne $TransactionId) { return }
        }
        catch { return }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Get-CurrentBackupInternal {
    [CmdletBinding()]
    param()

    if ($script:CurrentBackup) {
        $path = [string]$script:CurrentBackup['ManifestPath']
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $path = Assert-ManagedBackupManifestPath -ManifestPath $path
            $manifest = Read-BackupManifest -ManifestPath $path
            if ([string]$manifest['Status'] -eq 'InProgress') {
                $manifest = Resolve-InProgressBackupOwnership -Manifest $manifest
                if ($null -eq $manifest) { return $null }
                $script:CurrentBackup = $manifest
                return $manifest
            }
        }
        $script:CurrentBackup = $null
    }

    $pointerPath = Get-CurrentBackupPointerPath
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return $null }
    try {
        $pointer = Get-Content -LiteralPath $pointerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $manifestPath = Assert-ManagedBackupManifestPath -ManifestPath ([string]$pointer.ManifestPath)
        $manifest = Read-BackupManifest -ManifestPath $manifestPath
        if ([string]$manifest['Status'] -eq 'InProgress') {
            $manifest = Resolve-InProgressBackupOwnership -Manifest $manifest
            if ($null -eq $manifest) { return $null }
            $script:CurrentBackup = $manifest
            return $manifest
        }
        Remove-CurrentBackupPointer -TransactionId ([string]$pointer.TransactionId)
        return $null
    }
    catch {
        throw "O ponteiro de backup atual esta invalido: $($_.Exception.Message)"
    }
}

function ConvertTo-PublicBackupObject {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json -ErrorAction Stop)
}

function Get-BackupOwnerState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest)

    $ownerId = [int](Get-BackupPropertyValue $Manifest 'OwnerProcessId' 0)
    $ownerStart = [string](Get-BackupPropertyValue $Manifest 'OwnerProcessStartUtc' '')
    if ($ownerId -le 0 -or [string]::IsNullOrWhiteSpace($ownerStart)) {
        return [pscustomobject]@{ Alive = $false; IsCurrentProcess = $false; Reason = 'Metadados do proprietario ausentes.' }
    }
    try {
        $process = Get-Process -Id $ownerId -ErrorAction Stop
        $actualStart = $process.StartTime.ToUniversalTime().ToString('o')
        $alive = ($actualStart -eq $ownerStart)
        return [pscustomobject]@{
            Alive = $alive; IsCurrentProcess = ($alive -and $ownerId -eq $PID)
            Reason = if ($alive) { '' } else { 'PID reutilizado ou processo proprietario encerrado.' }
        }
    }
    catch {
        return [pscustomobject]@{ Alive = $false; IsCurrentProcess = $false; Reason = 'Processo proprietario encerrado.' }
    }
}

function Resolve-InProgressBackupOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest)

    if ([string]$Manifest['Status'] -ne 'InProgress') { return $Manifest }
    $owner = Get-BackupOwnerState -Manifest $Manifest
    if (-not $owner.Alive) {
        $Manifest['Status'] = 'Abandoned'
        $Manifest['CompletedAtUtc'] = [datetime]::UtcNow.ToString('o')
        $Manifest['ErrorMessage'] = "Transacao abandonada: $($owner.Reason)"
        Write-BackupManifest -Manifest $Manifest -ManifestPath ([string]$Manifest['ManifestPath'])
        Remove-CurrentBackupPointer -TransactionId ([string]$Manifest['TransactionId'])
        if ($script:CurrentBackup -and [string]$script:CurrentBackup['TransactionId'] -eq [string]$Manifest['TransactionId']) {
            $script:CurrentBackup = $null
        }
        return $null
    }
    if (-not $owner.IsCurrentProcess) {
        throw 'Outra instancia do otimizador possui uma transacao de backup ativa.'
    }
    return $Manifest
}

function Test-AllowedServiceName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($pattern in $script:AllowedServicePatterns) {
        if ($Name -match $pattern) { return $true }
    }
    return $false
}

function Test-AllowedAppxName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $context = Get-BackupContext
        $config = Get-BackupPropertyValue -InputObject $context -Name 'Config'
        $patterns = @(Get-BackupPropertyValue -InputObject $config -Name 'OptionalAppxPatterns' -Default @())
        foreach ($pattern in $patterns) {
            if ($Name -ieq [string]$pattern) { return $true }
        }
    }
    catch { }
    return $false
}

function Normalize-TaskIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskPath, [Parameter(Mandatory = $true)][string]$TaskName)

    $path = $TaskPath.Trim()
    if (-not $path.StartsWith('\')) { $path = '\' + $path }
    if (-not $path.EndsWith('\')) { $path += '\' }
    return $path + $TaskName.TrimStart('\')
}

function Test-AllowedScheduledTask {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskPath, [Parameter(Mandatory = $true)][string]$TaskName)

    $identity = Normalize-TaskIdentity -TaskPath $TaskPath -TaskName $TaskName
    return @($script:AllowedScheduledTasks | Where-Object { $_ -ieq $identity }).Count -gt 0
}

function Assert-BackupRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $command = Get-Command Assert-SafeRegistryPath -ErrorAction SilentlyContinue
    if ($command) {
        Assert-SafeRegistryPath -Path $Path
        return
    }
    if ($Path -notmatch '^(?i)HK(CU|LM):\\' -or $Path -match $script:BlockedRegistryPattern) {
        throw "Caminho do Registro nao permitido ou relacionado a rede: $Path"
    }
}

function Get-RegistryIdentityFromEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
    $applied = Get-BackupPropertyValue -InputObject $Entry -Name 'Applied'
    $path = [string](Get-BackupPropertyValue -InputObject $original -Name 'Path' -Default (Get-BackupPropertyValue -InputObject $applied -Name 'Path' -Default ''))
    $name = [string](Get-BackupPropertyValue -InputObject $original -Name 'Name' -Default (Get-BackupPropertyValue -InputObject $applied -Name 'Name' -Default ''))
    if ([string]::IsNullOrWhiteSpace($path)) {
        $id = [string](Get-BackupPropertyValue -InputObject $Entry -Name 'Id' -Default '')
        $separator = $id.LastIndexOf('|')
        if ($separator -gt 0) {
            $path = $id.Substring(0, $separator)
            $name = $id.Substring($separator + 1)
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'Entrada de Registro sem caminho.' }
    Assert-BackupRegistryPath -Path $path
    return [pscustomobject]@{ Path = $path; Name = $name }
}

function Assert-AllowedRegistryEntryIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('RegistryValue', 'StartupRegistry')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Name
    )

    if ($Type -eq 'RegistryValue') {
        $identity = "$Path|$Name"
        if (@($script:AllowedRegistryEntries | Where-Object { $_ -ieq $identity }).Count -ne 1) {
            throw "Valor do Registro fora da allowlist do otimizador: $identity"
        }
        return
    }
    if (@($script:AllowedStartupRegistryPaths | Where-Object { $_ -ieq $Path }).Count -ne 1 -or
        [string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 260 -or $Name -match '[\x00-\x1F]') {
        throw 'Entrada de inicializacao do Registro fora da allowlist.'
    }
}

function Test-GuidString {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    return ([string]$Value -match '^[{(]?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[)}]?$')
}

function Get-FileEntryPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
    $applied = Get-BackupPropertyValue -InputObject $Entry -Name 'Applied'
    $metadata = Get-BackupPropertyValue -InputObject $Entry -Name 'Metadata'
    $originalPath = [string](Get-BackupPropertyValue -InputObject $original -Name 'OriginalPath' -Default `
        (Get-BackupPropertyValue -InputObject $metadata -Name 'OriginalPath' -Default ''))
    $disabledPath = [string](Get-BackupPropertyValue -InputObject $original -Name 'DisabledPath' -Default `
        (Get-BackupPropertyValue -InputObject $applied -Name 'DisabledPath' -Default `
        (Get-BackupPropertyValue -InputObject $metadata -Name 'DisabledPath' -Default '')))
    return [pscustomobject]@{ OriginalPath = $originalPath; DisabledPath = $disabledPath }
}

function Test-PathWithinRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        return ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase))
    }
    catch { return $false }
}

function Assert-NoReparsePointWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AllowMissingLeaf
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $fullRoot)) {
        throw "O caminho esta fora da raiz permitida: $Path"
    }
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "A raiz permitida nao existe: $fullRoot" }
    $rootItem = Get-Item -LiteralPath $fullRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A raiz permitida e um ponto de nova analise: $fullRoot"
    }

    $relative = if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        ''
    }
    else { $fullPath.Substring($fullRoot.Length).TrimStart('\') }
    $current = $fullRoot
    $parts = @($relative -split '\\' | Where-Object { $_ -ne '' })
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $current = Join-Path $current $parts[$index]
        if (-not (Test-Path -LiteralPath $current)) {
            if ($AllowMissingLeaf) { break }
            throw "Componente do caminho nao existe: $current"
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Ponto de nova analise nao permitido: $current"
        }
    }
    return $true
}

function Get-PathMandatoryIntegrityRid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not ('WindowsFPSOptimizer.BackupPathIntegrity' -as [type])) {
        $source = @'
using System;
using System.Runtime.InteropServices;
namespace WindowsFPSOptimizer {
    public static class BackupPathIntegrity {
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetNamedSecurityInfo(string name, int objectType, uint securityInfo,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetAce(IntPtr acl, int index, out IntPtr ace);
        [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
        [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        public static int GetMandatoryRid(string path) {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetNamedSecurityInfo(path, 1, 0x10, out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0 || descriptor == IntPtr.Zero) return -1;
            if (sacl == IntPtr.Zero) { LocalFree(descriptor); return -1; }
            try {
                int count = (ushort)Marshal.ReadInt16(sacl, 4);
                for (int index = 0; index < count; index++) {
                    IntPtr ace;
                    if (!GetAce(sacl, index, out ace) || ace == IntPtr.Zero) continue;
                    if (Marshal.ReadByte(ace, 0) != 0x11) continue;
                    IntPtr sid = IntPtr.Add(ace, 8);
                    byte subCount = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    if (subCount == 0) return -1;
                    return Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(subCount - 1)));
                }
                return -1;
            }
            finally { LocalFree(descriptor); }
        }
    }
}
'@
        try { Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop }
        catch { return -1 }
    }
    try { return [WindowsFPSOptimizer.BackupPathIntegrity]::GetMandatoryRid([IO.Path]::GetFullPath($Path)) }
    catch { return -1 }
}

function Set-BackupFolderHighIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $context = Get-BackupContext
    $result = [ordered]@{ Requested = [bool]$context.IsAdministrator; Succeeded = $false; IntegrityRid = -1; Error = '' }
    if (-not [bool]$context.IsAdministrator) {
        $result['Error'] = 'Backup criado sem elevacao; o token atual nao pode definir integridade alta.'
        return $result
    }
    try {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) { throw 'icacls.exe nao foi encontrado.' }
        $output = @(& $icacls $Path '/setintegritylevel' '(OI)(CI)H' 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw "icacls.exe retornou $LASTEXITCODE. $($output -join ' ')" }
        $rid = Get-PathMandatoryIntegrityRid -Path $Path
        if ($rid -lt 0x3000) { throw 'Nao foi possivel confirmar o rotulo de integridade alta.' }
        $result['Succeeded'] = $true
        $result['IntegrityRid'] = $rid
    }
    catch { $result['Error'] = $_.Exception.Message }
    return $result
}

function Assert-ManagedBackupManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $context = Get-BackupContext
    $resolved = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
    if ([IO.Path]::GetFileName($resolved) -ine 'manifest.json' -or
        -not (Test-PathWithinRoot -Path $resolved -Root ([string]$context.BackupRoot))) {
        throw 'Somente manifestos importados para a pasta gerenciada de backups podem ser restaurados.'
    }
    Assert-NoReparsePointWithinRoot -Path $resolved -Root ([string]$context.BackupRoot) | Out-Null
    return $resolved
}

function Get-SafeBackupFileRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($special in @('Startup', 'CommonStartup')) {
        try {
            $root = [Environment]::GetFolderPath($special)
            if (-not [string]::IsNullOrWhiteSpace($root)) { $roots.Add($root) }
        }
        catch { }
    }
    $context = Get-BackupContext
    foreach ($root in @($context.DataRoot, $context.BackupRoot)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$root)) { $roots.Add([string]$root) }
    }
    foreach ($root in $roots) {
        if (Test-PathWithinRoot -Path $Path -Root $root) { return $root }
    }
    return $null
}

function Test-SafeBackupFilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^(?i)\\\\') { return $false }
    try { return ($null -ne (Get-SafeBackupFileRoot -Path $Path)) }
    catch { return $false }
}

function Assert-BackupEntrySafety {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $type = [string](Get-BackupPropertyValue -InputObject $Entry -Name 'Type' -Default '')
    if ($script:AllowedEntryTypes -notcontains $type) { throw "Tipo de entrada de backup nao permitido: $type" }
    $id = [string](Get-BackupPropertyValue -InputObject $Entry -Name 'Id' -Default '')
    if ([string]::IsNullOrWhiteSpace($id) -or $id.Length -gt 2048) { throw 'Identificador de entrada invalido.' }

    switch ($type) {
        { $_ -in @('RegistryValue', 'StartupRegistry') } {
            $identity = Get-RegistryIdentityFromEntry -Entry $Entry
            Assert-AllowedRegistryEntryIdentity -Type $type -Path $identity.Path -Name $identity.Name
        }
        'Service' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $name = [string](Get-BackupPropertyValue -InputObject $original -Name 'Name' -Default $id)
            if (-not (Test-AllowedServiceName -Name $name)) { throw "Servico fora da lista opcional permitida: $name" }
        }
        'ScheduledTask' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $taskPath = [string](Get-BackupPropertyValue -InputObject $original -Name 'TaskPath' -Default '')
            $taskName = [string](Get-BackupPropertyValue -InputObject $original -Name 'TaskName' -Default '')
            if (-not (Test-AllowedScheduledTask -TaskPath $taskPath -TaskName $taskName)) {
                throw "Tarefa agendada fora da lista permitida: $taskPath$taskName"
            }
        }
        'PowerPlan' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $guid = Get-BackupPropertyValue -InputObject $original -Name 'ActiveSchemeGuid'
            if (-not (Test-GuidString $guid)) { throw 'GUID original do plano de energia invalido.' }
        }
        'PowerSetting' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            foreach ($name in @('SchemeGuid', 'SubGroupGuid', 'SettingGuid')) {
                if (-not (Test-GuidString (Get-BackupPropertyValue -InputObject $original -Name $name))) {
                    throw "GUID invalido em PowerSetting: $name"
                }
            }
        }
        { $_ -in @('StartupFile', 'FileMove') } {
            $paths = Get-FileEntryPaths -Entry $Entry
            if (-not (Test-SafeBackupFilePath -Path $paths.OriginalPath) -or
                -not (Test-SafeBackupFilePath -Path $paths.DisabledPath)) {
                throw 'Entrada de arquivo fora das pastas de inicializacao ou de dados do aplicativo.'
            }
        }
        'PageFile' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $settings = @(Get-BackupPropertyValue -InputObject $original -Name 'Settings' -Default @())
            foreach ($setting in $settings) {
                $name = [string](Get-BackupPropertyValue -InputObject $setting -Name 'Name' -Default '')
                if ($name -notmatch '^[A-Za-z]:\\pagefile\.sys$') { throw "Caminho de arquivo de paginacao invalido: $name" }
            }
        }
        'ProcessPriority' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $processId = [int](Get-BackupPropertyValue -InputObject $original -Name 'ProcessId' -Default `
                (Get-BackupPropertyValue -InputObject $original -Name 'Id' -Default 0))
            if ($processId -le 4) { throw 'PID invalido ou critico em ProcessPriority.' }
        }
        'Process' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $processId = [int](Get-BackupPropertyValue -InputObject $original -Name 'ProcessId' -Default `
                (Get-BackupPropertyValue -InputObject $original -Name 'Id' -Default 0))
            if ($processId -le 4) { throw 'PID invalido ou critico em Process.' }
            $path = [string](Get-BackupPropertyValue -InputObject $original -Name 'Path' -Default '')
            if ($path -match '^(?i)\\\\') { throw 'Processos em caminhos de rede nao sao permitidos.' }
        }
        'Appx' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $name = [string](Get-BackupPropertyValue -InputObject $original -Name 'Name' -Default '')
            if (-not (Test-AllowedAppxName -Name $name)) { throw "Pacote Appx fora da allowlist opcional: $name" }
            $installLocation = [string](Get-BackupPropertyValue -InputObject $original -Name 'InstallLocation' -Default '')
            $manifestPath = [string](Get-BackupPropertyValue -InputObject $original -Name 'ManifestPath' -Default '')
            if ([string]::IsNullOrWhiteSpace($installLocation) -or [string]::IsNullOrWhiteSpace($manifestPath) -or
                $installLocation -match '^(?i)\\\\' -or $manifestPath -match '^(?i)\\\\' -or
                -not (Test-PathWithinRoot -Path $manifestPath -Root $installLocation) -or
                [IO.Path]::GetFileName($manifestPath) -ine 'AppxManifest.xml') {
                throw 'Caminho de manifesto Appx invalido.'
            }
        }
        'SystemParameter' {
            $original = Get-BackupPropertyValue -InputObject $Entry -Name 'Original'
            $option = [string](Get-BackupPropertyValue -InputObject $original -Name 'Option' -Default '')
            if ([string]::IsNullOrWhiteSpace($option) -or $option -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$') {
                throw 'Opcao de parametro visual invalida.'
            }
        }
        'GameSession' {
            $sessionId = [guid]::Empty
            if (-not [guid]::TryParse($id, [ref]$sessionId)) {
                throw 'Identificador de sessao de jogo invalido.'
            }
        }
    }
}

function Test-BackupManifestObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest)

    if ([int](Get-BackupPropertyValue -InputObject $Manifest -Name 'SchemaVersion' -Default 0) -ne $script:BackupSchemaVersion) {
        throw 'Versao de esquema do backup nao suportada.'
    }
    $transactionId = [string](Get-BackupPropertyValue -InputObject $Manifest -Name 'TransactionId' -Default '')
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($transactionId, [ref]$parsedGuid)) { throw 'TransactionId invalido.' }
    $entries = @(Get-BackupPropertyValue -InputObject $Manifest -Name 'Entries' -Default @())
    $seen = @{}
    foreach ($entry in $entries) {
        Assert-BackupEntrySafety -Entry $entry
        $entryId = [string](Get-BackupPropertyValue -InputObject $entry -Name 'EntryId' -Default '')
        $parsedEntryGuid = [guid]::Empty
        if (-not [guid]::TryParse($entryId, [ref]$parsedEntryGuid)) { throw 'EntryId invalido no manifesto.' }
        if ($seen.ContainsKey($entryId)) { throw "EntryId duplicado: $entryId" }
        $seen[$entryId] = $true
    }
    $baseline = Get-BackupPropertyValue -InputObject $Manifest -Name 'Baseline' -Default $null
    if ($baseline -and [bool](Get-BackupPropertyValue $baseline 'Captured' $false)) {
        $relativePath = [string](Get-BackupPropertyValue $baseline 'RelativePath' '')
        $expectedHash = [string](Get-BackupPropertyValue $baseline 'Sha256' '')
        $expectedSize = [int64](Get-BackupPropertyValue $baseline 'SizeBytes' 0)
        if ($relativePath -ine 'baseline.json' -or [IO.Path]::IsPathRooted($relativePath)) {
            throw 'Caminho do baseline invalido no manifesto.'
        }
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'SHA-256 do baseline invalido.' }
        if ($expectedSize -le 0 -or $expectedSize -gt 16777216) { throw 'Tamanho declarado do baseline invalido.' }
        $rootPath = [string](Get-BackupPropertyValue $Manifest 'RootPath' '')
        if (-not [string]::IsNullOrWhiteSpace($rootPath) -and (Test-Path -LiteralPath $rootPath -PathType Container)) {
            $baselinePath = Join-Path $rootPath $relativePath
            if (-not (Test-PathWithinRoot -Path $baselinePath -Root $rootPath) -or
                -not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
                throw 'Arquivo baseline.json ausente ou fora do pacote.'
            }
            $item = Get-Item -LiteralPath $baselinePath -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'O baseline nao pode ser um ponto de nova analise.' }
            if ([int64]$item.Length -ne $expectedSize) { throw 'Tamanho do baseline diverge do manifesto.' }
            $actualHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($actualHash -ine $expectedHash) { throw 'Hash SHA-256 do baseline diverge do manifesto.' }
        }
    }
    return $true
}

function Convert-RegistryProviderPathToNative {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-BackupRegistryPath -Path $Path
    if ($Path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) {
        return 'HKEY_CURRENT_USER\' + $Path.Substring(6)
    }
    if ($Path.StartsWith('HKLM:\', [StringComparison]::OrdinalIgnoreCase)) {
        return 'HKEY_LOCAL_MACHINE\' + $Path.Substring(6)
    }
    throw "Caminho do Registro nao reconhecido: $Path"
}

function Get-StableTextHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Add-EmergencyRegistryExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory = $true)][string]$RegistryPath
    )

    Assert-BackupRegistryPath -Path $RegistryPath
    $exports = @(Get-BackupPropertyValue -InputObject $Manifest -Name 'RegistryExports' -Default @())
    if (@($exports | Where-Object { [string](Get-BackupPropertyValue $_ 'Path') -ieq $RegistryPath }).Count -gt 0) { return }

    $root = [string]$Manifest['RootPath']
    $directory = Join-Path $root 'registry'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    $hash = (Get-StableTextHash -Text $RegistryPath).Substring(0, 16)
    $fileName = 'registry-{0}.reg' -f $hash
    $filePath = Join-Path $directory $fileName
    $record = [ordered]@{
        Path         = $RegistryPath
        File         = (Join-Path 'registry' $fileName)
        Succeeded    = $false
        Sha256       = $null
        Error        = ''
        CreatedAtUtc = [datetime]::UtcNow.ToString('o')
    }
    try {
        if (-not (Test-Path -LiteralPath $RegistryPath)) { throw 'A chave ainda nao existe e nao pode ser exportada.' }
        $nativePath = Convert-RegistryProviderPathToNative -Path $RegistryPath
        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        if (-not (Test-Path -LiteralPath $regExe -PathType Leaf)) { $regExe = 'reg.exe' }
        $output = @(& $regExe export $nativePath $filePath /y 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        if ([int]$exitCode -ne 0 -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "reg.exe retornou $exitCode. $($output -join ' ')"
        }
        $record['Succeeded'] = $true
        $record['Sha256'] = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        $record['Error'] = $_.Exception.Message
    }
    $Manifest['RegistryExports'] = @($exports) + @($record)
}

function New-BestEffortRestorePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TransactionId, [switch]$Requested)

    $result = [ordered]@{
        Requested     = [bool]$Requested
        Attempted     = $false
        Succeeded     = $false
        Description   = ''
        SequenceNumber = $null
        Error         = ''
    }
    if (-not $Requested) { return $result }
    $context = Get-BackupContext
    if ([bool]$context.Simulation) {
        $result['Error'] = 'Ignorado em modo de simulacao.'
        return $result
    }
    if (-not [bool]$context.IsAdministrator) {
        $result['Error'] = 'A criacao do ponto de restauracao requer administrador.'
        return $result
    }
    $command = Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue
    if (-not $command) {
        $result['Error'] = 'Checkpoint-Computer nao esta disponivel.'
        return $result
    }
    $result['Attempted'] = $true
    $description = 'WindowsFPSOptimizer-{0}' -f $TransactionId.Substring(0, 8)
    $result['Description'] = $description
    try {
        Checkpoint-Computer -Description $description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $result['Succeeded'] = $true
        try {
            $point = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending | Select-Object -First 1
            if ($point) { $result['SequenceNumber'] = [int]$point.SequenceNumber }
        }
        catch { }
    }
    catch {
        $result['Error'] = $_.Exception.Message
    }
    return $result
}

function Start-OptimizerBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Name,
        [AllowEmptyString()][string]$Profile = '',
        [switch]$CreateRestorePoint
    )

    $context = Get-BackupContext
    if ([bool]$context.ReadOnly) { throw 'Nao e possivel iniciar backup em modo somente leitura.' }
    if ([bool]$context.Simulation) {
        return [pscustomobject]@{ Result = 'Simulated'; ManifestPath = $null; TransactionId = $null }
    }
    Assert-NoReparsePointWithinRoot -Path ([string]$context.BackupRoot) -Root ([string]$context.BackupRoot) | Out-Null

    return Invoke-WithBackupMutex -ScriptBlock {
        $existing = Get-CurrentBackupInternal
        if ($existing) { throw "Ja existe uma transacao de backup em andamento: $($existing['TransactionId'])" }

        $transactionId = [guid]::NewGuid().ToString('D')
        $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $folder = Join-Path $context.BackupRoot ('{0}_{1}' -f $stamp, $transactionId)
        foreach ($path in @($folder, (Join-Path $folder 'registry'), (Join-Path $folder 'tasks'), (Join-Path $folder 'logs'))) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
        $folderIntegrity = Set-BackupFolderHighIntegrity -Path $folder
        $manifestPath = Join-Path $folder 'manifest.json'
        $userSid = ''
        try { $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
        $ownerStartUtc = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
        $platform = Get-BackupPropertyValue -InputObject $context -Name 'Platform'
        $manifest = [ordered]@{
            SchemaVersion   = $script:BackupSchemaVersion
            AppVersion      = [string](Get-BackupPropertyValue -InputObject $context -Name 'Version' -Default '')
            TransactionId   = $transactionId
            Name            = $Name
            Profile         = $Profile
            Status          = 'InProgress'
            CreatedAtUtc    = [datetime]::UtcNow.ToString('o')
            UpdatedAtUtc    = [datetime]::UtcNow.ToString('o')
            CompletedAtUtc  = $null
            ComputerName    = [string]$env:COMPUTERNAME
            UserSid         = $userSid
            OwnerProcessId  = [int]$PID
            OwnerProcessStartUtc = $ownerStartUtc
            OwnerSessionId  = [string](Get-BackupPropertyValue $context 'SessionId' '')
            HeartbeatAtUtc  = [datetime]::UtcNow.ToString('o')
            WindowsVersion  = [string](Get-BackupPropertyValue -InputObject $platform -Name 'Version' -Default '')
            WindowsBuild    = [int](Get-BackupPropertyValue -InputObject $platform -Name 'Build' -Default 0)
            PowerShell      = $PSVersionTable.PSVersion.ToString()
            ManifestPath    = $manifestPath
            RootPath        = $folder
            ErrorMessage    = ''
            RestorePoint    = [ordered]@{}
            FolderIntegrity = $folderIntegrity
            RegistryExports = @()
            Entries         = @()
            Baseline        = [ordered]@{
                Captured       = $false
                CapturedAtUtc  = $null
                RelativePath   = ''
                Sha256         = ''
                SizeBytes      = 0
                Description    = ''
            }
            Restoration     = [ordered]@{
                Status       = 'NotStarted'
                StartedAtUtc = $null
                CompletedAtUtc = $null
                Error        = ''
            }
            Imported        = $false
        }
        Write-BackupManifest -Manifest $manifest -ManifestPath $manifestPath
        Write-CurrentBackupPointer -Manifest $manifest
        $script:CurrentBackup = $manifest

        $restorePoint = New-BestEffortRestorePoint -TransactionId $transactionId -Requested:$CreateRestorePoint
        $manifest['RestorePoint'] = $restorePoint
        Write-BackupManifest -Manifest $manifest -ManifestPath $manifestPath
        Write-CurrentBackupPointer -Manifest $manifest
        $script:CurrentBackup = $manifest

        Write-BackupLog -Name 'Backup iniciado' -OldValue $null -NewValue @{ TransactionId = $transactionId; Name = $Name } `
            -Result 'Success' -Details @{ ManifestPath = $manifestPath; RestorePoint = $restorePoint }
        return ConvertTo-PublicBackupObject -Value $manifest
    }
}

function Get-CurrentOptimizerBackup {
    [CmdletBinding()]
    param()

    $context = Get-BackupContext
    if ([bool]$context.Simulation) { return $null }
    return Invoke-WithBackupMutex -ScriptBlock {
        $manifest = Get-CurrentBackupInternal
        return ConvertTo-PublicBackupObject -Value $manifest
    }
}

function Set-OptimizerBackupBaseline {
    <#
        Persiste um inventario somente leitura ao lado do manifesto ativo. O baseline
        serve para auditoria e restauracao manual; restauracoes automaticas continuam
        usando exclusivamente Entries validadas e registradas antes de cada mutacao.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Snapshot,
        [AllowEmptyString()][string]$Description = 'Inventario manual do sistema'
    )

    $context = Get-BackupContext
    if ([bool]$context.ReadOnly) { throw 'Captura de baseline bloqueada em modo somente leitura.' }
    if ([bool]$context.Simulation) {
        return [pscustomobject]@{ Result = 'Simulated'; Captured = $false; RelativePath = ''; Sha256 = '' }
    }

    return Invoke-WithBackupMutex -ScriptBlock {
        $manifest = Get-CurrentBackupInternal
        if (-not $manifest) { throw 'Nenhuma transacao de backup esta em andamento.' }
        if ([string]$manifest['Status'] -ne 'InProgress') { throw 'A transacao atual nao aceita um baseline.' }
        $rootPath = [string]$manifest['RootPath']
        Assert-NoReparsePointWithinRoot -Path $rootPath -Root ([string]$context.BackupRoot) | Out-Null
        $baselinePath = Join-Path $rootPath 'baseline.json'
        $document = [ordered]@{
            SchemaVersion = 1
            CapturedAtUtc = [datetime]::UtcNow.ToString('o')
            ComputerName = [string]$env:COMPUTERNAME
            AppVersion = [string]$context.Version
            Snapshot = Copy-BackupValue -Value $Snapshot
        }
        $json = $document | ConvertTo-Json -Depth 32
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16777216) {
            throw 'O inventario excedeu o limite seguro de 16 MB.'
        }
        Write-AtomicUtf8File -Path $baselinePath -Content $json
        $file = Get-Item -LiteralPath $baselinePath -Force -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $manifest['Baseline'] = [ordered]@{
            Captured = $true
            CapturedAtUtc = [string]$document['CapturedAtUtc']
            RelativePath = 'baseline.json'
            Sha256 = $hash
            SizeBytes = [int64]$file.Length
            Description = $Description
        }
        Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
        Write-CurrentBackupPointer -Manifest $manifest
        $script:CurrentBackup = $manifest
        Write-BackupLog -Name 'Baseline de backup capturado' -OldValue $null `
            -NewValue @{ RelativePath = 'baseline.json'; Sha256 = $hash } -Result 'Success'
        return [pscustomobject]@{
            Result = 'Captured'; Captured = $true; RelativePath = 'baseline.json'
            Sha256 = $hash; SizeBytes = [int64]$file.Length
        }
    }
}

function ConvertTo-UtcBackupTimestamp {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    try { return ([datetimeoffset]::Parse([string]$Value)).UtcDateTime.ToString('o') }
    catch { throw "Data/hora invalida na entrada de backup: $Value" }
}

function Normalize-NewBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entry)

    $type = [string]$Entry['Type']
    $original = $Entry['Original']
    $applied = $Entry['Applied']
    switch ($type) {
        'Service' {
            $name = [string](Get-BackupPropertyValue $original 'Name' $Entry['Id'])
            $originalDelayed = [bool](Get-BackupPropertyValue $original 'DelayedAutoStart' $false)
            $Entry['Applied'] = [ordered]@{
                Name             = $name
                StartMode        = Normalize-ServiceStartMode (Get-BackupPropertyValue $applied 'StartMode' (Get-BackupPropertyValue $original 'StartMode' 'Manual'))
                Status           = [string](Get-BackupPropertyValue $applied 'Status' (Get-BackupPropertyValue $original 'Status' 'Stopped'))
                DelayedAutoStart = [bool](Get-BackupPropertyValue $applied 'DelayedAutoStart' $originalDelayed)
            }
        }
        'ProcessPriority' {
            $processId = [int](Get-BackupPropertyValue $original 'ProcessId' (Get-BackupPropertyValue $original 'Id' 0))
            $startTime = ConvertTo-UtcBackupTimestamp (Get-BackupPropertyValue $original 'StartTimeUtc' (Get-BackupPropertyValue $original 'StartTime' ''))
            $Entry['Original'] = [ordered]@{
                Exists = $true; ProcessId = $processId; StartTimeUtc = $startTime
                PriorityClass = [string](Get-BackupPropertyValue $original 'PriorityClass' (Get-BackupPropertyValue $original 'Priority' 'Normal'))
            }
            $Entry['Applied'] = [ordered]@{
                Exists = $true; ProcessId = $processId; StartTimeUtc = $startTime
                PriorityClass = [string](Get-BackupPropertyValue $applied 'PriorityClass' (Get-BackupPropertyValue $applied 'Priority' 'Normal'))
            }
        }
        'Process' {
            $processId = [int](Get-BackupPropertyValue $original 'ProcessId' (Get-BackupPropertyValue $original 'Id' 0))
            $startTime = ConvertTo-UtcBackupTimestamp (Get-BackupPropertyValue $original 'StartTimeUtc' (Get-BackupPropertyValue $original 'StartTime' ''))
            $original['ProcessId'] = $processId
            $original['StartTimeUtc'] = $startTime
            $original['Running'] = [bool](Get-BackupPropertyValue $original 'Running' $true)
            $applied['ProcessId'] = $processId
            $applied['StartTimeUtc'] = $startTime
            $applied['Running'] = [bool](Get-BackupPropertyValue $applied 'Running' $false)
            $path = [string](Get-BackupPropertyValue $original 'Path' '')
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                try {
                    if (-not ($Entry['Metadata'] -is [System.Collections.IDictionary])) { $Entry['Metadata'] = [ordered]@{} }
                    $Entry['Metadata']['ExecutableSha256'] = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
                }
                catch { }
            }
        }
        { $_ -in @('StartupFile', 'FileMove') } {
            $source = [string](Get-BackupPropertyValue $original 'OriginalPath' (Get-BackupPropertyValue $original 'Path' ''))
            $target = [string](Get-BackupPropertyValue $original 'DisabledPath' `
                (Get-BackupPropertyValue $applied 'DisabledPath' (Get-BackupPropertyValue $applied 'Path' '')))
            $hash = ''
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                try { $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
            }
            $Entry['Original'] = [ordered]@{
                OriginalPath = $source; DisabledPath = $target
                OriginalExists = [bool](Get-BackupPropertyValue $original 'OriginalExists' (Get-BackupPropertyValue $original 'Exists' $true))
                DisabledExists = $false; Sha256 = $hash
            }
            $Entry['Applied'] = [ordered]@{
                OriginalPath = $source; DisabledPath = $target; OriginalExists = $false
                DisabledExists = [bool](Get-BackupPropertyValue $applied 'DisabledExists' (Get-BackupPropertyValue $applied 'Exists' $true))
                Sha256 = $hash
            }
        }
        'Appx' {
            if ($original -is [System.Collections.IDictionary]) { $original['Installed'] = $true }
            if ($applied -is [System.Collections.IDictionary]) { $applied['Installed'] = [bool](Get-BackupPropertyValue $applied 'Installed' $false) }
        }
    }
    return $Entry
}

function Add-OptimizerBackupEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('RegistryValue', 'Service', 'ScheduledTask', 'PowerPlan', 'PowerSetting',
            'StartupRegistry', 'StartupFile', 'PageFile', 'ProcessPriority',
            'GameSession', 'FileMove', 'SystemParameter', 'Process', 'Appx',
            'CleanupManifest', 'Irreversible')]
        [string]$Type,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory = $true)][AllowNull()]$Original,
        [Parameter(Mandatory = $true)][AllowNull()]$Applied,
        [AllowNull()]$Metadata = @{}
    )

    $context = Get-BackupContext
    if ([bool]$context.Simulation) {
        return [pscustomobject]@{ Recorded = $false; Result = 'Simulated'; Type = $Type; Id = $Id }
    }
    if ([bool]$context.ReadOnly) { throw 'Registro de alteracao bloqueado em modo somente leitura.' }

    return Invoke-WithBackupMutex -ScriptBlock {
        $manifest = Get-CurrentBackupInternal
        if (-not $manifest) { throw 'Nenhuma transacao de backup esta em andamento. A alteracao foi bloqueada.' }
        if ([string]$manifest['Status'] -ne 'InProgress') { throw 'A transacao atual nao aceita novas entradas.' }

        $candidate = [ordered]@{
            Type     = $Type
            Id       = $Id
            Original = Copy-BackupValue -Value $Original
            Applied  = Copy-BackupValue -Value $Applied
            Metadata = Copy-BackupValue -Value $Metadata
        }
        $candidate = Normalize-NewBackupEntry -Entry $candidate
        Assert-BackupEntrySafety -Entry $candidate
        $entries = @(Get-BackupPropertyValue -InputObject $manifest -Name 'Entries' -Default @())
        $existing = $null
        foreach ($entry in $entries) {
            if ([string](Get-BackupPropertyValue $entry 'Type') -eq $Type -and
                [string](Get-BackupPropertyValue $entry 'Id') -eq $Id) {
                $existing = $entry
                break
            }
        }

        if ($existing) {
            $existing['Applied'] = $candidate['Applied']
            if ($Type -eq 'PowerPlan') {
                $existingMetadata = ConvertTo-BackupHashtable (Get-BackupPropertyValue $existing 'Metadata' @{})
                $newMetadata = ConvertTo-BackupHashtable $candidate['Metadata']
                $created = @()
                foreach ($value in @(
                    (Get-BackupPropertyValue $existingMetadata 'CreatedSchemeGuid'),
                    (Get-BackupPropertyValue $newMetadata 'CreatedSchemeGuid')) +
                    @(Get-BackupPropertyValue $existingMetadata 'CreatedSchemeGuids' @()) +
                    @(Get-BackupPropertyValue $newMetadata 'CreatedSchemeGuids' @())) {
                    if (Test-GuidString $value) { $created += Normalize-GuidString $value }
                }
                foreach ($key in $newMetadata.Keys) { $existingMetadata[$key] = $newMetadata[$key] }
                if ($created.Count -gt 0) { $existingMetadata['CreatedSchemeGuids'] = @($created | Sort-Object -Unique) }
                $existing['Metadata'] = $existingMetadata
            }
            else { $existing['Metadata'] = $candidate['Metadata'] }
            $existing['UpdatedAtUtc'] = [datetime]::UtcNow.ToString('o')
            $entryResult = $existing
        }
        else {
            $sequence = 1
            if ($entries.Count -gt 0) {
                $sequence = 1 + [int](($entries | ForEach-Object { [int](Get-BackupPropertyValue $_ 'Sequence' 0) } | Measure-Object -Maximum).Maximum)
            }
            $entryResult = [ordered]@{
                Sequence      = $sequence
                EntryId       = [guid]::NewGuid().ToString('D')
                Type          = $Type
                Id            = $Id
                Original      = $candidate['Original']
                Applied       = $candidate['Applied']
                Metadata      = $candidate['Metadata']
                AddedAtUtc    = [datetime]::UtcNow.ToString('o')
                UpdatedAtUtc  = [datetime]::UtcNow.ToString('o')
                Restoration   = [ordered]@{
                    Status       = 'NotStarted'
                    AttemptedAtUtc = $null
                    CurrentBefore = $null
                    CurrentAfter  = $null
                    Error         = ''
                }
            }
            $manifest['Entries'] = @($entries) + @($entryResult)
        }

        if ($Type -in @('RegistryValue', 'StartupRegistry')) {
            $identity = Get-RegistryIdentityFromEntry -Entry $entryResult
            Add-EmergencyRegistryExport -Manifest $manifest -RegistryPath $identity.Path
        }
        Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
        Write-CurrentBackupPointer -Manifest $manifest
        $script:CurrentBackup = $manifest
        Write-BackupLog -Name 'Entrada adicionada ao backup' -OldValue $entryResult['Original'] `
            -NewValue $entryResult['Applied'] -Result 'Success' -Details @{ Type = $Type; Id = $Id }
        return ConvertTo-PublicBackupObject -Value $entryResult
    }
}

function Complete-OptimizerBackup {
    [CmdletBinding()]
    param(
        [ValidateSet('Completed', 'Failed', 'Cancelled')][string]$Status = 'Completed',
        [AllowEmptyString()][string]$ErrorMessage = '',
        [string]$ManifestPath
    )

    $context = Get-BackupContext
    if ([bool]$context.Simulation) { return [pscustomobject]@{ Result = 'Simulated'; Status = $Status } }

    return Invoke-WithBackupMutex -ScriptBlock {
        if ($ManifestPath) {
            $ManifestPath = Assert-ManagedBackupManifestPath -ManifestPath $ManifestPath
            $manifest = Read-BackupManifest -ManifestPath $ManifestPath
        }
        else { $manifest = Get-CurrentBackupInternal }
        if (-not $manifest) { throw 'Nenhuma transacao de backup esta em andamento.' }
        if ([string]$manifest['Status'] -ne 'InProgress') {
            if ([string]$manifest['Status'] -eq $Status) { return ConvertTo-PublicBackupObject -Value $manifest }
            throw "A transacao esta no estado $($manifest['Status']) e nao pode ser concluida como $Status."
        }
        $manifest['Status'] = $Status
        $manifest['CompletedAtUtc'] = [datetime]::UtcNow.ToString('o')
        $manifest['ErrorMessage'] = $ErrorMessage
        Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
        Remove-CurrentBackupPointer -TransactionId ([string]$manifest['TransactionId'])
        if ($script:CurrentBackup -and [string]$script:CurrentBackup['TransactionId'] -eq [string]$manifest['TransactionId']) {
            $script:CurrentBackup = $null
        }
        Write-BackupLog -Name 'Backup concluido' -OldValue 'InProgress' -NewValue $Status `
            -Result $(if ($Status -eq 'Completed') { 'Success' } else { 'Warning' }) -ErrorMessage $ErrorMessage `
            -Details @{ TransactionId = $manifest['TransactionId']; Entries = @($manifest['Entries']).Count }
        return ConvertTo-PublicBackupObject -Value $manifest
    }
}

function Normalize-ServiceStartMode {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    switch -Regex ([string]$Value) {
        '^(Auto|Automatic)$' { return 'Automatic' }
        '^Manual$' { return 'Manual' }
        '^Disabled$' { return 'Disabled' }
        default { return [string]$Value }
    }
}

function Normalize-GuidString {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim('{', '}', '(', ')').ToLowerInvariant()
}

function Get-PageFileComparableSettings {
    [CmdletBinding()]
    param([AllowNull()]$Settings)

    $result = @()
    foreach ($setting in @($Settings)) {
        $result += [ordered]@{
            Name        = ([string](Get-BackupPropertyValue $setting 'Name' '')).ToLowerInvariant()
            InitialSize = [uint64](Get-BackupPropertyValue $setting 'InitialSize' (Get-BackupPropertyValue $setting 'InitialSizeMB' 0))
            MaximumSize = [uint64](Get-BackupPropertyValue $setting 'MaximumSize' (Get-BackupPropertyValue $setting 'MaximumSizeMB' 0))
        }
    }
    return @($result | Sort-Object { $_['Name'] })
}

function Get-ComparableEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Type, [AllowNull()]$State)

    switch ($Type) {
        { $_ -in @('RegistryValue', 'StartupRegistry') } {
            return [ordered]@{
                ValueExisted = [bool](Get-BackupPropertyValue $State 'ValueExisted' $false)
                Value        = Get-BackupPropertyValue $State 'Value'
                Kind         = [string](Get-BackupPropertyValue $State 'Kind' '')
            }
        }
        'Service' {
            return [ordered]@{
                Name             = [string](Get-BackupPropertyValue $State 'Name' '')
                StartMode        = Normalize-ServiceStartMode (Get-BackupPropertyValue $State 'StartMode' '')
                Status           = ([string](Get-BackupPropertyValue $State 'Status' '')).ToLowerInvariant()
                DelayedAutoStart = [bool](Get-BackupPropertyValue $State 'DelayedAutoStart' $false)
            }
        }
        'ScheduledTask' {
            return [ordered]@{
                TaskPath = [string](Get-BackupPropertyValue $State 'TaskPath' '')
                TaskName = [string](Get-BackupPropertyValue $State 'TaskName' '')
                Enabled  = [bool](Get-BackupPropertyValue $State 'Enabled' $false)
            }
        }
        'PowerPlan' {
            return [ordered]@{ ActiveSchemeGuid = Normalize-GuidString (Get-BackupPropertyValue $State 'ActiveSchemeGuid' '') }
        }
        'PowerSetting' {
            return [ordered]@{
                SchemeGuid   = Normalize-GuidString (Get-BackupPropertyValue $State 'SchemeGuid' '')
                SubGroupGuid = Normalize-GuidString (Get-BackupPropertyValue $State 'SubGroupGuid' '')
                SettingGuid  = Normalize-GuidString (Get-BackupPropertyValue $State 'SettingGuid' '')
                AcValueIndex = [int64](Get-BackupPropertyValue $State 'AcValueIndex' (Get-BackupPropertyValue $State 'ACValue' 0))
                DcValueIndex = [int64](Get-BackupPropertyValue $State 'DcValueIndex' (Get-BackupPropertyValue $State 'DCValue' 0))
            }
        }
        'PageFile' {
            $automatic = [bool](Get-BackupPropertyValue $State 'AutomaticManagedPagefile' $false)
            return [ordered]@{
                AutomaticManagedPagefile = $automatic
                Settings = if ($automatic) { @() } else { Get-PageFileComparableSettings (Get-BackupPropertyValue $State 'Settings' @()) }
            }
        }
        'ProcessPriority' {
            return [ordered]@{
                Exists        = [bool](Get-BackupPropertyValue $State 'Exists' $true)
                ProcessId     = [int](Get-BackupPropertyValue $State 'ProcessId' 0)
                StartTimeUtc  = [string](Get-BackupPropertyValue $State 'StartTimeUtc' '')
                PriorityClass = [string](Get-BackupPropertyValue $State 'PriorityClass' '')
            }
        }
        'Process' {
            return [ordered]@{
                Running      = [bool](Get-BackupPropertyValue $State 'Running' $false)
                ProcessId    = [int](Get-BackupPropertyValue $State 'ProcessId' (Get-BackupPropertyValue $State 'Id' 0))
                StartTimeUtc = [string](Get-BackupPropertyValue $State 'StartTimeUtc' (Get-BackupPropertyValue $State 'StartTime' ''))
            }
        }
        'Appx' {
            return [ordered]@{ Installed = [bool](Get-BackupPropertyValue $State 'Installed' $false) }
        }
        { $_ -in @('StartupFile', 'FileMove') } {
            return [ordered]@{
                OriginalPath   = ([string](Get-BackupPropertyValue $State 'OriginalPath' '')).ToLowerInvariant()
                DisabledPath   = ([string](Get-BackupPropertyValue $State 'DisabledPath' '')).ToLowerInvariant()
                OriginalExists = [bool](Get-BackupPropertyValue $State 'OriginalExists' $false)
                DisabledExists = [bool](Get-BackupPropertyValue $State 'DisabledExists' $false)
                Sha256         = ([string](Get-BackupPropertyValue $State 'Sha256' '')).ToUpperInvariant()
            }
        }
        'SystemParameter' {
            return [ordered]@{
                Option = [string](Get-BackupPropertyValue $State 'Option' '')
                Value  = Get-BackupPropertyValue $State 'Value'
            }
        }
        default { return ConvertTo-CanonicalBackupValue -Value $State }
    }
}

function Test-EntryStateEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Type, [AllowNull()]$Left, [AllowNull()]$Right)

    return Test-BackupValueEqual -Left (Get-ComparableEntryState -Type $Type -State $Left) `
        -Right (Get-ComparableEntryState -Type $Type -State $Right)
}

function Get-RegistryEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $identity = Get-RegistryIdentityFromEntry -Entry $Entry
    $command = Get-Command Get-RegistryValueState -ErrorAction SilentlyContinue
    if ($command) { return Get-RegistryValueState -Path $identity.Path -Name $identity.Name }
    $state = [ordered]@{ Path = $identity.Path; Name = $identity.Name; PathExisted = $false; ValueExisted = $false; Value = $null; Kind = $null }
    if (-not (Test-Path -LiteralPath $identity.Path)) { return $state }
    $state['PathExisted'] = $true
    $key = Get-Item -LiteralPath $identity.Path -ErrorAction Stop
    if (@($key.GetValueNames()) -contains $identity.Name) {
        $state['ValueExisted'] = $true
        $state['Value'] = $key.GetValue($identity.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $state['Kind'] = $key.GetValueKind($identity.Name).ToString()
    }
    return $state
}

function Get-ServiceEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $name = [string](Get-BackupPropertyValue $original 'Name' (Get-BackupPropertyValue $Entry 'Id' ''))
    if (-not (Test-AllowedServiceName -Name $name)) { throw "Servico nao permitido: $name" }
    $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $name) -ErrorAction Stop
    $delayed = $false
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    try {
        $item = Get-ItemProperty -LiteralPath $path -Name 'DelayedAutoStart' -ErrorAction Stop
        $delayed = ([int](Get-BackupPropertyValue $item 'DelayedAutoStart' 0) -eq 1)
    }
    catch { }
    return [ordered]@{
        Name             = $name
        StartMode        = Normalize-ServiceStartMode $service.StartMode
        Status           = [string]$service.State
        DelayedAutoStart = $delayed
    }
}

function Get-ScheduledTaskEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $taskPath = [string](Get-BackupPropertyValue $original 'TaskPath' '')
    $taskName = [string](Get-BackupPropertyValue $original 'TaskName' '')
    if (-not (Test-AllowedScheduledTask -TaskPath $taskPath -TaskName $taskName)) { throw 'Tarefa fora da lista permitida.' }
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
    return [ordered]@{ TaskPath = $taskPath; TaskName = $taskName; Enabled = ([string]$task.State -ne 'Disabled') }
}

function Get-PowerCfgExecutable {
    [CmdletBinding()]
    param()

    $path = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return 'powercfg.exe'
}

function Invoke-BackupPowerCfg {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$Mutating)

    $exe = Get-PowerCfgExecutable
    $safe = Get-Command Invoke-SafeNativeCommand -ErrorAction SilentlyContinue
    if ($safe) {
        return Invoke-SafeNativeCommand -FilePath $exe -ArgumentList $Arguments -Description 'Restauracao de energia' `
            -RequiresAdministrator:$Mutating -Mutating:$Mutating
    }
    $output = @(& $exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    if ([int]$exitCode -ne 0) { throw "powercfg.exe retornou $exitCode. $($output -join ' ')" }
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output; Simulated = $false }
}

function Get-ActivePowerPlanState {
    [CmdletBinding()]
    param()

    $result = Invoke-BackupPowerCfg -Arguments @('/getactivescheme')
    $text = @($result.Output) -join ' '
    $match = [regex]::Match($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw 'Nao foi possivel identificar o plano de energia ativo.' }
    return [ordered]@{ ActiveSchemeGuid = $match.Value.ToLowerInvariant() }
}

function Get-PowerSettingEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $scheme = Normalize-GuidString (Get-BackupPropertyValue $original 'SchemeGuid' '')
    $subGroup = Normalize-GuidString (Get-BackupPropertyValue $original 'SubGroupGuid' '')
    $setting = Normalize-GuidString (Get-BackupPropertyValue $original 'SettingGuid' '')
    foreach ($guid in @($scheme, $subGroup, $setting)) {
        if (-not (Test-GuidString $guid)) { throw 'GUID invalido na consulta de PowerSetting.' }
    }
    $result = Invoke-BackupPowerCfg -Arguments @('/query', $scheme, $subGroup, $setting)
    $tokens = [regex]::Matches((@($result.Output) -join [Environment]::NewLine), '0x[0-9a-fA-F]+')
    if ($tokens.Count -lt 2) { throw 'Nao foi possivel ler os indices AC/DC da configuracao de energia.' }
    $ac = [Convert]::ToInt64($tokens[$tokens.Count - 2].Value.Substring(2), 16)
    $dc = [Convert]::ToInt64($tokens[$tokens.Count - 1].Value.Substring(2), 16)
    return [ordered]@{ SchemeGuid = $scheme; SubGroupGuid = $subGroup; SettingGuid = $setting; AcValueIndex = $ac; DcValueIndex = $dc }
}

function Get-PageFileEntryCurrentState {
    [CmdletBinding()]
    param()

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $settings = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ Name = [string]$_.Name; InitialSize = [uint64]$_.InitialSize; MaximumSize = [uint64]$_.MaximumSize }
    })
    return [ordered]@{ AutomaticManagedPagefile = [bool]$computer.AutomaticManagedPagefile; Settings = $settings }
}

function Get-ProcessPriorityEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $processId = [int](Get-BackupPropertyValue $original 'ProcessId' 0)
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        return [ordered]@{
            Exists        = $true
            ProcessId     = $processId
            StartTimeUtc  = $process.StartTime.ToUniversalTime().ToString('o')
            PriorityClass = $process.PriorityClass.ToString()
        }
    }
    catch {
        return [ordered]@{ Exists = $false; ProcessId = $processId; StartTimeUtc = ''; PriorityClass = '' }
    }
}

function Get-ProcessEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $processId = [int](Get-BackupPropertyValue $original 'ProcessId' (Get-BackupPropertyValue $original 'Id' 0))
    $expectedStart = [string](Get-BackupPropertyValue $original 'StartTimeUtc' (Get-BackupPropertyValue $original 'StartTime' ''))
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        $actualStart = $process.StartTime.ToUniversalTime().ToString('o')
        if ($expectedStart -eq '' -or $actualStart -eq $expectedStart) {
            return [ordered]@{ Running = $true; ProcessId = $processId; StartTimeUtc = $actualStart }
        }
    }
    catch { }

    # Um reinicio manual recebe outro PID. Reconhece-o apenas pelo mesmo caminho
    # local e pelo hash registrado, e projeta o estado para a identidade original.
    $path = [string](Get-BackupPropertyValue $original 'Path' '')
    $metadata = Get-BackupPropertyValue $Entry 'Metadata'
    $expectedHash = [string](Get-BackupPropertyValue $metadata 'ExecutableSha256' '')
    if ($path -and $expectedHash -match '^[A-Fa-f0-9]{64}$' -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        try {
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $expectedHash) {
                $equivalent = @(Get-ProcessesByExactExecutablePath -Path $path | Select-Object -First 1)
                if ($equivalent.Count -eq 1) {
                    return [ordered]@{
                        Running = $true; ProcessId = $processId; StartTimeUtc = $expectedStart
                        EquivalentProcessId = [int]$equivalent[0].Id
                    }
                }
            }
        }
        catch { }
    }
    return [ordered]@{ Running = $false; ProcessId = $processId; StartTimeUtc = $expectedStart }
}

function Get-AppxEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $name = [string](Get-BackupPropertyValue $original 'Name' '')
    if (-not (Test-AllowedAppxName -Name $name)) { throw 'Pacote Appx fora da allowlist.' }
    $package = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
    return [ordered]@{ Installed = ($null -ne $package) }
}

function Get-GameSessionEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $context = Get-BackupContext
    $path = Join-Path ([string]$context.StateRoot) 'active-game-session.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{ Active = $false; SessionId = '' }
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O arquivo da sessao ativa e um ponto de nova analise e nao sera seguido.'
    }
    try {
        $session = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "O estado da sessao de jogo esta corrompido: $($_.Exception.Message)"
    }
    $sessionId = [string](Get-BackupPropertyValue $session 'Id' '')
    $parsedSessionId = [guid]::Empty
    if (-not [guid]::TryParse($sessionId, [ref]$parsedSessionId)) {
        throw 'O arquivo da sessao ativa contem um identificador invalido.'
    }
    return [ordered]@{ Active = $true; SessionId = $parsedSessionId.ToString('D') }
}

function Restore-GameSessionEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $expectedId = [guid]::Empty
    if (-not [guid]::TryParse([string](Get-BackupPropertyValue $Entry 'Id' ''), [ref]$expectedId)) {
        throw 'Identificador de sessao de jogo invalido.'
    }
    $current = Get-GameSessionEntryCurrentState -Entry $Entry
    if (-not [bool](Get-BackupPropertyValue $current 'Active' $false)) { return $current }
    if ([string](Get-BackupPropertyValue $current 'SessionId' '') -ine $expectedId.ToString('D')) {
        throw 'Existe outra sessao de jogo ativa; o marcador atual nao sera removido.'
    }

    $context = Get-BackupContext
    $activePath = Join-Path ([string]$context.StateRoot) 'active-game-session.json'
    $session = Get-Content -LiteralPath $activePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $sessionState = ConvertTo-BackupHashtable -InputObject $session
    $now = [datetime]::UtcNow.ToString('o')
    $sessionState['Status'] = 'Restored'
    $sessionState['UpdatedAt'] = $now
    if (-not (Get-BackupPropertyValue $sessionState 'EndedAt')) { $sessionState['EndedAt'] = $now }
    $sessionState['RestoredByBackupManager'] = $true
    $historyPath = Join-Path ([string]$context.StateRoot) ("game-session-{0}.json" -f $expectedId.ToString('D'))
    Write-AtomicUtf8File -Path $historyPath -Content ($sessionState | ConvertTo-Json -Depth 50)
    Remove-Item -LiteralPath $activePath -Force -ErrorAction Stop
    return [ordered]@{ Active = $false; SessionId = '' }
}

function Get-FileMoveEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $paths = Get-FileEntryPaths -Entry $Entry
    if (-not (Test-SafeBackupFilePath $paths.OriginalPath) -or -not (Test-SafeBackupFilePath $paths.DisabledPath)) {
        throw 'Caminho de arquivo nao permitido.'
    }
    $originalRoot = Get-SafeBackupFileRoot -Path $paths.OriginalPath
    $disabledRoot = Get-SafeBackupFileRoot -Path $paths.DisabledPath
    Assert-NoReparsePointWithinRoot -Path $paths.OriginalPath -Root $originalRoot -AllowMissingLeaf | Out-Null
    Assert-NoReparsePointWithinRoot -Path $paths.DisabledPath -Root $disabledRoot -AllowMissingLeaf | Out-Null
    $originalExists = Test-Path -LiteralPath $paths.OriginalPath -PathType Leaf
    $disabledExists = Test-Path -LiteralPath $paths.DisabledPath -PathType Leaf
    $hash = ''
    $hashPath = if ($disabledExists) { $paths.DisabledPath } elseif ($originalExists) { $paths.OriginalPath } else { $null }
    if ($hashPath) {
        try { $hash = (Get-FileHash -LiteralPath $hashPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    }
    return [ordered]@{
        OriginalPath = $paths.OriginalPath; DisabledPath = $paths.DisabledPath
        OriginalExists = $originalExists; DisabledExists = $disabledExists; Sha256 = $hash
    }
}

function Get-BackupEntryCurrentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $type = [string](Get-BackupPropertyValue $Entry 'Type' '')
    switch ($type) {
        { $_ -in @('RegistryValue', 'StartupRegistry') } { return Get-RegistryEntryCurrentState -Entry $Entry }
        'Service' { return Get-ServiceEntryCurrentState -Entry $Entry }
        'ScheduledTask' { return Get-ScheduledTaskEntryCurrentState -Entry $Entry }
        'PowerPlan' { return Get-ActivePowerPlanState }
        'PowerSetting' { return Get-PowerSettingEntryCurrentState -Entry $Entry }
        'PageFile' { return Get-PageFileEntryCurrentState }
        'ProcessPriority' { return Get-ProcessPriorityEntryCurrentState -Entry $Entry }
        'Process' { return Get-ProcessEntryCurrentState -Entry $Entry }
        'Appx' { return Get-AppxEntryCurrentState -Entry $Entry }
        { $_ -in @('StartupFile', 'FileMove') } { return Get-FileMoveEntryCurrentState -Entry $Entry }
        'SystemParameter' {
            $handler = Get-Command Get-GraphicsSystemParameterBackupState -ErrorAction SilentlyContinue
            if (-not $handler) { throw 'O provedor de parametros visuais nao esta carregado.' }
            return Get-GraphicsSystemParameterBackupState -Entry (ConvertTo-PublicBackupObject $Entry)
        }
        'GameSession' { return Get-GameSessionEntryCurrentState -Entry $Entry }
        { $_ -in @('CleanupManifest', 'Irreversible') } { return $null }
        default { throw "Tipo de entrada nao suportado: $type" }
    }
}

function Convert-RegistryValueForKind {
    [CmdletBinding()]
    param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$Kind)

    switch ($Kind) {
        'DWord' { return [int32]$Value }
        'QWord' { return [int64]$Value }
        'Binary' { return [byte[]]@($Value | ForEach-Object { [byte]$_ }) }
        'MultiString' { return [string[]]@($Value | ForEach-Object { [string]$_ }) }
        'String' { return [string]$Value }
        'ExpandString' { return [string]$Value }
        default { throw "Tipo de valor do Registro nao permitido: $Kind" }
    }
}

function Restore-RegistryEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$Original)

    $identity = Get-RegistryIdentityFromEntry -Entry $Entry
    $valueExisted = [bool](Get-BackupPropertyValue $Original 'ValueExisted' $false)
    if ($valueExisted) {
        $kind = [string](Get-BackupPropertyValue $Original 'Kind' '')
        if ($kind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')) { throw 'Tipo original do Registro invalido.' }
        if (-not (Test-Path -LiteralPath $identity.Path)) {
            New-Item -Path $identity.Path -Force -ErrorAction Stop | Out-Null
        }
        $value = Convert-RegistryValueForKind -Value (Get-BackupPropertyValue $Original 'Value') -Kind $kind
        New-ItemProperty -LiteralPath $identity.Path -Name $identity.Name -Value $value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
    }
    else {
        if (Test-Path -LiteralPath $identity.Path) {
            $key = Get-Item -LiteralPath $identity.Path -ErrorAction Stop
            if (@($key.GetValueNames()) -contains $identity.Name) {
                Remove-ItemProperty -LiteralPath $identity.Path -Name $identity.Name -Force -ErrorAction Stop
            }
            $pathExisted = [bool](Get-BackupPropertyValue $Original 'PathExisted' $true)
            if (-not $pathExisted -and (Test-Path -LiteralPath $identity.Path)) {
                $key = Get-Item -LiteralPath $identity.Path -ErrorAction Stop
                if ($key.GetSubKeyNames().Count -eq 0 -and $key.GetValueNames().Count -eq 0) {
                    Remove-Item -LiteralPath $identity.Path -Force -ErrorAction Stop
                }
            }
        }
    }
}

function Restore-ServiceEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$Original)

    $name = [string](Get-BackupPropertyValue $Original 'Name' (Get-BackupPropertyValue $Entry 'Id' ''))
    if (-not (Test-AllowedServiceName $name)) { throw "Servico nao permitido: $name" }
    $targetStatus = ([string](Get-BackupPropertyValue $Original 'Status' 'Stopped')).ToLowerInvariant()
    $targetMode = Normalize-ServiceStartMode (Get-BackupPropertyValue $Original 'StartMode' 'Manual')
    if ($targetStatus -eq 'stopped') {
        $service = Get-Service -Name $name -ErrorAction Stop
        if ($service.Status -ne 'Stopped') { Stop-Service -Name $name -ErrorAction Stop }
    }
    Set-Service -Name $name -StartupType $targetMode -ErrorAction Stop
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    Assert-BackupRegistryPath $path
    if (Test-Path -LiteralPath $path) {
        $delayed = if ([bool](Get-BackupPropertyValue $Original 'DelayedAutoStart' $false)) { 1 } else { 0 }
        New-ItemProperty -LiteralPath $path -Name 'DelayedAutoStart' -Value $delayed -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }
    if ($targetStatus -eq 'running') {
        $service = Get-Service -Name $name -ErrorAction Stop
        if ($service.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop }
    }
}

function Restore-ScheduledTaskEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Original)

    $taskPath = [string](Get-BackupPropertyValue $Original 'TaskPath' '')
    $taskName = [string](Get-BackupPropertyValue $Original 'TaskName' '')
    if (-not (Test-AllowedScheduledTask $taskPath $taskName)) { throw 'Tarefa fora da lista permitida.' }
    if ([bool](Get-BackupPropertyValue $Original 'Enabled' $false)) {
        Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
    }
    else {
        Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
    }
}

function Restore-PowerPlanEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$Original)

    $guid = Normalize-GuidString (Get-BackupPropertyValue $Original 'ActiveSchemeGuid' '')
    if (-not (Test-GuidString $guid)) { throw 'GUID original do plano de energia invalido.' }
    Invoke-BackupPowerCfg -Arguments @('/setactive', $guid) -Mutating | Out-Null

    $metadata = Get-BackupPropertyValue $Entry 'Metadata'
    $createdGuids = @()
    foreach ($value in @((Get-BackupPropertyValue $metadata 'CreatedSchemeGuid')) +
        @(Get-BackupPropertyValue $metadata 'CreatedSchemeGuids' @())) {
        if (Test-GuidString $value) { $createdGuids += Normalize-GuidString $value }
    }
    if ($createdGuids.Count -gt 0) {
        $list = Invoke-BackupPowerCfg -Arguments @('/list')
        $lines = @($list.Output)
        foreach ($createdGuid in @($createdGuids | Sort-Object -Unique)) {
            if ($createdGuid -eq $guid) { continue }
            $matchingLine = @($lines | Where-Object { $_ -match [regex]::Escape($createdGuid) } | Select-Object -First 1)
            if ($matchingLine.Count -eq 0) { continue }
            if ([string]$matchingLine[0] -notmatch '(?i)Windows FPS Optimizer') {
                Write-BackupLog -Name 'Plano criado mantido por seguranca' -OldValue $createdGuid -NewValue $createdGuid `
                    -Result 'Warning' -ErrorMessage 'O nome do plano nao contem a marca do aplicativo.' -Level 'Warning'
                continue
            }
            Invoke-BackupPowerCfg -Arguments @('/delete', $createdGuid) -Mutating | Out-Null
        }
    }
}

function Restore-PowerSettingEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$Original)

    $scheme = Normalize-GuidString (Get-BackupPropertyValue $Original 'SchemeGuid' '')
    $subGroup = Normalize-GuidString (Get-BackupPropertyValue $Original 'SubGroupGuid' '')
    $setting = Normalize-GuidString (Get-BackupPropertyValue $Original 'SettingGuid' '')
    foreach ($guid in @($scheme, $subGroup, $setting)) { if (-not (Test-GuidString $guid)) { throw 'GUID invalido em PowerSetting.' } }
    $ac = [int64](Get-BackupPropertyValue $Original 'AcValueIndex' (Get-BackupPropertyValue $Original 'ACValue' 0))
    $dc = [int64](Get-BackupPropertyValue $Original 'DcValueIndex' (Get-BackupPropertyValue $Original 'DCValue' 0))
    if ($ac -lt 0 -or $dc -lt 0 -or $ac -gt [uint32]::MaxValue -or $dc -gt [uint32]::MaxValue) {
        throw 'Indice de configuracao de energia fora do intervalo permitido.'
    }
    Invoke-BackupPowerCfg -Arguments @('/setacvalueindex', $scheme, $subGroup, $setting, ([string]$ac)) -Mutating | Out-Null
    Invoke-BackupPowerCfg -Arguments @('/setdcvalueindex', $scheme, $subGroup, $setting, ([string]$dc)) -Mutating | Out-Null
    $metadata = Get-BackupPropertyValue $Entry 'Metadata'
    $activeScheme = ''
    try { $activeScheme = Normalize-GuidString (Get-BackupPropertyValue (Get-ActivePowerPlanState) 'ActiveSchemeGuid' '') }
    catch { }
    if ([bool](Get-BackupPropertyValue $metadata 'Reactivate' $false) -or $activeScheme -eq $scheme) {
        Invoke-BackupPowerCfg -Arguments @('/setactive', $scheme) -Mutating | Out-Null
    }
}

function Restore-PageFileEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Original)

    $automatic = [bool](Get-BackupPropertyValue $Original 'AutomaticManagedPagefile' $false)
    $validatedSettings = New-Object System.Collections.Generic.List[object]
    if (-not $automatic) {
        foreach ($setting in @(Get-BackupPropertyValue $Original 'Settings' @())) {
            $name = [string](Get-BackupPropertyValue $setting 'Name' '')
            if ($name -notmatch '^[A-Za-z]:\\pagefile\.sys$') { throw "Caminho de paginacao invalido: $name" }
            [uint64]$initialRaw = Get-BackupPropertyValue $setting 'InitialSize' (Get-BackupPropertyValue $setting 'InitialSizeMB' 0)
            [uint64]$maximumRaw = Get-BackupPropertyValue $setting 'MaximumSize' (Get-BackupPropertyValue $setting 'MaximumSizeMB' 0)
            if ($initialRaw -gt [uint32]::MaxValue -or $maximumRaw -gt [uint32]::MaxValue -or
                $maximumRaw -lt $initialRaw) { throw "Tamanhos de paginacao invalidos para $name" }
            $validatedSettings.Add([pscustomobject]@{ Name = $name; InitialSize = [uint32]$initialRaw; MaximumSize = [uint32]$maximumRaw })
        }
        if ($validatedSettings.Count -eq 0) { throw 'O estado original manual nao contem nenhuma configuracao de paginacao.' }
    }

    $rollback = Get-PageFileEntryCurrentState
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $automatic } -ErrorAction Stop | Out-Null
        if (-not $automatic) {
            foreach ($current in @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)) {
                Remove-CimInstance -InputObject $current -ErrorAction Stop
            }
            foreach ($setting in $validatedSettings.ToArray()) {
                New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                    Name = $setting.Name; InitialSize = $setting.InitialSize; MaximumSize = $setting.MaximumSize
                } -ErrorAction Stop | Out-Null
            }
        }
    }
    catch {
        $restoreError = $_
        try {
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $rollbackAutomatic = [bool](Get-BackupPropertyValue $rollback 'AutomaticManagedPagefile' $false)
            Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $rollbackAutomatic } -ErrorAction Stop | Out-Null
            if (-not $rollbackAutomatic) {
                foreach ($current in @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)) {
                    Remove-CimInstance -InputObject $current -ErrorAction Stop
                }
                foreach ($setting in @(Get-BackupPropertyValue $rollback 'Settings' @())) {
                    New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                        Name = [string](Get-BackupPropertyValue $setting 'Name' '')
                        InitialSize = [uint32](Get-BackupPropertyValue $setting 'InitialSize' 0)
                        MaximumSize = [uint32](Get-BackupPropertyValue $setting 'MaximumSize' 0)
                    } -ErrorAction Stop | Out-Null
                }
            }
        }
        catch { }
        throw $restoreError
    }
}

function Restore-ProcessPriorityEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$Original)

    $processId = [int](Get-BackupPropertyValue $Original 'ProcessId' 0)
    $process = Get-Process -Id $processId -ErrorAction Stop
    $expectedStart = [string](Get-BackupPropertyValue $Original 'StartTimeUtc' '')
    if ($expectedStart -and $process.StartTime.ToUniversalTime().ToString('o') -ne $expectedStart) {
        throw 'O PID foi reutilizado por outro processo; prioridade nao restaurada.'
    }
    $priority = [string](Get-BackupPropertyValue $Original 'PriorityClass' 'Normal')
    if ($priority -notin @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')) { throw 'Classe de prioridade original nao permitida.' }
    $priorityValue = [Enum]::Parse([Diagnostics.ProcessPriorityClass], $priority, $true)
    $process.PriorityClass = [Diagnostics.ProcessPriorityClass]$priorityValue
}

function Test-ProcessHasMediumOrLowerIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if (-not ('WindowsFPSOptimizer.BackupTokenInspector' -as [type])) {
        $source = @'
using System;
using System.Runtime.InteropServices;
namespace WindowsFPSOptimizer {
    public static class BackupTokenInspector {
        [StructLayout(LayoutKind.Sequential)] private struct TOKEN_MANDATORY_LABEL { public IntPtr LabelSid; public int Attributes; }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
        [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetTokenInformation(IntPtr token, int tokenClass, IntPtr info, int length, out int returnLength);
        [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
        [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        public static int GetIntegrityRid(int processId) {
            IntPtr process = IntPtr.Zero, token = IntPtr.Zero, buffer = IntPtr.Zero;
            try {
                process = OpenProcess(0x1000, false, processId);
                if (process == IntPtr.Zero || !OpenProcessToken(process, 0x0008, out token)) return -1;
                int length;
                GetTokenInformation(token, 25, IntPtr.Zero, 0, out length);
                if (length <= 0) return -1;
                buffer = Marshal.AllocHGlobal(length);
                if (!GetTokenInformation(token, 25, buffer, length, out length)) return -1;
                TOKEN_MANDATORY_LABEL label = (TOKEN_MANDATORY_LABEL)Marshal.PtrToStructure(buffer, typeof(TOKEN_MANDATORY_LABEL));
                byte count = Marshal.ReadByte(GetSidSubAuthorityCount(label.LabelSid));
                return Marshal.ReadInt32(GetSidSubAuthority(label.LabelSid, (uint)(count - 1)));
            }
            finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (token != IntPtr.Zero) CloseHandle(token);
                if (process != IntPtr.Zero) CloseHandle(process);
            }
        }
    }
}
'@
        try { Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop }
        catch { return $false }
    }
    try {
        $rid = [WindowsFPSOptimizer.BackupTokenInspector]::GetIntegrityRid($ProcessId)
        return ($rid -ge 0x1000 -and $rid -lt 0x3000)
    }
    catch { return $false }
}

function Get-ProcessesByExactExecutablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ([string]$process.Path -and ([string]$process.Path).Equals($Path, [StringComparison]::OrdinalIgnoreCase)) {
                $matches.Add($process)
            }
        }
        catch { }
    }
    return $matches.ToArray()
}

function Start-BackupProcessWithoutElevation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $context = Get-BackupContext
    if (-not [bool]$context.IsAdministrator) {
        return Start-Process -FilePath $Path -PassThru -ErrorAction Stop
    }

    foreach ($existing in @(Get-ProcessesByExactExecutablePath -Path $Path)) {
        if (Test-ProcessHasMediumOrLowerIntegrity -ProcessId ([int]$existing.Id)) { return $existing }
    }
    $currentSession = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    $broker = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $currentSession -and (Test-ProcessHasMediumOrLowerIntegrity -ProcessId ([int]$_.Id))
    } | Select-Object -First 1)
    if ($broker.Count -ne 1) {
        throw 'Nao foi encontrado um Explorer com integridade media; reinicie o aplicativo manualmente.'
    }

    $beforeIds = @(Get-ProcessesByExactExecutablePath -Path $Path | ForEach-Object { [int]$_.Id })
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.ShellExecute($Path, '', (Split-Path -Parent $Path), 'open', 1)
    }
    finally {
        if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }

    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 200
        foreach ($candidate in @(Get-ProcessesByExactExecutablePath -Path $Path)) {
            if ($beforeIds -contains [int]$candidate.Id) { continue }
            if (Test-ProcessHasMediumOrLowerIntegrity -ProcessId ([int]$candidate.Id)) { return $candidate }
            try { Stop-Process -Id ([int]$candidate.Id) -Force -ErrorAction Stop } catch { }
            throw 'O processo foi iniciado com integridade elevada e foi encerrado por seguranca.'
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Nao foi possivel confirmar o reinicio sem elevacao; inicie o aplicativo manualmente.'
}

function Restore-ProcessEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $original = Get-BackupPropertyValue $Entry 'Original'
    $metadata = Get-BackupPropertyValue $Entry 'Metadata'
    if (-not [bool](Get-BackupPropertyValue $original 'AllowRestart' $false)) {
        throw 'O processo nao foi autorizado para reinicio.'
    }
    $path = [string](Get-BackupPropertyValue $original 'Path' '')
    if ([string]::IsNullOrWhiteSpace($path) -or $path -match '^(?i)\\\\' -or
        [IO.Path]::GetExtension($path) -ine '.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Executavel local do processo nao esta disponivel.'
    }
    $expectedHash = [string](Get-BackupPropertyValue $metadata 'ExecutableSha256' '')
    if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Hash do executavel nao foi registrado.' }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualHash -ine $expectedHash) { throw 'O executavel mudou desde o backup; reinicio bloqueado.' }
    $process = Start-BackupProcessWithoutElevation -Path $path
    return [ordered]@{
        Running = $true; ProcessId = [int]$process.Id
        StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
        Path = $path
    }
}

function Restore-FileMoveEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $paths = Get-FileEntryPaths -Entry $Entry
    if (-not (Test-SafeBackupFilePath $paths.OriginalPath) -or -not (Test-SafeBackupFilePath $paths.DisabledPath)) {
        throw 'Caminho de arquivo nao permitido.'
    }
    $originalRoot = Get-SafeBackupFileRoot -Path $paths.OriginalPath
    $disabledRoot = Get-SafeBackupFileRoot -Path $paths.DisabledPath
    Assert-NoReparsePointWithinRoot -Path $paths.OriginalPath -Root $originalRoot -AllowMissingLeaf | Out-Null
    Assert-NoReparsePointWithinRoot -Path $paths.DisabledPath -Root $disabledRoot | Out-Null
    if (Test-Path -LiteralPath $paths.OriginalPath) { throw 'O caminho original ja existe; nenhum arquivo foi sobrescrito.' }
    if (-not (Test-Path -LiteralPath $paths.DisabledPath -PathType Leaf)) { throw 'O arquivo desabilitado nao foi encontrado.' }
    $parent = Split-Path -Parent $paths.OriginalPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    Assert-NoReparsePointWithinRoot -Path $parent -Root $originalRoot | Out-Null
    Assert-NoReparsePointWithinRoot -Path $paths.DisabledPath -Root $disabledRoot | Out-Null
    Move-Item -LiteralPath $paths.DisabledPath -Destination $paths.OriginalPath -ErrorAction Stop
}

function Restore-AppxEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $handler = Get-Command Restore-AppxBackupEntry -ErrorAction SilentlyContinue
    if (-not $handler) { throw 'O provedor de restauracao Appx nao esta carregado.' }
    Restore-AppxBackupEntry -Entry (ConvertTo-PublicBackupObject $Entry) -Force | Out-Null
}

function Restore-BackupEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $type = [string](Get-BackupPropertyValue $Entry 'Type' '')
    $original = Get-BackupPropertyValue $Entry 'Original'
    switch ($type) {
        { $_ -in @('RegistryValue', 'StartupRegistry') } { Restore-RegistryEntryState -Entry $Entry -Original $original }
        'Service' { Restore-ServiceEntryState -Entry $Entry -Original $original }
        'ScheduledTask' { Restore-ScheduledTaskEntryState -Original $original }
        'PowerPlan' { Restore-PowerPlanEntryState -Entry $Entry -Original $original }
        'PowerSetting' { Restore-PowerSettingEntryState -Entry $Entry -Original $original }
        'PageFile' { Restore-PageFileEntryState -Original $original }
        'ProcessPriority' { Restore-ProcessPriorityEntryState -Entry $Entry -Original $original }
        'Appx' { Restore-AppxEntryState -Entry $Entry }
        { $_ -in @('StartupFile', 'FileMove') } { Restore-FileMoveEntryState -Entry $Entry }
        'SystemParameter' {
            $handler = Get-Command Restore-GraphicsSystemParameterBackupEntry -ErrorAction SilentlyContinue
            if (-not $handler) { throw 'O provedor de restauracao de parametros visuais nao esta carregado.' }
            Restore-GraphicsSystemParameterBackupEntry -Entry (ConvertTo-PublicBackupObject $Entry) | Out-Null
        }
        'Process' { return Restore-ProcessEntryState -Entry $Entry }
        'GameSession' { return Restore-GameSessionEntryState -Entry $Entry }
        { $_ -in @('CleanupManifest', 'Irreversible') } { throw "O tipo $type nao possui restauracao direta." }
        default { throw "Tipo de entrada nao suportado: $type" }
    }
}

function Test-BackupEntryNotReversible {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $type = [string](Get-BackupPropertyValue $Entry 'Type' '')
    if ($type -in @('CleanupManifest', 'Irreversible')) { return $true }
    if ($type -eq 'Process') {
        $original = Get-BackupPropertyValue $Entry 'Original'
        $metadata = Get-BackupPropertyValue $Entry 'Metadata'
        if (-not [bool](Get-BackupPropertyValue $original 'AllowRestart' $false)) { return $true }
        $path = [string](Get-BackupPropertyValue $original 'Path' '')
        $hash = [string](Get-BackupPropertyValue $metadata 'ExecutableSha256' '')
        if ([string]::IsNullOrWhiteSpace($path) -or $path -match '^(?i)\\\\' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or $hash -notmatch '^[A-Fa-f0-9]{64}$') { return $true }
    }
    if ($type -eq 'Appx') {
        $original = Get-BackupPropertyValue $Entry 'Original'
        $manifestPath = [string](Get-BackupPropertyValue $original 'ManifestPath' '')
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $true }
    }
    $metadata = Get-BackupPropertyValue $Entry 'Metadata'
    $reversibility = [string](Get-BackupPropertyValue $metadata 'Reversibility' '')
    if ($reversibility -ieq 'None') { return $true }
    $reversible = Get-BackupPropertyValue $metadata 'Reversible' $true
    return (-not [bool]$reversible)
}

function Set-EntryRestorationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entry,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()]$CurrentBefore,
        [AllowNull()]$CurrentAfter,
        [string]$ErrorMessage = ''
    )

    $Entry['Restoration'] = [ordered]@{
        Status         = $Status
        AttemptedAtUtc = [datetime]::UtcNow.ToString('o')
        CurrentBefore  = Copy-BackupValue $CurrentBefore
        CurrentAfter   = Copy-BackupValue $CurrentAfter
        Error          = $ErrorMessage
    }
}

function Get-OverallRestorationStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest)

    $statuses = @($Manifest['Entries'] | ForEach-Object {
        [string](Get-BackupPropertyValue (Get-BackupPropertyValue $_ 'Restoration') 'Status' 'NotStarted')
    })
    if ($statuses.Count -eq 0) { return 'Restored' }
    $successful = @('Restored', 'RestoredBestEffort', 'AlreadyRestored', 'NoLongerRunning')
    if (@($statuses | Where-Object { $_ -notin $successful }).Count -eq 0) { return 'Restored' }
    if (@($statuses | Where-Object { $_ -in @('Error', 'Conflict', 'NotReversible', 'NotStarted', 'Unsupported') }).Count -gt 0) {
        return 'RestorePartial'
    }
    return 'RestorePartial'
}

function Invoke-BackupSidecarReconciliation {
    <#
        Mantem os arquivos auxiliares alinhados ao estado efetivamente restaurado.
        O dispatcher e deliberadamente restrito a Restored/AlreadyRestored; conflitos,
        erros, itens ignorados e simulacoes nunca alteram sidecars.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Restored', 'AlreadyRestored')][string]$Status
    )

    $type = [string](Get-BackupPropertyValue $Entry 'Type' '')
    $provider = switch ($type) {
        { $_ -in @('StartupRegistry', 'StartupFile') } {
            [pscustomobject]@{ Module = 'StartupManager'; Command = 'Sync-StartupStateAfterBackupRestore' }; break
        }
        { $_ -in @('PowerPlan', 'PowerSetting') } {
            [pscustomobject]@{ Module = 'PowerOptimizations'; Command = 'Sync-PowerStateAfterBackupRestore' }; break
        }
        { $_ -in @('RegistryValue', 'SystemParameter') } {
            [pscustomobject]@{ Module = 'GraphicsOptimizations'; Command = 'Sync-VisualStateAfterBackupRestore' }; break
        }
        default { $null }
    }
    if ($null -eq $provider) { return }
    $handler = Get-Command -Name ([string]$provider.Command) -Module ([string]$provider.Module) `
        -ErrorAction SilentlyContinue
    if (-not $handler) { return }
    & $handler -Entry (ConvertTo-PublicBackupObject $Entry) -Status $Status | Out-Null
}

function Restore-OptimizerBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ManifestPath,
        [Alias('ItemId')][string[]]$EntryId,
        [switch]$Force
    )

    $context = Get-BackupContext
    if ([bool]$context.ReadOnly) { throw 'Restauracao bloqueada em modo somente leitura.' }
    $backupHandle = Enter-OptimizerBackupMutex -TimeoutSeconds 30
    try {
    $activeBackup = Get-CurrentBackupInternal
    if ($activeBackup) { throw 'Conclua a transacao de backup ativa antes de iniciar uma restauracao.' }
    $ManifestPath = Assert-ManagedBackupManifestPath -ManifestPath $ManifestPath
    $manifest = Read-BackupManifest -ManifestPath $ManifestPath
    if ([string]$manifest['Status'] -eq 'InProgress') { throw 'Um backup em andamento nao pode ser restaurado.' }
    Test-BackupManifestObject -Manifest $manifest | Out-Null
    $manifestFolderIntegrityRid = Get-PathMandatoryIntegrityRid -Path ([string]$manifest['RootPath'])
    $manifestProtectedForElevation = ($manifestFolderIntegrityRid -ge 0x3000)
    $allEntries = @($manifest['Entries'])
    if ($EntryId -and $EntryId.Count -gt 0) {
        $selected = @($allEntries | Where-Object {
            $requested = $EntryId
            $requested -contains [string](Get-BackupPropertyValue $_ 'EntryId' '') -or
            $requested -contains [string](Get-BackupPropertyValue $_ 'Id' '')
        })
        if ($selected.Count -eq 0) { throw 'Nenhum item solicitado foi encontrado no backup.' }
    }
    else { $selected = $allEntries }
    # Entradas concretas sao restauradas em ordem inversa. O marcador GameSession
    # sempre fica por ultimo para que a sessao so seja finalizada apos os filhos.
    $selected = @(
        @($selected | Where-Object { [string](Get-BackupPropertyValue $_ 'Type' '') -ne 'GameSession' } |
            Sort-Object { [int](Get-BackupPropertyValue $_ 'Sequence' 0) } -Descending) +
        @($selected | Where-Object { [string](Get-BackupPropertyValue $_ 'Type' '') -eq 'GameSession' } |
            Sort-Object { [int](Get-BackupPropertyValue $_ 'Sequence' 0) } -Descending)
    )

    if ([bool]$context.Simulation -or $WhatIfPreference) {
        return @($selected | ForEach-Object {
            [pscustomobject]@{ EntryId = Get-BackupPropertyValue $_ 'EntryId'; Id = Get-BackupPropertyValue $_ 'Id'; Type = Get-BackupPropertyValue $_ 'Type'; Status = 'Simulated'; Error = '' }
        })
    }

    $mutationHandle = $null
    $results = New-Object System.Collections.Generic.List[object]
    $gameSessionRestoreError = ''
    try {
        $mutationHandle = Enter-OptimizerMutationMutex -TimeoutSeconds 30
        $manifest['Restoration']['Status'] = 'InProgress'
        $manifest['Restoration']['StartedAtUtc'] = [datetime]::UtcNow.ToString('o')
        $manifest['Restoration']['Error'] = ''
        Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])

        foreach ($entryObject in $selected) {
            $entry = ConvertTo-BackupHashtable $entryObject
            $index = -1
            for ($i = 0; $i -lt $manifest['Entries'].Count; $i++) {
                if ([string](Get-BackupPropertyValue $manifest['Entries'][$i] 'EntryId') -eq [string](Get-BackupPropertyValue $entry 'EntryId')) { $index = $i; break }
            }
            if ($index -lt 0) { continue }
            $type = [string]$entry['Type']
            $id = [string]$entry['Id']
            $resultStatus = 'Error'
            $errorMessage = ''
            $current = $null
            $after = $null
            try {
                Assert-BackupEntrySafety -Entry $entry
                $requiresProtectedManifest = [bool]$context.IsAdministrator -and
                    $type -in @('Process', 'Appx', 'StartupRegistry', 'StartupFile', 'FileMove')
                if ($requiresProtectedManifest -and -not $manifestProtectedForElevation) {
                    $resultStatus = 'NotReversible'
                    $errorMessage = 'Restauracao privilegiada bloqueada: a pasta do backup nao possui integridade alta verificavel.'
                }
                elseif (Test-BackupEntryNotReversible -Entry $entry) {
                    $resultStatus = 'NotReversible'
                    $errorMessage = 'A operacao foi registrada como irreversivel.'
                }
                elseif ($type -eq 'GameSession') {
                    $dependencySuccess = @('Restored', 'RestoredBestEffort', 'AlreadyRestored', 'NoLongerRunning')
                    $incompleteDependencies = @($manifest['Entries'] | Where-Object {
                        [string](Get-BackupPropertyValue $_ 'Type' '') -ne 'GameSession' -and
                        [string](Get-BackupPropertyValue (Get-BackupPropertyValue $_ 'Restoration') 'Status' 'NotStarted') -notin $dependencySuccess
                    })
                    if ($incompleteDependencies.Count -gt 0) {
                        $resultStatus = 'Conflict'
                        $errorMessage = 'A sessao nao foi finalizada porque uma ou mais alteracoes filhas nao foram restauradas.'
                        $gameSessionRestoreError = $errorMessage
                    }
                    else {
                        $current = Get-GameSessionEntryCurrentState -Entry $entry
                        $currentActive = [bool](Get-BackupPropertyValue $current 'Active' $false)
                        $currentId = [string](Get-BackupPropertyValue $current 'SessionId' '')
                        if (-not $currentActive) {
                            $resultStatus = 'AlreadyRestored'
                            $after = $current
                        }
                        elseif ($currentId -ine $id) {
                            $resultStatus = 'Conflict'
                            $errorMessage = 'Existe outra sessao de jogo ativa; seu marcador nao sera removido.'
                            $gameSessionRestoreError = $errorMessage
                        }
                        elseif ($PSCmdlet.ShouldProcess($id, 'Finalizar marcador da sessao de jogo')) {
                            $after = Restore-GameSessionEntryState -Entry $entry
                            $resultStatus = 'Restored'
                        }
                        else { $resultStatus = 'Skipped' }
                    }
                }
                elseif ($type -eq 'Process') {
                    $current = Get-BackupEntryCurrentState -Entry $entry
                    $original = $entry['Original']
                    $applied = $entry['Applied']
                    if (Test-EntryStateEqual -Type $type -Left $current -Right $original) {
                        $resultStatus = 'AlreadyRestored'
                        $after = $current
                    }
                    else {
                        $matchesApplied = Test-EntryStateEqual -Type $type -Left $current -Right $applied
                        if (-not $matchesApplied -and -not $Force) {
                            $resultStatus = 'Conflict'
                            $errorMessage = 'O estado do PID mudou depois do encerramento.'
                        }
                        elseif ($PSCmdlet.ShouldProcess("Process/$id", 'Reiniciar processo autorizado')) {
                            $after = Restore-ProcessEntryState -Entry $entry
                            $resultStatus = 'RestoredBestEffort'
                        }
                        else { $resultStatus = 'Skipped' }
                    }
                }
                else {
                    $current = Get-BackupEntryCurrentState -Entry $entry
                    $original = $entry['Original']
                    $applied = $entry['Applied']
                    if ($type -eq 'ProcessPriority' -and -not [bool](Get-BackupPropertyValue $current 'Exists' $true)) {
                        $resultStatus = 'NoLongerRunning'
                    }
                    elseif (Test-EntryStateEqual -Type $type -Left $current -Right $original) {
                        $resultStatus = 'AlreadyRestored'
                        $after = $current
                    }
                    else {
                        $matchesApplied = Test-EntryStateEqual -Type $type -Left $current -Right $applied
                        if (-not $matchesApplied -and -not $Force) {
                            $resultStatus = 'Conflict'
                            $errorMessage = 'O estado atual difere tanto do estado original quanto do estado aplicado.'
                        }
                        elseif ($type -eq 'ProcessPriority' -and $Force) {
                            $expectedStart = [string](Get-BackupPropertyValue $original 'StartTimeUtc' '')
                            $currentStart = [string](Get-BackupPropertyValue $current 'StartTimeUtc' '')
                            if ($expectedStart -and $expectedStart -ne $currentStart) {
                                $resultStatus = 'Conflict'
                                $errorMessage = 'O PID pertence agora a outro processo.'
                            }
                        }
                        if ($resultStatus -notin @('Conflict')) {
                            if ($PSCmdlet.ShouldProcess("$type/$id", 'Restaurar estado original')) {
                                Restore-BackupEntryState -Entry $entry
                                $after = Get-BackupEntryCurrentState -Entry $entry
                                if (-not (Test-EntryStateEqual -Type $type -Left $after -Right $original)) {
                                    throw 'A verificacao posterior nao corresponde ao estado original.'
                                }
                                $resultStatus = 'Restored'
                            }
                            else { $resultStatus = 'Skipped' }
                        }
                    }
                }
                if ($resultStatus -in @('Restored', 'AlreadyRestored')) {
                    try { Invoke-BackupSidecarReconciliation -Entry $entry -Status $resultStatus }
                    catch {
                        throw "O Windows foi restaurado, mas a reconciliacao do estado auxiliar falhou; repita a restauracao. $($_.Exception.Message)"
                    }
                }
            }
            catch {
                $resultStatus = 'Error'
                $errorMessage = $_.Exception.Message
            }

            Set-EntryRestorationResult -Entry $entry -Status $resultStatus -CurrentBefore $current -CurrentAfter $after -ErrorMessage $errorMessage
            $manifest['Entries'][$index] = $entry
            Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
            $publicResult = [pscustomobject]@{
                EntryId = $entry['EntryId']; Id = $id; Type = $type
                Status = $resultStatus; Conflict = ($resultStatus -eq 'Conflict'); Error = $errorMessage
            }
            $results.Add($publicResult)
            $logResult = switch ($resultStatus) {
                'Restored' { 'Restored' }
                'RestoredBestEffort' { 'Restored' }
                'AlreadyRestored' { 'Skipped' }
                'NoLongerRunning' { 'Skipped' }
                'Conflict' { 'Warning' }
                'NotReversible' { 'Warning' }
                'Unsupported' { 'Warning' }
                'Skipped' { 'Skipped' }
                default { 'Error' }
            }
            Write-BackupLog -Name "Restaurar $type/$id" -OldValue $entry['Applied'] -NewValue $entry['Original'] `
                -Result $logResult -ErrorMessage $errorMessage -Level $(if ($resultStatus -eq 'Error') { 'Error' } elseif ($resultStatus -in @('Conflict', 'NotReversible', 'Unsupported')) { 'Warning' } else { 'Information' }) `
                -RequiresRestart ([bool](Get-BackupPropertyValue $entry['Metadata'] 'RequiresRestart' $false))
        }

        $overall = Get-OverallRestorationStatus -Manifest $manifest
        $manifest['Restoration']['Status'] = $overall
        $manifest['Restoration']['CompletedAtUtc'] = [datetime]::UtcNow.ToString('o')
        $manifest['Status'] = $overall
        Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
        if ($gameSessionRestoreError) { throw $gameSessionRestoreError }
        Write-BackupLog -Name 'Restauracao do backup concluida' -OldValue '' -NewValue $overall `
            -Result $(if ($overall -eq 'Restored') { 'Restored' } else { 'Warning' }) `
            -Details @{ TransactionId = $manifest['TransactionId']; Results = $results.Count }
    }
    catch {
        try {
            $manifest['Restoration']['Status'] = 'RestorePartial'
            $manifest['Restoration']['Error'] = $_.Exception.Message
            $manifest['Restoration']['CompletedAtUtc'] = [datetime]::UtcNow.ToString('o')
            $manifest['Status'] = 'RestorePartial'
            Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
        }
        catch { }
        throw
    }
    finally { Exit-OptimizerMutationMutex -Handle $mutationHandle }
    return $results.ToArray()
    }
    finally { Exit-OptimizerBackupMutex -Handle $backupHandle }
}

function Get-OptimizerBackups {
    [CmdletBinding()]
    param([switch]$IncludeInvalid)

    $context = Get-BackupContext
    if (-not (Test-Path -LiteralPath $context.BackupRoot)) { return @() }
    Assert-NoReparsePointWithinRoot -Path ([string]$context.BackupRoot) -Root ([string]$context.BackupRoot) | Out-Null
    $items = New-Object System.Collections.Generic.List[object]
    $manifestFiles = New-Object System.Collections.Generic.List[object]
    foreach ($directory in @(Get-ChildItem -LiteralPath $context.BackupRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            if ($IncludeInvalid) {
                $items.Add([pscustomobject]@{
                    ManifestPath = ''; TransactionId = ''; Name = $directory.Name; Profile = ''; CreatedAtUtc = ''
                    Status = 'Invalid'; EntryCount = 0; RestoredCount = 0; NotReversibleCount = 0; PendingCount = 0
                    HasBaseline = $false; RestorePointRequested = $false; RestorePointSucceeded = $false; RestorePointError = ''
                    Imported = $false; IsValid = $false; ValidationError = 'Pasta de backup e um ponto de nova analise.'
                })
            }
            continue
        }
        $candidate = Join-Path $directory.FullName 'manifest.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $manifestFiles.Add((Get-Item -LiteralPath $candidate -Force)) }
    }
    foreach ($file in $manifestFiles.ToArray()) {
        try {
            Assert-ManagedBackupManifestPath -ManifestPath $file.FullName | Out-Null
            $manifest = Read-BackupManifest -ManifestPath $file.FullName
            Test-BackupManifestObject -Manifest $manifest | Out-Null
            $statuses = @($manifest['Entries'] | ForEach-Object {
                [string](Get-BackupPropertyValue (Get-BackupPropertyValue $_ 'Restoration') 'Status' 'NotStarted')
            })
            $terminalStatuses = @('Restored', 'RestoredBestEffort', 'AlreadyRestored', 'NoLongerRunning', 'NotReversible')
            $baseline = Get-BackupPropertyValue $manifest 'Baseline' @{}
            $restorePoint = Get-BackupPropertyValue $manifest 'RestorePoint' @{}
            $items.Add([pscustomobject]@{
                ManifestPath   = $file.FullName
                TransactionId  = [string]$manifest['TransactionId']
                Name           = [string]$manifest['Name']
                Profile        = [string]$manifest['Profile']
                CreatedAtUtc   = [string]$manifest['CreatedAtUtc']
                Status         = [string]$manifest['Status']
                EntryCount     = @($manifest['Entries']).Count
                RestoredCount  = @($statuses | Where-Object { $_ -in @('Restored', 'RestoredBestEffort', 'AlreadyRestored', 'NoLongerRunning') }).Count
                NotReversibleCount = @($statuses | Where-Object { $_ -eq 'NotReversible' }).Count
                PendingCount   = @($statuses | Where-Object { $_ -notin $terminalStatuses }).Count
                HasBaseline    = [bool](Get-BackupPropertyValue $baseline 'Captured' $false)
                RestorePointRequested = [bool](Get-BackupPropertyValue $restorePoint 'Requested' $false)
                RestorePointSucceeded = [bool](Get-BackupPropertyValue $restorePoint 'Succeeded' $false)
                RestorePointError = [string](Get-BackupPropertyValue $restorePoint 'Error' '')
                Imported       = [bool](Get-BackupPropertyValue $manifest 'Imported' $false)
                IsValid        = $true
                ValidationError = ''
            })
        }
        catch {
            if ($IncludeInvalid) {
                $items.Add([pscustomobject]@{
                    ManifestPath = $file.FullName; TransactionId = ''; Name = $file.Directory.Name
                    Profile = ''; CreatedAtUtc = ''; Status = 'Invalid'; EntryCount = 0; RestoredCount = 0
                    NotReversibleCount = 0; PendingCount = 0; HasBaseline = $false
                    RestorePointRequested = $false; RestorePointSucceeded = $false; RestorePointError = ''; Imported = $false
                    IsValid = $false; ValidationError = $_.Exception.Message
                })
            }
        }
    }
    return @($items | Sort-Object @{ Expression = { $_.CreatedAtUtc }; Descending = $true })
}

function Get-OptimizerBackupList {
    [CmdletBinding()]
    param([switch]$IncludeInvalid)
    return Get-OptimizerBackups -IncludeInvalid:$IncludeInvalid
}

function Get-OptimizerBackupEntries {
    <#
        Retorna somente um resumo seguro das entradas de uma transacao. Os valores
        Original/Applied podem conter comandos, caminhos e dados internos e, por isso,
        nunca sao projetados diretamente para a interface.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ManifestPath)

    $ManifestPath = Assert-ManagedBackupManifestPath -ManifestPath $ManifestPath
    $manifest = Read-BackupManifest -ManifestPath $ManifestPath
    Test-BackupManifestObject -Manifest $manifest | Out-Null

    $typeLabels = @{
        RegistryValue = 'Registro'; Service = 'Servico'; ScheduledTask = 'Tarefa agendada'
        PowerPlan = 'Plano de energia'; PowerSetting = 'Configuracao de energia'
        StartupRegistry = 'Inicializacao (Registro)'; StartupFile = 'Inicializacao (arquivo)'
        PageFile = 'Arquivo de paginacao'; ProcessPriority = 'Prioridade de processo'
        GameSession = 'Sessao de jogo'; FileMove = 'Arquivo movido'
        SystemParameter = 'Efeito visual'; Process = 'Processo'; Appx = 'Aplicativo do Windows'
        CleanupManifest = 'Limpeza'; Irreversible = 'Operacao irreversivel'
    }
    $statusLabels = @{
        NotStarted = 'Pendente'; Restored = 'Restaurado'; RestoredBestEffort = 'Restaurado (melhor esforco)'
        AlreadyRestored = 'Ja restaurado'; NoLongerRunning = 'Nao esta mais em execucao'
        NotReversible = 'Nao reversivel'; Unsupported = 'Nao suportado'; Conflict = 'Conflito preservado'
        Error = 'Erro'; InProgress = 'Em andamento'; Simulated = 'Simulado'
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($manifest['Entries'] | Sort-Object { [int](Get-BackupPropertyValue $_ 'Sequence' 0) })) {
        $type = [string](Get-BackupPropertyValue $entry 'Type' '')
        $id = [string](Get-BackupPropertyValue $entry 'Id' '')
        $metadata = Get-BackupPropertyValue $entry 'Metadata' @{}
        $description = [string](Get-BackupPropertyValue $metadata 'Description' '')
        if ([string]::IsNullOrWhiteSpace($description)) { $description = $id }
        $restoration = Get-BackupPropertyValue $entry 'Restoration' @{}
        $status = [string](Get-BackupPropertyValue $restoration 'Status' 'NotStarted')
        $errorText = [string](Get-BackupPropertyValue $restoration 'Error' '')
        $reversible = -not (Test-BackupEntryNotReversible -Entry $entry)
        $typeLabel = if ($typeLabels.ContainsKey($type)) { [string]$typeLabels[$type] } else { $type }
        $statusLabel = if ($statusLabels.ContainsKey($status)) { [string]$statusLabels[$status] } else { $status }
        $requiresRestart = [bool](Get-BackupPropertyValue $metadata 'RequiresRestart' $false)

        $result.Add([pscustomobject]@{
            ManifestPath    = $ManifestPath
            EntryId         = [string](Get-BackupPropertyValue $entry 'EntryId' '')
            Sequence        = [int](Get-BackupPropertyValue $entry 'Sequence' 0)
            Type            = $type
            TypeLabel       = $typeLabel
            Resource        = $id
            Description     = $description
            Status          = $status
            StatusLabel     = $statusLabel
            Reversible      = $reversible
            ReversibleText  = $(if ($reversible) { 'Sim' } else { 'Nao' })
            RequiresRestart = $requiresRestart
            RestartText     = $(if ($requiresRestart) { 'Sim' } else { 'Nao' })
            Error           = $errorText
        })
    }
    return $result.ToArray()
}

function Get-RelativeBackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $fullRoot)) {
        throw "O caminho nao pertence ao pacote de backup: $Path"
    }
    if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $fullPath.Substring($fullRoot.Length).TrimStart('\')
}

function Get-SafeBackupBundleFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateRange(1, 10000)][int]$MaximumFiles = 4096,
        [ValidateRange(1, 2147483647)][int64]$MaximumBytes = 536870912
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'A origem do backup deve ser uma pasta.' }
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A pasta do backup importado e um ponto de nova analise.'
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $files = New-Object System.Collections.Generic.List[object]
    $pending.Push($resolvedRoot)
    [int64]$totalBytes = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Pontos de nova analise nao sao permitidos em backups importados: $($child.FullName)"
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
                continue
            }
            $files.Add($child)
            $totalBytes += [int64]$child.Length
            if ($files.Count -gt $MaximumFiles -or $totalBytes -gt $MaximumBytes) {
                throw 'O pacote de backup excede o limite seguro de arquivos ou tamanho.'
            }
        }
    }
    return $files.ToArray()
}

function Copy-SafeBackupBundleFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Files,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    Assert-NoReparsePointWithinRoot -Path $DestinationRoot -Root $DestinationRoot | Out-Null
    foreach ($file in @($Files)) {
        $relative = Get-RelativeBackupPath -Path ([string]$file.FullName) -Root $SourceRoot
        if ($relative -in @('manifest.json', 'manifest.sha256')) { continue }
        if ($relative -match '^(?i)manifest-recovery\\') { continue }
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $destination = Join-Path $DestinationRoot $relative
        if (-not (Test-PathWithinRoot -Path $destination -Root $DestinationRoot)) {
            throw "Destino de importacao invalido: $relative"
        }
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        Assert-NoReparsePointWithinRoot -Path $parent -Root $DestinationRoot | Out-Null
        Copy-Item -LiteralPath ([string]$file.FullName) -Destination $destination -Force -ErrorAction Stop
        Assert-NoReparsePointWithinRoot -Path $destination -Root $DestinationRoot | Out-Null
        $sourceHash = (Get-FileHash -LiteralPath ([string]$file.FullName) -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHash -ine $destinationHash) { throw "Falha de integridade ao copiar artefato: $relative" }
    }
}

function Resolve-ImportedPayloadPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RecordedPath,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DeclaredRoot,
        [Parameter(Mandatory = $true)]$BundleFiles,
        [Parameter(Mandatory = $true)][string]$EntryType
    )

    $relative = ''
    if (-not [string]::IsNullOrWhiteSpace($RecordedPath) -and
        (Test-PathWithinRoot -Path $RecordedPath -Root $SourceRoot)) {
        $relative = Get-RelativeBackupPath -Path $RecordedPath -Root $SourceRoot
    }
    elseif (-not [string]::IsNullOrWhiteSpace($RecordedPath) -and
        -not [string]::IsNullOrWhiteSpace($DeclaredRoot) -and
        (Test-PathWithinRoot -Path $RecordedPath -Root $DeclaredRoot)) {
        $relative = Get-RelativeBackupPath -Path $RecordedPath -Root $DeclaredRoot
    }
    elseif ($EntryType -eq 'StartupFile' -and -not [string]::IsNullOrWhiteSpace($RecordedPath)) {
        $relative = Join-Path 'startup-files' ([IO.Path]::GetFileName($RecordedPath))
    }
    else {
        throw 'O artefato movido nao pertence ao pacote de backup importado.'
    }

    $candidate = Join-Path $SourceRoot $relative
    if (-not (Test-PathWithinRoot -Path $candidate -Root $SourceRoot)) {
        throw 'O caminho relativo do artefato importado e invalido.'
    }
    $match = @($BundleFiles | Where-Object {
        ([string]$_.FullName).Equals([IO.Path]::GetFullPath($candidate), [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($match.Count -ne 1) { throw "Artefato do backup nao encontrado: $relative" }
    return [pscustomobject]@{ SourcePath = [string]$match[0].FullName; RelativePath = $relative }
}

function Import-OptimizerBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path)

    $context = Get-BackupContext
    if ([bool]$context.ReadOnly) { throw 'Importacao bloqueada em modo somente leitura.' }
    $sourceManifest = if (Test-Path -LiteralPath $Path -PathType Container) { Join-Path $Path 'manifest.json' } else { $Path }
    $sourceManifest = (Resolve-Path -LiteralPath $sourceManifest -ErrorAction Stop).Path
    $sourceRoot = Split-Path -Parent $sourceManifest
    $sourceHash = Join-Path $sourceRoot 'manifest.sha256'
    if (-not (Test-Path -LiteralPath $sourceHash -PathType Leaf)) {
        throw 'O backup nao possui manifest.sha256 e nao pode ser importado com seguranca.'
    }
    $manifest = Read-BackupManifest -ManifestPath $sourceManifest
    Test-BackupManifestObject -Manifest $manifest | Out-Null
    $bundleFiles = @(Get-SafeBackupBundleFiles -Root $sourceRoot)
    Assert-NoReparsePointWithinRoot -Path ([string]$context.BackupRoot) -Root ([string]$context.BackupRoot) | Out-Null

    return Invoke-WithBackupMutex -ScriptBlock {
        $newTransactionId = [guid]::NewGuid().ToString('D')
        $folder = Join-Path $context.BackupRoot ('Imported_{0}_{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $newTransactionId)
        $createdFolder = $false
        try {
            $declaredRoot = [string](Get-BackupPropertyValue $manifest 'FolderPath' $sourceRoot)
            if ([string]::IsNullOrWhiteSpace($declaredRoot)) { $declaredRoot = $sourceRoot }
            $sourceStatus = [string](Get-BackupPropertyValue $manifest 'Status' '')
            $sourceCreatedAt = [string](Get-BackupPropertyValue $manifest 'CreatedAtUtc' '')
            $sourceTransactionId = [string](Get-BackupPropertyValue $manifest 'TransactionId' '')

            foreach ($entryObject in @(Get-BackupPropertyValue $manifest 'Entries' @())) {
                $entry = ConvertTo-BackupHashtable -InputObject $entryObject
                $type = [string](Get-BackupPropertyValue $entry 'Type' '')
                $metadata = ConvertTo-BackupHashtable -InputObject (Get-BackupPropertyValue $entry 'Metadata' @{})
                if ($null -eq $metadata) { $metadata = [ordered]@{} }
                if ($type -in @('Process', 'Appx', 'StartupRegistry', 'StartupFile', 'FileMove')) {
                    $metadata['Reversible'] = $false
                    $metadata['ImportRestriction'] = switch ($type) {
                        'Process' { 'Processos nao sao reiniciados a partir de backup importado.' }
                        'Appx' { 'Pacotes Appx nao sao registrados a partir de backup importado; use o backup local original.' }
                        default { 'Itens de inicializacao e arquivos movidos exigem restauracao pelo backup local autenticado.' }
                    }
                }
                $entry['Metadata'] = $metadata

                if ($type -in @('StartupFile', 'FileMove')) {
                    $paths = Get-FileEntryPaths -Entry $entry
                    $payload = Resolve-ImportedPayloadPath -RecordedPath ([string]$paths.DisabledPath) `
                        -SourceRoot $sourceRoot -DeclaredRoot $declaredRoot -BundleFiles $bundleFiles -EntryType $type
                    $expectedHash = [string](Get-BackupPropertyValue (Get-BackupPropertyValue $entry 'Applied') 'Sha256' `
                        (Get-BackupPropertyValue (Get-BackupPropertyValue $entry 'Original') 'Sha256' ''))
                    if ($expectedHash -match '^[A-Fa-f0-9]{64}$') {
                        $actualHash = (Get-FileHash -LiteralPath $payload.SourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ($actualHash -ine $expectedHash) { throw "Hash invalido no artefato importado: $($payload.RelativePath)" }
                    }
                    else {
                        $metadata['Reversible'] = $false
                        $metadata['ImportRestriction'] = 'Artefato importado sem hash SHA-256 individual.'
                        $entry['Metadata'] = $metadata
                    }
                    $targetPayload = Join-Path $folder $payload.RelativePath
                    $entry['Original']['DisabledPath'] = $targetPayload
                    $entry['Applied']['DisabledPath'] = $targetPayload
                }

                $entry['Restoration'] = [ordered]@{
                    Status = 'NotStarted'; AttemptedAtUtc = $null
                    CurrentBefore = $null; CurrentAfter = $null; Error = ''
                }
                for ($index = 0; $index -lt $manifest['Entries'].Count; $index++) {
                    if ([string](Get-BackupPropertyValue $manifest['Entries'][$index] 'EntryId' '') -eq
                        [string](Get-BackupPropertyValue $entry 'EntryId' '')) {
                        $manifest['Entries'][$index] = $entry
                        break
                    }
                }
            }

            foreach ($export in @(Get-BackupPropertyValue $manifest 'RegistryExports' @())) {
                if (-not [bool](Get-BackupPropertyValue $export 'Succeeded' $false)) { continue }
                $relativeFile = [string](Get-BackupPropertyValue $export 'File' '')
                if ([IO.Path]::IsPathRooted($relativeFile) -or [string]::IsNullOrWhiteSpace($relativeFile)) {
                    throw 'Caminho invalido em artefato de Registro importado.'
                }
                $sourceFile = Join-Path $sourceRoot $relativeFile
                if (-not (Test-PathWithinRoot -Path $sourceFile -Root $sourceRoot)) {
                    throw 'Artefato de Registro fora do pacote importado.'
                }
                $bundleMatch = @($bundleFiles | Where-Object {
                    ([string]$_.FullName).Equals([IO.Path]::GetFullPath($sourceFile), [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
                if ($bundleMatch.Count -ne 1) { throw "Artefato de Registro ausente: $relativeFile" }
                $expectedHash = [string](Get-BackupPropertyValue $export 'Sha256' '')
                if ($expectedHash -match '^[A-Fa-f0-9]{64}$') {
                    $actualHash = (Get-FileHash -LiteralPath $bundleMatch[0].FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($actualHash -ine $expectedHash) { throw "Hash invalido no artefato de Registro: $relativeFile" }
                }
                else { throw "O artefato de Registro nao possui hash SHA-256 valido: $relativeFile" }
            }

            $now = [datetime]::UtcNow.ToString('o')
            $manifest['Imported'] = $true
            $manifest['ImportedAtUtc'] = $now
            $manifest['ImportedFromTransactionId'] = $sourceTransactionId
            $manifest['ImportedFromPath'] = $sourceManifest
            $manifest['ImportedSourceStatus'] = $sourceStatus
            $manifest['ImportedSourceCreatedAtUtc'] = $sourceCreatedAt
            $manifest['TransactionId'] = $newTransactionId
            $manifest['CreatedAtUtc'] = $now
            $manifest['CompletedAtUtc'] = $now
            $manifest['Status'] = 'Completed'
            $manifest['ErrorMessage'] = ''
            $manifest['ManifestPath'] = Join-Path $folder 'manifest.json'
            $manifest['RootPath'] = $folder
            $manifest['FolderPath'] = $folder
            $manifest['Restoration'] = [ordered]@{
                Status = 'NotStarted'; StartedAtUtc = $null; CompletedAtUtc = $null; Error = ''
            }
            Test-BackupManifestObject -Manifest $manifest | Out-Null

            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            $createdFolder = $true
            Assert-NoReparsePointWithinRoot -Path $folder -Root ([string]$context.BackupRoot) | Out-Null
            $manifest['FolderIntegrity'] = Set-BackupFolderHighIntegrity -Path $folder
            Copy-SafeBackupBundleFiles -Files $bundleFiles -SourceRoot $sourceRoot -DestinationRoot $folder
            # Revalida artefatos no destino real antes de confirmar a importacao.
            # Isto impede TOCTOU entre a leitura do pacote e a copia do baseline.
            Test-BackupManifestObject -Manifest $manifest | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $folder 'registry') -Force -ErrorAction Stop | Out-Null
            Write-BackupManifest -Manifest $manifest -ManifestPath ([string]$manifest['ManifestPath'])
            Write-BackupLog -Name 'Backup importado' -OldValue $sourceManifest -NewValue $manifest['ManifestPath'] `
                -Result 'Success' -Details @{ TransactionId = $newTransactionId; SourceTransactionId = $sourceTransactionId }
            return ConvertTo-PublicBackupObject $manifest
        }
        catch {
            if ($createdFolder -and (Test-Path -LiteralPath $folder -PathType Container) -and
                (Test-PathWithinRoot -Path $folder -Root ([string]$context.BackupRoot)) -and
                [IO.Path]::GetFileName($folder) -like 'Imported_*') {
                try {
                    Assert-NoReparsePointWithinRoot -Path $folder -Root ([string]$context.BackupRoot) | Out-Null
                    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
                }
                catch { }
            }
            throw
        }
    }
}

function Restore-OptimizerBackupItem {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][Alias('Id')][string]$EntryId,
        [switch]$Force
    )
    return Restore-OptimizerBackup -ManifestPath $ManifestPath -EntryId $EntryId -Force:$Force `
        -WhatIf:$WhatIfPreference -Confirm:$false
}

function Undo-LastOptimizerBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([switch]$Force)

    $candidate = Get-OptimizerBackups | Where-Object {
        $_.IsValid -and $_.PendingCount -gt 0 -and $_.Status -ne 'InProgress'
    } | Select-Object -First 1
    if (-not $candidate) { throw 'Nenhum backup pendente de restauracao foi encontrado.' }
    return Restore-OptimizerBackup -ManifestPath $candidate.ManifestPath -Force:$Force `
        -WhatIf:$WhatIfPreference -Confirm:$false
}

function Undo-LastOptimization {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([switch]$Force)
    return Undo-LastOptimizerBackup -Force:$Force -WhatIf:$WhatIfPreference -Confirm:$false
}

function Restore-AllOptimizerBackups {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([switch]$Force)

    $backups = @(Get-OptimizerBackups | Where-Object {
        $_.IsValid -and $_.PendingCount -gt 0 -and $_.Status -ne 'InProgress'
    } | Sort-Object CreatedAtUtc -Descending)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($backup in $backups) {
        try {
            $entryResults = @(Restore-OptimizerBackup -ManifestPath $backup.ManifestPath -Force:$Force `
                -WhatIf:$WhatIfPreference -Confirm:$false)
            $results.Add([pscustomobject]@{ ManifestPath = $backup.ManifestPath; Status = 'Processed'; Results = $entryResults; Error = '' })
        }
        catch {
            $results.Add([pscustomobject]@{ ManifestPath = $backup.ManifestPath; Status = 'Error'; Results = @(); Error = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

function Restore-AllOptimizerChanges {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([switch]$Force)
    return Restore-AllOptimizerBackups -Force:$Force -WhatIf:$WhatIfPreference -Confirm:$false
}

function Open-OptimizerBackupFolder {
    [CmdletBinding()]
    param([string]$ManifestPath)

    $context = Get-BackupContext
    $path = if ($ManifestPath) { Split-Path -Parent (Assert-ManagedBackupManifestPath -ManifestPath $ManifestPath) } else { $context.BackupRoot }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Pasta de backup nao encontrada: $path" }
    Assert-NoReparsePointWithinRoot -Path $path -Root ([string]$context.BackupRoot) | Out-Null
    Start-Process -FilePath 'explorer.exe' -ArgumentList @("`"$path`"") -ErrorAction Stop | Out-Null
    return $path
}

Export-ModuleMember -Function Start-OptimizerBackup, Get-CurrentOptimizerBackup,
    Set-OptimizerBackupBaseline, Add-OptimizerBackupEntry, Complete-OptimizerBackup, Restore-OptimizerBackup,
    Restore-OptimizerBackupItem, Get-OptimizerBackups, Get-OptimizerBackupList,
    Get-OptimizerBackupEntries,
    Import-OptimizerBackup, Undo-LastOptimizerBackup, Undo-LastOptimization,
    Restore-AllOptimizerBackups, Restore-AllOptimizerChanges, Open-OptimizerBackupFolder
