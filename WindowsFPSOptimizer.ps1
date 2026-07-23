#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Simulation,
    [switch]$NoSimulation,
    [switch]$ReadOnly,
    [switch]$Relaunched,
    [string]$LaunchGameProfile = '',
    [string]$ResumeAction = '',
    [string]$ResumeDataBase64 = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:AppRoot 'Config.json'
$script:MainScriptPath = $MyInvocation.MyCommand.Path

function Test-BootstrapAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BootstrapTrustedProgramFilesPath {
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
        if ($null -eq $currentVersionKey) { return $null }
        $programFilesPath = [string]$currentVersionKey.GetValue(
            'ProgramFilesDir',
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        if ([string]::IsNullOrWhiteSpace($programFilesPath) -or $programFilesPath.Contains('%')) {
            return $null
        }
        return [IO.Path]::GetFullPath($programFilesPath)
    }
    finally {
        if ($null -ne $currentVersionKey) { $currentVersionKey.Dispose() }
        $baseKey.Dispose()
    }
}

function Test-BootstrapProtectedPath {
    $programFilesPath = Get-BootstrapTrustedProgramFilesPath
    if ([string]::IsNullOrWhiteSpace($programFilesPath)) { return $false }

    $trustedRoot = [IO.Path]::GetFullPath(
        (Join-Path $programFilesPath 'WindowsFPSOptimizer\App')
    ).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $scriptFull = [IO.Path]::GetFullPath($script:MainScriptPath)
    if (-not $scriptFull.StartsWith($trustedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $pathRoot = [IO.Path]::GetPathRoot($scriptFull)
    $cursor = $pathRoot
    foreach ($segment in @(($scriptFull.Substring($pathRoot.Length)) -split '[\\/]')) {
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

# Nao carregue modulos ou XAML gravaveis pelo usuario dentro de um processo ja
# elevado. O modo de simulacao continua disponivel sem elevacao a partir da fonte.
if ((Test-BootstrapAdministrator) -and -not (Test-BootstrapProtectedPath)) {
    throw (
        'Execucao administrativa recusada fora da instalacao protegida. ' +
        'Use o Setup.exe e abra o aplicativo pelo atalho criado em Program Files.'
    )
}

function Get-RelaunchArguments {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $script:MainScriptPath), '-Relaunched')
    if ($Simulation) { $arguments += '-Simulation' }
    if ($NoSimulation) { $arguments += '-NoSimulation' }
    if ($ReadOnly) { $arguments += '-ReadOnly' }
    if ($LaunchGameProfile) { $arguments += '-LaunchGameProfile'; $arguments += ('"{0}"' -f $LaunchGameProfile) }
    if ($ResumeAction) { $arguments += '-ResumeAction'; $arguments += ('"{0}"' -f $ResumeAction) }
    if ($ResumeDataBase64) { $arguments += '-ResumeDataBase64'; $arguments += $ResumeDataBase64 }
    return $arguments
}

# WPF, Registro e System32 devem usar o Windows PowerShell x64 em STA.
if (-not $Relaunched -and [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $trustedWindowsRoot = Split-Path -Parent ([Environment]::SystemDirectory)
    $sysnative = Join-Path $trustedWindowsRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        Start-Process -FilePath $sysnative -ArgumentList ((Get-RelaunchArguments) -join ' ') -ErrorAction Stop | Out-Null
        exit
    }
}
if (-not $Relaunched -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powershellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershellExe -ArgumentList ((Get-RelaunchArguments) -join ' ') -ErrorAction Stop | Out-Null
    exit
}

$moduleOrder = @(
    'Logging.psm1', 'Core.psm1', 'BackupManager.psm1', 'ProcessManager.psm1',
    'ServiceManager.psm1', 'StartupManager.psm1', 'PowerOptimizations.psm1',
    'GraphicsOptimizations.psm1', 'StorageOptimizations.psm1', 'WindowsAppsManager.psm1',
    'PrivacyManager.psm1', 'ScheduledTaskManager.psm1', 'GameOptimizations.psm1',
    'SystemAnalysis.psm1', 'Profiles.psm1', 'UIController.psm1'
)
foreach ($moduleName in $moduleOrder) {
    $modulePath = Join-Path $script:AppRoot $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Modulo obrigatorio ausente: $moduleName" }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

$configPreview = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$simulationMode = if ($NoSimulation) { $false } elseif ($Simulation) { $true } else { [bool]$configPreview.App.DefaultSimulation }
$context = Initialize-OptimizerContext -AppRoot $script:AppRoot -ConfigPath $script:ConfigPath `
    -Simulation:$simulationMode -ReadOnly:$ReadOnly
Initialize-OptimizerLogging -RootPath $context.LogRoot -SessionId $context.SessionId | Out-Null

if (-not $context.Platform.IsSupported) { throw 'Este aplicativo requer Windows 10 ou Windows 11.' }
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Execute com Windows PowerShell 5.1 (powershell.exe), nao com PowerShell 7/pwsh.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms
$xamlPath = Join-Path $script:AppRoot 'MainWindow.xaml'
$xamlDocument = New-Object System.Xml.XmlDocument
$xamlDocument.PreserveWhitespace = $true
$xamlDocument.Load($xamlPath)
$reader = New-Object System.Xml.XmlNodeReader $xamlDocument
$window = [Windows.Markup.XamlReader]::Load($reader)

$script:Controls = @{}
$namespace = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
$namespace.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
foreach ($node in @($xamlDocument.SelectNodes('//*[@x:Name]', $namespace))) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $script:Controls[$name] = $window.FindName($name) }
}

function Get-Control {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:Controls.ContainsKey($Name) -or $null -eq $script:Controls[$Name]) { throw "Controle XAML nao encontrado: $Name" }
    return $script:Controls[$Name]
}

function Show-AppMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Title = 'Windows FPS Optimizer',
        [Windows.MessageBoxImage]$Icon = [Windows.MessageBoxImage]::Information
    )
    [void][Windows.MessageBox]::Show($window, $Message, $Title, [Windows.MessageBoxButton]::OK, $Icon)
}

function Confirm-AppAction {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Title = 'Confirmar alteracao')
    return [Windows.MessageBox]::Show($window, $Message, $Title,
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning) -eq [Windows.MessageBoxResult]::Yes
}

function Set-ItemsSource {
    param([Parameter(Mandatory = $true)]$Control, $Items)
    $Control.ItemsSource = $null
    $Control.ItemsSource = [Collections.ArrayList]@($Items)
}

function Get-SelectedRows {
    param([Parameter(Mandatory = $true)]$Grid)
    return @($Grid.SelectedItems | ForEach-Object { $_ })
}

function ConvertTo-DisplayText {
    param($Value, [string]$Fallback = 'Indisponivel')
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Fallback }
    return [string]$Value
}

function Update-LogView {
    try {
        $entries = @(Get-OptimizerLogEntries -Last 120)
        $list = Get-Control 'LogListBox'
        $list.Items.Clear()
        foreach ($entry in $entries) {
            $time = ''
            try { $time = ([datetimeoffset]::Parse([string]$entry.Timestamp)).ToLocalTime().ToString('HH:mm:ss') } catch { $time = [string]$entry.Timestamp }
            $errorSuffix = if ($entry.Error) { " | $($entry.Error)" } else { '' }
            [void]$list.Items.Add("$time [$($entry.Result)] $($entry.Category): $($entry.Name)$errorSuffix")
        }
        if ($list.Items.Count -gt 0) { $list.ScrollIntoView($list.Items[$list.Items.Count - 1]) }
    }
    catch { }
}

$navigation = [ordered]@{
    NavHome = @{ Page = 'PageHome'; Title = 'Inicio'; Subtitle = 'Visao geral e acoes recomendadas' }
    NavGaming = @{ Page = 'PageGaming'; Title = 'Otimizacoes de jogos'; Subtitle = 'Recursos suportados e sessao temporaria' }
    NavPrograms = @{ Page = 'PagePrograms'; Title = 'Jogos e programas'; Subtitle = 'Perfis separados por executavel' }
    NavPower = @{ Page = 'PagePower'; Title = 'CPU e energia'; Subtitle = 'Planos, processador, tela e suspensao' }
    NavGraphics = @{ Page = 'PageGraphics'; Title = 'GPU e graficos'; Subtitle = 'Driver, configuracoes oficiais, caches e efeitos' }
    NavMemory = @{ Page = 'PageMemory'; Title = 'Memoria RAM'; Subtitle = 'Uso real, processos e arquivo de paginacao' }
    NavStorage = @{ Page = 'PageStorage'; Title = 'Armazenamento'; Subtitle = 'Limpeza seletiva, TRIM, HDD e integridade' }
    NavProcesses = @{ Page = 'PageProcesses'; Title = 'Processos e servicos'; Subtitle = 'Listas protegidas e opcoes individuais' }
    NavStartup = @{ Page = 'PageStartup'; Title = 'Inicializacao'; Subtitle = 'Desativacao reversivel sem remover programas' }
    NavVisual = @{ Page = 'PageVisual'; Title = 'Interface e efeitos visuais'; Subtitle = 'Perfis, opcoes individuais e previa do diff' }
    NavApps = @{ Page = 'PageApps'; Title = 'Aplicativos do Windows'; Subtitle = 'Inventario e remocao conservadora' }
    NavPrivacy = @{ Page = 'PagePrivacy'; Title = 'Privacidade e telemetria'; Subtitle = 'Somente politicas opcionais documentadas' }
    NavTasks = @{ Page = 'PageTasks'; Title = 'Tarefas agendadas'; Subtitle = 'Allowlist individual com explicacao' }
    NavSecurity = @{ Page = 'PageSecurity'; Title = 'Seguranca e integridade'; Subtitle = 'Defender, pontos, SFC, DISM e estado local' }
    NavProfiles = @{ Page = 'PageProfiles'; Title = 'Perfis de otimizacao'; Subtitle = 'Seguro, equilibrado e maximo FPS' }
}

function Show-AppPage {
    param([Parameter(Mandatory = $true)][string]$NavigationName)
    $target = $navigation[$NavigationName]
    foreach ($definition in $navigation.GetEnumerator()) {
        (Get-Control $definition.Value.Page).Visibility = if ($definition.Key -eq $NavigationName) { 'Visible' } else { 'Collapsed' }
        $button = Get-Control $definition.Key
        if ($definition.Key -eq $NavigationName) {
            $button.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#1D3355')
            $button.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#3B82F6')
            $button.FontWeight = 'SemiBold'
            try { [Windows.Automation.AutomationProperties]::SetHelpText($button, 'Pagina atual') } catch { }
        }
        else {
            $button.Background = [Windows.Media.Brushes]::Transparent
            $button.BorderBrush = [Windows.Media.Brushes]::Transparent
            $button.FontWeight = 'Normal'
            try { [Windows.Automation.AutomationProperties]::SetHelpText($button, '') } catch { }
        }
    }
    (Get-Control 'PageTitleText').Text = $target.Title
    (Get-Control 'PageSubtitleText').Text = $target.Subtitle
    try { [void](Get-Control $target.Page).Focus() } catch { }
}

foreach ($name in $navigation.Keys) {
    $capturedName = $name
    (Get-Control $name).Add_Click({ Show-AppPage -NavigationName $capturedName }.GetNewClosure())
}

# O pool mantem a thread WPF livre. Apenas uma operacao de UI e despachada por vez;
# cada operacao importa os mesmos modulos em um runspace isolado.
$script:RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, 2)
$script:RunspacePool.ApartmentState = 'MTA'
$script:RunspacePool.ThreadOptions = 'ReuseThread'
$script:RunspacePool.Open()
$script:ActiveTask = $null
$script:LastMetricsStarted = [datetime]::MinValue
$script:MetricsRetryAfter = [datetime]::MinValue
$script:MetricsHadFailure = $false
$script:MetricsFailureCount = 0
$script:PendingRefresh = $false
$script:CancelRequested = $false
$script:GraphicsCacheEstimate = $null

$workerScript = {
    param($Root, $ConfigPath, [bool]$SimulationMode, [bool]$ReadOnlyMode, $ActionId, $ActionParameters)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $modules = @(
        'Logging.psm1', 'Core.psm1', 'BackupManager.psm1', 'ProcessManager.psm1',
        'ServiceManager.psm1', 'StartupManager.psm1', 'PowerOptimizations.psm1',
        'GraphicsOptimizations.psm1', 'StorageOptimizations.psm1', 'WindowsAppsManager.psm1',
        'PrivacyManager.psm1', 'ScheduledTaskManager.psm1', 'GameOptimizations.psm1',
        'SystemAnalysis.psm1', 'Profiles.psm1', 'UIController.psm1'
    )
    foreach ($module in $modules) { Import-Module (Join-Path $Root $module) -Force -ErrorAction Stop }
    $workerContext = Initialize-OptimizerContext -AppRoot $Root -ConfigPath $ConfigPath `
        -Simulation:$SimulationMode -ReadOnly:$ReadOnlyMode
    Initialize-OptimizerLogging -RootPath $workerContext.LogRoot -SessionId $workerContext.SessionId | Out-Null
    return Invoke-UIAction -ActionId $ActionId -Parameters $ActionParameters
}

function Set-UiBusyState {
    param([bool]$Busy, [string]$Message = 'Pronto.')
    $gameMonitorActive = $Busy -and $script:ActiveTask -and $script:ActiveTask.ActionId -in @('StartGameSession', 'InvokeGameProfile')
    # Durante o monitoramento do jogo a interface continua operavel. Novas mutacoes
    # sao recusadas pelo dispatcher, mas o usuario ainda pode pedir encerramento.
    (Get-Control 'ContentHost').IsEnabled = (-not $Busy) -or $gameMonitorActive
    (Get-Control 'OperationStatusText').Text = $Message
    $progress = Get-Control 'OperationProgressBar'
    $progress.IsIndeterminate = $Busy
    $progress.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    if (-not $Busy) { $progress.Value = 0 }
    (Get-Control 'BtnCancelOperation').IsEnabled = $Busy
    (Get-Control 'SimulationCheckBox').IsEnabled = -not $Busy
    (Get-Control 'ReadOnlyCheckBox').IsEnabled = -not $Busy
    (Get-Control 'BtnElevate').IsEnabled = -not $Busy
}

function Set-MetricsRetryBackoff {
    # Falhas repetidas de metricas nao devem bloquear a interface nem gerar um
    # log a cada poucos segundos. O atraso cresce ate cinco minutos e volta ao
    # normal assim que uma leitura for concluida com sucesso.
    $retryStepsSeconds = @(15, 30, 60, 120, 240, 300)
    $script:MetricsFailureCount = [math]::Min(
        $script:MetricsFailureCount + 1,
        $retryStepsSeconds.Count
    )
    $delaySeconds = [int]$retryStepsSeconds[$script:MetricsFailureCount - 1]
    $script:MetricsHadFailure = $true
    $script:MetricsRetryAfter = (Get-Date).AddSeconds($delaySeconds)
    try {
        (Get-Control 'OperationStatusText').Text = (
            "Falha ao atualizar metricas; nova tentativa em $delaySeconds segundos. Consulte o log."
        )
    }
    catch { }
}

function Write-UiBackgroundFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ActionId,
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Phase,
        [string]$StatusMessage = 'Falha em uma atualizacao de segundo plano. Consulte o log.'
    )

    # Um callback do Dispatcher nunca deve derrubar a janela ao tentar relatar
    # sua propria falha. Logging, status e refresh ficam isolados entre si.
    try {
        Write-OptimizerLog `
            -Name $Name `
            -Category 'Interface' `
            -Result 'Error' `
            -ErrorMessage $ErrorRecord.Exception.ToString() `
            -Level 'Error' `
            -Details @{
                ActionId = $ActionId
                Phase = $Phase
                ScriptStackTrace = [string]$ErrorRecord.ScriptStackTrace
            } | Out-Null
    }
    catch { }
    try { (Get-Control 'OperationStatusText').Text = $StatusMessage } catch { }
    try { Update-LogView } catch { }
}

