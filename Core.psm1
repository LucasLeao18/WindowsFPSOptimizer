#requires -Version 5.1

Set-StrictMode -Version Latest

$script:OptimizerContext = $null
$script:AllowedRegistryRoots = @('HKCU:', 'HKLM:')
$script:BlockedRegistryPattern = '(?i)(\\Tcpip6?(\\|$)|\\Winsock|\\Dnscache|\\NetworkList|\\NetworkProvider|\\Internet Settings|\\FirewallPolicy|\\QoS|\\Teredo|\\WcmSvc|\\NlaSvc)'
$script:BlockedNativePattern = '(?i)(netsh|winsock|\bdns\b|tcp\/?ip|\bmtu\b|firewall|\bproxy\b|teredo|\bqos\b|\broute\b|routing|\bwlan\b|ethernet|network\s*adapter)'

function Write-CoreLog {
    param(
        [string]$Name,
        [string]$Category = 'Core',
        $OldValue,
        $NewValue,
        [string]$Result = 'Info',
        [string]$ErrorMessage = '',
        [bool]$RequiresRestart = $false,
        [string]$Level = 'Information'
    )

    if (Get-Command Write-OptimizerLog -ErrorAction SilentlyContinue) {
        Write-OptimizerLog -Name $Name -Category $Category -OldValue $OldValue -NewValue $NewValue `
            -Result $Result -ErrorMessage $ErrorMessage -RequiresRestart $RequiresRestart `
            -Profile $(if ($script:OptimizerContext) { $script:OptimizerContext.CurrentProfile } else { '' }) `
            -Level $Level | Out-Null
    }
}

function Test-Administrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-OptimizerTrustedProgramFilesPath {
    [CmdletBinding()]
    param()

    $view = if ([Environment]::Is64BitOperatingSystem) {
        [Microsoft.Win32.RegistryView]::Registry64
    }
    else {
        [Microsoft.Win32.RegistryView]::Registry32
    }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        $view
    )
    $currentVersionKey = $null
    try {
        $currentVersionKey = $baseKey.OpenSubKey(
            'SOFTWARE\Microsoft\Windows\CurrentVersion',
            $false
        )
        if ($null -eq $currentVersionKey) { throw 'CurrentVersion ausente.' }
        $programFilesPath = [string]$currentVersionKey.GetValue(
            'ProgramFilesDir',
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        if ([string]::IsNullOrWhiteSpace($programFilesPath) -or $programFilesPath.Contains('%')) {
            throw 'ProgramFilesDir invalido.'
        }
        return [IO.Path]::GetFullPath($programFilesPath)
    }
    finally {
        if ($null -ne $currentVersionKey) { $currentVersionKey.Dispose() }
        $baseKey.Dispose()
    }
}

function Test-OptimizerProtectedCodePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    try {
        $programFilesPath = Get-OptimizerTrustedProgramFilesPath

        $trustedRoot = [IO.Path]::GetFullPath(
            (Join-Path $programFilesPath 'WindowsFPSOptimizer\App')
        ).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $scriptFull = [IO.Path]::GetFullPath($ScriptPath)
        if (-not $scriptFull.StartsWith($trustedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        if (-not (Test-Path -LiteralPath $scriptFull -PathType Leaf)) {
            return $false
        }

        # Nenhum componente entre Program Files e o script pode redirecionar
        # para uma pasta gravavel pelo usuario.
        $pathRoot = [IO.Path]::GetPathRoot($scriptFull)
        $relativePart = $scriptFull.Substring($pathRoot.Length)
        $cursor = $pathRoot
        foreach ($segment in @($relativePart -split '[\\/]')) {
            if ([string]::IsNullOrWhiteSpace($segment)) { continue }
            $cursor = Join-Path $cursor $segment
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $false
                }
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-WindowsPlatformInfo {
    [CmdletBinding()]
    param()

    $caption = [Environment]::OSVersion.VersionString
    $edition = ''
    $build = [Environment]::OSVersion.Version.Build
    $version = [Environment]::OSVersion.Version
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = [string]$os.Caption
        $edition = [string]$os.OperatingSystemSKU
        $version = [version]$os.Version
        $build = [int]$os.BuildNumber
    }
    catch { }

    return [pscustomobject]@{
        Caption       = $caption
        EditionSku    = $edition
        Version       = $version.ToString()
        Build         = $build
        IsWindows10   = ($build -ge 10240 -and $build -lt 22000)
        IsWindows11   = ($build -ge 22000)
        IsSupported   = ($build -ge 10240)
        Is64BitOS     = [Environment]::Is64BitOperatingSystem
        PowerShell    = $PSVersionTable.PSVersion.ToString()
    }
}

function ConvertTo-OptimizerHashtable {
    <# Converte PSCustomObject recursivamente para facilitar consultas de configuracao. #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$InputObject)

    # No Windows PowerShell 5.1, o operador `-is [pscustomobject]` tambem pode
    # aceitar valores escalares que receberam membros adaptados pelo ETS. Trate
    # escalares antes de objetos JSON para preservar listas como string[].
    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[$key] = ConvertTo-OptimizerHashtable $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-OptimizerHashtable $_ })
    }
    if ($InputObject.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-OptimizerHashtable $property.Value
        }
        return $table
    }
    return $InputObject
}

function Initialize-OptimizerContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AppRoot,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ConfigPath,
        [switch]$Simulation,
        [switch]$ReadOnly
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Arquivo de configuracao nao encontrado: $ConfigPath"
    }
    try {
        $configuration = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $configuration = ConvertTo-OptimizerHashtable $configuration
    }
    catch {
        throw "Config.json invalido: $($_.Exception.Message)"
    }

    $platform = Get-WindowsPlatformInfo
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localData)) { $localData = $AppRoot }
    $dataRoot = Join-Path $localData 'WindowsFPSOptimizer'
    $dataIsPersistent = $true
    try {
        foreach ($folder in @($dataRoot, (Join-Path $dataRoot 'Logs'), (Join-Path $dataRoot 'Backups'), (Join-Path $dataRoot 'State'))) {
            if (-not (Test-Path -LiteralPath $folder)) {
                New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            }
        }
    }
    catch {
        # Nunca tente gravar junto ao codigo protegido em Program Files. O
        # fallback temporario permite diagnostico/simulacao, mas mutacoes reais
        # serao recusadas porque nao ha garantia de backup persistente.
        $dataRoot = Join-Path ([IO.Path]::GetTempPath()) 'WindowsFPSOptimizer'
        $dataIsPersistent = $false
        foreach ($folder in @($dataRoot, (Join-Path $dataRoot 'Logs'), (Join-Path $dataRoot 'Backups'), (Join-Path $dataRoot 'State'))) {
            if (-not (Test-Path -LiteralPath $folder)) {
                New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            }
        }
    }

    $script:OptimizerContext = [pscustomobject]@{
        AppRoot          = (Resolve-Path -LiteralPath $AppRoot -ErrorAction Stop).Path
        ConfigPath       = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
        Config           = $configuration
        DataRoot         = $dataRoot
        LogRoot          = Join-Path $dataRoot 'Logs'
        BackupRoot       = Join-Path $dataRoot 'Backups'
        StateRoot        = Join-Path $dataRoot 'State'
        SessionId        = [guid]::NewGuid().ToString('N')
        StartedAt        = Get-Date
        IsAdministrator  = Test-Administrator
        CodePathProtected = Test-OptimizerProtectedCodePath -ScriptPath (
            Join-Path $AppRoot 'WindowsFPSOptimizer.ps1'
        )
        DataIsPersistent  = $dataIsPersistent
        Simulation       = [bool]$Simulation
        ReadOnly         = [bool]$ReadOnly
        Platform         = $platform
        CurrentProfile   = ''
        Cancellation     = $false
        Version          = [string]$configuration.App.Version
    }

    return $script:OptimizerContext
}

function Get-OptimizerContext {
    [CmdletBinding()]
    param()
    if (-not $script:OptimizerContext) { throw 'O contexto do aplicativo ainda nao foi inicializado.' }
    return $script:OptimizerContext
}

function Set-OptimizerMode {
    [CmdletBinding()]
    param([Nullable[bool]]$Simulation, [Nullable[bool]]$ReadOnly)

    $context = Get-OptimizerContext
    if ($null -ne $Simulation) { $context.Simulation = [bool]$Simulation }
    if ($null -ne $ReadOnly) { $context.ReadOnly = [bool]$ReadOnly }
    Write-CoreLog -Name 'Modo do aplicativo alterado' -OldValue '' `
        -NewValue @{ Simulation = $context.Simulation; ReadOnly = $context.ReadOnly }
    return $context
}

function Set-OptimizerCurrentProfile {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Name)
    (Get-OptimizerContext).CurrentProfile = $Name
}

