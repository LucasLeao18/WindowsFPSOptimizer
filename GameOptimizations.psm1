#requires -Version 5.1

Set-StrictMode -Version Latest

$script:GameModePath = 'HKCU:\Software\Microsoft\GameBar'
$script:GameModeName = 'AutoGameModeEnabled'
$script:GameDvrPolicyPath = 'HKLM:\Software\Policies\Microsoft\Windows\GameDVR'
$script:GameDvrPolicyName = 'AllowGameDVR'
$script:GameProfileSchemaVersion = 1
$script:GameSettingsPages = @{
    GameMode         = @{ Uri = 'ms-settings:gaming-gamemode'; MinimumBuild = 10240 }
    GameBar          = @{ Uri = 'ms-settings:gaming-gamebar'; MinimumBuild = 10240 }
    Captures         = @{ Uri = 'ms-settings:gaming-gamedvr'; MinimumBuild = 10240 }
    Hags             = @{ Uri = 'ms-settings:display-advancedgraphics-default'; MinimumBuild = 19041 }
    Graphics         = @{ Uri = 'ms-settings:display-advancedgraphics'; MinimumBuild = 17134 }
    WindowedGames    = @{ Uri = 'ms-settings:display-advancedgraphics'; MinimumBuild = 22621 }
    DoNotDisturbGame = @{ Uri = 'ms-settings:quietmomentsgame'; MinimumBuild = 16299 }
    DoNotDisturb     = @{ Uri = 'ms-settings:quiethours'; MinimumBuild = 15063 }
    Notifications    = @{ Uri = 'ms-settings:notifications'; MinimumBuild = 10240 }
}

function Write-GameOptimizerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $OldValue,
        $NewValue,
        [ValidateSet('Success', 'Skipped', 'Simulated', 'Warning', 'Error', 'Info', 'Restored')]
        [string]$Result = 'Info',
        [string]$ErrorMessage = '',
        [bool]$RequiresRestart = $false,
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')][string]$Level = 'Information'
    )

    if (Get-Command Write-OptimizerLog -ErrorAction SilentlyContinue) {
        $profile = ''
        try { $profile = [string](Get-OptimizerContext).CurrentProfile } catch { }
        Write-OptimizerLog -Name $Name -Category 'Jogos' -OldValue $OldValue -NewValue $NewValue `
            -Result $Result -ErrorMessage $ErrorMessage -RequiresRestart $RequiresRestart `
            -Profile $profile -Level $Level | Out-Null
    }
}

function Get-GameEditionSupport {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    $caption = [string]$platform.Caption
    $editionId = ''
    $productName = ''
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $editionId = [string]$currentVersion.EditionID
        $productName = [string]$currentVersion.ProductName
    }
    catch { }
    $editionText = "$caption $editionId $productName"
    $isEnterprise = $editionText -match '(?i)Enterprise|Education|IoT'
    $isPro = $isEnterprise -or $editionText -match '(?i)\bPro\b|Professional|Workstation'
    $isHome = $editionText -match '(?i)\bHome\b|Core|Single Language'
    return [pscustomobject]@{
        Caption       = $caption
        EditionId     = $editionId
        ProductName   = $productName
        IsHome        = [bool]$isHome
        IsProOrHigher = [bool]$isPro
        IsEnterprise  = [bool]$isEnterprise
        IsKnown       = [bool]($isHome -or $isPro)
    }
}

function Get-GamePolicyManagementState {
    [CmdletBinding()]
    param()

    $command = Get-Command Get-PolicyManagementStatus -ErrorAction SilentlyContinue
    if ($command) {
        try { return Get-PolicyManagementStatus } catch { }
    }
    $domainJoined = $false
    try { $domainJoined = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }
    $mdmDetected = $false
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        try { $mdmDetected = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction Stop).Count -gt 0 } catch { }
    }
    if (-not $mdmDetected -and (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments')) {
        foreach ($key in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue)) {
            try {
                $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $state = if ($item.PSObject.Properties['EnrollmentState']) { [int]$item.EnrollmentState } else { 0 }
                $provider = if ($item.PSObject.Properties['ProviderID']) { [string]$item.ProviderID } else { '' }
                $discovery = if ($item.PSObject.Properties['DiscoveryServiceFullURL']) { [string]$item.DiscoveryServiceFullURL } else { '' }
                $upn = if ($item.PSObject.Properties['UPN']) { [string]$item.UPN } else { '' }
                if ($state -eq 1 -and ($discovery -or $upn -or $provider -match '(?i)MDM|Intune|Device\s*Management|AirWatch|MobileIron|Workspace\s*ONE|MaaS360|Citrix|VMware')) {
                    $mdmDetected = $true
                    break
                }
            }
            catch { }
        }
    }
    return [pscustomobject]@{
        IsManaged       = [bool]($domainJoined -or $mdmDetected)
        IsDomainJoined  = $domainJoined
        IsMdmEnrolled   = $mdmDetected
        DetectionDetail = if ($domainJoined -or $mdmDetected) { 'Computador associado a dominio ou inscricao MDM.' } else { 'Nenhum gerenciamento detectado pelo fallback.' }
    }
}

function Get-GameModeState {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    if (-not $platform.IsSupported) {
        return [pscustomobject]@{
            Name = 'Game Mode'; State = 'Unsupported'; CanAutomate = $false
            Value = $null; Reason = 'Versao do Windows nao suportada.'; RequiresRestart = $false
        }
    }
    if (-not $platform.IsWindows11) {
        return [pscustomobject]@{
            Name = 'Game Mode'; State = 'Manual'; CanAutomate = $false
            Value = $null; Reason = 'No Windows 10, o modulo usa somente a pagina oficial de Configuracoes.'
            RequiresRestart = $false
        }
    }

    $state = Get-RegistryValueState -Path $script:GameModePath -Name $script:GameModeName
    $label = if (-not $state.ValueExisted) { 'Default' } elseif ([int]$state.Value -eq 1) { 'Enabled' } else { 'Disabled' }
    return [pscustomobject]@{
        Name = 'Game Mode'; State = $label; CanAutomate = $true
        Value = if ($state.ValueExisted) { [int]$state.Value } else { $null }
        ValueExisted = [bool]$state.ValueExisted
        Reason = 'Valor documentado pela referencia oficial de configuracoes do Windows 11.'
        RequiresRestart = $false
    }
}

function Set-GameMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    $capability = Get-GameModeState
    if (-not $capability.CanAutomate) {
        if ([string]$capability.State -eq 'Manual' -and -not (Get-OptimizerContext).Simulation) {
            $opened = Open-WindowsGamingSettings -Page GameMode
            Add-Member -InputObject $capability -NotePropertyName SettingsResult -NotePropertyValue $opened -Force
        }
        Write-GameOptimizerLog -Name 'Alterar Game Mode' -OldValue $capability.State -NewValue 'Manual' `
            -Result 'Skipped' -ErrorMessage $capability.Reason
        return $capability
    }

    return Invoke-OptimizerOperation -Name $(if ($Enabled) { 'Ativar Game Mode' } else { 'Desativar Game Mode' }) `
        -Risk 'Seguro' -SkipRestorePoint -ScriptBlock {
            Set-SafeRegistryValue -Path $script:GameModePath -Name $script:GameModeName `
                -Value $(if ($Enabled) { 1 } else { 0 }) -Type DWord `
                -Description $(if ($Enabled) { 'Ativar Game Mode' } else { 'Desativar Game Mode' })
        }
}

function Set-GameModeState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    return Set-GameMode -Enabled $Enabled
}