function Request-AdministrativeRelaunch {
    param([string]$PendingActionId = '', [hashtable]$PendingParameters = @{})
    if ($context.IsAdministrator) { return $true }
    if (-not (Confirm-AppAction -Message "Esta operacao requer privilegios de administrador. Deseja reiniciar o aplicativo com UAC?`n`nNenhuma alteracao foi aplicada." -Title 'Elevacao necessaria')) { return $false }
    $arguments = @()
    if ([bool](Get-Control 'SimulationCheckBox').IsChecked) { $arguments += '-Simulation' } else { $arguments += '-NoSimulation' }
    if ([bool](Get-Control 'ReadOnlyCheckBox').IsChecked) { $arguments += '-ReadOnly' }
    if (-not [string]::IsNullOrWhiteSpace($LaunchGameProfile)) {
        $arguments += '-LaunchGameProfile'
        $arguments += $LaunchGameProfile
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PendingActionId)) {
        $json = $PendingParameters | ConvertTo-Json -Depth 12 -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($json))
        $arguments += '-ResumeAction'; $arguments += $PendingActionId
        $arguments += '-ResumeDataBase64'; $arguments += $encoded
    }
    if (Start-OptimizerElevated -ScriptPath $script:MainScriptPath -AdditionalArguments $arguments) {
        $window.Close()
        return $false
    }
    return $true
}

function Start-UiAction {
    param(
        [Parameter(Mandatory = $true)][string]$ActionId,
        [hashtable]$Parameters = @{},
        [string]$Status = 'Executando operacao...',
        [switch]$RequiresAdministrator,
        [switch]$Quiet,
        [scriptblock]$OnCompleted
    )

    if ($script:ActiveTask) {
        if ($ActionId -eq 'StopGameSession' -and $script:ActiveTask.ActionId -in @('StartGameSession', 'InvokeGameProfile')) {
            try {
                [void]$script:ActiveTask.PowerShell.BeginStop($null, $null)
                (Get-Control 'OperationStatusText').Text = 'Encerramento solicitado; restaurando a sessao...'
                (Get-Control 'GameSessionStatusText').Text = 'Encerramento solicitado; aguardando restauracao segura...'
            }
            catch { Show-AppMessage -Message $_.Exception.Message -Title 'Sessao de jogo' -Icon Error }
            return
        }
        (Get-Control 'OperationStatusText').Text = 'Aguarde a operacao atual terminar.'
        return
    }
    if ($RequiresAdministrator -and -not [bool](Get-Control 'SimulationCheckBox').IsChecked -and
        -not (Request-AdministrativeRelaunch -PendingActionId $ActionId -PendingParameters $Parameters)) { return }
    $powerShell = $null
    $handle = $null
    try {
        $powerShell = [PowerShell]::Create()
        $powerShell.RunspacePool = $script:RunspacePool
        [void]$powerShell.AddScript($workerScript)
        [void]$powerShell.AddArgument($script:AppRoot)
        [void]$powerShell.AddArgument($script:ConfigPath)
        [void]$powerShell.AddArgument([bool](Get-Control 'SimulationCheckBox').IsChecked)
        [void]$powerShell.AddArgument([bool](Get-Control 'ReadOnlyCheckBox').IsChecked)
        [void]$powerShell.AddArgument($ActionId)
        [void]$powerShell.AddArgument($Parameters)
        $handle = $powerShell.BeginInvoke()
        $script:CancelRequested = $false
        $script:ActiveTask = [pscustomobject]@{
            ActionId = $ActionId; PowerShell = $powerShell; Handle = $handle; OnCompleted = $OnCompleted
            Started = Get-Date; Status = $Status; Quiet = [bool]$Quiet
        }
        if (-not $Quiet) { Set-UiBusyState -Busy $true -Message $Status }
    }
    catch {
        if (
            $script:ActiveTask -and
            [object]::ReferenceEquals($script:ActiveTask.PowerShell, $powerShell)
        ) {
            $script:ActiveTask = $null
        }
        if ($null -ne $powerShell) {
            if ($null -ne $handle -and -not $handle.IsCompleted) {
                try { [void]$powerShell.BeginStop($null, $null) } catch { }
            }
            try { $powerShell.Dispose() } catch { }
        }
        throw
    }
}

function Update-HomeOverview {
    param($Overview)
    if (-not $Overview) { return }
    (Get-Control 'HomeComputerText').Text = ConvertTo-DisplayText $Overview.ComputerName
    (Get-Control 'HomeWindowsText').Text = "$(ConvertTo-DisplayText $Overview.WindowsCaption) ($($Overview.WindowsBuild))"
    (Get-Control 'HomeCpuText').Text = ConvertTo-DisplayText $Overview.Processor
    (Get-Control 'HomeRamText').Text = if ($Overview.Memory) { "$($Overview.Memory.TotalGB) GB" } else { 'Indisponivel' }
    (Get-Control 'HomeGpuText').Text = (@($Overview.Graphics | ForEach-Object { $_.Name }) -join '; ')
    (Get-Control 'HomeStorageText').Text = (@($Overview.Storage | ForEach-Object { "$($_.Drive) $($_.Type)" }) -join '; ')
    $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\')
    $systemStorage = @($Overview.Storage | Where-Object Drive -eq $systemDrive | Select-Object -First 1)
    (Get-Control 'HomeFreeSpaceText').Text = if ($systemStorage) { "$($systemStorage[0].FreeGB) GB ($($systemStorage[0].FreePercent)%)" } else { 'Indisponivel' }
    (Get-Control 'HomePowerText').Text = if ($Overview.PowerPlan -and $Overview.PowerPlan.ActivePlan) { [string]$Overview.PowerPlan.ActivePlan.Name } else { 'Indisponivel' }
    (Get-Control 'HomeGameModeText').Text = if ($Overview.GameMode) { [string]$Overview.GameMode.State } else { 'Indisponivel' }
    (Get-Control 'HomeHagsText').Text = if ($Overview.Hags) { [string]$Overview.Hags.State } else { 'Indisponivel' }
    if ($Overview.Metrics) {
        (Get-Control 'HomeProcessText').Text = [string]$Overview.Metrics.ProcessCount
        (Get-Control 'HomeUsageText').Text = "CPU $($Overview.Metrics.CpuPercent)% | RAM $($Overview.Metrics.RamPercent)% | Disco $($Overview.Metrics.DiskPercent)%"
    }
    (Get-Control 'PowerHardwareText').Text = "$(if ($Overview.IsLaptop) { 'Notebook' } else { 'Desktop' }) | CPU $($Overview.ProcessorVendor) | $($Overview.Processor)"
}

function Update-SecurityControls {
    param($Security)
    if (-not $Security) { return }
    (Get-Control 'DefenderStatusText').Text = if ($Security.Defender) { [string]$Security.Defender.Status } else { 'Indisponivel' }
    (Get-Control 'RestartPendingText').Text = if ($Security.Restart.Pending) { 'Sim' } else { 'Nao' }
    (Get-Control 'RestorePointText').Text = if ($Security.RestorePoint) { "$($Security.RestorePoint.CreationTime) | $($Security.RestorePoint.Description)" } else { 'Nenhum ponto encontrado' }
    (Get-Control 'UpdateStatusText').Text = "Atualizacoes pendentes: $($Security.Updates.PendingSearchStatus). Ultima instalada: $($Security.Updates.LastInstalledId)"
    $integrity = $Security.Integrity
    (Get-Control 'IntegrityStatusText').Text = if (-not $integrity -or -not [bool]$integrity.Available) {
        'Integridade: nenhuma verificacao registrada.'
    } elseif ($null -eq $integrity.Healthy) {
        "Integridade: inconclusiva. $($integrity.Reason)"
    } else {
        $source = if ($integrity.AssessmentSource) { $integrity.AssessmentSource } else { $integrity.LastCheck }
        "Integridade: $(if ([bool]$integrity.Healthy) { 'sem corrupcao conhecida' } else { 'atencao necessaria' }). Fonte vigente: $($source.Tool) $($source.Mode), $($source.CheckedAtUtc). $($source.Evidence)"
    }
}