function Request-OptimizerCancellation {
    [CmdletBinding()]
    param()
    (Get-OptimizerContext).Cancellation = $true
}

function Reset-OptimizerCancellation {
    [CmdletBinding()]
    param()
    (Get-OptimizerContext).Cancellation = $false
}

function Test-OptimizerCancellation {
    [CmdletBinding()]
    param()
    return [bool](Get-OptimizerContext).Cancellation
}

function Assert-OptimizerMutationAllowed {
    [CmdletBinding()]
    param([switch]$RequiresAdministrator, [string]$Operation = 'Alteracao')

    $context = Get-OptimizerContext
    if ($context.ReadOnly) { throw "$Operation foi bloqueada porque o modo somente leitura esta ativo." }
    if (-not $context.Simulation -and -not $context.CodePathProtected) {
        throw (
            "$Operation foi bloqueada porque o codigo nao esta em uma instalacao protegida. " +
            'Use o Setup.exe e execute o aplicativo pelo atalho de Program Files.'
        )
    }
    if (-not $context.Simulation -and -not $context.DataIsPersistent) {
        throw (
            "$Operation foi bloqueada porque nao existe armazenamento persistente " +
            'para backups e logs no perfil do usuario.'
        )
    }
    if ($RequiresAdministrator -and -not $context.IsAdministrator -and -not $context.Simulation) {
        throw "$Operation requer execucao como administrador. Reinicie o aplicativo com elevacao."
    }
    return $true
}