function Get-GameDvrState {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    $edition = Get-GameEditionSupport
    if (-not $platform.IsWindows10) {
        return [pscustomobject]@{
            Name = 'Game DVR'; State = $(if ($platform.IsWindows11) { 'Manual' } else { 'Unsupported' })
            CanAutomate = $false; Value = $null
            Reason = $(if ($platform.IsWindows11) {
                'A politica AllowGameDVR e documentada como aplicada somente ao Windows 10 desktop.'
            } else { 'Versao do Windows nao suportada.' })
            RequiresRestart = $false
        }
    }
    if (-not $edition.IsProOrHigher) {
        return [pscustomobject]@{
            Name = 'Game DVR'; State = 'Unsupported'; CanAutomate = $false; Value = $null
            Reason = 'A politica documentada requer Windows Pro, Enterprise, Education ou IoT.'
            RequiresRestart = $false
        }
    }

    $value = Get-RegistryValueState -Path $script:GameDvrPolicyPath -Name $script:GameDvrPolicyName
    $label = if (-not $value.ValueExisted) { 'AllowedByDefault' } elseif ([int]$value.Value -eq 0) { 'Disabled' } else { 'Allowed' }
    return [pscustomobject]@{
        Name = 'Game DVR'; State = $label; CanAutomate = $true
        Value = if ($value.ValueExisted) { [int]$value.Value } else { $null }
        ValueExisted = [bool]$value.ValueExisted
        Reason = 'Politica ApplicationManagement/AllowGameDVR suportada no Windows 10 desktop.'
        RequiresRestart = $false
    }
}

function Set-GameDvrEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [switch]$AllowManagedDevice
    )

    $capability = Get-GameDvrState
    if (-not $capability.CanAutomate) {
        Write-GameOptimizerLog -Name 'Alterar Game DVR' -OldValue $capability.State -NewValue 'Manual/Unsupported' `
            -Result 'Skipped' -ErrorMessage $capability.Reason
        return $capability
    }
    $management = Get-GamePolicyManagementState
    if ($management.IsManaged -and -not $AllowManagedDevice) {
        throw 'O computador aparenta ser gerenciado por dominio ou MDM. A politica Game DVR nao sera sobrescrita sem confirmacao explicita.'
    }

    return Invoke-OptimizerOperation -Name $(if ($Enabled) { 'Permitir Game DVR' } else { 'Desativar Game DVR' }) `
        -Risk 'Moderado' -RequiresAdministrator -SkipRestorePoint -ScriptBlock {
            Set-SafeRegistryValue -Path $script:GameDvrPolicyPath -Name $script:GameDvrPolicyName `
                -Value $(if ($Enabled) { 1 } else { 0 }) -Type DWord -RequiresAdministrator `
                -Description $(if ($Enabled) { 'Permitir gravacao e transmissao de jogos' } else { 'Desativar gravacao e transmissao de jogos' })
        }
}

function Set-GameCaptureState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Disabled,
        [switch]$AllowManagedDevice
    )
    return Set-GameDvrEnabled -Enabled (-not $Disabled) -AllowManagedDevice:$AllowManagedDevice
}

function Get-ManualGamingFeatureState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('GameBar', 'Captures', 'Hags', 'Graphics', 'WindowedGames', 'DoNotDisturbGame', 'DoNotDisturb', 'Notifications', 'FullscreenOptimizations')][string]$Feature)

    $platform = Get-WindowsPlatformInfo
    if ($Feature -eq 'FullscreenOptimizations') {
        return [pscustomobject]@{
            Name = $Feature; State = $(if ($platform.IsSupported) { 'Manual' } else { 'Unsupported' })
            CanAutomate = $false; SettingsPage = $null; RequiresRestart = $false
            Reason = 'A alteracao deve ser feita por executavel nas propriedades de compatibilidade. Desativacao global nao e suportada pelo modulo.'
        }
    }
    $page = $script:GameSettingsPages[$Feature]
    $supported = $platform.IsSupported -and $platform.Build -ge [int]$page.MinimumBuild
    return [pscustomobject]@{
        Name = $Feature
        State = if ($supported) { 'Manual' } else { 'Unsupported' }
        CanAutomate = $false
        SettingsPage = if ($supported) { [string]$page.Uri } else { $null }
        RequiresRestart = ($Feature -eq 'Hags')
        Reason = if ($supported) {
            'Nao existe contrato publico estavel para escrita automatica; use a pagina oficial do Windows.'
        } else { 'Recurso indisponivel nesta versao do Windows.' }
    }
}

function Get-GameOptimizationCapabilities {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    return [pscustomobject]@{
        Platform               = $platform
        Edition                = Get-GameEditionSupport
        GameMode               = Get-GameModeState
        GameDvr                = Get-GameDvrState
        GameBar                = Get-ManualGamingFeatureState -Feature GameBar
        Captures               = Get-ManualGamingFeatureState -Feature Captures
        Hags                   = Get-ManualGamingFeatureState -Feature Hags
        GpuPreference          = Get-ManualGamingFeatureState -Feature Graphics
        WindowedGames          = Get-ManualGamingFeatureState -Feature WindowedGames
        DoNotDisturb           = Get-ManualGamingFeatureState -Feature DoNotDisturbGame
        FullscreenOptimizations = Get-ManualGamingFeatureState -Feature FullscreenOptimizations
        SafetyNotes            = @(
            'HAGS nao e forcado por Registro e pode melhorar, piorar ou nao alterar o frametime.',
            'Preferencia de GPU e configurada somente pela pagina oficial do Windows.',
            'Otimizacoes de tela cheia nunca sao desativadas globalmente.',
            'Nenhuma funcao altera rede, arquivos de jogos, memoria de processos ou injeta codigo.'
        )
    }
}