function Show-ManualBackupResult {
    param($Result)
    if (-not $Result) { return }
    $messageProperty = $Result.PSObject.Properties['Message']
    $succeededProperty = $Result.PSObject.Properties['Succeeded']
    $restorePointProperty = $Result.PSObject.Properties['RestorePointSucceeded']
    $resultProperty = $Result.PSObject.Properties['Result']
    $message = if ($messageProperty) { [string]$messageProperty.Value } else { 'Operacao de backup concluida.' }
    $isSimulation = $resultProperty -and [string]$resultProperty.Value -eq 'Simulated'
    $warning = ($succeededProperty -and -not [bool]$succeededProperty.Value) -or
        (-not $isSimulation -and $restorePointProperty -and -not [bool]$restorePointProperty.Value)
    Show-AppMessage -Title 'Backup e ponto de restauracao' -Message $message `
        -Icon $(if ($warning) { [Windows.MessageBoxImage]::Warning } else { [Windows.MessageBoxImage]::Information })
}

function Update-PrivacyControls {
    param($States)
    $mapping = @{
        PrivacyTailoredCheck = 'TailoredExperiences'
        PrivacyThirdPartyCheck = 'ThirdPartySuggestions'
        PrivacyAdvertisingCheck = 'AdvertisingId'
        PrivacyActivityCheck = 'ActivityHistory'
        PrivacyDiagnosticsCheck = 'OptionalDiagnostics'
        PrivacyWindowsTipsCheck = 'WindowsTips'
        PrivacyConsumerFeaturesCheck = 'WindowsConsumerFeatures'
        PrivacyStartRecommendationsCheck = 'StartRecommendations'
    }
    foreach ($item in $mapping.GetEnumerator()) {
        $control = Get-Control $item.Key
        $state = @($States | Where-Object { [string]$_.Name -eq [string]$item.Value } | Select-Object -First 1)
        if ($state.Count -eq 0) {
            $control.IsEnabled = $false
            $control.ToolTip = 'Estado indisponivel.'
            continue
        }
        $control.IsChecked = ([string]$state[0].State -eq 'Protected')
        $control.IsEnabled = [bool]$state[0].Supported -and -not [bool]$state[0].ManagedWriteBlocked
        $control.ToolTip = if (-not [bool]$state[0].Supported) {
            [string]$state[0].CompatibilityReason
        } elseif ([bool]$state[0].ManagedWriteBlocked) {
            'Politica gerenciada por dominio ou MDM; alteracao local bloqueada.'
        } else {
            "Estado atual: $($state[0].State). $($state[0].Benefit)"
        }
    }
}

function Format-PageFileStatus {
    param($PageFile)
    if (-not $PageFile -or -not [bool]$PageFile.Available) {
        $errorText = if ($PageFile -and $PageFile.Error) { " Erro: $($PageFile.Error)" } else { '' }
        return "Estado indisponivel sem acesso ao provedor local.$errorText"
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($(if ([bool]$PageFile.AutomaticManagedPagefile) { 'Gerenciamento automatico do Windows.' } else { 'Configuracao manual ativa.' }))
    foreach ($setting in @($PageFile.Settings)) {
        $lines.Add(("{0}: inicial {1} MB, maximo {2} MB" -f $setting.Name, $setting.InitialSizeMB, $setting.MaximumSizeMB))
    }
    foreach ($usage in @($PageFile.Usage)) {
        $lines.Add(("{0}: alocado {1} MB, uso {2} MB, pico {3} MB" -f $usage.Name, $usage.AllocatedMB, $usage.CurrentUsageMB, $usage.PeakUsageMB))
    }
    if ($lines.Count -eq 1) { $lines.Add('O Windows nao expos detalhes adicionais nesta leitura.') }
    return ($lines -join [Environment]::NewLine)
}

function Update-UiFromResult {
    param([string]$ActionId, $Result)
    switch ($ActionId) {
        'InitialData' {
            Update-HomeOverview $Result.Overview
            if ($Result.Memory) {
                (Get-Control 'MemoryTotalText').Text = "$($Result.Memory.TotalGB) GB"
                (Get-Control 'MemoryUsedText').Text = "$($Result.Memory.UsedGB) GB ($($Result.Memory.UsedPercent)%)"
                (Get-Control 'MemoryAvailableText').Text = "$($Result.Memory.AvailableGB) GB"
            }
            Set-ItemsSource (Get-Control 'TopMemoryGrid') $Result.TopMemory
            (Get-Control 'PageFileStatusText').Text = Format-PageFileStatus $Result.PageFile
            Set-ItemsSource (Get-Control 'StorageGrid') $Result.Storage
            Set-ItemsSource (Get-Control 'GpuGrid') $Result.Graphics
            Set-ItemsSource (Get-Control 'AllProcessesGrid') $Result.Processes
            Set-ItemsSource (Get-Control 'ServicesGrid') $Result.Services
            Set-ItemsSource (Get-Control 'ServiceProfilesCombo') $Result.ServiceProfiles
            Set-ItemsSource (Get-Control 'StartupGrid') $Result.Startup
            Set-ItemsSource (Get-Control 'AppsGrid') $Result.Applications
            Set-ItemsSource (Get-Control 'TasksGrid') $Result.Tasks
            Set-ItemsSource (Get-Control 'GamesGrid') $Result.Games
            Set-ItemsSource (Get-Control 'BackupsGrid') $Result.Backups
            Set-ItemsSource (Get-Control 'BackupEntriesGrid') @()
            (Get-Control 'GameSessionStatusText').Text = if ($Result.GameSession) {
                "Sessao pendente $($Result.GameSession.Id) ($($Result.GameSession.Status)). Use Encerrar e restaurar sessao."
            } else { 'Nenhuma sessao ativa.' }
            Update-SecurityControls $Result.Security
            Update-PrivacyControls $Result.Privacy
            if ($Result.GraphicsCache) {
                $script:GraphicsCacheEstimate = $Result.GraphicsCache
                (Get-Control 'GraphicsCacheEstimateText').Text = "$($Result.GraphicsCache.TotalMegabytes) MB em $($Result.GraphicsCache.TotalFiles) arquivos."
                $cacheTypes = @($Result.GraphicsCache.Locations | ForEach-Object { [string]$_.Type } | Select-Object -Unique)
                (Get-Control 'CacheNvidiaCheck').IsEnabled = $cacheTypes -contains 'NVIDIA'
                (Get-Control 'CacheAmdCheck').IsEnabled = $cacheTypes -contains 'AMD'
                (Get-Control 'CacheNvidiaCheck').ToolTip = if ($cacheTypes -contains 'NVIDIA') { 'GPU/cache NVIDIA detectado.' } else { 'Nenhuma GPU/cache NVIDIA aplicavel foi detectado.' }
                (Get-Control 'CacheAmdCheck').ToolTip = if ($cacheTypes -contains 'AMD') { 'GPU/cache AMD detectado.' } else { 'Nenhuma GPU/cache AMD aplicavel foi detectado.' }
            }
            if ($Result.GameCapabilities) {
                $game = $Result.GameCapabilities
                (Get-Control 'BtnEnableGameMode').IsEnabled = ([string]$game.GameMode.State -ne 'Unsupported')
                (Get-Control 'BtnEnableGameMode').Content = if ($game.GameMode.CanAutomate) { 'Ativar Game Mode' } else { 'Abrir Game Mode (manual)' }
                (Get-Control 'BtnEnableGameMode').ToolTip = [string]$game.GameMode.Reason
                (Get-Control 'BtnDisableCaptures').IsEnabled = [bool]$game.GameDvr.CanAutomate
                (Get-Control 'BtnDisableCaptures').ToolTip = [string]$game.GameDvr.Reason
                (Get-Control 'BtnOpenCaptures').IsEnabled = ([string]$game.Captures.State -ne 'Unsupported')
                (Get-Control 'BtnOpenGameBar').IsEnabled = ([string]$game.GameBar.State -ne 'Unsupported')
                (Get-Control 'BtnOpenHags').IsEnabled = ([string]$game.Hags.State -ne 'Unsupported')
                (Get-Control 'BtnGraphicsHags').IsEnabled = ([string]$game.Hags.State -ne 'Unsupported')
                (Get-Control 'BtnOpenGraphicsSettings').IsEnabled = ([string]$game.GpuPreference.State -ne 'Unsupported')
                (Get-Control 'BtnGraphicsPreferences').IsEnabled = ([string]$game.GpuPreference.State -ne 'Unsupported')
                (Get-Control 'BtnOpenFocus').IsEnabled = ([string]$game.DoNotDisturb.State -ne 'Unsupported')
            }
            if ($Result.PowerCapabilities) {
                $powerSupported = [bool]$Result.PowerCapabilities.SupportedWindows
                foreach ($controlName in @('BtnHighPerformance', 'BtnUltimatePerformance', 'BtnCreateGamingPlan', 'BtnApplySleepSettings')) {
                    (Get-Control $controlName).IsEnabled = $powerSupported
                }
                (Get-Control 'CoolingPolicyCombo').IsEnabled = [bool]$Result.PowerCapabilities.CoolingPolicyAvailable
                (Get-Control 'CoolingPolicyCombo').ToolTip = if ($Result.PowerCapabilities.CoolingPolicyAvailable) { 'Politica exposta pelo firmware.' } else { 'Politica de resfriamento indisponivel neste hardware/plano.' }
            }
        }
        'Analyze' {
            Update-HomeOverview $Result.Overview
            (Get-Control 'ScoreText').Text = [string]$Result.Assessment.Score
            (Get-Control 'ScoreLabelText').Text = [string]$Result.Assessment.Label
            Set-ItemsSource (Get-Control 'RecommendationsGrid') $Result.Recommendations
            Update-SecurityControls $Result.Security
        }
        'CreateBackup' { Show-ManualBackupResult $Result }
        'CreateRestorePoint' { Show-ManualBackupResult $Result }
        'Metrics' {
            (Get-Control 'HomeProcessText').Text = [string]$Result.ProcessCount
            (Get-Control 'HomeUsageText').Text = "CPU $($Result.CpuPercent)% | RAM $($Result.RamPercent)% | Disco $($Result.DiskPercent)%"
        }
        'Memory' {
            (Get-Control 'MemoryTotalText').Text = "$($Result.Memory.TotalGB) GB"
            (Get-Control 'MemoryUsedText').Text = "$($Result.Memory.UsedGB) GB ($($Result.Memory.UsedPercent)%)"
            (Get-Control 'MemoryAvailableText').Text = "$($Result.Memory.AvailableGB) GB"
            Set-ItemsSource (Get-Control 'TopMemoryGrid') $Result.Top
            (Get-Control 'PageFileStatusText').Text = Format-PageFileStatus $Result.PageFile
        }
        'Processes' { Set-ItemsSource (Get-Control 'AllProcessesGrid') $Result }
        'Services' { Set-ItemsSource (Get-Control 'ServicesGrid') $Result }
        'ServiceProfiles' { Set-ItemsSource (Get-Control 'ServiceProfilesCombo') $Result }
        'Startup' { Set-ItemsSource (Get-Control 'StartupGrid') $Result }
        'Storage' { Set-ItemsSource (Get-Control 'StorageGrid') $Result }
        'CleanupEstimate' { Set-ItemsSource (Get-Control 'CleanupEstimateGrid') $Result }
        'Graphics' { Set-ItemsSource (Get-Control 'GpuGrid') $Result.Adapters }
        'GraphicsCacheEstimate' {
            $script:GraphicsCacheEstimate = $Result
            (Get-Control 'GraphicsCacheEstimateText').Text = "$($Result.TotalMegabytes) MB em $($Result.TotalFiles) arquivos. $($Result.Warning)"
        }
        'Applications' { Set-ItemsSource (Get-Control 'AppsGrid') $Result }
        'Tasks' { Set-ItemsSource (Get-Control 'TasksGrid') $Result }
        'Security' { Update-SecurityControls $Result }
        'Games' { Set-ItemsSource (Get-Control 'GamesGrid') $Result }
        'Backups' {
            Set-ItemsSource (Get-Control 'BackupsGrid') $Result
            Set-ItemsSource (Get-Control 'BackupEntriesGrid') @()
        }
        'BackupEntries' { Set-ItemsSource (Get-Control 'BackupEntriesGrid') $Result }
        'VisualPreview' {
            $preview = Get-Control 'VisualPreviewList'; $preview.Items.Clear()
            [void]$preview.Items.Add("Previa do perfil: $($Result.Profile)")
            foreach ($property in $Result.Proposed.PSObject.Properties) {
                $before = if ($property.Name -eq 'Transparency') {
                    $Result.Current.Transparency
                } else {
                    Get-ObjectPropertyValue $Result.Current.SystemParameters $property.Name 'Indisponivel'
                }
                $status = if (Compare-OptimizerValue $before $property.Value) { 'sem mudanca' } else { "$before -> $($property.Value)" }
                [void]$preview.Items.Add("$($property.Name): $status")
            }
            [void]$preview.Items.Add("Preservado: $(@($Result.Preserved) -join ', ')")
        }
    }
}

function Get-OperationCompletionMessage {
    param($Result, [double]$ElapsedSeconds)

    $states = New-Object System.Collections.Generic.List[string]
    function Add-ResultStates {
        param($Value, [int]$Depth = 0)
        if ($null -eq $Value -or $Depth -gt 3 -or $Value -is [string]) { return }
        if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
            foreach ($child in @($Value)) { Add-ResultStates -Value $child -Depth ($Depth + 1) }
            return
        }
        foreach ($propertyName in @('Result', 'Status', 'State')) {
            $property = $Value.PSObject.Properties[$propertyName]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $states.Add([string]$property.Value)
            }
        }
        foreach ($propertyName in @('Results', 'Outcomes', 'Changes', 'ProfileResults', 'Restoration')) {
            $property = $Value.PSObject.Properties[$propertyName]
            if ($property) { Add-ResultStates -Value $property.Value -Depth ($Depth + 1) }
        }
    }
    Add-ResultStates -Value $Result
    $allStates = $states.ToArray()
    if (@($allStates | Where-Object { $_ -match '^(Error|Failed|RestoreFailed)$' }).Count -gt 0) {
        return "Concluido com falhas registradas em $ElapsedSeconds s. Consulte o log."
    }
    if (@($allStates | Where-Object { $_ -match '^(Warning|Partial|RestorePartial|Conflict|Unsupported)$' }).Count -gt 0) {
        return "Concluido com alertas em $ElapsedSeconds s. Consulte o log."
    }
    if (@($allStates | Where-Object { $_ -match '^(UnsupportedManual|Manual)$' }).Count -gt 0) {
        return "Recurso manual ou indisponivel nesta configuracao. Verifique os detalhes."
    }
    if (@($allStates | Where-Object { $_ -eq 'Simulated' }).Count -gt 0) {
        return "Simulacao concluida em $ElapsedSeconds s; nenhuma alteracao real foi aplicada."
    }
    if (@($allStates | Where-Object { $_ -match '^(NoChange|Skipped|AlreadyRestored)$' }).Count -gt 0) {
        return "Nenhuma alteracao adicional foi necessaria ($ElapsedSeconds s)."
    }
    return "Concluido em $ElapsedSeconds s."
}

$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$pollTimer.Add_Tick({
    $task = $script:ActiveTask
    try {
        if (-not $task -or -not $task.Handle.IsCompleted) { return }
        if (-not [object]::ReferenceEquals($script:ActiveTask, $task)) { return }
        $script:ActiveTask = $null
        try {
            $output = @($task.PowerShell.EndInvoke($task.Handle))
            if ($task.PowerShell.Streams.Error.Count -gt 0) { throw $task.PowerShell.Streams.Error[0].Exception }
            # EndInvoke devolve PSObject, mas a enumeracao do PowerShell 5.1 ja
            # apresenta seus objetos-base. Nao acesse .BaseObject diretamente:
            # PSCustomObject nao expoe essa propriedade sob StrictMode.
            $result = if ($output.Count -eq 1) { $output[0] } else { @($output) }
            Update-UiFromResult -ActionId $task.ActionId -Result $result
            if ($task.OnCompleted) { & $task.OnCompleted $result }
            if ($task.ActionId -eq 'Metrics') {
                $script:MetricsRetryAfter = [datetime]::MinValue
                $script:MetricsFailureCount = 0
                if ($script:MetricsHadFailure) {
                    (Get-Control 'OperationStatusText').Text = 'Atualizacao automatica restabelecida.'
                    $script:MetricsHadFailure = $false
                }
            }
            $elapsed = [math]::Round(((Get-Date) - $task.Started).TotalSeconds, 1)
            if (-not $task.Quiet) {
                Set-UiBusyState -Busy $false -Message (Get-OperationCompletionMessage -Result $result -ElapsedSeconds $elapsed)
            }
        }
        catch {
            $operationError = $_
            try {
                Write-OptimizerLog `
                    -Name "Falha na interface: $($task.ActionId)" `
                    -Category 'Interface' `
                    -Result 'Error' `
                    -ErrorMessage $operationError.Exception.ToString() `
                    -Level 'Error' `
                    -Details @{
                        ActionId = [string]$task.ActionId
                        Quiet = [bool]$task.Quiet
                        ScriptStackTrace = [string]$operationError.ScriptStackTrace
                    } | Out-Null
            }
            catch { }

            if ($script:CancelRequested -or $operationError.Exception -is [Management.Automation.PipelineStoppedException]) {
                $isGameSession = $task.ActionId -in @('StartGameSession', 'InvokeGameProfile')
                Set-UiBusyState -Busy $false -Message $(if ($isGameSession) {
                    'Sessao interrompida; restauracao solicitada. Verifique o log.'
                } else { 'Operacao cancelada. Verifique o log para confirmar o rollback.' })
                if ($isGameSession) {
                    (Get-Control 'GameSessionStatusText').Text = 'Sessao interrompida; confira no log se a restauracao foi concluida.'
                    $script:PendingRefresh = $true
                }
            }
            else {
                if ($task.ActionId -eq 'Metrics') {
                    # Falhas de telemetria local em segundo plano nao devem abrir
                    # um MessageBox a cada ciclo. Informe na barra, registre o erro
                    # e tente novamente com backoff.
                    Set-MetricsRetryBackoff
                }
                elseif ($task.Quiet) {
                    # Quiet e um contrato de tarefa em segundo plano: registre e
                    # sinalize a falha sem interromper o usuario com uma modal.
                    (Get-Control 'OperationStatusText').Text = (
                        "A tarefa em segundo plano '$($task.ActionId)' falhou. Consulte o log."
                    )
                }
                else {
                    Set-UiBusyState -Busy $false -Message 'Falha na operacao.'
                    Show-AppMessage -Message (
                        "A operacao falhou:`n`n" +
                        $operationError.Exception.Message +
                        "`n`nConsulte o log para detalhes."
                    ) -Title 'Erro' -Icon Error
                }
            }
        }
        finally {
            $script:CancelRequested = $false
            try { $task.PowerShell.Dispose() } catch { }
            try { Update-LogView } catch { }
        }
    }
    catch {
        $pollError = $_
        # Se o proprio handle ficou invalido antes de IsCompleted, remova apenas
        # o snapshot que ainda for a tarefa ativa. Isso impede um erro a cada
        # tick de 180 ms sem interferir em uma tarefa que tenha sido substituida.
        try {
            if ($task -and [object]::ReferenceEquals($script:ActiveTask, $task)) {
                $script:ActiveTask = $null
                try { [void]$task.PowerShell.BeginStop($null, $null) } catch { }
                try { $task.PowerShell.Dispose() } catch { }
            }
        }
        catch { }
        if ($task -and $task.ActionId -eq 'Metrics') {
            try { Set-MetricsRetryBackoff } catch { }
        }
        Write-UiBackgroundFailure `
            -Name 'Falha no monitor de conclusao da interface' `
            -ActionId $(if ($task) { [string]$task.ActionId } else { 'DispatcherPoll' }) `
            -ErrorRecord $pollError `
            -Phase 'PollTimer' `
            -StatusMessage 'Falha ao concluir uma atualizacao da interface. Consulte o log.'
    }
})
$pollTimer.Start()

