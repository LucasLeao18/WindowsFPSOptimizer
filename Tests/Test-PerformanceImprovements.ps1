#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('Benchmark', 'Profiles', 'SystemAnalysis', 'ProcessManager', 'GameOptimizations', 'UIController')) {
    Import-Module (Join-Path $projectRoot "$module.psm1") -Force -DisableNameChecking
}
$checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Near([double]$Actual, [double]$Expected, [string]$Message) {
    Assert-True ([math]::Abs($Actual - $Expected) -lt 0.00001) "$Message (esperado $Expected; recebido $Actual)"
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $_.Exception.Message -match $Pattern }
    Assert-True $rejected "Entrada deveria ser recusada: $Pattern"
}

# Fixtures isoladas, sem contexto real, Registro, backup ou plano de energia.
$fixtureRoot = Join-Path $projectRoot ('.build\performance-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    $beforePath = Join-Path $fixtureRoot 'before.csv'
    $afterPath = Join-Path $fixtureRoot 'after.csv'
    $header = 'Application,ProcessID,SwapChainAddress,MsBetweenPresents'
    @($header, 'game.exe,42,0xA,0') + @(1..99 | ForEach-Object { 'game.exe,42,0xA,10' }) + @('game.exe,42,0xA,100') |
        Set-Content -LiteralPath $beforePath -Encoding UTF8
    @($header) + @(1..100 | ForEach-Object { 'game.exe,96,0xB,10' }) |
        Set-Content -LiteralPath $afterPath -Encoding UTF8
    $before = Import-FrameTimeCapture $beforePath
    $after = Import-FrameTimeCapture $afterPath
    Assert-True ($before.FrameCount -eq 100 -and $before.ZeroIntervalsSkipped -eq 1) 'Intervalos zero contam como quadros validos.'
    Assert-Near $before.AverageFps (100000.0 / 1090) 'FPS medio deve usar tempo total, nao media de FPS instantaneo.'
    Assert-Near $before.OnePercentLowFps 10 '1% low deve preservar a travada de 100 ms.'
    Assert-Near $before.P95FrameTimeMs 10 'P95 incorreto.'
    Assert-Near $before.P99FrameTimeMs 10 'P99 deve usar nearest-rank.'
    Assert-Near $before.SlowestFrameTimeMs 100 'Pior quadro foi filtrado indevidamente.'
    $comparison = Compare-FrameTimeCapture $before $after
    Assert-Near $comparison.Metrics[0].ChangePercent 9 'Variacao de FPS incorreta.'
    Assert-Near $comparison.Metrics[1].ChangePercent 900 'Variacao de 1% low incorreta.'
    Assert-True ($comparison.Warnings.Count -gt 0) 'Captura curta deve informar incerteza.'
    $uiResult = Invoke-UIAction -ActionId CompareBenchmarks -Parameters @{ BeforePath = $beforePath; AfterPath = $afterPath }
    Assert-True ($uiResult.Metrics.Count -eq 6) 'Comparador nao esta disponivel pelo dispatcher da interface.'
    $badPath = Join-Path $fixtureRoot 'bad.csv'
    @($header) + @(1..99 | ForEach-Object { 'game.exe,42,0xA,10' }) + @('game.exe,42,0xA,50', 'game.exe,42,0xA,100') |
        Set-Content $badPath -Encoding UTF8
    Assert-Near (Import-FrameTimeCapture $badPath).OnePercentLowFps (1000.0 / 75) '1% low de 101 quadros deve usar os dois intervalos mais lentos.'
    foreach ($bad in @('NaN', 'Infinity', '-1', 'invalido', '1e309', '"16,7"', '600001')) {
        @($header, "game.exe,42,0xA,$bad", 'game.exe,42,0xA,10') | Set-Content $badPath -Encoding UTF8
        Assert-Rejected { Import-FrameTimeCapture $badPath } 'invalido'
    }
    @('FrameTime', '10', '20') | Set-Content $badPath -Encoding UTF8
    Assert-Rejected { Import-FrameTimeCapture $badPath } 'MsBetweenPresents ausente'
    @($header, 'game.exe,42,0xA,10', 'game.exe,42,0xB,10') | Set-Content $badPath -Encoding UTF8
    Assert-Rejected { Import-FrameTimeCapture $badPath } 'mistura'
    @($header, 'game.exe,42,0xA,10', 'game.exe,43,0xA,10', 'game.exe,42,0xA,20') | Set-Content $badPath -Encoding UTF8
    Assert-Rejected { Import-FrameTimeCapture $badPath } 'mistura'
    $filtered = Import-FrameTimeCapture $badPath -ProcessId 42 -SwapChainAddress '0xA'
    Assert-True ($filtered.FrameCount -eq 2) 'Filtro deve isolar o fluxo selecionado.'
    $filtered.Application = 'outro.exe'
    Assert-Rejected { Compare-FrameTimeCapture $before $filtered } 'aplicativos diferentes'
    Assert-Rejected { Import-FrameTimeCapture $badPath -ProcessId 999 } 'pelo menos dois'
    Assert-Rejected { Import-FrameTimeCapture $beforePath -WarmupFrames 99 } 'pelo menos dois'
    $cultureBefore = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
        @('MsBetweenPresents', '12.5', '12.5') | Set-Content $badPath -Encoding UTF8
        Assert-Near (Import-FrameTimeCapture $badPath).AverageFps 80 'Decimais do CSV devem ser independentes do idioma.'
    }
    finally { [Threading.Thread]::CurrentThread.CurrentCulture = $cultureBefore }

    $profileProbe = & (Get-Module Profiles) {
        $calls = New-Object 'System.Collections.Generic.List[string]'
        function Set-OptimizerCurrentProfile { param($Name) $null = $Name }
        function Invoke-OptimizerOperation { param([Alias('Name')]$OperationName, [Alias('Risk')]$OperationRisk, [switch]$RequiresAdministrator, $ScriptBlock) & $ScriptBlock }
        function Invoke-KnownProfileCommand { param($CommandName, $Parameters, [switch]$Optional) $calls.Add($CommandName) }
        function Invoke-SafeCleanup { param($Categories, [switch]$Confirmed) $calls.Add('Cleanup:' + ($Categories -join ',')) }
        Invoke-OptimizationProfile -Name Safe -IncludeCleanup -ConfirmedIrreversible | Out-Null
        $safeCalls = $calls.ToArray()
        $calls.Clear()
        function Set-OptionalServiceState { param($Name, $DesiredState) $calls.Add('Service:' + $Name) }
        Invoke-OptimizationProfile -Name Balanced -Confirmed -SelectedServices @('Spooler') | Out-Null
        $balancedCalls = $calls.ToArray()
        function Test-SafeExecutablePath { param($Path) return $true }
        function Invoke-TransientGameProfile {
            param($ExecutablePath, $Priority, $SuspendServices, $PowerPlan, $PreventSleep, $ReduceVisualEffects, $UseConfiguredProcessList)
            [pscustomobject]@{ Priority = $Priority; PowerPlan = $PowerPlan }
        }
        $calls.Clear()
        $maximum = Invoke-OptimizationProfile -Name MaximumFPS -Confirmed -GameExecutable 'game.exe'
        [pscustomobject]@{ Safe = $safeCalls; Balanced = $balancedCalls; Maximum = $maximum.GameSession; MaximumPersistentCalls = $calls.Count }
    }
    Assert-True ($profileProbe.Safe -contains 'Set-GameModeState') 'Perfil seguro perdeu Game Mode.'
    Assert-True ($profileProbe.Safe -contains 'Cleanup:UserTemp') 'Limpeza de perfil deve preservar shader cache.'
    Assert-True (@($profileProbe.Safe + $profileProbe.Balanced | Where-Object { $_ -match 'PerformancePlan|Tailored|ThirdParty' }).Count -eq 0) 'Perfil automatico alterou energia ou privacidade.'
    Assert-True ($profileProbe.Balanced -contains 'Service:Spooler') 'Selecao explicita de servico foi ignorada.'
    Assert-True ($profileProbe.Maximum.Priority -eq 'AboveNormal' -and $profileProbe.Maximum.PowerPlan -eq 'HighPerformance') 'Sessao maxima usou padroes inesperados.'
    Assert-True ($profileProbe.MaximumPersistentCalls -eq 0) 'Perfil temporario aplicou ajustes persistentes antes da sessao.'
    Assert-Rejected { Invoke-OptimizationProfile -Name MaximumFPS -Confirmed -IncludeCleanup -ConfirmedIrreversible } 'Desmarque a limpeza'
    Assert-True (Test-UiGameSessionAction ApplyProfile @{ Name = 'MaximumFPS' }) 'Sessao maxima precisa permitir encerrar e restaurar pela interface.'
    Assert-True (-not (Test-UiGameSessionAction ApplyProfile @{ Name = 'Safe' })) 'Perfil seguro nao e um monitor de jogo.'
    Assert-True (Test-UiGameSessionAction StartGameSession) 'Sessao avulsa perdeu monitoramento.'

    $analysisProbe = & (Get-Module SystemAnalysis) {
        param($ConfigPath)
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        function Get-OptimizerContext { [pscustomobject]@{ Config = $config } }
        $snapshot = [pscustomobject]@{
            StartupCount = 2; ProcessCount = 100; CpuPercent = 2; RamPercent = 40
            DiskFreePercent = 30; PowerPlanOptimized = $false; PowerPlanName = 'Balanced'
            GameModeEnabled = $true; CaptureDisabled = $true; OptionalServicesActive = 8
            BackgroundApps = 30; VisualProfile = 'Default'; IntegrityHealthy = $null
        }
        $first = Get-PerformanceAssessment $snapshot
        $recommendations = @(Get-PerformanceRecommendations $snapshot)
        $snapshot.ProcessCount = 350; $snapshot.PowerPlanOptimized = $true
        $snapshot.OptionalServicesActive = 0; $snapshot.BackgroundApps = 0; $snapshot.VisualProfile = 'MaximumPerformance'
        $second = Get-PerformanceAssessment $snapshot
        [pscustomobject]@{ First = $first.Score; Second = $second.Score; Recommendations = $recommendations }
    } (Join-Path $projectRoot 'Config.json')
    Assert-True ($analysisProbe.First -eq $analysisProbe.Second) 'Nota incentiva reduzir contagens ou forcar energia/visuais.'
    Assert-True (@($analysisProbe.Recommendations | Where-Object Id -in @('power-plan', 'services', 'background-apps')).Count -eq 0) 'Recomendacao sem evidencia de carga real.'

    $processProbe = & (Get-Module ProcessManager) {
        function Get-ProcessSafetyConfiguration { return @('System') }
        function Test-ProtectedProcessMetadata { param($Name, $Description, $Company, $Path) return $false }
        $provideCounters = $true
        function Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_ComputerSystem' { [pscustomobject]@{ NumberOfLogicalProcessors = 16 } }
                'Win32_PerfFormattedData_PerfProc_Process' {
                    if ($provideCounters) { [pscustomobject]@{ IDProcess = 9876; PercentProcessorTime = 320; IODataBytesPersec = 1MB } }
                }
            }
        }
        function Get-Process {
            [pscustomobject]@{ Id = 9876; ProcessName = 'game'; Path = ''; StartTime = (Get-Date); SessionId = 1; WorkingSet64 = 1MB; PrivateMemorySize64 = 1MB }
        }
        $available = @(Get-ProcessInventory)[0]
        $provideCounters = $false
        $missing = @(Get-ProcessInventory)[0]
        [pscustomobject]@{ Available = $available; Missing = $missing }
    }
    Assert-Near $processProbe.Available.CpuPercent 20 'CPU por processo precisa ser normalizada pelo total de nucleos.'
    Assert-True ($null -eq $processProbe.Missing.CpuPercent -and $null -eq $processProbe.Missing.DiskMBps) 'Contadores ausentes devem permanecer indeterminados.'

    $capabilities = & (Get-Module GameOptimizations) {
        function Get-WindowsPlatformInfo { [pscustomobject]@{ IsSupported = $true; Build = 19045 } }
        $old = Get-ManualGamingFeatureState WindowedGames
        function Get-WindowsPlatformInfo { [pscustomobject]@{ IsSupported = $true; Build = 22621 } }
        [pscustomobject]@{ Old = $old; New = Get-ManualGamingFeatureState WindowedGames }
    }
    Assert-True ($capabilities.Old.State -eq 'Unsupported' -and $capabilities.New.State -eq 'Manual') 'Jogos em janela precisa respeitar a build minima.'
    Write-Host "TESTES DE DESEMPENHO APROVADOS: $checks verificacoes sem tweaks reais." -ForegroundColor Green
}
finally {
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.build')).TrimEnd('\') + '\'
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixture.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Caminho de limpeza inesperado.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction Stop
}