function Test-SafeRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Trim()
    $validRoot = $false
    foreach ($root in $script:AllowedRegistryRoots) {
        if ($normalized.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $validRoot = $true; break }
    }
    if (-not $validRoot) { return $false }
    if ($normalized -match $script:BlockedRegistryPattern) { return $false }
    return $true
}

function Assert-SafeRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-SafeRegistryPath -Path $Path)) {
        throw "Caminho do Registro fora do escopo permitido ou relacionado a rede: $Path"
    }
}

function Get-RegistryValueState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )

    Assert-SafeRegistryPath -Path $Path
    $state = [ordered]@{
        Path          = $Path
        Name          = $Name
        PathExisted   = $false
        ValueExisted  = $false
        Value         = $null
        Kind          = $null
    }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$state }
    $state.PathExisted = $true
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = @($key.GetValueNames())
        if ($names -contains $Name) {
            $state.ValueExisted = $true
            $state.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $state.Kind = $key.GetValueKind($Name).ToString()
        }
    }
    catch { }
    return [pscustomobject]$state
}

function Compare-OptimizerValue {
    [CmdletBinding()]
    param($Left, $Right)

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if (($Left -is [array]) -or ($Right -is [array])) {
        return ((ConvertTo-Json @($Left) -Compress) -eq (ConvertTo-Json @($Right) -Compress))
    }
    return ([string]$Left -ceq [string]$Right)
}

function Set-SafeRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Type = 'DWord',
        [string]$Description = 'Alteracao de Registro',
        [bool]$RequiresRestart = $false,
        [switch]$RequiresAdministrator
    )

    Assert-SafeRegistryPath -Path $Path
    Assert-OptimizerMutationAllowed -RequiresAdministrator:$RequiresAdministrator -Operation $Description | Out-Null
    $context = Get-OptimizerContext
    $before = Get-RegistryValueState -Path $Path -Name $Name
    if ($before.ValueExisted -and (Compare-OptimizerValue $before.Value $Value) -and $before.Kind -eq $Type) {
        Write-CoreLog -Name $Description -Category 'Registro' -OldValue $before.Value -NewValue $Value `
            -Result 'Skipped' -RequiresRestart $RequiresRestart
        return [pscustomobject]@{ Changed = $false; Result = 'Skipped'; Before = $before; After = $before }
    }

    if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
        Add-OptimizerBackupEntry -Type 'RegistryValue' -Id "$Path|$Name" -Original $before `
            -Applied ([pscustomobject]@{ ValueExisted = $true; Value = $Value; Kind = $Type }) `
            -Metadata @{ Description = $Description; RequiresRestart = $RequiresRestart } | Out-Null
    }

    if ($context.Simulation) {
        Write-CoreLog -Name $Description -Category 'Registro' -OldValue $before.Value -NewValue $Value `
            -Result 'Simulated' -RequiresRestart $RequiresRestart
        return [pscustomobject]@{ Changed = $false; Result = 'Simulated'; Before = $before; After = $null }
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        $after = Get-RegistryValueState -Path $Path -Name $Name
        if (-not $after.ValueExisted -or -not (Compare-OptimizerValue $after.Value $Value)) {
            throw 'A verificacao posterior nao encontrou o valor solicitado.'
        }
        Write-CoreLog -Name $Description -Category 'Registro' -OldValue $before.Value -NewValue $after.Value `
            -Result 'Success' -RequiresRestart $RequiresRestart
        return [pscustomobject]@{ Changed = $true; Result = 'Success'; Before = $before; After = $after }
    }
    catch {
        Write-CoreLog -Name $Description -Category 'Registro' -OldValue $before.Value -NewValue $Value `
            -Result 'Error' -ErrorMessage $_.Exception.Message -RequiresRestart $RequiresRestart -Level 'Error'
        throw
    }
}