$metricsTimer = New-Object Windows.Threading.DispatcherTimer
$metricsTimer.Interval = [TimeSpan]::FromSeconds([math]::Max(2, [int]$context.Config.App.MetricsRefreshSeconds))
$metricsTimer.Add_Tick({
    try {
        $now = Get-Date
        if (
            -not $script:ActiveTask -and
            $now -ge $script:MetricsRetryAfter -and
            ($now - $script:LastMetricsStarted).TotalSeconds -ge 2
        ) {
            $script:LastMetricsStarted = Get-Date
            Start-UiAction -ActionId 'Metrics' -Status 'Atualizando metricas...' -Quiet
        }
    }
    catch {
        $metricsStartError = $_
        try { Set-MetricsRetryBackoff } catch { }
        Write-UiBackgroundFailure `
            -Name 'Falha ao iniciar atualizacao automatica de metricas' `
            -ActionId 'Metrics' `
            -ErrorRecord $metricsStartError `
            -Phase 'ScheduleOrBeginInvoke' `
            -StatusMessage 'Falha ao atualizar metricas; uma nova tentativa sera feita automaticamente.'
    }
})

function Add-AsyncButtonHandler {
    param(
        [string]$ControlName, [string]$ActionId, [scriptblock]$ParameterFactory,
        [string]$Status, [switch]$RequiresAdministrator,
        [string]$ConfirmationMessage = '', [scriptblock]$OnCompleted
    )
    $control = Get-Control $ControlName
    $control.Add_Click({
        try {
            if ($ConfirmationMessage -and -not (Confirm-AppAction -Message $ConfirmationMessage)) { return }
            $parameters = if ($ParameterFactory) { & $ParameterFactory } else { @{} }
            Start-UiAction -ActionId $ActionId -Parameters $parameters -Status $Status `
                -RequiresAdministrator:$RequiresAdministrator -OnCompleted $OnCompleted
        }
        catch { Show-AppMessage -Message $_.Exception.Message -Title 'Validacao' -Icon Warning }
    }.GetNewClosure())
}

function Add-OpenSettingsHandler {
    param([string]$ControlName, [string]$Page)
    (Get-Control $ControlName).Add_Click({
        try { Open-WindowsGamingSettings -Page $Page | Out-Null; Update-LogView }
        catch { Show-AppMessage -Message $_.Exception.Message -Title 'Nao foi possivel abrir Configuracoes' -Icon Error }
    }.GetNewClosure())
}

function Get-SelectedServiceNames {
    return @((Get-SelectedRows (Get-Control 'ServicesGrid')) | Where-Object {
        $optionalProperty = $_.PSObject.Properties['IsOptional']
        if ($optionalProperty) { return [bool]$optionalProperty.Value }
        $installedProperty = $_.PSObject.Properties['Installed']
        return ($installedProperty -and [bool]$installedProperty.Value)
    } | ForEach-Object { [string]$_.Name })
}

function Get-SelectedTaskIds {
    return @((Get-SelectedRows (Get-Control 'TasksGrid')) | ForEach-Object { "{0}|{1}" -f $_.TaskPath, $_.TaskName })
}

function Get-SelectedStartupIds {
    return @((Get-SelectedRows (Get-Control 'StartupGrid')) | Where-Object IsEnabled | ForEach-Object { [string]$_.Id })
}

function Get-ComboContent {
    param([Parameter(Mandatory = $true)]$ComboBox)
    if ($ComboBox.SelectedItem -and $ComboBox.SelectedItem.PSObject.Properties['Content']) { return [string]$ComboBox.SelectedItem.Content }
    return [string]$ComboBox.Text
}

function Set-ComboContent {
    param([Parameter(Mandatory = $true)]$ComboBox, [string]$Content)
    foreach ($item in @($ComboBox.Items)) {
        if ($item.PSObject.Properties['Content'] -and [string]$item.Content -eq $Content) {
            $ComboBox.SelectedItem = $item
            return
        }
    }
}