function Open-WindowsGamingSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('GameMode', 'GameBar', 'Captures', 'Hags', 'Graphics', 'WindowedGames', 'DoNotDisturbGame', 'DoNotDisturb', 'Notifications')][string]$Page)

    $definition = $script:GameSettingsPages[$Page]
    $platform = Get-WindowsPlatformInfo
    if (-not $platform.IsSupported -or $platform.Build -lt [int]$definition.MinimumBuild) {
        return [pscustomobject]@{ Page = $Page; State = 'Unsupported'; Opened = $false; Uri = $null }
    }
    if ((Get-OptimizerContext).Simulation) {
        Write-GameOptimizerLog -Name "Abrir configuracoes: $Page" -OldValue '' -NewValue $definition.Uri -Result 'Simulated'
        return [pscustomobject]@{ Page = $Page; State = 'Manual'; Opened = $false; Uri = $definition.Uri; Simulated = $true }
    }
    try {
        Start-Process -FilePath ([string]$definition.Uri) -ErrorAction Stop | Out-Null
        Write-GameOptimizerLog -Name "Abrir configuracoes: $Page" -OldValue '' -NewValue $definition.Uri -Result 'Success'
        return [pscustomobject]@{ Page = $Page; State = 'Manual'; Opened = $true; Uri = $definition.Uri }
    }
    catch {
        Write-GameOptimizerLog -Name "Abrir configuracoes: $Page" -OldValue '' -NewValue $definition.Uri `
            -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
        throw
    }
}

function Get-GameProfilesPath {
    return Join-Path (Get-OptimizerContext).StateRoot 'game-profiles.json'
}

function ConvertTo-GameProfileId {
    param([Parameter(Mandatory = $true)][string]$Id)

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Id, [ref]$parsed)) { throw 'O identificador do perfil de jogo e invalido.' }
    return $parsed.ToString('D')
}

function Get-ActiveGameSessionPath {
    return Join-Path (Get-OptimizerContext).StateRoot 'active-game-session.json'
}

function Read-GameProfileStore {
    $path = Get-GameProfilesPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ SchemaVersion = $script:GameProfileSchemaVersion; UpdatedAt = $null; Profiles = @() }
    }
    try {
        $store = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{
            SchemaVersion = [int]$store.SchemaVersion
            UpdatedAt = $store.UpdatedAt
            Profiles = @($store.Profiles)
        }
    }
    catch {
        throw "O arquivo de perfis de jogos esta invalido: $($_.Exception.Message)"
    }
}

function Write-GameProfileStore {
    param([Parameter(Mandatory = $true)]$Store)

    $Store.UpdatedAt = (Get-Date).ToString('o')
    if ((Get-OptimizerContext).Simulation) { return $Store }
    Save-OptimizerJsonFile -Path (Get-GameProfilesPath) -InputObject $Store -Depth 20 | Out-Null
    return $Store
}

function Test-LocalGameExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return Test-SafeExecutablePath -Path $Path
}

function Test-ProcessTokenElevated {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    try {
        if (-not ('WindowsFPSOptimizer.Native.TokenInspector' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace WindowsFPSOptimizer.Native {
    public static class TokenInspector {
        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_ELEVATION { public int TokenIsElevated; }
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr tokenHandle, int tokenInformationClass,
            out TOKEN_ELEVATION tokenInformation, int tokenInformationLength, out int returnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
        public static bool IsElevated(IntPtr processHandle) {
            IntPtr token;
            if (!OpenProcessToken(processHandle, 0x0008, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                TOKEN_ELEVATION elevation;
                int returned;
                if (!GetTokenInformation(token, 20, out elevation, Marshal.SizeOf(typeof(TOKEN_ELEVATION)), out returned))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return elevation.TokenIsElevated != 0;
            }
            finally { CloseHandle(token); }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
        }
        return [WindowsFPSOptimizer.Native.TokenInspector]::IsElevated($Process.Handle)
    }
    catch { return $null }
}

function Start-ProfileGameProcess {
    <#
        Quando a sessao precisou de UAC para energia/servicos, Start-Process faria o
        jogo herdar High Integrity. O Shell do Explorer pertence ao usuario interativo
        e faz a abertura no contexto normal. Nao existe fallback elevado: se o broker
        nao estiver disponivel, a sessao falha e o finally restaura tudo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Profile)

    $executable = [string]$Profile.ExecutablePath
    $workingDirectory = [string]$Profile.WorkingDirectory
    $arguments = [string]$Profile.Arguments
    $processName = [IO.Path]::GetFileNameWithoutExtension($executable)
    $beforeIds = @{}
    foreach ($existing in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        $beforeIds[[int]$existing.Id] = $true
    }

    if (-not (Get-OptimizerContext).IsAdministrator) {
        $parameters = @{
            FilePath = $executable
            WorkingDirectory = $workingDirectory
            PassThru = $true
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($arguments)) { $parameters.ArgumentList = $arguments }
        $standardProcess = Start-Process @parameters
        return [pscustomobject]@{
            Process = $standardProcess
            LaunchMethod = 'StartProcessStandardUser'
            LaunchedElevated = Test-ProcessTokenElevated -Process $standardProcess
        }
    }

    $interactiveExplorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId } | Select-Object -First 1)
    if ($interactiveExplorer.Count -eq 0) {
        throw 'Nao ha Explorer interativo para iniciar o jogo sem elevacao. Reinicie o otimizador sem UAC e use uma sessao sem opcoes administrativas.'
    }
    $explorerElevation = Test-ProcessTokenElevated -Process $interactiveExplorer[0]
    if ($null -eq $explorerElevation -or $explorerElevation) {
        throw 'Nao foi possivel confirmar um Explorer sem elevacao. O jogo nao sera iniciado a partir do otimizador elevado.'
    }

    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application -ErrorAction Stop
        $shell.ShellExecute($executable, $arguments, $workingDirectory, 'open', 1)
    }
    catch { throw "O jogo nao foi iniciado porque o broker nao elevado do Explorer falhou: $($_.Exception.Message)" }
    finally {
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch { } }
    }

    $deadline = (Get-Date).AddSeconds(20)
    $launched = $null
    do {
        Start-Sleep -Milliseconds 200
        $candidates = @(Get-Process -Name $processName -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending)
        $launched = @($candidates | Where-Object { -not $beforeIds.ContainsKey([int]$_.Id) } | Select-Object -First 1)
        if ($launched.Count -eq 0 -and $candidates.Count -gt 0) {
            # Aplicativos single-instance podem reutilizar o processo que ja existia.
            $launched = @($candidates | Select-Object -First 1)
        }
    } while ($launched.Count -eq 0 -and (Get-Date) -lt $deadline)
    if ($launched.Count -eq 0) {
        throw 'O Explorer recebeu a solicitacao, mas o processo do jogo nao foi identificado em 20 segundos.'
    }
    Write-GameOptimizerLog -Name 'Iniciar jogo sem herdar UAC' -OldValue 'Otimizador elevado' `
        -NewValue 'Shell do usuario interativo' -Result 'Success'
    return [pscustomobject]@{
        Process = $launched[0]
        LaunchMethod = 'ExplorerShellExecute'
        LaunchedElevated = Test-ProcessTokenElevated -Process $launched[0]
    }
}

function Get-SafeProfileProcessNames {
    param([string[]]$Names)

    $protected = @((Get-OptimizerContext).Config.Safety.ProtectedProcesses)
    return @($Names | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) { [IO.Path]::GetFileNameWithoutExtension($_.Trim()) }
    } | Where-Object {
        $_ -and $protected -notcontains $_ -and
        (-not (Get-Command Test-ProtectedProcessMetadata -ErrorAction SilentlyContinue) -or
            -not (Test-ProtectedProcessMetadata -Name $_))
    } | Sort-Object -Unique)
}

function Get-SafeProfileServiceNames {
    param([string[]]$Names)

    $context = Get-OptimizerContext
    $allowed = @($context.Config.OptionalServices | ForEach-Object { [string]$_.Name })
    $protected = @($context.Config.Safety.ProtectedServices)
    return @($Names | Where-Object { $_ -and $allowed -contains $_ -and $protected -notcontains $_ } | Sort-Object -Unique)
}

function New-NormalizedGameProfile {
    param(
        [string]$Id,
        [string]$Name,
        [string]$ExecutablePath,
        [string]$Arguments,
        [string]$Priority,
        [string[]]$CloseProcesses,
        [string[]]$SuspendServices,
        [string]$PowerPlan,
        [bool]$PreventSleep,
        [bool]$ReduceVisualEffects,
        [bool]$OpenDoNotDisturbSettings,
        [bool]$UseConfiguredProcessList,
        [string]$CreatedAt
    )

    if (-not (Test-LocalGameExecutable -Path $ExecutablePath)) {
        throw 'O executavel deve existir, ser local e possuir extensao .exe.'
    }
    if ($Priority -notin @('Normal', 'AboveNormal', 'High')) { throw 'Prioridade de processo invalida.' }
    if ($PowerPlan -notin @('None', 'HighPerformance', 'Ultimate', 'Custom')) { throw 'Plano de energia do perfil invalido.' }
    if ($Arguments -match '[\x00\r\n]') { throw 'Os argumentos nao podem conter caracteres de controle ou quebra de linha.' }
    if ($Arguments.Length -gt 4096) { throw 'A linha de argumentos excede 4096 caracteres.' }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = [IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
    }
    if ($Name -match '[\x00\r\n]') { throw 'O nome do perfil contem caracteres invalidos.' }

    $resolved = (Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
    $now = (Get-Date).ToString('o')
    return [pscustomobject][ordered]@{
        Id                       = if ($Id) { ConvertTo-GameProfileId -Id $Id } else { [guid]::NewGuid().ToString('D') }
        Name                     = $Name.Trim()
        ExecutablePath           = $resolved
        Arguments                = [string]$Arguments
        WorkingDirectory         = Split-Path -Parent $resolved
        Priority                 = $Priority
        CloseProcesses           = @(Get-SafeProfileProcessNames -Names $CloseProcesses)
        SuspendServices          = @(Get-SafeProfileServiceNames -Names $SuspendServices)
        PowerPlan                = $PowerPlan
        PreventSleep             = $PreventSleep
        ReduceVisualEffects      = $ReduceVisualEffects
        OpenDoNotDisturbSettings = $OpenDoNotDisturbSettings
        UseConfiguredProcessList = $UseConfiguredProcessList
        CreatedAt                = if ($CreatedAt) { $CreatedAt } else { $now }
        UpdatedAt                = $now
    }
}

function ConvertTo-ValidatedStoredGameProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    return New-NormalizedGameProfile -Id ([string]$Profile.Id) -Name ([string]$Profile.Name) `
        -ExecutablePath ([string]$Profile.ExecutablePath) -Arguments ([string]$Profile.Arguments) `
        -Priority ([string]$Profile.Priority) -CloseProcesses @($Profile.CloseProcesses) `
        -SuspendServices @($Profile.SuspendServices) -PowerPlan ([string]$Profile.PowerPlan) `
        -PreventSleep ([bool]$Profile.PreventSleep) -ReduceVisualEffects ([bool]$Profile.ReduceVisualEffects) `
        -OpenDoNotDisturbSettings ([bool]$Profile.OpenDoNotDisturbSettings) `
        -UseConfiguredProcessList ([bool]$Profile.UseConfiguredProcessList) -CreatedAt ([string]$Profile.CreatedAt)
}