function Remove-SafeRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [string]$Description = 'Remocao de valor do Registro',
        [bool]$RequiresRestart = $false,
        [switch]$RequiresAdministrator
    )

    Assert-SafeRegistryPath -Path $Path
    Assert-OptimizerMutationAllowed -RequiresAdministrator:$RequiresAdministrator -Operation $Description | Out-Null
    $context = Get-OptimizerContext
    $before = Get-RegistryValueState -Path $Path -Name $Name
    if (-not $before.ValueExisted) {
        Write-CoreLog -Name $Description -Category 'Registro' -OldValue $null -NewValue $null `
            -Result 'Skipped' -RequiresRestart $RequiresRestart
        return [pscustomobject]@{ Changed = $false; Result = 'Skipped'; Before = $before; After = $before }
    }

    if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
        Add-OptimizerBackupEntry -Type 'RegistryValue' -Id "$Path|$Name" -Original $before `
            -Applied ([pscustomobject]@{ ValueExisted = $false; Value = $null; Kind = $null }) `
            -Metadata @{ Description = $Description; RequiresRestart = $RequiresRestart } | Out-Null
    }
    if ($context.Simulation) {
        Write-CoreLog -Name $Description -Category 'Registro' -OldValue $before.Value -NewValue $null `
            -Result 'Simulated' -RequiresRestart $RequiresRestart
        return [pscustomobject]@{ Changed = $false; Result = 'Simulated'; Before = $before; After = $null }
    }

    Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
    $after = Get-RegistryValueState -Path $Path -Name $Name
    if ($after.ValueExisted) { throw 'O valor permaneceu presente apos a remocao.' }
    Write-CoreLog -Name $Description -Category 'Registro' -OldValue $before.Value -NewValue $null `
        -Result 'Success' -RequiresRestart $RequiresRestart
    return [pscustomobject]@{ Changed = $true; Result = 'Success'; Before = $before; After = $after }
}

function Test-SafeNativeCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList)

    $allowed = @('powercfg.exe', 'sfc.exe', 'dism.exe', 'chkdsk.exe', 'reg.exe', 'defrag.exe', 'cleanmgr.exe')
    $leaf = [IO.Path]::GetFileName($FilePath)
    if ($allowed -notcontains $leaf.ToLowerInvariant()) { return $false }
    $joined = [string]::Join(' ', @($ArgumentList))
    return -not ($joined -match $script:BlockedNativePattern)
}

function Invoke-SafeNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Description = 'Comando do Windows',
        [switch]$RequiresAdministrator,
        [switch]$Mutating,
        [int[]]$SuccessExitCodes = @(0)
    )

    if (-not (Test-SafeNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList)) {
        throw "Comando nao permitido ou contem parametros relacionados a rede: $FilePath"
    }
    if ($Mutating) {
        Assert-OptimizerMutationAllowed -RequiresAdministrator:$RequiresAdministrator -Operation $Description | Out-Null
        if ((Get-OptimizerContext).Simulation) {
            Write-CoreLog -Name $Description -Category 'Comando' -OldValue '' -NewValue ($ArgumentList -join ' ') -Result 'Simulated'
            return [pscustomobject]@{ ExitCode = 0; Output = @('SIMULADO'); Simulated = $true }
        }
    }
    elseif ($RequiresAdministrator -and -not (Get-OptimizerContext).IsAdministrator) {
        throw "$Description requer execucao como administrador."
    }

    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        if ($SuccessExitCodes -notcontains [int]$exitCode) {
            throw "Codigo de saida $exitCode. $($output -join [Environment]::NewLine)"
        }
        Write-CoreLog -Name $Description -Category 'Comando' -OldValue '' -NewValue ($ArgumentList -join ' ') -Result 'Success'
        return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output; Simulated = $false }
    }
    catch {
        Write-CoreLog -Name $Description -Category 'Comando' -OldValue '' -NewValue ($ArgumentList -join ' ') `
            -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
        throw
    }
}

