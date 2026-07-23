#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

$moduleOrder = @(
    'Logging.psm1', 'Core.psm1', 'BackupManager.psm1', 'ProcessManager.psm1',
    'ServiceManager.psm1', 'StartupManager.psm1', 'PowerOptimizations.psm1',
    'GraphicsOptimizations.psm1', 'StorageOptimizations.psm1', 'WindowsAppsManager.psm1',
    'PrivacyManager.psm1', 'ScheduledTaskManager.psm1', 'GameOptimizations.psm1',
    'SystemAnalysis.psm1', 'Profiles.psm1', 'UIController.psm1'
)
foreach ($module in $moduleOrder) {
    Import-Module (Join-Path $projectRoot $module) -Force -DisableNameChecking -ErrorAction Stop
}

$context = Initialize-OptimizerContext -AppRoot $projectRoot -ConfigPath (Join-Path $projectRoot 'Config.json') -Simulation
Initialize-OptimizerLogging -RootPath $context.LogRoot -SessionId $context.SessionId | Out-Null

$profilesBefore = @(Get-GameProfiles)
$testExecutable = Join-Path $env:SystemRoot 'System32\notepad.exe'
if (Test-Path -LiteralPath $testExecutable -PathType Leaf) {
    $simulatedProfile = Add-GameProfile -ExecutablePath $testExecutable -Name 'Teste de simulacao'
    if ($null -eq $simulatedProfile -or [string]::IsNullOrWhiteSpace([string]$simulatedProfile.Id)) {
        throw 'Add-GameProfile nao retornou um perfil simulado valido.'
    }
    $profilesAfter = @(Get-GameProfiles)
    if ($profilesAfter.Count -ne $profilesBefore.Count) { throw 'A simulacao persistiu indevidamente um perfil de jogo.' }

    if (-not (Get-ActiveGameSession)) {
        $transient = Invoke-UIAction -ActionId 'StartGameSession' -Parameters @{
            ExecutablePath = $testExecutable; Priority = 'AboveNormal'; Services = @()
            PowerPlan = 'None'; PreventSleep = $false; ReduceVisualEffects = $false
            CloseProcesses = $false; OpenDoNotDisturbSettings = $false
        }
        if ([string]$transient.Result -ne 'Simulated') { throw 'A sessao transitoria nao informou resultado Simulated.' }
        if (Get-ActiveGameSession) { throw 'A sessao simulada criou estado ativo persistente.' }
        if (@(Get-GameProfiles).Count -ne $profilesBefore.Count) { throw 'A sessao transitoria alterou a biblioteca de jogos.' }
    }
}

$overview = Get-SystemOverview
$analysis = Invoke-ComputerAnalysis
$initialData = Get-UiInitialData
$cleanup = @(Get-SafeCleanupEstimate -MinimumAgeDays 7)
$catalog = @(Get-OptimizerOperationCatalog)
$privacy = @(Get-PrivacyOptimizationState)
$services = @(Get-OptionalServices -IncludeUnavailable)
$allServiceProbe = @(Get-AllServiceInventory -Search 'Spooler')
$selectedCleanup = @(Invoke-UIAction -ActionId 'CleanupEstimate' -Parameters @{ Categories = @('UserTemp', 'DirectXCache') })
$pageFileBeforeState = Get-PageFileConfiguration
$pageFileBefore = [pscustomobject]@{
    AutomaticManagedPagefile = $pageFileBeforeState.AutomaticManagedPagefile
    Settings = @($pageFileBeforeState.Settings)
} | ConvertTo-Json -Depth 8 -Compress
$pageFileSimulation = Set-AutomaticPageFile
$pageFileAfterState = Get-PageFileConfiguration
$pageFileAfter = [pscustomobject]@{
    AutomaticManagedPagefile = $pageFileAfterState.AutomaticManagedPagefile
    Settings = @($pageFileAfterState.Settings)
} | ConvertTo-Json -Depth 8 -Compress

if ($catalog.Count -lt 40) { throw "Catalogo incompleto: $($catalog.Count) itens." }
if ($cleanup.Count -ne 7) { throw "Categorias de limpeza inesperadas: $($cleanup.Count)." }
if ($null -eq $analysis.Assessment -or $null -eq $analysis.Recommendations) { throw 'Analise nao retornou avaliacao e recomendacoes.' }
if ($null -eq $initialData.Overview -or $null -eq $initialData.Security) { throw 'Dados iniciais da interface incompletos.' }
if (@($selectedCleanup | Where-Object { $_.Id -notin @('UserTemp', 'DirectXCache') }).Count -gt 0) { throw 'A estimativa ignorou o filtro de categorias.' }
if ($pageFileBefore -ne $pageFileAfter) { throw 'A simulacao alterou a configuracao real de paginacao.' }
if ($null -eq $pageFileSimulation) { throw 'A simulacao de paginacao nao retornou resultado.' }

[pscustomobject]@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Edition = $PSVersionTable.PSEdition
    Simulation = [bool]$context.Simulation
    DataRoot = $context.DataRoot
    Processes = [int]$overview.Metrics.ProcessCount
    Score = $analysis.Assessment.Score
    Recommendations = @($analysis.Recommendations).Count
    Catalog = $catalog.Count
    CleanupCategories = $cleanup.Count
    PrivacyItems = $privacy.Count
    OptionalServices = $services.Count
    ServiceProbe = $allServiceProbe.Count
    SelectedCleanup = $selectedCleanup.Count
    InitialSections = @($initialData.PSObject.Properties).Count
} | ConvertTo-Json -Depth 4

Write-Host 'SMOKE TEST APROVADO: nenhuma mutacao real foi executada.' -ForegroundColor Green