function Get-GameProfiles {
    [CmdletBinding()]
    param([string]$Id)

    $profiles = @((Read-GameProfileStore).Profiles)
    if ($Id) {
        $normalizedId = ConvertTo-GameProfileId -Id $Id
        return @($profiles | Where-Object {
            try { (ConvertTo-GameProfileId -Id ([string]$_.Id)) -eq $normalizedId } catch { $false }
        })
    }
    return @($profiles | Sort-Object Name)
}

function Add-GameProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$Name = '',
        [string]$Arguments = '',
        [ValidateSet('Normal', 'AboveNormal', 'High')][string]$Priority = 'AboveNormal',
        [string[]]$CloseProcesses = @(),
        [string[]]$SuspendServices = @(),
        [ValidateSet('None', 'HighPerformance', 'Ultimate', 'Custom')][string]$PowerPlan = 'None',
        [bool]$PreventSleep = $true,
        [bool]$ReduceVisualEffects = $false,
        [bool]$OpenDoNotDisturbSettings = $false,
        [bool]$UseConfiguredProcessList = $true
    )

    Assert-OptimizerMutationAllowed -Operation 'Adicionar perfil de jogo' | Out-Null
    $profile = New-NormalizedGameProfile -Name $Name -ExecutablePath $ExecutablePath -Arguments $Arguments `
        -Priority $Priority -CloseProcesses $CloseProcesses -SuspendServices $SuspendServices `
        -PowerPlan $PowerPlan -PreventSleep $PreventSleep -ReduceVisualEffects $ReduceVisualEffects `
        -OpenDoNotDisturbSettings $OpenDoNotDisturbSettings -UseConfiguredProcessList $UseConfiguredProcessList
    $store = Read-GameProfileStore
    if (@($store.Profiles | Where-Object { [string]$_.ExecutablePath -ieq $profile.ExecutablePath }).Count -gt 0) {
        throw 'Ja existe um perfil para este executavel.'
    }
    $store.Profiles = @($store.Profiles) + $profile
    Write-GameProfileStore -Store $store | Out-Null
    Write-GameOptimizerLog -Name 'Adicionar perfil de jogo' -OldValue '' -NewValue $profile -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' })
    return $profile
}

function Set-GameProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Name,
        [string]$ExecutablePath,
        [string]$Arguments,
        [ValidateSet('Normal', 'AboveNormal', 'High')][string]$Priority,
        [string[]]$CloseProcesses,
        [string[]]$SuspendServices,
        [ValidateSet('None', 'HighPerformance', 'Ultimate', 'Custom')][string]$PowerPlan,
        [Nullable[bool]]$PreventSleep,
        [Nullable[bool]]$ReduceVisualEffects,
        [Nullable[bool]]$OpenDoNotDisturbSettings,
        [Nullable[bool]]$UseConfiguredProcessList
    )

    Assert-OptimizerMutationAllowed -Operation 'Atualizar perfil de jogo' | Out-Null
    $Id = ConvertTo-GameProfileId -Id $Id
    $store = Read-GameProfileStore
    $current = @($store.Profiles | Where-Object { [string]$_.Id -eq $Id })
    if ($current.Count -ne 1) { throw 'Perfil de jogo nao encontrado.' }
    $old = $current[0]
    $values = @{
        Id = [string]$old.Id; Name = [string]$old.Name; ExecutablePath = [string]$old.ExecutablePath
        Arguments = [string]$old.Arguments; Priority = [string]$old.Priority
        CloseProcesses = @($old.CloseProcesses); SuspendServices = @($old.SuspendServices)
        PowerPlan = [string]$old.PowerPlan; PreventSleep = [bool]$old.PreventSleep
        ReduceVisualEffects = [bool]$old.ReduceVisualEffects
        OpenDoNotDisturbSettings = [bool]$old.OpenDoNotDisturbSettings
        UseConfiguredProcessList = [bool]$old.UseConfiguredProcessList; CreatedAt = [string]$old.CreatedAt
    }
    foreach ($key in @('Name', 'ExecutablePath', 'Arguments', 'Priority', 'CloseProcesses', 'SuspendServices', 'PowerPlan')) {
        if ($PSBoundParameters.ContainsKey($key)) { $values[$key] = $PSBoundParameters[$key] }
    }
    foreach ($key in @('PreventSleep', 'ReduceVisualEffects', 'OpenDoNotDisturbSettings', 'UseConfiguredProcessList')) {
        if ($PSBoundParameters.ContainsKey($key) -and $null -ne $PSBoundParameters[$key]) { $values[$key] = [bool]$PSBoundParameters[$key] }
    }
    $updated = New-NormalizedGameProfile @values
    $duplicates = @($store.Profiles | Where-Object { [string]$_.Id -ne $Id -and [string]$_.ExecutablePath -ieq $updated.ExecutablePath })
    if ($duplicates.Count -gt 0) { throw 'Outro perfil ja utiliza este executavel.' }
    $store.Profiles = @($store.Profiles | ForEach-Object { if ([string]$_.Id -eq $Id) { $updated } else { $_ } })
    Write-GameProfileStore -Store $store | Out-Null
    Write-GameOptimizerLog -Name 'Atualizar perfil de jogo' -OldValue $old -NewValue $updated -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' })
    return $updated
}

function Remove-GameProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)

    Assert-OptimizerMutationAllowed -Operation 'Remover perfil de jogo' | Out-Null
    $Id = ConvertTo-GameProfileId -Id $Id
    $store = Read-GameProfileStore
    $current = @($store.Profiles | Where-Object { [string]$_.Id -eq $Id })
    if ($current.Count -ne 1) { return [pscustomobject]@{ Changed = $false; Result = 'NotFound'; Id = $Id } }
    $store.Profiles = @($store.Profiles | Where-Object { [string]$_.Id -ne $Id })
    Write-GameProfileStore -Store $store | Out-Null
    Write-GameOptimizerLog -Name 'Remover perfil de jogo' -OldValue $current[0] -NewValue '' -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' })
    return [pscustomobject]@{ Changed = $true; Result = $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }); Profile = $current[0] }
}

function Select-GameExecutable {
    [CmdletBinding()]
    param([string]$InitialDirectory)

    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Selecionar executavel do jogo'
    $dialog.Filter = 'Executaveis (*.exe)|*.exe'
    $dialog.Multiselect = $false
    $dialog.CheckFileExists = $true
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
        $dialog.InitialDirectory = (Resolve-Path -LiteralPath $InitialDirectory).Path
    }
    $accepted = $dialog.ShowDialog()
    if (-not $accepted) { return $null }
    if (-not (Test-LocalGameExecutable -Path $dialog.FileName)) { throw 'O arquivo selecionado nao e um executavel local valido.' }
    return (Resolve-Path -LiteralPath $dialog.FileName).Path
}

function Find-InstalledGames {
    [CmdletBinding()]
    param(
        [string[]]$AdditionalFolders = @(),
        [ValidateRange(1, 5000)][int]$MaximumResults = 500
    )

    $context = Get-OptimizerContext
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($configured in @($context.Config.CommonGameFolders) + @($AdditionalFolders)) {
        if ([string]::IsNullOrWhiteSpace([string]$configured)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$configured)
        if (-not [IO.Path]::IsPathRooted($expanded) -or $expanded.StartsWith('\\')) { continue }
        if (Test-Path -LiteralPath $expanded -PathType Container) {
            $resolved = (Resolve-Path -LiteralPath $expanded -ErrorAction SilentlyContinue).Path
            if ($resolved -and -not $roots.Contains($resolved)) { $roots.Add($resolved) }
        }
    }

    $excluded = '(?i)(^|[\\_.-])(unins|uninstall|setup|installer|update|updater|crash|report|redist|vc_redist|dxsetup|eac|easyanticheat|battleye|cef|webview|helper|service|benchmark)([\\_.-]|$)'
    $seen = @{}
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue)) {
            if (Get-Command Test-OptimizerCancellation -ErrorAction SilentlyContinue) {
                if (Test-OptimizerCancellation) { break }
            }
            if ($results.Count -ge $MaximumResults) { break }
            if ($file.FullName -match $excluded -or $seen.ContainsKey($file.FullName.ToLowerInvariant())) { continue }
            $seen[$file.FullName.ToLowerInvariant()] = $true
            $description = ''
            $product = ''
            $company = ''
            try {
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
                $description = [string]$version.FileDescription
                $product = [string]$version.ProductName
                $company = [string]$version.CompanyName
            }
            catch { }
            $relative = $file.FullName.Substring($root.Length).TrimStart('\')
            $topFolder = ($relative -split '\\')[0]
            $confidence = if ($file.Length -ge 20MB -or $description -match '(?i)game') { 'Alta' } `
                elseif ($file.Length -ge 2MB) { 'Media' } else { 'Baixa' }
            $results.Add([pscustomobject]@{
                Name = if ($product) { $product } elseif ($description) { $description } elseif ($topFolder) { $topFolder } else { $file.BaseName }
                ExecutablePath = $file.FullName
                FileName = $file.Name
                Product = $product
                Description = $description
                Company = $company
                SizeMB = [math]::Round($file.Length / 1MB, 1)
                Root = $root
                Confidence = $confidence
            })
        }
        if ($results.Count -ge $MaximumResults) { break }
    }
    return @($results | Sort-Object @{ Expression = { switch ($_.Confidence) { 'Alta' { 0 }; 'Media' { 1 }; default { 2 } } } }, Name)
}