function Get-ObjectPropertyValue {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-ValidatedInteger {
    param([string]$Text, [int]$Minimum, [int]$Maximum, [string]$Label)
    $value = 0
    if (-not [int]::TryParse($Text, [ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) {
        throw "$Label deve ser um numero entre $Minimum e $Maximum."
    }
    return $value
}

function Get-ReportFormatFromPath {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.csv' { return 'CSV' } '.json' { return 'JSON' } '.html' { return 'HTML' } default { return 'TXT' }
    }
}

# Estado inicial e modos de seguranca.
(Get-Control 'SimulationCheckBox').IsChecked = [bool]$context.Simulation
(Get-Control 'ReadOnlyCheckBox').IsChecked = [bool]$context.ReadOnly
(Get-Control 'AdminStatusText').Text = if ($context.IsAdministrator) { 'Permissoes: administrador' } else { 'Permissoes: usuario (analise liberada)' }
(Get-Control 'BtnElevate').Visibility = if ($context.IsAdministrator) { 'Collapsed' } else { 'Visible' }

$modeChanged = {
    try {
        Set-OptimizerMode -Simulation ([bool](Get-Control 'SimulationCheckBox').IsChecked) `
            -ReadOnly ([bool](Get-Control 'ReadOnlyCheckBox').IsChecked) | Out-Null
        (Get-Control 'OperationStatusText').Text = if ([bool](Get-Control 'ReadOnlyCheckBox').IsChecked) {
            'Modo somente leitura: alteracoes e restauracoes estao bloqueadas.'
        } elseif ([bool](Get-Control 'SimulationCheckBox').IsChecked) {
            'Modo simulacao: nenhuma alteracao sera aplicada.'
        } else { 'Modo normal: backups serao criados antes das alteracoes.' }
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Modo' -Icon Error }
}
(Get-Control 'SimulationCheckBox').Add_Checked($modeChanged)
(Get-Control 'SimulationCheckBox').Add_Unchecked($modeChanged)
(Get-Control 'ReadOnlyCheckBox').Add_Checked($modeChanged)
(Get-Control 'ReadOnlyCheckBox').Add_Unchecked($modeChanged)

(Get-Control 'BtnElevate').Add_Click({ [void](Request-AdministrativeRelaunch) })
(Get-Control 'BtnCancelOperation').Add_Click({
    if (-not $script:ActiveTask) { return }
    if ($script:ActiveTask.ActionId -in @('SfcScan', 'DismCheck', 'DismScan', 'DismRestore', 'ComponentCleanup', 'OptimizeVolume', 'DiskScan')) {
        Show-AppMessage -Message 'Esta ferramenta do Windows nao deve ser interrompida a forca. Aguarde a conclusao.' -Title 'Cancelamento indisponivel' -Icon Warning
        return
    }
    try {
        $script:CancelRequested = $true
        [void]$script:ActiveTask.PowerShell.BeginStop($null, $null)
        (Get-Control 'OperationStatusText').Text = 'Cancelamento solicitado; aguardando ponto seguro...'
    }
    catch { }
})
(Get-Control 'BtnClearLogView').Add_Click({ (Get-Control 'LogListBox').Items.Clear() })

# Inicio, backup, relatorios e restauracao.
Add-AsyncButtonHandler 'BtnAnalyze' 'Analyze' $null 'Analisando computador...'
Add-AsyncButtonHandler 'BtnCreateBackup' 'CreateBackup' $null 'Criando backup e checkpoint...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnQuickOptimize' 'QuickOptimize' { @{ StartupIds = Get-SelectedStartupIds } } `
    'Aplicando perfil seguro...' -RequiresAdministrator `
    -ConfirmationMessage 'A Otimizacao rapida usa apenas o perfil seguro. Um backup sera criado antes. Continuar?'
Add-AsyncButtonHandler 'BtnRestoreLast' 'UndoLast' { @{ Force = $false } } 'Restaurando ultima otimizacao...' `
    -RequiresAdministrator -ConfirmationMessage 'Restaurar a ultima otimizacao? Conflitos posteriores nao serao sobrescritos.'
Add-AsyncButtonHandler 'BtnRestoreAll' 'RestoreAll' { @{ Force = $false } } 'Restaurando todos os backups...' `
    -RequiresAdministrator -ConfirmationMessage 'Restaurar todas as configuracoes reversiveis, da mais recente para a mais antiga? Limpezas e reparos nao podem ser desfeitos.'

(Get-Control 'BtnOpenBackup').Add_Click({
    try { Open-OptimizerBackupFolder | Out-Null } catch { Show-AppMessage -Message $_.Exception.Message -Title 'Backups' -Icon Error }
})
(Get-Control 'BtnExportReport').Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Exportar relatorio'; $dialog.Filter = 'HTML (*.html)|*.html|JSON (*.json)|*.json|CSV (*.csv)|*.csv|Texto (*.txt)|*.txt'
    $dialog.FileName = "WindowsFPSOptimizer-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
    if ($dialog.ShowDialog($window)) {
        Start-UiAction -ActionId 'ExportReport' -Parameters @{ Path = $dialog.FileName; Format = Get-ReportFormatFromPath $dialog.FileName } -Status 'Exportando relatorio...'
    }
})
(Get-Control 'BtnImportBackup').Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Importar manifesto de backup'; $dialog.Filter = 'Manifesto JSON (manifest.json)|manifest.json|JSON (*.json)|*.json'
    if ($dialog.ShowDialog($window)) {
        Start-UiAction -ActionId 'ImportBackup' -Parameters @{ Path = $dialog.FileName } -Status 'Validando e importando backup...' -RequiresAdministrator
    }
})
(Get-Control 'BtnRefreshBackups').Add_Click({ Start-UiAction -ActionId 'Backups' -Status 'Atualizando backups...' })
(Get-Control 'BackupsGrid').Add_SelectionChanged({ Set-ItemsSource (Get-Control 'BackupEntriesGrid') @() })
(Get-Control 'BtnRefreshBackupEntries').Add_Click({
    try {
        $row = (Get-Control 'BackupsGrid').SelectedItem
        if (-not $row -or [string]::IsNullOrWhiteSpace([string]$row.ManifestPath)) { throw 'Selecione uma transacao de backup valida.' }
        Start-UiAction -ActionId 'BackupEntries' -Parameters @{ ManifestPath = [string]$row.ManifestPath } `
            -Status 'Carregando itens da transacao...'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Itens do backup' -Icon Warning }
})
(Get-Control 'BtnRestoreSelectedBackup').Add_Click({
    try {
        $row = (Get-Control 'BackupsGrid').SelectedItem
        if (-not $row -or [string]::IsNullOrWhiteSpace([string]$row.ManifestPath)) { throw 'Selecione um backup valido.' }
        if ([int]$row.EntryCount -eq 0) {
            throw 'Esta transacao contem somente o baseline JSON e, quando disponivel, um ponto do Windows. Nao ha entradas automaticas para restaurar; abra a pasta para consultar o baseline ou use a Restauracao do Sistema.'
        }
        if (-not (Confirm-AppAction -Message 'Restaurar a transacao inteira? Alteracoes posteriores conflitantes serao preservadas.')) { return }
        Start-UiAction -ActionId 'RestoreManifest' -Parameters @{ ManifestPath = [string]$row.ManifestPath; Force = $false } `
            -Status 'Restaurando a transacao selecionada...' -RequiresAdministrator
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Restaurar backup' -Icon Warning }
})
(Get-Control 'BtnRestoreSelectedEntry').Add_Click({
    try {
        $row = (Get-Control 'BackupEntriesGrid').SelectedItem
        if (-not $row -or [string]::IsNullOrWhiteSpace([string]$row.EntryId) -or
            [string]::IsNullOrWhiteSpace([string]$row.ManifestPath)) {
            throw 'Carregue uma transacao e selecione o item que deseja restaurar.'
        }
        if (-not [bool]$row.Reversible) {
            throw 'Este item foi registrado apenas para auditoria e nao possui restauracao direta.'
        }
        $label = if ([string]::IsNullOrWhiteSpace([string]$row.Description)) { [string]$row.Resource } else { [string]$row.Description }
        if (-not (Confirm-AppAction -Message "Restaurar somente '$label'? Alteracoes posteriores conflitantes serao preservadas.")) { return }
        Start-UiAction -ActionId 'RestoreBackupItem' `
            -Parameters @{ ManifestPath = [string]$row.ManifestPath; EntryId = [string]$row.EntryId; Force = $false } `
            -Status 'Restaurando somente o item selecionado...' -RequiresAdministrator
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Restaurar item' -Icon Warning }
})

(Get-Control 'BtnRecommendationDetails').Add_Click({
    try {
        $row = (Get-Control 'RecommendationsGrid').SelectedItem
        if (-not $row) { throw 'Selecione uma recomendacao.' }
        Show-AppMessage -Title ([string]$row.Name) -Message ("Situacao atual: {0}`n`nAlteracao proposta: {1}`n`nBeneficio esperado: {2}`n`nRisco: {3}`nReinicio: {4}" -f `
            $row.Current, $row.Proposed, $row.ExpectedBenefit, $row.Risk, $(if ($row.RequiresRestart) { 'Sim' } else { 'Nao' }))
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Recomendacao' -Icon Warning }
})
(Get-Control 'BtnApplyRecommendation').Add_Click({
    try {
        $row = (Get-Control 'RecommendationsGrid').SelectedItem
        if (-not $row) { throw 'Selecione uma recomendacao.' }
        switch ([string]$row.OperationId) {
            'games.game-mode' { Start-UiAction -ActionId 'EnableGameMode' -Status 'Aplicando Game Mode...'; break }
            'games.capture' { Start-UiAction -ActionId 'DisableGameDvr' -Status 'Revisando capturas...' -RequiresAdministrator; break }
            'power.high-performance' { Start-UiAction -ActionId 'HighPerformance' -Status 'Ativando Alto Desempenho...' -RequiresAdministrator; break }
            'startup.review' { Show-AppPage -NavigationName 'NavStartup'; break }
            'services.review' { Show-AppPage -NavigationName 'NavProcesses'; break }
            'process.review' { Show-AppPage -NavigationName 'NavProcesses'; break }
            'memory.review' { Show-AppPage -NavigationName 'NavMemory'; break }
            'storage.cleanup' { Show-AppPage -NavigationName 'NavStorage'; break }
            default { throw 'Esta recomendacao e informativa ou deve ser aplicada na categoria correspondente.' }
        }
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Aplicar recomendacao' -Icon Warning }
})
(Get-Control 'BtnUndoRecommendation').Add_Click({
    if (Confirm-AppAction -Message 'Desfazer a ultima transacao de otimizacao reversivel?') {
        Start-UiAction -ActionId 'UndoLast' -Parameters @{ Force = $false } -Status 'Desfazendo ultima aplicacao...' -RequiresAdministrator
    }
})

# Jogos e paginas oficiais do Windows.
Add-AsyncButtonHandler 'BtnEnableGameMode' 'EnableGameMode' $null 'Aplicando Game Mode quando suportado...'
Add-AsyncButtonHandler 'BtnDisableCaptures' 'DisableGameDvr' $null 'Aplicando politica de captura quando suportada...' -RequiresAdministrator
Add-OpenSettingsHandler 'BtnOpenCaptures' 'Captures'
Add-OpenSettingsHandler 'BtnOpenGameBar' 'GameBar'
Add-OpenSettingsHandler 'BtnOpenHags' 'Hags'
Add-OpenSettingsHandler 'BtnOpenGraphicsSettings' 'Graphics'
Add-OpenSettingsHandler 'BtnOpenFocus' 'DoNotDisturbGame'
Add-OpenSettingsHandler 'BtnOpenNotifications' 'Notifications'
Add-OpenSettingsHandler 'BtnGraphicsHags' 'Hags'
Add-OpenSettingsHandler 'BtnGraphicsPreferences' 'Graphics'

(Get-Control 'BtnSelectGameExecutable').Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Selecionar executavel do jogo'; $dialog.Filter = 'Executavel (*.exe)|*.exe'; $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($window)) { (Get-Control 'GameExecutableTextBox').Text = $dialog.FileName }
})
Add-AsyncButtonHandler 'BtnStartGameSession' 'StartGameSession' {
    $path = [string](Get-Control 'GameExecutableTextBox').Text
    if (-not (Test-SafeExecutablePath -Path $path)) { throw 'Selecione um executavel .exe local valido.' }
    (Get-Control 'GameSessionStatusText').Text = 'Preparando recursos e iniciando o jogo...'
    @{
        ExecutablePath = $path; Priority = Get-ComboContent (Get-Control 'GameSessionPriorityCombo')
        Services = if ([bool](Get-Control 'GameSessionServicesCheck').IsChecked) { Get-SelectedServiceNames } else { @() }
        PowerPlan = if ([bool](Get-Control 'GameSessionPowerCheck').IsChecked) { 'HighPerformance' } else { 'None' }
        PreventSleep = [bool](Get-Control 'GameSessionPreventSleepCheck').IsChecked
        ReduceVisualEffects = [bool](Get-Control 'GameSessionVisualCheck').IsChecked
        CloseProcesses = [bool](Get-Control 'GameSessionCloseProcessesCheck').IsChecked
        OpenDoNotDisturbSettings = [bool](Get-Control 'GameSessionDoNotDisturbCheck').IsChecked
    }
} 'Executando perfil e monitorando o jogo...' -RequiresAdministrator `
    -ConfirmationMessage 'A sessao pode fechar processos selecionados e parar servicos opcionais. O estado sera restaurado ao fechar o jogo. Continuar?'
Add-AsyncButtonHandler 'BtnStopGameSession' 'StopGameSession' {
    (Get-Control 'GameSessionStatusText').Text = 'Encerramento solicitado; restaurando recursos...'
    @{ Force = $false }
} 'Restaurando sessao de jogo...' `
    -RequiresAdministrator -ConfirmationMessage 'Encerrar a sessao e restaurar recursos agora?'

# Energia e CPU.
Add-AsyncButtonHandler 'BtnHighPerformance' 'HighPerformance' $null 'Ativando Alto Desempenho...' -RequiresAdministrator `
    -ConfirmationMessage 'O plano aumenta consumo e temperatura. Ativar?'
Add-AsyncButtonHandler 'BtnUltimatePerformance' 'UltimatePerformance' $null 'Ativando Desempenho Maximo...' -RequiresAdministrator `
    -ConfirmationMessage 'Alteracao agressiva: maior consumo, temperatura e ruido, com beneficio dependente do hardware. Continuar?'
Add-AsyncButtonHandler 'BtnCreateGamingPlan' 'CreateGamingPlan' $null 'Criando plano de jogos...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnRestorePowerPlan' 'RestorePower' { @{ Force = $false } } 'Restaurando energia...' -RequiresAdministrator
(Get-Control 'BtnOpenPowerOptions').Add_Click({ try { Open-PowerOptions | Out-Null } catch { Show-AppMessage $_.Exception.Message } })
Add-AsyncButtonHandler 'BtnApplyProcessorPower' 'ProcessorPower' {
    $minAc = ConvertTo-ValidatedInteger (Get-Control 'CpuMinAcTextBox').Text 0 100 'Minimo AC'
    $maxAc = ConvertTo-ValidatedInteger (Get-Control 'CpuMaxAcTextBox').Text 1 100 'Maximo AC'
    $minDc = ConvertTo-ValidatedInteger (Get-Control 'CpuMinDcTextBox').Text 0 100 'Minimo bateria'
    $maxDc = ConvertTo-ValidatedInteger (Get-Control 'CpuMaxDcTextBox').Text 1 100 'Maximo bateria'
    if ($minAc -gt $maxAc -or $minDc -gt $maxDc) { throw 'O estado minimo nao pode exceder o maximo.' }
    $cooling = Get-ComboContent (Get-Control 'CoolingPolicyCombo')
    @{ MinimumAC = $minAc; MaximumAC = $maxAc; MinimumDC = $minDc; MaximumDC = $maxDc; CoolingAC = if ($cooling -eq 'Ativa') { 'Active' } else { 'Passive' }; CoolingDC = 'Passive'; ApplyCooling = [bool](Get-Control 'CoolingPolicyCombo').IsEnabled }
} 'Aplicando limites de CPU e resfriamento...' -RequiresAdministrator `
    -ConfirmationMessage 'Estados minimos altos podem elevar temperatura e reduzir boost sustentado. Aplicar os valores informados?'
Add-AsyncButtonHandler 'BtnApplySleepSettings' 'SleepSettings' {
    @{ DisplayAC = ConvertTo-ValidatedInteger (Get-Control 'DisplayTimeoutAcTextBox').Text 0 1440 'Tela AC'; DisplayDC = 10
       SleepAC = ConvertTo-ValidatedInteger (Get-Control 'SleepTimeoutAcTextBox').Text 0 1440 'Suspensao AC'; SleepDC = 30 }
} 'Aplicando tempos de tela e suspensao...' -RequiresAdministrator
(Get-Control 'BtnOpenDeviceManager').Add_Click({ try { Start-Process 'devmgmt.msc' | Out-Null } catch { Show-AppMessage $_.Exception.Message } })

# GPU, visuais e caches.
Add-AsyncButtonHandler 'BtnRefreshGpu' 'Graphics' $null 'Atualizando GPU e driver...'
Add-AsyncButtonHandler 'BtnEstimateGraphicsCache' 'GraphicsCacheEstimate' {
    $types = New-Object System.Collections.Generic.List[string]
    if ((Get-Control 'CacheDirectXCheck').IsChecked) { $types.Add('DirectX') }
    if ((Get-Control 'CacheNvidiaCheck').IsChecked) { $types.Add('NVIDIA') }
    if ((Get-Control 'CacheAmdCheck').IsChecked) { $types.Add('AMD') }
    @{ Types = $types.ToArray() }
} 'Estimando caches graficos...'
(Get-Control 'BtnClearGraphicsCache').Add_Click({
    try {
        $types = New-Object System.Collections.Generic.List[string]
        if ((Get-Control 'CacheDirectXCheck').IsChecked) { $types.Add('DirectX') }
        if ((Get-Control 'CacheNvidiaCheck').IsChecked) { $types.Add('NVIDIA') }
        if ((Get-Control 'CacheAmdCheck').IsChecked) { $types.Add('AMD') }
        if ($types.Count -eq 0) { throw 'Selecione ao menos um cache.' }
        if (-not (Confirm-AppAction -Message 'Caches sao irreversiveis e serao recompilados; os primeiros jogos podem apresentar mais stutter. Continuar?')) { return }
        $selectedTypes = $types.ToArray()
        $adminLocations = if ($script:GraphicsCacheEstimate) {
            @($script:GraphicsCacheEstimate.Locations | Where-Object {
                $selectedTypes -contains [string]$_.Type -and [bool]$_.Exists -and [bool]$_.RequiresAdministrator
            })
        } else { @() }
        # Se a estimativa ainda nao terminou, NVIDIA fica conservadoramente elevada
        # porque pode incluir o cache compartilhado em ProgramData.
        $knownNvidiaLocations = if ($script:GraphicsCacheEstimate) {
            @($script:GraphicsCacheEstimate.Locations | Where-Object { [string]$_.Type -eq 'NVIDIA' })
        } else { @() }
        $requiresAdmin = $adminLocations.Count -gt 0 -or
            ($selectedTypes -contains 'NVIDIA' -and $knownNvidiaLocations.Count -eq 0)
        Start-UiAction -ActionId 'ClearGraphicsCache' `
            -Parameters @{ Types = $selectedTypes; MinimumAgeHours = 0 } `
            -Status 'Limpando caches graficos...' -RequiresAdministrator:$requiresAdmin
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Caches graficos' -Icon Warning }
})

(Get-Control 'BtnApplyGraphicsEffects').Add_Click({
    try {
        $options = @(
            @{ Control = 'GraphicsTransparencyCheck'; Option = 'Transparency' },
            @{ Control = 'GraphicsAnimationsCheck'; Option = 'WindowAnimations' },
            @{ Control = 'GraphicsShadowsCheck'; Option = 'DropShadows' },
            @{ Control = 'GraphicsThumbnailsCheck'; Option = 'Thumbnails' },
            @{ Control = 'GraphicsFontSmoothingCheck'; Option = 'FontSmoothing' }
        )
        $selected = @($options | Where-Object { [bool](Get-Control $_.Control).IsChecked })
        if ($selected.Count -eq 0) { throw 'Selecione ao menos uma opcao.' }
        if (($selected.Option -contains 'FontSmoothing') -and -not (Confirm-AppAction 'Desativar suavizacao de fontes prejudica legibilidade e quase nunca melhora desempenho. Continuar?')) { return }
        $changes = @($selected | ForEach-Object { @{ Option = [string]$_.Option; Enabled = $false } })
        Start-UiAction -ActionId 'VisualOptions' -Parameters @{ Options = $changes } -Status 'Aplicando efeitos visuais...'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Efeitos visuais' -Icon Warning }
})

# Memoria, processos e paginacao.
Add-AsyncButtonHandler 'BtnRefreshMemory' 'Memory' $null 'Atualizando memoria...'
Add-AsyncButtonHandler 'BtnEndMemoryProcess' 'StopProcess' {
    $row = (Get-Control 'TopMemoryGrid').SelectedItem; if (-not $row) { throw 'Selecione um processo.' }
    @{ Id = [int]$row.Id; StartTime = [string]$row.StartTime; AllowRestart = $false }
} 'Encerrando processo selecionado...' -ConfirmationMessage 'Encerrar o processo selecionado pode causar perda de dados nao salvos. Continuar?'
Add-AsyncButtonHandler 'BtnAutomaticPageFile' 'AutomaticPageFile' $null 'Ativando paginacao automatica...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnCustomPageFile' 'CustomPageFile' {
    $drive = [IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\')
    @{ Path = "$drive\pagefile.sys"; InitialSizeMB = ConvertTo-ValidatedInteger (Get-Control 'PageFileInitialTextBox').Text 1024 1048576 'Tamanho inicial'; MaximumSizeMB = ConvertTo-ValidatedInteger (Get-Control 'PageFileMaximumTextBox').Text 1024 1048576 'Tamanho maximo' }
} 'Configurando memoria virtual...' -RequiresAdministrator `
    -ConfirmationMessage 'Alteracao agressiva de memoria virtual; configuracao inadequada pode causar falhas e exige reinicializacao. Continuar?'

Add-AsyncButtonHandler 'BtnRefreshProcesses' 'Processes' { @{ Search = [string](Get-Control 'ProcessSearchTextBox').Text } } 'Atualizando processos...'
Add-AsyncButtonHandler 'BtnEndSelectedProcess' 'StopProcess' {
    $row = (Get-Control 'AllProcessesGrid').SelectedItem; if (-not $row) { throw 'Selecione um processo.' }; if ($row.IsProtected) { throw 'Processo protegido.' }
    @{ Id = [int]$row.Id; StartTime = [string]$row.StartTime; AllowRestart = $false }
} 'Encerrando processo...' -ConfirmationMessage 'O processo pode conter trabalho nao salvo. Encerrar?'
Add-AsyncButtonHandler 'BtnSetProcessPriority' 'ProcessPriority' {
    $row = (Get-Control 'AllProcessesGrid').SelectedItem; if (-not $row) { throw 'Selecione um processo.' }
    @{ Id = [int]$row.Id; StartTime = [string]$row.StartTime; Priority = Get-ComboContent (Get-Control 'ProcessPriorityCombo') }
} 'Aplicando prioridade temporaria...'

(Get-Control 'BtnAllowSelectedProcess').Add_Click({
    try {
        $row = (Get-Control 'AllProcessesGrid').SelectedItem; if (-not $row) { throw 'Selecione um processo.' }
        $state = Get-ProcessListState
        Start-UiAction -ActionId 'ProcessLists' -Parameters @{ Allowed = @($state.Allowed) + [string]$row.Name; CloseBeforeGame = @($state.CloseBeforeGame | Where-Object { $_ -ne $row.Name }) } -Status 'Salvando allowlist...'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Processos' -Icon Warning }
})
(Get-Control 'BtnCloseBeforeGame').Add_Click({
    try {
        $row = (Get-Control 'AllProcessesGrid').SelectedItem; if (-not $row) { throw 'Selecione um processo.' }; if ($row.IsProtected) { throw 'Processo protegido.' }
        $state = Get-ProcessListState
        Start-UiAction -ActionId 'ProcessLists' -Parameters @{ Allowed = @($state.Allowed | Where-Object { $_ -ne $row.Name }); CloseBeforeGame = @($state.CloseBeforeGame) + [string]$row.Name } -Status 'Salvando lista de sessao...'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Processos' -Icon Warning }
})

# Armazenamento e integridade.
function Get-SelectedCleanupCategories {
    $categories = New-Object System.Collections.Generic.List[string]
    if ((Get-Control 'CleanupUserTempCheck').IsChecked) { $categories.Add('UserTemp') }
    if ((Get-Control 'CleanupWindowsTempCheck').IsChecked) { $categories.Add('WindowsTemp') }
    if ((Get-Control 'CleanupDirectXCheck').IsChecked) { $categories.Add('DirectXCache') }
    if ((Get-Control 'CleanupThumbnailsCheck').IsChecked) { $categories.Add('Thumbnails') }
    if ((Get-Control 'CleanupWerCheck').IsChecked) {
        $categories.Add('UserWER'); $categories.Add('MachineWERArchive'); $categories.Add('MachineWERQueue')
    }
    if ($categories.Count -eq 0) { throw 'Selecione ao menos uma categoria.' }
    return $categories.ToArray()
}
Add-AsyncButtonHandler 'BtnRefreshStorage' 'Storage' $null 'Atualizando unidades...'
Add-AsyncButtonHandler 'BtnEstimateCleanup' 'CleanupEstimate' { @{ Categories = Get-SelectedCleanupCategories } } 'Estimando espaco liberavel...'
Add-AsyncButtonHandler 'BtnRunCleanup' 'Cleanup' {
    @{ Categories = Get-SelectedCleanupCategories }
} 'Removendo apenas arquivos validados...' -RequiresAdministrator `
    -ConfirmationMessage 'Arquivos temporarios, caches e relatorios removidos nao podem ser restaurados. Downloads e arquivos pessoais ficam fora. Continuar?'
Add-AsyncButtonHandler 'BtnComponentCleanup' 'ComponentCleanup' $null 'Executando DISM StartComponentCleanup...' `
    -RequiresAdministrator -ConfirmationMessage 'Esta manutencao remove componentes substituidos e nao pode ser desfeita. /ResetBase nao sera usado. Continuar?'
Add-AsyncButtonHandler 'BtnEmptyRecycleBin' 'RecycleBin' {
    @{ DriveLetter = [IO.Path]::GetPathRoot($env:SystemRoot).Substring(0, 1) }
} 'Esvaziando Lixeira...' -ConfirmationMessage 'Esvaziar a Lixeira da unidade do Windows e irreversivel. Continuar?'
Add-AsyncButtonHandler 'BtnOptimizeSelectedVolume' 'OptimizeVolume' {
    $row = (Get-Control 'StorageGrid').SelectedItem; if (-not $row) { throw 'Selecione uma unidade.' }
    if ($row.Type -eq 'Desconhecido') { throw 'Tipo de midia desconhecido; operacao bloqueada.' }
    @{ DriveLetter = [string]$row.Drive.Substring(0, 1) }
} 'Otimizando a unidade com o metodo apropriado...' -RequiresAdministrator `
    -ConfirmationMessage 'SSD/NVMe recebera apenas ReTrim; somente HDD confirmado sera desfragmentado. Continuar?'
Add-AsyncButtonHandler 'BtnSfcVerify' 'SfcVerify' $null 'Executando SFC /verifyonly...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnSfcScan' 'SfcScan' $null 'Executando SFC /scannow...' -RequiresAdministrator `
    -ConfirmationMessage 'SFC pode reparar arquivos do sistema e exigir reinicializacao. Reparos nao possuem undo item a item. Continuar?'
Add-AsyncButtonHandler 'BtnDismCheck' 'DismCheck' $null 'Executando DISM CheckHealth...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnDismScan' 'DismScan' $null 'Executando DISM ScanHealth...' -RequiresAdministrator
(Get-Control 'BtnDismRestore').Add_Click({
    if (-not (Confirm-AppAction 'DISM RestoreHealth pode modificar o component store. Para manter o app offline, escolha uma fonte local e /LimitAccess sera usado. Continuar?')) { return }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Selecione uma fonte local valida (por exemplo, pasta sxs montada)'
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        Start-UiAction -ActionId 'DismRestore' -Parameters @{ Source = $dialog.SelectedPath } -Status 'Executando DISM RestoreHealth com fonte local...' -RequiresAdministrator
    }
})
Add-AsyncButtonHandler 'BtnDiskScan' 'DiskScan' {
    @{ DriveLetter = [IO.Path]::GetPathRoot($env:SystemRoot).Substring(0, 1) }
} 'Executando CHKDSK /scan...' -RequiresAdministrator

# Servicos opcionais.
function Test-OptionalServiceRow {
    param($Row)
    if (-not $Row) { return $false }
    $optional = $Row.PSObject.Properties['IsOptional']
    if ($optional) { return [bool]$optional.Value }
    $installed = $Row.PSObject.Properties['Installed']
    return ($installed -and [bool]$installed.Value)
}
Add-AsyncButtonHandler 'BtnRefreshServices' 'Services' {
    @{ Search = [string](Get-Control 'ServiceSearchTextBox').Text; ShowAll = [bool](Get-Control 'ServiceShowAllCheck').IsChecked }
} 'Atualizando inventario de servicos...'
Add-AsyncButtonHandler 'BtnStopServiceSession' 'SetService' {
    $row = (Get-Control 'ServicesGrid').SelectedItem; if (-not (Test-OptionalServiceRow $row)) { throw 'Selecione um servico opcional instalado.' }
    @{ Name = [string]$row.Name; DesiredState = 'StopOnly' }
} 'Parando servico opcional...' -RequiresAdministrator `
    -ConfirmationMessage 'O servico sera parado. O recurso descrito pode deixar de funcionar ate a restauracao/reinicio. Continuar?'
Add-AsyncButtonHandler 'BtnDisableService' 'SetService' {
    $row = (Get-Control 'ServicesGrid').SelectedItem; if (-not (Test-OptionalServiceRow $row)) { throw 'Selecione um servico opcional instalado.' }
    @{ Name = [string]$row.Name; DesiredState = 'Disabled' }
} 'Desativando servico opcional...' -RequiresAdministrator `
    -ConfirmationMessage 'Desativar o servico muda seu tipo de inicializacao. Leia finalidade, beneficio e problemas exibidos antes de continuar.'
Add-AsyncButtonHandler 'BtnRestoreService' 'RestoreService' {
    $row = (Get-Control 'ServicesGrid').SelectedItem; if (-not (Test-OptionalServiceRow $row)) { throw 'Selecione um servico opcional.' }
    @{ Name = [string]$row.Name; Force = $false }
} 'Restaurando servico pelo backup...' -RequiresAdministrator
(Get-Control 'ServicesGrid').Add_SelectionChanged({
    $row = (Get-Control 'ServicesGrid').SelectedItem
    if ($row) {
        $isOptional = Test-OptionalServiceRow $row
        $description = [string](Get-ObjectPropertyValue $row 'Description' 'Descricao nao fornecida pelo Windows.')
        $benefit = [string](Get-ObjectPropertyValue $row 'Benefit' $(if ($isOptional) { 'Consulte a definicao da allowlist.' } else { 'Somente inventario; nenhuma alteracao permitida.' }))
        $problems = [string](Get-ObjectPropertyValue $row 'Problems' $(if ($isOptional) { 'O recurso associado pode parar.' } else { 'Servico fora da allowlist; alteracao bloqueada.' }))
        $restart = [string](Get-ObjectPropertyValue $row 'Restart' 'Desconhecido')
        $autoRestore = [bool](Get-ObjectPropertyValue $row 'AutoRestoreInGameSession' $false)
        (Get-Control 'ServiceDetailsText').Text = "Finalidade: $description`nBeneficio possivel: $benefit`nProblemas: $problems`nReinicio: $restart`nOpcional permitido: $isOptional`nRestauracao automatica em sessao: $autoRestore"
        foreach ($controlName in @('BtnStopServiceSession', 'BtnDisableService', 'BtnRestoreService')) {
            (Get-Control $controlName).IsEnabled = $isOptional
        }
    }
})
Add-AsyncButtonHandler 'BtnSaveServiceProfile' 'SaveServiceProfile' {
    $names = Get-SelectedServiceNames
    if ($names.Count -eq 0) { throw 'Selecione um ou mais servicos opcionais.' }
    $name = [string](Get-Control 'ServiceProfileNameTextBox').Text
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Informe um nome para o perfil.' }
    @{ Name = $name.Trim(); Services = $names }
} 'Salvando perfil de servicos...'
Add-AsyncButtonHandler 'BtnRefreshServiceProfiles' 'ServiceProfiles' $null 'Atualizando perfis de servicos...'
Add-AsyncButtonHandler 'BtnApplyServiceProfile' 'ApplyServiceProfile' {
    $profile = (Get-Control 'ServiceProfilesCombo').SelectedItem
    $modeItem = (Get-Control 'ServiceProfileModeCombo').SelectedItem
    if (-not $profile) { throw 'Selecione um perfil salvo.' }
    if (-not $modeItem) { throw 'Selecione o modo de aplicacao.' }
    @{ Name = [string]$profile.Name; Mode = [string]$modeItem.Tag }
} 'Aplicando perfil de servicos...' -RequiresAdministrator `
    -ConfirmationMessage 'Somente servicos opcionais da allowlist serao alterados. O modo Desativar permanece ate a restauracao pelo backup; o modo Parar muda apenas o estado atual. Continuar?'

# Inicializacao.
Add-AsyncButtonHandler 'BtnRefreshStartup' 'Startup' $null 'Atualizando inicializacao...'
Add-AsyncButtonHandler 'BtnDisableStartup' 'DisableStartupMany' {
    $ids = Get-SelectedStartupIds; if ($ids.Count -eq 0) { throw 'Selecione itens ativos e nao protegidos.' }
    @{ Ids = $ids }
} 'Desativando itens de inicializacao...' -RequiresAdministrator `
    -ConfirmationMessage 'Os programas nao serao apagados; valores/atalhos serao movidos para backup. Desativar os selecionados?'
Add-AsyncButtonHandler 'BtnRestoreStartup' 'RestoreStartupMany' {
    $ids = @((Get-SelectedRows (Get-Control 'StartupGrid')) | Where-Object { -not $_.IsEnabled } | ForEach-Object { [string]$_.Id })
    if ($ids.Count -eq 0) { throw 'Selecione itens desativados.' }
    @{ Ids = $ids; Force = $false }
} 'Restaurando inicializacao...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnRestoreAllStartup' 'RestoreAllStartup' { @{ Force = $false } } 'Restaurando todos os itens de inicializacao...' -RequiresAdministrator

# Perfis e efeitos visuais.
Add-AsyncButtonHandler 'BtnVisualBalanced' 'VisualProfile' { @{ Profile = 'Balanced' } } 'Aplicando perfil visual equilibrado...'
Add-AsyncButtonHandler 'BtnVisualMaximum' 'VisualProfile' { @{ Profile = 'MaximumPerformance' } } 'Aplicando perfil visual maximo...' `
    -ConfirmationMessage 'O perfil maximo remove mais efeitos visuais e pode prejudicar a experiencia do desktop. Continuar?'
Add-AsyncButtonHandler 'BtnRestoreVisual' 'RestoreVisual' { @{ Force = $false } } 'Restaurando efeitos visuais...'
Add-AsyncButtonHandler 'BtnPreviewVisual' 'VisualPreview' {
    @{ Profile = Get-ComboContent (Get-Control 'VisualPreviewProfileCombo') }
} 'Calculando previa sem alterar o Windows...'
(Get-Control 'BtnApplyVisualOptions').Add_Click({
    try {
        $changes = New-Object System.Collections.Generic.List[object]
        $map = @(
            @{ Control = 'VisualWindowAnimationsCheck'; Option = 'WindowAnimations' },
            @{ Control = 'VisualTaskbarAnimationsCheck'; Option = 'TaskbarAnimations' },
            @{ Control = 'VisualContentAnimationsCheck'; Option = 'ContentAnimations' },
            @{ Control = 'VisualShadowsCheck'; Option = 'DropShadows' },
            @{ Control = 'VisualThumbnailsCheck'; Option = 'Thumbnails' },
            @{ Control = 'VisualFontSmoothingCheck'; Option = 'FontSmoothing' }
        )
        foreach ($entry in $map) {
            if ([bool](Get-Control $entry.Control).IsChecked) {
                $changes.Add(@{ Option = [string]$entry.Option; Enabled = $false })
            }
        }
        if ([bool](Get-Control 'VisualMenuDelayCheck').IsChecked) {
            $delay = ConvertTo-ValidatedInteger (Get-Control 'VisualMenuDelayTextBox').Text 0 4000 'Atraso do menu'
            $changes.Add(@{ Option = 'MenuDelay'; Enabled = $true; MenuDelay = $delay })
        }
        if ($changes.Count -eq 0) { throw 'Marque ao menos uma opcao visual.' }
        if ([bool](Get-Control 'VisualFontSmoothingCheck').IsChecked -and
            -not (Confirm-AppAction 'Desativar suavizacao de fontes prejudica a legibilidade e quase nunca melhora o desempenho. Continuar?')) { return }
        Start-UiAction -ActionId 'VisualOptions' -Parameters @{ Options = $changes.ToArray() } `
            -Status 'Aplicando opcoes visuais individuais...'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Efeitos visuais' -Icon Warning }
})
(Get-Control 'BtnReviewVisualTips').Add_Click({
    Show-AppPage -NavigationName 'NavPrivacy'
    (Get-Control 'OperationStatusText').Text = 'Revise as opcoes de sugestoes e experiencias personalizadas.'
})