function Test-SafeExecutablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return (-not $item.PSIsContainer -and $item.Extension -ieq '.exe')
    }
    catch { return $false }
}

function Save-OptimizerJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject,
        [ValidateRange(2, 100)][int]$Depth = 20
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $InputObject | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $tempPath -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
    return Get-Item -LiteralPath $Path -ErrorAction Stop
}

function Invoke-OptimizerOperation {
    <#
        Executa uma unidade transacional. Em perfis, a transacao externa e reutilizada;
        em uma acao individual, cria backup e tenta rollback se ocorrer falha.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [ValidateSet('Seguro', 'Moderado', 'Agressivo')][string]$Risk = 'Seguro',
        [switch]$RequiresAdministrator,
        [switch]$RequiresRestart,
        [switch]$SkipRestorePoint
    )

    Assert-OptimizerMutationAllowed -RequiresAdministrator:$RequiresAdministrator -Operation $Name | Out-Null
    $context = Get-OptimizerContext
    $ownsBackup = $false
    $backup = $null

    if (-not $context.Simulation -and (Get-Command Start-OptimizerBackup -ErrorAction SilentlyContinue)) {
        $current = if (Get-Command Get-CurrentOptimizerBackup -ErrorAction SilentlyContinue) { Get-CurrentOptimizerBackup } else { $null }
        if (-not $current) {
            # Um checkpoint e sempre solicitado para a transacao raiz. O Windows pode
            # recusar por Protecao do Sistema desativada ou limite proprio; o manifesto
            # registra essa condicao e os snapshots JSON/.reg continuam obrigatorios.
            $backup = Start-OptimizerBackup -Name $Name -Profile $context.CurrentProfile -CreateRestorePoint
            $ownsBackup = $true
        }
    }

    try {
        Write-CoreLog -Name $Name -Category 'Operacao' -OldValue '' -NewValue @{ Risk = $Risk } -Result 'Info'
        $result = & $ScriptBlock
        if ($ownsBackup -and (Get-Command Complete-OptimizerBackup -ErrorAction SilentlyContinue)) {
            Complete-OptimizerBackup -Status 'Completed' | Out-Null
        }
        return $result
    }
    catch {
        $message = $_.Exception.Message
        Write-CoreLog -Name $Name -Category 'Operacao' -OldValue '' -NewValue '' -Result 'Error' -ErrorMessage $message -Level 'Error'
        if ($ownsBackup -and (Get-Command Complete-OptimizerBackup -ErrorAction SilentlyContinue)) {
            Complete-OptimizerBackup -Status 'Failed' -ErrorMessage $message | Out-Null
            if ($backup -and (Get-Command Restore-OptimizerBackup -ErrorAction SilentlyContinue)) {
                try { Restore-OptimizerBackup -ManifestPath $backup.ManifestPath -Force | Out-Null } catch { }
            }
        }
        throw
    }
}

function Start-OptimizerElevated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$AdditionalArguments = @()
    )

    if (Test-Administrator) { return $false }
    if (-not (Test-OptimizerProtectedCodePath -ScriptPath $ScriptPath)) {
        throw (
            'Elevacao recusada: o script precisa estar instalado sob Program Files, ' +
            'sem junctions ou links simbolicos. Execute o Setup.exe primeiro.'
        )
    }

    $powerShellPath = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 nao foi encontrado no caminho nativo do Windows.'
    }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $ScriptPath))
    $arguments += $AdditionalArguments
    Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList ($arguments -join ' ') -ErrorAction Stop | Out-Null
    return $true
}

Export-ModuleMember -Function Initialize-OptimizerContext, Get-OptimizerContext, Set-OptimizerMode,
    Test-Administrator, Test-OptimizerProtectedCodePath, Get-WindowsPlatformInfo, Assert-OptimizerMutationAllowed,
    Test-SafeRegistryPath, Assert-SafeRegistryPath, Get-RegistryValueState,
    Set-SafeRegistryValue, Remove-SafeRegistryValue, Compare-OptimizerValue,
    Test-SafeNativeCommand, Invoke-SafeNativeCommand, Test-SafeExecutablePath,
    Save-OptimizerJsonFile, Invoke-OptimizerOperation, Start-OptimizerElevated,
    Set-OptimizerCurrentProfile, Request-OptimizerCancellation, Reset-OptimizerCancellation,
    Test-OptimizerCancellation
