#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$checks = New-Object System.Collections.Generic.List[object]

function Add-CheckResult {
    param([string]$Name, [bool]$Passed, [string]$Details = '')
    $checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Details = $Details })
    if (-not $Passed) { $failures.Add("$Name`: $Details") }
}

function Test-Condition {
    param([string]$Name, [scriptblock]$Test, [string]$FailureMessage)
    try {
        $value = & $Test
        Add-CheckResult -Name $Name -Passed ([bool]$value) -Details $(if ($value) { 'OK' } else { $FailureMessage })
    }
    catch { Add-CheckResult -Name $Name -Passed $false -Details $_.Exception.Message }
}

$requiredFiles = @(
    'WindowsFPSOptimizer.ps1', 'MainWindow.xaml', 'Core.psm1', 'SystemAnalysis.psm1',
    'GameOptimizations.psm1', 'PowerOptimizations.psm1', 'GraphicsOptimizations.psm1',
    'StorageOptimizations.psm1', 'ServiceManager.psm1', 'StartupManager.psm1',
    'BackupManager.psm1', 'ProcessManager.psm1', 'Logging.psm1', 'Profiles.psm1',
    'WindowsAppsManager.psm1', 'PrivacyManager.psm1', 'ScheduledTaskManager.psm1',
    'UIController.psm1', 'Benchmark.psm1', 'Config.json', 'README.md'
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $projectRoot $relativePath
    Add-CheckResult -Name "Arquivo $relativePath" -Passed (Test-Path -LiteralPath $path -PathType Leaf) `
        -Details $(if (Test-Path -LiteralPath $path -PathType Leaf) { 'OK' } else { 'Ausente' })
}

$buildPrefix = (Join-Path $projectRoot '.build').TrimEnd('\') + '\'
$distPrefix = (Join-Path $projectRoot 'dist').TrimEnd('\') + '\'
$powerShellFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -ErrorAction Stop |
    Where-Object {
        $_.Extension -in @('.ps1', '.psm1') -and
        -not $_.FullName.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        -not $_.FullName.StartsWith($distPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
$allAsts = @{}
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    $allAsts[$file.FullName] = $ast
    Add-CheckResult -Name "Sintaxe $($file.Name)" -Passed ($parseErrors.Count -eq 0) `
        -Details $(if ($parseErrors.Count -eq 0) { 'OK' } else { ($parseErrors | ForEach-Object { "linha $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' })

    $emptyFunctions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Body.EndBlock.Statements.Count -eq 0
    }, $true))
    Add-CheckResult -Name "Funcoes implementadas $($file.Name)" -Passed ($emptyFunctions.Count -eq 0) `
        -Details $(if ($emptyFunctions.Count -eq 0) { 'OK' } else { "Vazias: $(@($emptyFunctions | ForEach-Object Name) -join ', ')" })

    $placeholderComments = @($tokens | Where-Object {
        $_.Kind -eq [Management.Automation.Language.TokenKind]::Comment -and
        $_.Text -match '(?i)(^\s*#\s*(TODO|FIXME)\b|implementar\s+posteriormente|notimplementedexception)'
    })
    Add-CheckResult -Name "Sem placeholders $($file.Name)" -Passed ($placeholderComments.Count -eq 0) `
        -Details $(if ($placeholderComments.Count -eq 0) { 'OK' } else { 'Comentario de implementacao pendente encontrado' })

    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $containsNonAscii = @($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1).Count -gt 0
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Add-CheckResult -Name "Codificacao PS5.1 $($file.Name)" -Passed (-not $containsNonAscii -or $hasUtf8Bom) `
        -Details $(if (-not $containsNonAscii) { 'ASCII seguro' } elseif ($hasUtf8Bom) { 'UTF-8 com BOM' } else { 'Texto nao ASCII sem BOM' })
}

try {
    $config = Get-Content -LiteralPath (Join-Path $projectRoot 'Config.json') -Raw | ConvertFrom-Json -ErrorAction Stop
    Add-CheckResult -Name 'Config.json valido' -Passed $true -Details "Versao $($config.App.Version)"
    Add-CheckResult -Name 'Simulacao padrao' -Passed ([bool]$config.App.DefaultSimulation) -Details 'DefaultSimulation deve ser true'
}
catch { Add-CheckResult -Name 'Config.json valido' -Passed $false -Details $_.Exception.Message }

try {
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $projectRoot 'MainWindow.xaml') -Raw -ErrorAction Stop
    $namespace = New-Object Xml.XmlNamespaceManager($xaml.NameTable)
    $namespace.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $names = @($xaml.SelectNodes('//*[@x:Name]', $namespace) | ForEach-Object {
        $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    })
    $duplicates = @($names | Group-Object | Where-Object Count -gt 1)
    Add-CheckResult -Name 'XAML XML valido' -Passed $true -Details "$($names.Count) controles nomeados"
    Add-CheckResult -Name 'Nomes XAML unicos' -Passed ($duplicates.Count -eq 0) `
        -Details $(if ($duplicates.Count -eq 0) { 'OK' } else { @($duplicates.Name) -join ', ' })

    $mainSource = Get-Content -LiteralPath (Join-Path $projectRoot 'WindowsFPSOptimizer.ps1') -Raw
    $controlReferences = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @("Get-Control\s+'([^']+)'", "Add-AsyncButtonHandler\s+'([^']+)'", "Add-OpenSettingsHandler\s+'([^']+)'")) {
        foreach ($match in [regex]::Matches($mainSource, $pattern)) { $controlReferences.Add($match.Groups[1].Value) }
    }
    $missingControls = @($controlReferences.ToArray() | Sort-Object -Unique | Where-Object { $_ -notin $names })
    Add-CheckResult -Name 'Referencias de controles XAML' -Passed ($missingControls.Count -eq 0) `
        -Details $(if ($missingControls.Count -eq 0) { "$(@($controlReferences.ToArray() | Sort-Object -Unique).Count) referencias validas" } else { $missingControls -join ', ' })

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load((Join-Path $projectRoot 'MainWindow.xaml'))
    $reader = New-Object Xml.XmlNodeReader($document)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    Add-CheckResult -Name 'WPF XamlReader' -Passed ($null -ne $window) -Details 'Arvore WPF criada'
    if ($window) { $window.Close() }
}
catch { Add-CheckResult -Name 'XAML/WPF' -Passed $false -Details $_.Exception.Message }

$forbiddenCommandPattern = '^(netsh|route|arp|nbtstat|ipconfig|Set-Net|New-Net|Remove-Net|Disable-Net|Enable-Net|Restart-Net|Set-Dns|Clear-Dns|Get-NetFirewall|Set-NetFirewall|New-NetFirewall|Remove-NetFirewall)'
$forbiddenCommands = New-Object System.Collections.Generic.List[string]
foreach ($entry in $allAsts.GetEnumerator()) {
    foreach ($commandAst in @($entry.Value.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = $commandAst.GetCommandName()
        if ($commandName -and $commandName -match $forbiddenCommandPattern) {
            $forbiddenCommands.Add("$([IO.Path]::GetFileName($entry.Key)):$($commandAst.Extent.StartLineNumber) $commandName")
        }
    }
}
Add-CheckResult -Name 'Sem comandos de rede' -Passed ($forbiddenCommands.Count -eq 0) `
    -Details $(if ($forbiddenCommands.Count -eq 0) { 'OK' } else { $forbiddenCommands.ToArray() -join '; ' })

$moduleOrder = @(
    'Logging.psm1', 'Core.psm1', 'BackupManager.psm1', 'ProcessManager.psm1',
    'ServiceManager.psm1', 'StartupManager.psm1', 'PowerOptimizations.psm1',
    'GraphicsOptimizations.psm1', 'StorageOptimizations.psm1', 'WindowsAppsManager.psm1',
    'PrivacyManager.psm1', 'ScheduledTaskManager.psm1', 'GameOptimizations.psm1',
    'SystemAnalysis.psm1', 'Benchmark.psm1', 'Profiles.psm1', 'UIController.psm1'
)
try {
    foreach ($module in $moduleOrder) {
        Import-Module (Join-Path $projectRoot $module) -Force -DisableNameChecking -ErrorAction Stop
    }
    Add-CheckResult -Name 'Importacao de modulos' -Passed $true -Details "$($moduleOrder.Count) modulos"
}
catch { Add-CheckResult -Name 'Importacao de modulos' -Passed $false -Details $_.Exception.Message }

$requiredCommands = @(
    'Initialize-OptimizerContext', 'Invoke-OptimizerOperation', 'Start-OptimizerBackup',
    'Restore-OptimizerBackup', 'Get-SystemOverview', 'Invoke-ComputerAnalysis',
    'Set-GameMode', 'Start-GameSession', 'Invoke-TransientGameProfile',
    'Set-HighPerformancePlan', 'Get-PowerCapabilities', 'Get-HagsState',
    'Invoke-SafeCleanup', 'Get-OptionalServices', 'Get-StartupItems', 'Get-ProcessInventory',
    'Get-AllServiceInventory', 'Get-InstalledApplications', 'Get-PrivacyOptimizationState', 'Get-ScheduledTaskInventory',
    'Invoke-OptimizationProfile', 'Invoke-UIAction', 'Import-FrameTimeCapture', 'Compare-FrameTimeCapture'
)
foreach ($command in $requiredCommands) {
    Add-CheckResult -Name "Contrato $command" -Passed ($null -ne (Get-Command $command -ErrorAction SilentlyContinue)) `
        -Details $(if (Get-Command $command -ErrorAction SilentlyContinue) { 'OK' } else { 'Funcao nao exportada' })
}

if (Get-Command Initialize-OptimizerContext -ErrorAction SilentlyContinue) {
    try {
        $context = Initialize-OptimizerContext -AppRoot $projectRoot -ConfigPath (Join-Path $projectRoot 'Config.json') -Simulation
        Initialize-OptimizerLogging -RootPath $context.LogRoot -SessionId $context.SessionId | Out-Null
        Add-CheckResult -Name 'Contexto simulado' -Passed ([bool]$context.Simulation) -Details $context.DataRoot
        $protectedPatterns = @($context.Config.Safety.ProtectedProcessPatterns)
        Add-CheckResult -Name 'Listas JSON preservam strings' `
            -Passed ($protectedPatterns.Count -gt 0 -and @($protectedPatterns | Where-Object { $_ -isnot [string] }).Count -eq 0) `
            -Details (($protectedPatterns | ForEach-Object { $_.GetType().FullName } | Select-Object -Unique) -join ', ')
        Add-CheckResult -Name 'Bloqueio Registro de rede' `
            -Passed (-not (Test-SafeRegistryPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters')) `
            -Details 'Tcpip deve ser recusado'
        Add-CheckResult -Name 'Bloqueio comando de rede' `
            -Passed (-not (Test-SafeNativeCommand -FilePath 'netsh.exe' -ArgumentList @('interface', 'show', 'interface'))) `
            -Details 'netsh deve ser recusado'
        Add-CheckResult -Name 'Protecao ExitLag' `
            -Passed (Test-ProtectedProcessMetadata -Name 'ExitLag' -Description 'ExitLag tunneling client') `
            -Details 'ExitLag deve ser tratado como processo protegido'
        Add-CheckResult -Name 'Protecao VPN' `
            -Passed (Test-ProtectedProcessMetadata -Name 'OpenVPN-GUI') `
            -Details 'Aplicativos VPN devem ser tratados como protegidos'
    }
    catch { Add-CheckResult -Name 'Contexto e guardas' -Passed $false -Details $_.Exception.Message }
}

$checks.ToArray() | Format-Table -AutoSize
if ($failures.Count -gt 0) {
    Write-Error ("Validacao falhou em {0} item(ns):`n- {1}" -f $failures.Count, ($failures.ToArray() -join "`n- "))
    exit 1
}
Write-Host "VALIDACAO APROVADA: $($checks.Count) verificacoes." -ForegroundColor Green
