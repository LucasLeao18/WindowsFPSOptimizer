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
Write-OptimizerLog -Name 'Contrato de valor nulo' -Category 'Teste' -OldValue $null -NewValue $null -Result Info | Out-Null

$analysis = Invoke-ComputerAnalysis
foreach ($property in @('Defender', 'Restart', 'Updates', 'RestorePoint', 'Integrity')) {
    if (-not $analysis.Security.PSObject.Properties[$property]) { throw "Contrato Security ausente: $property" }
}

$initial = Get-UiInitialData
if (@($initial.Privacy).Count -ne 8) { throw 'A interface nao recebeu as oito opcoes de privacidade.' }
if (-not $initial.PSObject.Properties['ServiceProfiles']) { throw 'Perfis de servico ausentes dos dados iniciais.' }

$rejected = $false
try { Invoke-OptimizationProfile -Name MaximumFPS -Confirmed | Out-Null }
catch { $rejected = $_.Exception.Message -match 'exige um executavel' }
if (-not $rejected) { throw 'MaximumFPS sem jogo nao foi recusado antes da transacao.' }
if (Get-CurrentOptimizerBackup) { throw 'MaximumFPS recusado deixou backup ativo.' }
if (Get-ActiveGameSession) { throw 'MaximumFPS recusado deixou sessao ativa.' }

$manualBackup = Invoke-UIAction -ActionId CreateBackup
if ([string]$manualBackup.Result -ne 'Simulated') { throw 'Backup manual em simulacao nao retornou Simulated.' }

$storageModule = Get-Module StorageOptimizations
$sfcHealthy = & $storageModule {
    $fake = [pscustomobject]@{
        ExitCode = 0; Simulated = $false
        Output = @('Windows Resource Protection did not find any integrity violations.')
    }
    Get-IntegrityCommandInterpretation -Tool SFC -Mode VerifyOnly -CommandResult $fake
}
if ($sfcHealthy.Healthy -ne $true -or $sfcHealthy.Outcome -ne 'Healthy') { throw 'Interpretacao conservadora do SFC saudavel falhou.' }
$dismUnhealthy = & $storageModule {
    $fake = [pscustomobject]@{
        ExitCode = 0; Simulated = $false
        Output = @('The component store is repairable.')
    }
    Get-IntegrityCommandInterpretation -Tool DISM -Mode ScanHealth -CommandResult $fake
}
if ($dismUnhealthy.Healthy -ne $false -or $dismUnhealthy.Outcome -ne 'CorruptionDetected') { throw 'Interpretacao conservadora do DISM reparavel falhou.' }
$sfcRepaired = & $storageModule {
    $fake = [pscustomobject]@{
        ExitCode = 0; Simulated = $false
        Output = @('Windows Resource Protection found corrupt files and successfully repaired them.')
    }
    Get-IntegrityCommandInterpretation -Tool SFC -Mode ScanNow -CommandResult $fake
}
if ($null -ne $sfcRepaired.Healthy -or $sfcRepaired.Outcome -ne 'RepairedNeedsVerification') {
    throw 'Um reparo SFC foi classificado indevidamente como estado final saudavel ou corrompido.'
}
$integrityAssessment = & $storageModule {
    $now = [datetime]::UtcNow
    $checks = @(
        [pscustomobject]@{ Tool = 'SFC'; Mode = 'VerifyOnly'; CheckedAtUtc = $now.ToString('o'); Healthy = $null; Outcome = 'Unknown'; Evidence = 'Inconclusivo'; ExitCode = 0 },
        [pscustomobject]@{ Tool = 'DISM'; Mode = 'ScanHealth'; CheckedAtUtc = $now.AddDays(-5).ToString('o'); Healthy = $true; Outcome = 'Healthy'; Evidence = 'Sem corrupcao'; ExitCode = 0 }
    )
    Get-IntegrityAssessmentFromChecks -Checks $checks -NowUtc $now -ValidityDays 30
}
if ($null -ne $integrityAssessment.Healthy -or $integrityAssessment.Reason -notmatch 'inconclusiva') {
    throw 'Uma verificacao recente inconclusiva foi mascarada por resultado conhecido de outra ferramenta.'
}
$freshAssessment = & $storageModule {
    $now = [datetime]::UtcNow
    $checks = @(
        [pscustomobject]@{ Tool = 'SFC'; Mode = 'VerifyOnly'; CheckedAtUtc = $now.ToString('o'); Healthy = $true; Outcome = 'Healthy'; Evidence = 'Sem violacoes'; ExitCode = 0 },
        [pscustomobject]@{ Tool = 'DISM'; Mode = 'ScanHealth'; CheckedAtUtc = $now.AddDays(-60).ToString('o'); Healthy = $false; Outcome = 'CorruptionDetected'; Evidence = 'Antigo'; ExitCode = 0 }
    )
    Get-IntegrityAssessmentFromChecks -Checks $checks -NowUtc $now -ValidityDays 30
}
if ($freshAssessment.Healthy -ne $true -or $freshAssessment.StaleCount -ne 1) {
    throw 'A janela de validade da integridade nao expirou corretamente um resultado antigo.'
}

$serviceModule = Get-Module ServiceManager
$serviceMode = & $serviceModule {
    function Get-ServiceProfiles {
        return @([pscustomobject]@{ Name = 'Teste'; Services = @('Spooler') })
    }
    function Set-OptionalServiceState {
        param([string]$Name, [string]$DesiredState)
        return [pscustomobject]@{ Name = $Name; DesiredState = $DesiredState }
    }
    return @((Apply-ServiceProfile -Name Teste -Mode Disabled))[0].DesiredState
}
if ([string]$serviceMode -ne 'Disabled') { throw 'Apply-ServiceProfile ignorou o modo Disabled.' }

Write-Host 'TESTE DE CONTRATOS APROVADO: integracao em simulacao, sem tweaks reais.' -ForegroundColor Green