function Get-ActiveGameSession {
    [CmdletBinding()]
    param()

    $path = Get-ActiveGameSessionPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "O estado da sessao de jogo esta corrompido: $($_.Exception.Message)" }
}

function Save-ActiveGameSession {
    param([Parameter(Mandatory = $true)]$Session)

    $Session.UpdatedAt = (Get-Date).ToString('o')
    if (-not (Get-OptimizerContext).Simulation) {
        Save-OptimizerJsonFile -Path (Get-ActiveGameSessionPath) -InputObject $Session -Depth 30 | Out-Null
    }
    return $Session
}

function Get-SessionServiceSnapshot {
    param([string[]]$Names)

    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(Get-SafeProfileServiceNames -Names $Names)) {
        try {
            $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $name.Replace("'", "''")) -ErrorAction Stop
            if (-not $cim) { continue }
            $delayed = $false
            try {
                $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
                $delayed = [bool](Get-ItemPropertyValue -LiteralPath $serviceKey -Name DelayedAutoStart -ErrorAction SilentlyContinue)
            }
            catch { }
            $snapshots.Add([pscustomobject]@{
                Name = [string]$cim.Name; StartMode = [string]$cim.StartMode
                Status = [string]$cim.State; DelayedAutoStart = $delayed
            })
        }
        catch { }
    }
    return $snapshots.ToArray()
}

