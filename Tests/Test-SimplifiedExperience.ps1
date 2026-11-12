#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'UIController.psm1') -Force -DisableNameChecking
$fixture = Join-Path $root ('.build\experience-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$checks = 0
function Assert-Experience([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
try {
    & (Get-Module Core) {
        param($Folder)
        $script:OptimizerContext = [pscustomobject]@{ StateRoot = $Folder; Simulation = $true; ReadOnly = $true }
    } $fixture
    $initial = Get-OptimizerUiPreferences
    Assert-Experience (-not $initial.OnboardingCompleted -and $initial.Interface -eq 'Simple') 'Novo usuario deve receber onboarding e interface simples.'
    Set-OptimizerUiPreferences -Interface Advanced -OnboardingCompleted $true
    $saved = Get-OptimizerUiPreferences
    Assert-Experience ($saved.OnboardingCompleted -and $saved.Interface -eq 'Advanced') 'Conclusao e escolha de interface devem persistir, inclusive em simulacao.'
    Set-OptimizerUiPreferences -Interface Simple -OnboardingCompleted $true
    Assert-Experience ((Get-OptimizerUiPreferences).Interface -eq 'Simple') 'Alternancia de interface nao foi salva.'
    '{"SchemaVersion":1,"Interface":"Simple","OnboardingCompleted":"false"}' | Set-Content (Join-Path $fixture 'ui-preferences.json')
    Assert-Experience (-not (Get-OptimizerUiPreferences).OnboardingCompleted) 'Tipo invalido nao pode suprimir o onboarding.'
    'dados invalidos' | Set-Content (Join-Path $fixture 'ui-preferences.json')
    Assert-Experience (-not (Get-OptimizerUiPreferences).OnboardingCompleted) 'Preferencias corrompidas devem recuperar o padrao.'
    $probe = & (Get-Module UIController) {
        $script:selectionCount = -1
        function Invoke-OptimizationProfile {
            param($Name, [switch]$Confirmed, $GameExecutable, [string[]]$SelectedStartupIds = @())
            $script:selectionCount = $SelectedStartupIds.Count
            [pscustomobject]@{ Result = 'Simulated'; Name = $Name }
        }
        $result = Invoke-UIAction SimpleOptimize
        $balanced = Invoke-UIAction SimpleOptimize @{ Preset = 'Balanced' }
        $maximum = Invoke-UIAction SimpleOptimize @{ Preset = 'MaximumFPS'; GameExecutable = 'game.exe' }
        [pscustomobject]@{ Result = $result; Selections = $script:selectionCount; Balanced = $balanced; Maximum = $maximum }
    }
    Assert-Experience ($probe.Selections -eq 0 -and $probe.Result.Result -eq 'Simulated') 'O padrao simples nao deve herdar selecoes avancadas nem aplicar em simulacao.'
    Assert-Experience ($probe.Balanced.Changes[0].Name -eq 'Balanced' -and $probe.Maximum.Changes[0].Name -eq 'MaximumFPS') 'Os tres presets devem chegar ao motor correto.'
    Assert-Experience (Test-UiGameSessionAction SimpleOptimize @{ Preset = 'MaximumFPS' }) 'Maximo FPS simples precisa manter controles de encerramento.'
    $main = Get-Content (Join-Path $root 'WindowsFPSOptimizer.ps1') -Raw -Encoding UTF8
    Assert-Experience ($main -match 'OnboardingCompleted -and -not \$ResumeAction') 'O onboarding nao deve interromper a retomada apos UAC.'
    Assert-Experience ($main -match 'SimpleOptimize -Parameters \$parameters' -and $main -match 'Confirm-AppAction -Title') 'Aplicacao simples deve continuar exigindo confirmacao.'
    $appSource = Get-Content (Join-Path $root 'Installer\AppLauncher.cs') -Raw
    Assert-Experience ($appSource -match 'RunspaceFactory\.CreateRunspace' -and $appSource -notmatch 'Process\.Start\(|powershell\.exe\b') 'O aplicativo deve hospedar o motor sem processo de console.'
    $setupSource = Get-Content (Join-Path $root 'Installer\SetupLauncher.cs') -Raw
    Assert-Experience ($setupSource -notmatch 'cmd.exe|InnerSetup.exe' -and $setupSource -match 'CreateNoWindow = true') 'O instalador nao deve usar CMD nem mostrar console.'
    Assert-Experience (-not (Test-Path (Join-Path $root 'Installer\Run-Installer.cmd'))) 'A dependencia de CMD deve ser removida.'
    $native = Invoke-OptimizerHiddenNativeProcess -FilePath powercfg.exe -ArgumentList @('/getactivescheme')
    Assert-Experience ($native.ExitCode -eq 0 -and ($native.Output -join '') -match '[0-9a-fA-F]{8}-') 'Consulta de energia sem console falhou.'
    $quote = & (Get-Module Core) { ConvertTo-WindowsNativeArgument 'C:\pasta com espacos\' }
    Assert-Experience ($quote -eq '"C:\pasta com espacos\\"') 'Barra final precisa ser preservada em argumentos com espacos.'
    $quote = & (Get-Module Core) { ConvertTo-WindowsNativeArgument 'nome "citado"' }
    Assert-Experience ($quote -eq '"nome \"citado\""') 'Aspas em argumentos nativos precisam ser escapadas.'
    [xml]$xml = Get-Content (Join-Path $root 'MainWindow.xaml') -Raw -Encoding UTF8
    $manager = New-Object Xml.XmlNamespaceManager($xml.NameTable)
    $manager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    foreach ($name in @('PageSimple','BtnSimpleApply','BtnSimplePreview','BtnSimpleUndo','SimpleSafePreset','SimpleBalancedPreset','SimpleMaximumPreset','SimpleGamePanel','BtnSimpleStopSession','OnboardingOverlay','BtnOnboardingNext','BtnOnboardingSkip','BtnShowOnboarding')) {
        Assert-Experience ($null -ne $xml.SelectSingleNode("//*[@x:Name='$name']", $manager)) "Controle ausente: $name"
    }
    Write-Host "EXPERIENCIA SIMPLIFICADA APROVADA: $checks verificacoes, sem alterar o Windows."
}
finally {
    $expected = [IO.Path]::GetFullPath((Join-Path $root '.build')).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture fora da pasta permitida.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