function Get-ProfileParameters {
    param([string]$Name, [bool]$Confirmed)
    $gameExecutable = [string](Get-Control 'GameExecutableTextBox').Text
    if ($Name -eq 'MaximumFPS' -and [string]::IsNullOrWhiteSpace($gameExecutable)) {
        throw 'Selecione o executavel do jogo na aba Otimizacoes de jogos antes de iniciar o perfil maximo FPS.'
    }
    $includeCleanup = [bool](Get-Control 'ProfileIncludeCleanupCheck').IsChecked
    $confirmedIrreversible = $false
    if ($includeCleanup) {
        $confirmedIrreversible = Confirm-AppAction -Title 'Confirmar limpeza irreversivel' `
            -Message 'A limpeza removera temporarios e cache de shaders, que nao podem ser restaurados pelo backup. Confirmar separadamente?'
        if (-not $confirmedIrreversible) { throw 'Aplicacao do perfil cancelada: a limpeza irreversivel nao foi confirmada.' }
    }
    return @{
        Name = $Name; Services = Get-SelectedServiceNames; Tasks = Get-SelectedTaskIds
        StartupIds = Get-SelectedStartupIds; IncludeCleanup = $includeCleanup
        Confirmed = $Confirmed; ConfirmedIrreversible = $confirmedIrreversible
        GameExecutable = $gameExecutable
    }
}
Add-AsyncButtonHandler 'BtnProfileSafe' 'ApplyProfile' { Get-ProfileParameters 'Safe' $true } 'Aplicando perfil seguro...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnProfileBalanced' 'ApplyProfile' { Get-ProfileParameters 'Balanced' $true } 'Aplicando perfil equilibrado...' `
    -RequiresAdministrator -ConfirmationMessage 'O perfil equilibrado aplicara apenas servicos, tarefas e inicializacao atualmente selecionados. Continuar?'
Add-AsyncButtonHandler 'BtnProfileMaximum' 'ApplyProfile' { Get-ProfileParameters 'MaximumFPS' $true } 'Aplicando perfil maximo FPS...' `
    -RequiresAdministrator -ConfirmationMessage 'Perfil agressivo e temporario: iniciara o jogo selecionado, aplicara energia/visuais/servicos/processos somente durante a sessao e restaurara ao fechar. Defender, Update, rede e servicos essenciais permanecem intactos. Continuar?'

# Aplicativos.
Add-AsyncButtonHandler 'BtnRefreshApps' 'Applications' { @{ Search = [string](Get-Control 'AppsSearchTextBox').Text } } 'Atualizando aplicativos...'
Add-AsyncButtonHandler 'BtnRemoveOptionalApp' 'RemoveAppx' {
    $row = (Get-Control 'AppsGrid').SelectedItem; if (-not $row -or $row.Type -ne 'Appx') { throw 'Selecione um aplicativo Appx.' }; if (-not $row.CanRemove) { throw 'O pacote nao esta classificado como opcional/removivel.' }
    @{ PackageFullName = [string]$row.PackageFullName }
} 'Removendo Appx opcional...' `
    -ConfirmationMessage 'A reinstalacao offline nao e garantida se o payload local for removido. Store, Security, Xbox, Gaming Services e frameworks estao bloqueados. Continuar?'
(Get-Control 'BtnRestoreOptionalApp').Add_Click({
    Show-AppPage -NavigationName 'NavHome'
    try { [void](Get-Control 'BackupsGrid').Focus() } catch { }
    (Get-Control 'OperationStatusText').Text = 'Selecione a transacao de remocao do Appx em Backups persistentes e clique em Restaurar item selecionado.'
})
(Get-Control 'BtnOpenInstalledApps').Add_Click({ try { Open-InstalledAppsSettings | Out-Null } catch { Show-AppMessage $_.Exception.Message } })
(Get-Control 'BtnOpenBackgroundApps').Add_Click({ try { Open-BackgroundAppSettings | Out-Null } catch { Show-AppMessage $_.Exception.Message } })

# Privacidade e telemetria opcional.
Add-AsyncButtonHandler 'BtnApplyPrivacy' 'ApplyPrivacy' {
    @{
        Tailored = [bool](Get-Control 'PrivacyTailoredCheck').IsChecked -and [bool](Get-Control 'PrivacyTailoredCheck').IsEnabled
        ThirdParty = [bool](Get-Control 'PrivacyThirdPartyCheck').IsChecked -and [bool](Get-Control 'PrivacyThirdPartyCheck').IsEnabled
        Advertising = [bool](Get-Control 'PrivacyAdvertisingCheck').IsChecked -and [bool](Get-Control 'PrivacyAdvertisingCheck').IsEnabled
        Activity = [bool](Get-Control 'PrivacyActivityCheck').IsChecked -and [bool](Get-Control 'PrivacyActivityCheck').IsEnabled
        Diagnostics = [bool](Get-Control 'PrivacyDiagnosticsCheck').IsChecked -and [bool](Get-Control 'PrivacyDiagnosticsCheck').IsEnabled
        WindowsTips = [bool](Get-Control 'PrivacyWindowsTipsCheck').IsChecked -and [bool](Get-Control 'PrivacyWindowsTipsCheck').IsEnabled
        ConsumerFeatures = [bool](Get-Control 'PrivacyConsumerFeaturesCheck').IsChecked -and [bool](Get-Control 'PrivacyConsumerFeaturesCheck').IsEnabled
        StartRecommendations = [bool](Get-Control 'PrivacyStartRecommendationsCheck').IsChecked -and [bool](Get-Control 'PrivacyStartRecommendationsCheck').IsEnabled
    }
} 'Aplicando preferencias de privacidade...' -RequiresAdministrator `
    -ConfirmationMessage 'Estas politicas podem deixar algumas opcoes como "gerenciadas". Nao ha promessa de ganho de FPS. Continuar?'
(Get-Control 'BtnOpenPrivacy').Add_Click({ try { Open-PrivacySettings | Out-Null } catch { Start-Process 'ms-settings:privacy-general' | Out-Null } })

# Tarefas agendadas.
Add-AsyncButtonHandler 'BtnRefreshTasks' 'Tasks' { @{ Search = [string](Get-Control 'TaskSearchTextBox').Text } } 'Atualizando tarefas...'
Add-AsyncButtonHandler 'BtnDisableTask' 'SetTask' {
    $row = (Get-Control 'TasksGrid').SelectedItem; if (-not $row -or -not $row.IsOptional) { throw 'Selecione uma tarefa opcional da allowlist.' }
    @{ TaskPath = [string]$row.TaskPath; TaskName = [string]$row.TaskName; Enabled = $false }
} 'Desativando tarefa opcional...' -RequiresAdministrator `
    -ConfirmationMessage 'A tarefa selecionada sera desativada, nao excluida. Leia o impacto exibido. Continuar?'
Add-AsyncButtonHandler 'BtnRestoreTask' 'RestoreTask' {
    $row = (Get-Control 'TasksGrid').SelectedItem; if (-not $row -or -not $row.IsOptional) { throw 'Selecione uma tarefa opcional da allowlist.' }
    @{ TaskPath = [string]$row.TaskPath; TaskName = [string]$row.TaskName; Force = $false }
} 'Restaurando tarefa pelo backup...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnRestoreAllTasks' 'RestoreAllTasks' { @{ Force = $false } } `
    'Restaurando todas as tarefas opcionais com backup...' -RequiresAdministrator `
    -ConfirmationMessage 'Restaurar todas as tarefas opcionais que possuem backup valido?'
(Get-Control 'TasksGrid').Add_SelectionChanged({
    $row = (Get-Control 'TasksGrid').SelectedItem
    if ($row) {
        (Get-Control 'TaskDetailsText').Text = "Classificacao: $($row.Classification)`nDescricao: $($row.Description)`nBeneficio possivel: $($row.Benefit)`nProblemas: $($row.Problems)`nOpcional: $($row.IsOptional)`nProtegida: $($row.IsProtected)"
        (Get-Control 'BtnDisableTask').IsEnabled = [bool]$row.IsOptional -and -not [bool]$row.IsProtected
        (Get-Control 'BtnRestoreTask').IsEnabled = [bool]$row.IsOptional
    }
})

# Seguranca e integridade.
Add-AsyncButtonHandler 'BtnRefreshSecurity' 'Security' $null 'Atualizando seguranca...'
Add-AsyncButtonHandler 'BtnSecurityRestorePoint' 'CreateRestorePoint' $null 'Criando ponto de restauracao...' -RequiresAdministrator
Add-AsyncButtonHandler 'BtnSecuritySfc' 'SfcScan' $null 'Executando SFC /scannow...' -RequiresAdministrator `
    -ConfirmationMessage 'SFC podera reparar arquivos do sistema. Continuar?'
Add-AsyncButtonHandler 'BtnSecurityDism' 'DismScan' $null 'Executando DISM ScanHealth...' -RequiresAdministrator
(Get-Control 'BtnExportRegistry').Add_Click({
    try {
        Open-OptimizerBackupFolder | Out-Null
        Show-AppMessage -Message 'Cada backup exporta as chaves de Registro tocadas na subpasta registry. A pasta foi aberta.'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Registro' -Icon Error }
})
(Get-Control 'BtnSecurityReport').Add_Click({ (Get-Control 'BtnExportReport').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) })

# Biblioteca de jogos.
(Get-Control 'BtnAddGame').Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Adicionar jogo ou programa'; $dialog.Filter = 'Executavel (*.exe)|*.exe'; $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($window)) {
        Start-UiAction -ActionId 'AddGame' -Parameters @{ ExecutablePath = $dialog.FileName; Name = [IO.Path]::GetFileNameWithoutExtension($dialog.FileName) } -Status 'Adicionando perfil do jogo...'
    }
})
Add-AsyncButtonHandler 'BtnDetectGames' 'DetectGames' $null 'Procurando executaveis em bibliotecas comuns...'
Add-AsyncButtonHandler 'BtnAddDetectedGame' 'AddGame' {
    $row = (Get-Control 'GamesGrid').SelectedItem
    $path = [string](Get-ObjectPropertyValue $row 'ExecutablePath' '')
    if (-not $row -or -not (Test-SafeExecutablePath -Path $path)) { throw 'Selecione um executavel detectado valido.' }
    if (Get-ObjectPropertyValue $row 'Id' $null) { throw 'O item selecionado ja e um perfil salvo.' }
    @{ ExecutablePath = $path; Name = [string](Get-ObjectPropertyValue $row 'Name' ([IO.Path]::GetFileNameWithoutExtension($path))) }
} 'Adicionando o executavel detectado a biblioteca...'
Add-AsyncButtonHandler 'BtnRemoveGame' 'RemoveGame' {
    $row = (Get-Control 'GamesGrid').SelectedItem
    $id = [string](Get-ObjectPropertyValue $row 'Id' '')
    if (-not $row -or [string]::IsNullOrWhiteSpace($id)) { throw 'Selecione um perfil salvo.' }
    @{ Id = $id }
} 'Removendo perfil da lista...' -ConfirmationMessage 'Remover apenas o perfil selecionado da lista? O jogo nao sera alterado.'
(Get-Control 'GamesGrid').Add_SelectionChanged({
    $row = (Get-Control 'GamesGrid').SelectedItem
    if (-not $row) { return }
    (Get-Control 'GameProfileNameTextBox').Text = [string](Get-ObjectPropertyValue $row 'Name' '')
    (Get-Control 'GameProfileArgumentsTextBox').Text = [string](Get-ObjectPropertyValue $row 'Arguments' '')
    Set-ComboContent (Get-Control 'GameProfilePriorityCombo') ([string](Get-ObjectPropertyValue $row 'Priority' 'AboveNormal'))
    Set-ComboContent (Get-Control 'GameProfilePowerCombo') ([string](Get-ObjectPropertyValue $row 'PowerPlan' 'HighPerformance'))
    (Get-Control 'GameProfilePreventSleepCheck').IsChecked = [bool](Get-ObjectPropertyValue $row 'PreventSleep' $true)
    (Get-Control 'GameProfileReduceVisualCheck').IsChecked = [bool](Get-ObjectPropertyValue $row 'ReduceVisualEffects' $false)
    (Get-Control 'GameProfileDoNotDisturbCheck').IsChecked = [bool](Get-ObjectPropertyValue $row 'OpenDoNotDisturbSettings' $false)
    (Get-Control 'GameProfileProcessListCheck').IsChecked = [bool](Get-ObjectPropertyValue $row 'UseConfiguredProcessList' $true)
    $profileServices = @(Get-ObjectPropertyValue -InputObject $row -Name 'SuspendServices' -Default @())
    (Get-Control 'GameProfileSelectedServicesCheck').IsChecked = $profileServices.Count -gt 0
    $path = [string](Get-ObjectPropertyValue $row 'ExecutablePath' '')
    if (Test-SafeExecutablePath -Path $path) {
        (Get-Control 'GameExecutableTextBox').Text = $path
    }
})
Add-AsyncButtonHandler 'BtnSaveGameProfile' 'UpdateGame' {
    $row = (Get-Control 'GamesGrid').SelectedItem
    $id = [string](Get-ObjectPropertyValue $row 'Id' '')
    if (-not $row -or [string]::IsNullOrWhiteSpace($id)) { throw 'Selecione um perfil salvo.' }
    $name = [string](Get-Control 'GameProfileNameTextBox').Text
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Informe um nome para o perfil.' }
    @{
        Id = $id; Name = $name.Trim()
        Arguments = [string](Get-Control 'GameProfileArgumentsTextBox').Text
        Priority = Get-ComboContent (Get-Control 'GameProfilePriorityCombo')
        PowerPlan = Get-ComboContent (Get-Control 'GameProfilePowerCombo')
        Services = if ([bool](Get-Control 'GameProfileSelectedServicesCheck').IsChecked) { Get-SelectedServiceNames } else { @() }
        PreventSleep = [bool](Get-Control 'GameProfilePreventSleepCheck').IsChecked
        ReduceVisualEffects = [bool](Get-Control 'GameProfileReduceVisualCheck').IsChecked
        OpenDoNotDisturbSettings = [bool](Get-Control 'GameProfileDoNotDisturbCheck').IsChecked
        UseConfiguredProcessList = [bool](Get-Control 'GameProfileProcessListCheck').IsChecked
    }
} 'Salvando configuracao individual do jogo...'
Add-AsyncButtonHandler 'BtnRunGameProfile' 'InvokeGameProfile' {
    $row = (Get-Control 'GamesGrid').SelectedItem
    $id = [string](Get-ObjectPropertyValue $row 'Id' '')
    if (-not $row -or [string]::IsNullOrWhiteSpace($id)) { throw 'Selecione um perfil salvo.' }
    (Get-Control 'GameSessionStatusText').Text = "Iniciando e monitorando $(Get-ObjectPropertyValue $row 'Name' 'jogo')..."
    @{ Id = $id }
} 'Aplicando o perfil e monitorando o jogo...' -RequiresAdministrator `
    -ConfirmationMessage 'O perfil pode fechar processos e suspender servicos opcionais. Tudo reversivel sera restaurado quando o jogo fechar. Continuar?'
(Get-Control 'BtnGameGpuPreference').Add_Click({
    try {
        $row = (Get-Control 'GamesGrid').SelectedItem
        $path = [string](Get-ObjectPropertyValue $row 'ExecutablePath' '')
        if (-not $row -or -not (Test-SafeExecutablePath -Path $path)) { throw 'Selecione um perfil com executavel valido.' }
        Show-AppMessage -Title 'Preferencia de GPU' -Message ("Na pagina oficial que sera aberta, adicione este executavel e escolha Alto desempenho:`n`n" + $path)
        Open-GraphicsSettings | Out-Null
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Preferencia de GPU' -Icon Warning }
})
Add-AsyncButtonHandler 'BtnGameFullscreenCompatibility' 'GameFullscreen' {
    $row = (Get-Control 'GamesGrid').SelectedItem
    $path = [string](Get-ObjectPropertyValue $row 'ExecutablePath' '')
    if (-not $row -or -not (Test-SafeExecutablePath -Path $path)) { throw 'Selecione um perfil com executavel valido.' }
    @{ ExecutablePath = $path }
} 'Abrindo o local do executavel para configuracao manual...'
(Get-Control 'BtnCreateGameShortcut').Add_Click({
    try {
        $row = (Get-Control 'GamesGrid').SelectedItem
        $id = [string](Get-ObjectPropertyValue $row 'Id' '')
        if (-not $row -or [string]::IsNullOrWhiteSpace($id)) { throw 'Selecione um perfil salvo.' }
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title = 'Criar atalho otimizado'; $dialog.Filter = 'Atalho (*.lnk)|*.lnk'; $dialog.FileName = "$($row.Name) - Otimizado.lnk"
        if ($dialog.ShowDialog($window)) { Start-UiAction -ActionId 'CreateGameShortcut' -Parameters @{ Id = $id; DestinationPath = $dialog.FileName; Force = $false } -Status 'Criando atalho...' }
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Atalho' -Icon Warning }
})

# Atualizacoes apos alteracoes comuns.
$refreshAfterActions = @('CreateBackup', 'CreateRestorePoint', 'QuickOptimize', 'ApplyProfile', 'UndoLast', 'RestoreAll', 'RestoreManifest', 'RestoreBackupItem', 'HighPerformance',
    'UltimatePerformance', 'CreateGamingPlan', 'RestorePower', 'VisualProfile', 'VisualOptions',
    'ClearGraphicsCache', 'AutomaticPageFile', 'CustomPageFile', 'Cleanup', 'OptimizeVolume',
    'SfcVerify', 'SfcScan', 'DismCheck', 'DismScan', 'DismRestore',
    'SetService', 'RestoreService', 'SaveServiceProfile', 'ApplyServiceProfile', 'DisableStartupMany', 'RestoreStartupMany', 'RestoreAllStartup',
    'RemoveAppx', 'RestoreAppx', 'SetTask', 'RestoreTask', 'RestoreTaskMany', 'RestoreAllTasks', 'ApplyPrivacy',
    'AddGame', 'UpdateGame', 'RemoveGame', 'StartGameSession', 'InvokeGameProfile', 'StopGameSession')
$pollTimer.Add_Tick({
    # O primeiro timer ja finaliza a tarefa. Este bloco agenda uma atualizacao leve
    # apenas quando a interface estiver ociosa e a acao anterior foi mutante.
    try {
        if (-not $script:ActiveTask -and $script:PendingRefresh) {
            $script:PendingRefresh = $false
            Start-UiAction -ActionId 'InitialData' -Status 'Atualizando a interface...'
        }
    }
    catch {
        $refreshError = $_
        $script:PendingRefresh = $false
        Write-UiBackgroundFailure `
            -Name 'Falha ao iniciar atualizacao da interface' `
            -ActionId 'InitialData' `
            -ErrorRecord $refreshError `
            -Phase 'PostOperationRefresh' `
            -StatusMessage 'A operacao terminou, mas a atualizacao da tela falhou. Use Atualizar para tentar novamente.'
    }
})

# Marca refresh no callback central sem criar outra fila concorrente.
$originalUpdateFunction = ${function:Update-UiFromResult}
function Update-UiFromResult {
    param([string]$ActionId, $Result)
    & $originalUpdateFunction $ActionId $Result
    if ($refreshAfterActions -contains $ActionId) { $script:PendingRefresh = $true }
    if ($ActionId -eq 'DetectGames') { Set-ItemsSource (Get-Control 'GamesGrid') $Result }
    if ($ActionId -in @('StartGameSession', 'InvokeGameProfile')) {
        $simulated = [string](Get-ObjectPropertyValue $Result 'Result' '') -eq 'Simulated'
        $runtime = [double](Get-ObjectPropertyValue $Result 'RuntimeSeconds' 0)
        (Get-Control 'GameSessionStatusText').Text = if ($simulated) {
            'Simulacao concluida; nenhum jogo ou recurso do sistema foi alterado.'
        } else { "Jogo encerrado apos $runtime s; restauracao automatica concluida. Consulte o log para detalhes." }
    }
    if ($ActionId -eq 'StopGameSession') { (Get-Control 'GameSessionStatusText').Text = 'Restauracao da sessao concluida.' }
}

Show-AppPage -NavigationName 'NavHome'
Set-UiBusyState -Busy $false -Message $(if ($context.Simulation) { 'Modo simulacao ativo por padrao.' } else { 'Pronto.' })
Update-LogView
$window.Add_ContentRendered({
    try {
        $afterInitial = if ($LaunchGameProfile) {
            { Start-UiAction -ActionId 'InvokeGameProfile' -Parameters @{ Id = $LaunchGameProfile } `
                    -Status 'Iniciando jogo pelo perfil otimizado...' -RequiresAdministrator }.GetNewClosure()
        }
        elseif ($ResumeAction) {
            {
                try {
                    $json = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ResumeDataBase64))
                    $decoded = $json | ConvertFrom-Json -ErrorAction Stop
                    $parameters = @{}
                    foreach ($property in $decoded.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
                    Start-UiAction -ActionId $ResumeAction -Parameters $parameters `
                        -Status 'Retomando operacao apos elevacao...' -RequiresAdministrator
                }
                catch { Show-AppMessage -Message ("Nao foi possivel retomar a operacao: " + $_.Exception.Message) -Title 'Retomar apos UAC' -Icon Error }
            }.GetNewClosure()
        }
        else { $null }
        Start-UiAction -ActionId 'InitialData' -Status 'Carregando informacoes do computador...' -OnCompleted $afterInitial
        $metricsTimer.Start()
    }
    catch {
        Write-UiBackgroundFailure `
            -Name 'Falha ao iniciar a interface' `
            -ActionId 'InitialData' `
            -ErrorRecord $_ `
            -Phase 'InitialRender' `
            -StatusMessage 'Nao foi possivel carregar os dados iniciais. Consulte o log e tente Atualizar.'
    }
})
$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:ActiveTask) { return }
    $eventArgs.Cancel = $true
    $nonCancelable = @('SfcScan', 'DismCheck', 'DismScan', 'DismRestore', 'ComponentCleanup', 'OptimizeVolume', 'DiskScan')
    if ($script:ActiveTask.ActionId -in $nonCancelable) {
        Show-AppMessage -Message 'Uma ferramenta de manutencao do Windows ainda esta em execucao. A janela permanecera aberta ate a conclusao segura.' `
            -Title 'Operacao em andamento' -Icon Warning
        return
    }
    if ($script:CancelRequested) {
        (Get-Control 'OperationStatusText').Text = 'Aguardando cancelamento e restauracao...'
        return
    }
    $isGameSession = $script:ActiveTask.ActionId -in @('StartGameSession', 'InvokeGameProfile')
    $message = if ($isGameSession) {
        'Encerrar a sessao, restaurar os recursos e manter a janela aberta ate concluir?'
    } else { 'Cancelar a operacao atual? A janela permanecera aberta ate o rollback terminar.' }
    if (-not (Confirm-AppAction -Message $message -Title 'Operacao em andamento')) { return }
    try {
        $script:CancelRequested = $true
        [void]$script:ActiveTask.PowerShell.BeginStop($null, $null)
        (Get-Control 'OperationStatusText').Text = 'Cancelando com seguranca; aguarde a restauracao...'
    }
    catch { Show-AppMessage -Message $_.Exception.Message -Title 'Cancelamento' -Icon Error }
})
$window.Add_Closed({
    try { $metricsTimer.Stop(); $pollTimer.Stop() } catch { }
    try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { }
})

[void]$window.ShowDialog()