function Stop-SessionProcesses {
    param([string[]]$Names, [bool]$UseConfiguredList)

    $targets = @(Get-SafeProfileProcessNames -Names $Names)
    if ($UseConfiguredList -and (Get-Command Get-ProcessListState -ErrorAction SilentlyContinue)) {
        $targets += @((Get-ProcessListState).CloseBeforeGame)
        $targets = @(Get-SafeProfileProcessNames -Names $targets)
    }
    if ($targets.Count -eq 0) { return @() }
    if (-not (Get-Command Get-ProcessInventory -ErrorAction SilentlyContinue) -or -not (Get-Command Stop-SelectedProcess -ErrorAction SilentlyContinue)) {
        throw 'ProcessManager nao esta carregado; processos selecionados nao podem ser fechados com seguranca.'
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-ProcessInventory)) {
        if ($targets -notcontains [string]$process.Name -or $process.IsProtected) { continue }
        try {
            $result = Stop-SelectedProcess -Id ([int]$process.Id) -ExpectedStartTime ([string]$process.StartTime) -AllowRestart
            $results.Add([pscustomobject]@{
                Name = [string]$process.Name; Id = [int]$process.Id; Path = [string]$process.Path
                StartTime = [string]$process.StartTime; Result = [string]$result.Result
            })
        }
        catch {
            $results.Add([pscustomobject]@{ Name = [string]$process.Name; Id = [int]$process.Id; Result = 'Error'; Error = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

function Suspend-SessionServicesFallback {
    param([Parameter(Mandatory = $true)]$Snapshots)

    Assert-OptimizerMutationAllowed -RequiresAdministrator -Operation 'Suspender servicos opcionais para sessao' | Out-Null
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @($Snapshots)) {
        if ([string]$snapshot.Status -ne 'Running') {
            $results.Add([pscustomobject]@{ Name = $snapshot.Name; Result = 'Skipped'; Reason = 'Servico nao estava em execucao.' })
            continue
        }
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'Service' -Id ([string]$snapshot.Name) -Original $snapshot `
                -Applied ([pscustomobject]@{ Name = $snapshot.Name; StartMode = $snapshot.StartMode; Status = 'Stopped'; DelayedAutoStart = $snapshot.DelayedAutoStart }) `
                -Metadata @{ SessionOnly = $true; StartupTypeChanged = $false } | Out-Null
        }
        if ((Get-OptimizerContext).Simulation) {
            $results.Add([pscustomobject]@{ Name = $snapshot.Name; Result = 'Simulated' })
            continue
        }
        try {
            Stop-Service -Name ([string]$snapshot.Name) -ErrorAction Stop
            $service = Get-Service -Name ([string]$snapshot.Name) -ErrorAction Stop
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(15))
            $results.Add([pscustomobject]@{ Name = $snapshot.Name; Result = 'Success' })
        }
        catch {
            $results.Add([pscustomobject]@{ Name = $snapshot.Name; Result = 'Error'; Error = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

function Start-GameSessionInternal {
    [CmdletBinding()]
    param(
        [string]$ProfileId = '',
        [string[]]$CloseProcesses = @(),
        [string[]]$SuspendServices = @(),
        [ValidateSet('None', 'HighPerformance', 'Ultimate', 'Custom')][string]$PowerPlan = 'None',
        [bool]$PreventSleep = $true,
        [bool]$ReduceVisualEffects = $false,
        [bool]$UseConfiguredProcessList = $true,
        [bool]$OpenDoNotDisturbSettings = $false,
        [switch]$DeferBackupCompletion
    )

    if ($ProfileId) { $ProfileId = ConvertTo-GameProfileId -Id $ProfileId }
    $requiresAdmin = ($PowerPlan -ne 'None' -or $PreventSleep -or @(Get-SafeProfileServiceNames -Names $SuspendServices).Count -gt 0)
    Assert-OptimizerMutationAllowed -RequiresAdministrator:$requiresAdmin -Operation 'Iniciar sessao de jogo' | Out-Null
    if (-not (Get-OptimizerContext).Simulation) {
        $requiredBackupCommands = @('Start-OptimizerBackup', 'Add-OptimizerBackupEntry', 'Complete-OptimizerBackup', 'Restore-OptimizerBackup')
        $missingBackupCommands = @($requiredBackupCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
        if ($missingBackupCommands.Count -gt 0) {
            throw "A sessao transacional requer BackupManager. Funcoes ausentes: $($missingBackupCommands -join ', ')."
        }
    }
    $existing = Get-ActiveGameSession
    if ($existing -and [string]$existing.Status -notin @('Restored', 'Completed')) {
        throw "Ja existe uma sessao de jogo pendente ($($existing.Id)). Restaure-a antes de iniciar outra."
    }

    $session = [pscustomobject][ordered]@{
        SchemaVersion = 1; Id = [guid]::NewGuid().ToString('D'); ProfileId = $ProfileId
        Status = 'Starting'; StartedAt = (Get-Date).ToString('o'); UpdatedAt = (Get-Date).ToString('o')
        EndedAt = $null; BackupManifestPath = $null; GameProcessId = $null
        GameProcessStartTime = $null; RuntimeSeconds = 0
        ProcessResults = @(); ServiceOriginal = @(); ServiceResults = @()
        PowerOriginal = $null; PowerResult = $null; VisualOriginal = $null; VisualResult = $null
        PriorityResult = $null; BackupCompletionDeferred = [bool]$DeferBackupCompletion
        ManualActions = @(); Errors = @(); AppliedSteps = @()
    }
    Save-ActiveGameSession -Session $session | Out-Null

    $backupStarted = $false
    try {
        if (-not (Get-OptimizerContext).Simulation -and (Get-Command Start-OptimizerBackup -ErrorAction SilentlyContinue)) {
            if (Get-Command Get-CurrentOptimizerBackup -ErrorAction SilentlyContinue) {
                $currentBackup = Get-CurrentOptimizerBackup
                if ($currentBackup) { throw 'Outra transacao de backup esta ativa; a sessao de jogo nao pode ser aninhada.' }
            }
            $backup = Start-OptimizerBackup -Name "Sessao de jogo $($session.Id)" -Profile 'Sessao de jogo' -CreateRestorePoint
            $backupStarted = $true
            if ($backup.PSObject.Properties['ManifestPath']) { $session.BackupManifestPath = [string]$backup.ManifestPath }
            if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
                Add-OptimizerBackupEntry -Type 'GameSession' -Id ([string]$session.Id) `
                    -Original ([pscustomobject]@{ Active = $false }) -Applied ([pscustomobject]@{ Active = $true }) `
                    -Metadata @{ ProfileId = $ProfileId; StartedAt = $session.StartedAt; Reversibility = 'BestEffort' } | Out-Null
            }
            Save-ActiveGameSession -Session $session | Out-Null
        }

        $session.ProcessResults = @(Stop-SessionProcesses -Names $CloseProcesses -UseConfiguredList $UseConfiguredProcessList)
        $session.AppliedSteps += 'Processes'
        Save-ActiveGameSession -Session $session | Out-Null

        $safeServices = @(Get-SafeProfileServiceNames -Names $SuspendServices)
        if ($safeServices.Count -gt 0) {
            $session.ServiceOriginal = @(Get-SessionServiceSnapshot -Names $safeServices)
            if (Get-Command Suspend-OptionalServicesForSession -ErrorAction SilentlyContinue) {
                $session.ServiceResults = @(Suspend-OptionalServicesForSession -Names $safeServices)
            }
            else {
                $session.ServiceResults = @(Suspend-SessionServicesFallback -Snapshots $session.ServiceOriginal)
            }
            $session.AppliedSteps += 'Services'
            Save-ActiveGameSession -Session $session | Out-Null
        }

        if ($PowerPlan -ne 'None' -or $PreventSleep) {
            if (-not (Get-Command Get-PowerPlanState -ErrorAction SilentlyContinue)) { throw 'PowerOptimizations nao esta carregado.' }
            $session.PowerOriginal = Get-PowerPlanState
            if (Get-Command Set-GameSessionPower -ErrorAction SilentlyContinue) {
                $session.PowerResult = Set-GameSessionPower -Plan $PowerPlan -PreventSleep:$PreventSleep
            }
            else {
                switch ($PowerPlan) {
                    'Ultimate' { $session.PowerResult = Enable-UltimatePerformancePlan }
                    'Custom' { $session.PowerResult = New-GamingPowerPlan -Activate }
                    'None' { throw 'A versao carregada de PowerOptimizations nao oferece ajuste isolado de suspensao.' }
                    default { $session.PowerResult = Set-HighPerformancePlan }
                }
            }
            $session.AppliedSteps += 'Power'
            Save-ActiveGameSession -Session $session | Out-Null
        }

        if ($ReduceVisualEffects) {
            if ((Get-Command Get-VisualEffectsState -ErrorAction SilentlyContinue) -and (Get-Command Set-VisualEffectsProfile -ErrorAction SilentlyContinue)) {
                if (-not $session.BackupManifestPath -and -not (Get-OptimizerContext).Simulation) {
                    throw 'Efeitos visuais so podem ser alterados em sessao quando o backup transacional esta disponivel.'
                }
                $session.VisualOriginal = Get-VisualEffectsState
                $session.VisualResult = Set-VisualEffectsProfile -Profile MaximumPerformance
                $session.AppliedSteps += 'VisualEffects'
            }
            else {
                $session.ManualActions += 'O modulo de efeitos visuais nao esta carregado; nenhuma alteracao visual foi aplicada.'
            }
            Save-ActiveGameSession -Session $session | Out-Null
        }

        if ($OpenDoNotDisturbSettings) {
            $session.ManualActions += 'Ative manualmente Nao Perturbe na pagina oficial. O modulo nao escreve valores internos de notificacoes.'
            if (-not (Get-OptimizerContext).Simulation) {
                $null = Open-WindowsGamingSettings -Page DoNotDisturbGame
            }
        }

        if ($backupStarted -and -not $DeferBackupCompletion -and (Get-Command Complete-OptimizerBackup -ErrorAction SilentlyContinue)) {
            Complete-OptimizerBackup -Status 'Completed' | Out-Null
        }
        $session.Status = if ((Get-OptimizerContext).Simulation) { 'Simulated' } elseif ($DeferBackupCompletion) { 'Prepared' } else { 'Active' }
        Save-ActiveGameSession -Session $session | Out-Null
        Write-GameOptimizerLog -Name 'Iniciar sessao de jogo' -OldValue 'Inactive' -NewValue $session `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' })
        return $session
    }
    catch {
        $session.Errors += $_.Exception.Message
        $session.Status = 'Failed'
        Save-ActiveGameSession -Session $session | Out-Null
        if ($backupStarted -and (Get-Command Complete-OptimizerBackup -ErrorAction SilentlyContinue)) {
            try { Complete-OptimizerBackup -Status 'Failed' -ErrorMessage $_.Exception.Message | Out-Null } catch { }
        }
        try { Stop-GameSession -SessionId $session.Id -Force | Out-Null } catch { }
        Write-GameOptimizerLog -Name 'Iniciar sessao de jogo' -OldValue 'Inactive' -NewValue $session `
            -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
        throw
    }
}

function Start-GameSession {
    <#
        Entrada publica para uma sessao sem lancamento monitorado. A conclusao do
        manifesto nunca pode ser adiada por chamadores externos; somente o executor
        interno de perfil usa esse intervalo para registrar a prioridade do jogo.
    #>
    [CmdletBinding()]
    param(
        [string]$ProfileId = '',
        [string[]]$CloseProcesses = @(),
        [string[]]$SuspendServices = @(),
        [ValidateSet('None', 'HighPerformance', 'Ultimate', 'Custom')][string]$PowerPlan = 'None',
        [bool]$PreventSleep = $true,
        [bool]$ReduceVisualEffects = $false,
        [bool]$UseConfiguredProcessList = $true,
        [bool]$OpenDoNotDisturbSettings = $false
    )

    return Start-GameSessionInternal -ProfileId $ProfileId -CloseProcesses $CloseProcesses `
        -SuspendServices $SuspendServices -PowerPlan $PowerPlan -PreventSleep $PreventSleep `
        -ReduceVisualEffects $ReduceVisualEffects -UseConfiguredProcessList $UseConfiguredProcessList `
        -OpenDoNotDisturbSettings $OpenDoNotDisturbSettings
}

function Restore-SessionFallback {
    param([Parameter(Mandatory = $true)]$Session)

    $results = New-Object System.Collections.Generic.List[object]
    $allowedServiceNames = @(Get-SafeProfileServiceNames -Names @($Session.ServiceOriginal | ForEach-Object { [string]$_.Name }))
    foreach ($service in @($Session.ServiceOriginal)) {
        if ($allowedServiceNames -notcontains [string]$service.Name) {
            $results.Add([pscustomobject]@{ Type = 'Service'; Name = [string]$service.Name; Result = 'Blocked'; Reason = 'Servico fora da allowlist opcional.' })
            continue
        }
        if ([string]$service.Status -ne 'Running') { continue }
        try {
            if (-not (Get-OptimizerContext).Simulation) { Start-Service -Name ([string]$service.Name) -ErrorAction Stop }
            $results.Add([pscustomobject]@{ Type = 'Service'; Name = $service.Name; Result = $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Restored' }) })
        }
        catch { $results.Add([pscustomobject]@{ Type = 'Service'; Name = $service.Name; Result = 'Error'; Error = $_.Exception.Message }) }
    }
    if ($Session.PowerOriginal -and (Get-Command Restore-PreviousPowerPlan -ErrorAction SilentlyContinue)) {
        try { $results.Add((Restore-PreviousPowerPlan -Force)) } catch { $results.Add([pscustomobject]@{ Type = 'Power'; Result = 'Error'; Error = $_.Exception.Message }) }
    }
    # Nunca iniciamos um executavel obtido do JSON de sessao em um processo elevado.
    # A restauracao de processos e delegada ao BackupManager, que valida caminho,
    # hash do executavel e a allowlist antes de fazer a tentativa best-effort.
    if (@($Session.ProcessResults | Where-Object { [string]$_.Result -eq 'Success' }).Count -gt 0) {
        $results.Add([pscustomobject]@{
            Type = 'Process'; Result = 'RequiresValidatedBackup'
            Reason = 'Processos nao sao relancados sem manifesto validado pelo BackupManager.'
        })
    }
    return $results.ToArray()
}

function Test-GameSessionBackupManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    try {
        if ([IO.Path]::GetFileName($ManifestPath) -ine 'manifest.json') { return $false }
        $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
        $resolvedRoot = (Resolve-Path -LiteralPath (Get-OptimizerContext).BackupRoot -ErrorAction Stop).Path.TrimEnd('\')
        if (-not $resolvedManifest.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $manifest = Get-Content -LiteralPath $resolvedManifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $sessionEntries = @($manifest.Entries | Where-Object { [string]$_.Type -eq 'GameSession' -and [string]$_.Id -eq $SessionId })
        return ($sessionEntries.Count -eq 1)
    }
    catch { return $false }
}

function Restore-GameSessionBackupEntry {
    <#
        GameSession e uma entrada declarativa. As mudancas reversiveis existem como
        entradas filhas (Process, Service, PowerPlan, PowerSetting, RegistryValue e
        SystemParameter) e sao restauradas pelo BackupManager. Este handler apenas
        confirma que nao ha comando arbitrario embutido a executar.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    $id = [string]$Entry.Id
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($id, [ref]$parsed)) { throw 'Identificador de sessao invalido no backup.' }
    return [pscustomobject]@{
        Status = 'RestoredByChildEntries'; SessionId = $id
        Force = [bool]$Force; ExecutedCommands = 0
    }
}

function Stop-GameSession {
    [CmdletBinding()]
    param([string]$SessionId, [switch]$Force)

    $mutex = New-Object Threading.Mutex($false, 'Local\WindowsFPSOptimizer.GameSessionRestore')
    $lockTaken = $false
    try {
        try { $lockTaken = $mutex.WaitOne([timespan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw 'Outra restauracao de sessao ainda esta em andamento.' }

        $session = Get-ActiveGameSession
        if (-not $session) { return [pscustomobject]@{ Result = 'Skipped'; Reason = 'Nenhuma sessao ativa.' } }
        if ($SessionId -and [string]$session.Id -ne $SessionId) { throw 'O identificador nao corresponde a sessao ativa.' }
        # Estados simulados nunca sao persistidos. Portanto, qualquer marcador lido
        # aqui pertence a uma sessao real e nao pode ser "restaurado" por uma chamada
        # que deliberadamente nao altera o Windows.
        if ((Get-OptimizerContext).Simulation) {
            throw 'Existe uma sessao real pendente. Desative o modo de simulacao e execute a restauracao com os privilegios solicitados.'
        }
        if ([string]$session.Status -eq 'Restoring') {
            return [pscustomobject]@{ Result = 'InProgress'; SessionId = [string]$session.Id }
        }
        if ([string]$session.Status -eq 'Starting') {
            return [pscustomobject]@{ Result = 'Busy'; Reason = 'A sessao ainda esta aplicando alteracoes.'; SessionId = [string]$session.Id }
        }
        $needsAdmin = (@($session.ServiceOriginal).Count -gt 0 -or $null -ne $session.PowerOriginal)
        Assert-OptimizerMutationAllowed -RequiresAdministrator:$needsAdmin -Operation 'Restaurar sessao de jogo' | Out-Null
        $session.Status = 'Restoring'
        Save-ActiveGameSession -Session $session | Out-Null
        $restoration = $null
        $errors = New-Object System.Collections.Generic.List[string]

        try {
            if ($session.BackupManifestPath -and -not (Test-GameSessionBackupManifest `
                    -ManifestPath ([string]$session.BackupManifestPath) -SessionId ([string]$session.Id))) {
                throw 'O manifesto da sessao nao corresponde ao estado ativo ou esta fora da pasta de backups.'
            }
            if ($session.BackupManifestPath -and (Get-Command Restore-OptimizerBackup -ErrorAction SilentlyContinue)) {
                try { $restoration = Restore-OptimizerBackup -ManifestPath ([string]$session.BackupManifestPath) -Force:$Force }
                catch { $errors.Add($_.Exception.Message) }
            }
            else {
                $restoration = Restore-SessionFallback -Session $session
            }

            if ($errors.Count -gt 0) {
                $session.Status = 'RestoreFailed'
                $session.Errors = @($session.Errors) + $errors.ToArray()
                Save-ActiveGameSession -Session $session | Out-Null
                throw ($errors -join '; ')
            }

            $session.Status = 'Restored'
            $session.EndedAt = (Get-Date).ToString('o')
            Save-ActiveGameSession -Session $session | Out-Null
            if (-not (Get-OptimizerContext).Simulation) {
                $historyPath = Join-Path (Get-OptimizerContext).StateRoot ("game-session-{0}.json" -f $session.Id)
                Save-OptimizerJsonFile -Path $historyPath -InputObject $session -Depth 30 | Out-Null
                Remove-Item -LiteralPath (Get-ActiveGameSessionPath) -Force -ErrorAction Stop
            }
            Write-GameOptimizerLog -Name 'Restaurar sessao de jogo' -OldValue 'Active' -NewValue 'Restored' -Result 'Restored'
            return [pscustomobject]@{ Result = 'Restored'; Session = $session; Restoration = $restoration }
        }
        catch {
            Write-GameOptimizerLog -Name 'Restaurar sessao de jogo' -OldValue 'Active' -NewValue 'RestoreFailed' `
                -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
            throw
        }
    }
    finally {
        if ($lockTaken) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-NormalizedGameProfile {
    <#
        Executa um perfil ja validado sem pressupor que ele exista no arquivo de
        perfis. A transacao da sessao permanece aberta ate o processo ser criado e
        sua prioridade ser registrada; assim uma unica restauracao cobre energia,
        servicos, efeitos e prioridade.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Profile)

    $profile = ConvertTo-ValidatedStoredGameProfile -Profile $Profile
    if (-not (Test-LocalGameExecutable -Path ([string]$profile.ExecutablePath))) {
        throw 'O executavel do perfil nao esta mais disponivel.'
    }

    $session = Start-GameSessionInternal -ProfileId ([string]$profile.Id) -CloseProcesses @($profile.CloseProcesses) `
        -SuspendServices @($profile.SuspendServices) -PowerPlan ([string]$profile.PowerPlan) `
        -PreventSleep ([bool]$profile.PreventSleep) -ReduceVisualEffects ([bool]$profile.ReduceVisualEffects) `
        -UseConfiguredProcessList ([bool]$profile.UseConfiguredProcessList) `
        -OpenDoNotDisturbSettings ([bool]$profile.OpenDoNotDisturbSettings) -DeferBackupCompletion
    if ((Get-OptimizerContext).Simulation) {
        return [pscustomobject]@{ Result = 'Simulated'; Profile = $profile; Session = $session; RuntimeSeconds = 0 }
    }

    $process = $null
    $started = Get-Date
    $backupCommitted = $false
    try {
        $launch = Start-ProfileGameProcess -Profile $profile
        $process = $launch.Process
        $session.GameProcessId = [int]$process.Id
        try { $session.GameProcessStartTime = $process.StartTime.ToString('o') } catch { }
        Save-ActiveGameSession -Session $session | Out-Null

        if ((Get-Command Set-SelectedProcessPriority -ErrorAction SilentlyContinue) -and [string]$profile.Priority -ne 'Normal') {
            try {
                $session.PriorityResult = Set-SelectedProcessPriority -Id ([int]$process.Id) `
                    -Priority ([string]$profile.Priority) -ExpectedStartTime ([string]$session.GameProcessStartTime)
                Save-ActiveGameSession -Session $session | Out-Null
            }
            catch {
                Write-GameOptimizerLog -Name 'Aplicar prioridade ao jogo' -OldValue 'Normal' -NewValue $profile.Priority `
                    -Result 'Warning' -ErrorMessage $_.Exception.Message -Level 'Warning'
            }
        }

        if (-not $session.BackupManifestPath) { throw 'A sessao real nao possui manifesto de backup.' }
        $currentBackup = if (Get-Command Get-CurrentOptimizerBackup -ErrorAction SilentlyContinue) { Get-CurrentOptimizerBackup } else { $null }
        if (-not $currentBackup -or [string]$currentBackup.ManifestPath -ine [string]$session.BackupManifestPath) {
            throw 'A transacao da sessao deixou de ser a transacao ativa antes da conclusao.'
        }
        Complete-OptimizerBackup -Status 'Completed' | Out-Null
        $backupCommitted = $true
        $session.BackupCompletionDeferred = $false
        $session.Status = 'Active'
        Save-ActiveGameSession -Session $session | Out-Null

        while (-not $process.HasExited) {
            if ((Get-Command Test-OptimizerCancellation -ErrorAction SilentlyContinue) -and (Test-OptimizerCancellation)) { break }
            $null = $process.WaitForExit(1000)
            $process.Refresh()
        }
        $runtime = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        $current = Get-ActiveGameSession
        if ($current) {
            $current.RuntimeSeconds = $runtime
            Save-ActiveGameSession -Session $current | Out-Null
        }
        return [pscustomobject]@{
            Result = 'Completed'; Profile = $profile; ProcessId = $process.Id
            ExitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
            RuntimeSeconds = $runtime; StartedAt = $started; EndedAt = Get-Date
            LaunchedElevated = $launch.LaunchedElevated
            LaunchMethod = [string]$launch.LaunchMethod
        }
    }
    catch {
        $sessionFailure = $_
        if (-not $backupCommitted -and $session.BackupManifestPath) {
            try {
                $currentBackup = if (Get-Command Get-CurrentOptimizerBackup -ErrorAction SilentlyContinue) { Get-CurrentOptimizerBackup } else { $null }
                if ($currentBackup -and [string]$currentBackup.ManifestPath -ieq [string]$session.BackupManifestPath) {
                    Complete-OptimizerBackup -Status 'Failed' -ErrorMessage $sessionFailure.Exception.Message | Out-Null
                }
            }
            catch {
                Write-GameOptimizerLog -Name 'Finalizar transacao incompleta da sessao' -OldValue 'InProgress' -NewValue 'Failed' `
                    -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
            }
        }
        throw $sessionFailure
    }
    finally {
        try {
            # Falhas anteriores ao commit usam Force para rollback imediato. O fim
            # normal preserva a deteccao de conflitos e nunca sobrescreve uma mudanca
            # feita conscientemente pelo usuario durante o jogo.
            Stop-GameSession -SessionId ([string]$session.Id) -Force:(-not $backupCommitted) | Out-Null
        }
        catch {
            Write-GameOptimizerLog -Name 'Restauracao automatica apos jogo' -OldValue 'Active' -NewValue 'RestoreFailed' `
                -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
            throw
        }
    }
}

function Invoke-TransientGameProfile {
    <# Executa uma configuracao de jogo sem adicionar nem alterar game-profiles.json. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$Name = '',
        [string]$Arguments = '',
        [ValidateSet('Normal', 'AboveNormal', 'High')][string]$Priority = 'AboveNormal',
        [string[]]$CloseProcesses = @(),
        [string[]]$SuspendServices = @(),
        [ValidateSet('None', 'HighPerformance', 'Ultimate', 'Custom')][string]$PowerPlan = 'None',
        [bool]$PreventSleep = $true,
        [bool]$ReduceVisualEffects = $false,
        [bool]$OpenDoNotDisturbSettings = $false,
        [bool]$UseConfiguredProcessList = $true
    )

    $profile = New-NormalizedGameProfile -Name $Name -ExecutablePath $ExecutablePath -Arguments $Arguments `
        -Priority $Priority -CloseProcesses $CloseProcesses -SuspendServices $SuspendServices `
        -PowerPlan $PowerPlan -PreventSleep $PreventSleep -ReduceVisualEffects $ReduceVisualEffects `
        -OpenDoNotDisturbSettings $OpenDoNotDisturbSettings -UseConfiguredProcessList $UseConfiguredProcessList
    return Invoke-NormalizedGameProfile -Profile $profile
}

function Invoke-GameProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProfileId)

    $ProfileId = ConvertTo-GameProfileId -Id $ProfileId
    $profile = @(Get-GameProfiles -Id $ProfileId)
    if ($profile.Count -ne 1) { throw 'Perfil de jogo nao encontrado.' }
    return Invoke-NormalizedGameProfile -Profile $profile[0]
}

function New-GameProfileShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [switch]$Force
    )

    Assert-OptimizerMutationAllowed -Operation 'Criar atalho otimizado' | Out-Null
    $ProfileId = ConvertTo-GameProfileId -Id $ProfileId
    $profile = @(Get-GameProfiles -Id $ProfileId)
    if ($profile.Count -ne 1) { throw 'Perfil de jogo nao encontrado.' }
    $profile = ConvertTo-ValidatedStoredGameProfile -Profile $profile[0]
    $mainScript = Join-Path (Get-OptimizerContext).AppRoot 'WindowsFPSOptimizer.ps1'
    if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) { throw 'WindowsFPSOptimizer.ps1 nao foi encontrado na pasta do aplicativo.' }

    $destination = [Environment]::ExpandEnvironmentVariables($DestinationPath)
    if (Test-Path -LiteralPath $destination -PathType Container) {
        $safeName = ([string]$profile.Name -replace '[<>:"/\\|?*]', '_').Trim()
        $destination = Join-Path $destination ("{0} - Otimizado.lnk" -f $safeName)
    }
    if ($destination.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Atalhos devem ser criados em um caminho local.' }
    if ([IO.Path]::GetExtension($destination) -ine '.lnk') { throw 'O destino do atalho deve ter extensao .lnk.' }
    $parent = Split-Path -Parent $destination
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'A pasta de destino do atalho nao existe.' }
    if ((Test-Path -LiteralPath $destination) -and -not $Force) { throw 'O atalho ja existe. Use -Force para substitui-lo.' }
    if ((Get-OptimizerContext).Simulation) {
        return [pscustomobject]@{ Result = 'Simulated'; Path = $destination; ProfileId = $ProfileId }
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw 'Windows PowerShell 5.1 nao foi encontrado.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -NoSimulation -LaunchGameProfile "{1}"' -f $mainScript, $ProfileId
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($destination)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = (Get-OptimizerContext).AppRoot
        $shortcut.Description = "Iniciar $($profile.Name) com perfil do Windows FPS Optimizer"
        $shortcut.IconLocation = ('{0},0' -f [string]$profile.ExecutablePath)
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw 'O atalho nao foi criado.' }
        Write-GameOptimizerLog -Name 'Criar atalho otimizado' -OldValue '' -NewValue $destination -Result 'Success'
        return Get-Item -LiteralPath $destination -ErrorAction Stop
    }
    finally {
        if ($shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
}

Export-ModuleMember -Function Get-GameModeState, Set-GameMode, Set-GameModeState,
    Get-GameDvrState, Set-GameDvrEnabled, Set-GameCaptureState,
    Get-ManualGamingFeatureState, Get-GameOptimizationCapabilities,
    Open-WindowsGamingSettings, Get-GameProfiles, Add-GameProfile, Set-GameProfile,
    Remove-GameProfile, Select-GameExecutable, Find-InstalledGames, Get-ActiveGameSession,
    Start-GameSession, Stop-GameSession, Restore-GameSessionBackupEntry,
    Invoke-GameProfile, Invoke-TransientGameProfile, New-GameProfileShortcut
