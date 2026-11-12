#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-LivePerformanceMetrics {
    [CmdletBinding()]
    param()

    $cpu = $null
    $disk = $null
    try {
        $cpuSample = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $cpu = [math]::Min(100, [math]::Round([double]$cpuSample.PercentProcessorTime, 1))
    }
    catch { }
    try {
        $diskSample = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
        $disk = [math]::Min(100, [math]::Round([double]$diskSample.PercentDiskTime, 1))
    }
    catch { }
    $memory = $null
    try { $memory = Get-MemoryStatus } catch { }
    return [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        CpuPercent = $cpu
        RamPercent = if ($memory) { $memory.UsedPercent } else { $null }
        RamUsedGB = if ($memory) { $memory.UsedGB } else { $null }
        RamAvailableGB = if ($memory) { $memory.AvailableGB } else { $null }
        DiskPercent = $disk
        ProcessCount = @(Get-Process -ErrorAction SilentlyContinue).Count
    }
}

function Get-DefenderStatus {
    [CmdletBinding()]
    param()

    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Active = $null; RealTimeProtection = $null; Status = 'Indisponivel' }
    }
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        return [pscustomobject]@{
            Available = $true
            Active = [bool]$status.AntivirusEnabled
            RealTimeProtection = [bool]$status.RealTimeProtectionEnabled
            AntispywareEnabled = [bool]$status.AntispywareEnabled
            SignaturesLastUpdated = $status.AntivirusSignatureLastUpdated
            QuickScanAgeDays = $status.QuickScanAge
            Status = if ($status.AntivirusEnabled -and $status.RealTimeProtectionEnabled) { 'Ativo' } else { 'Atencao' }
        }
    }
    catch {
        return [pscustomobject]@{ Available = $true; Active = $null; RealTimeProtection = $null; Status = 'Erro'; Error = $_.Exception.Message }
    }
}

function Get-PendingRestartStatus {
    [CmdletBinding()]
    param()

    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $path) { $reasons.Add($path) }
    }
    try {
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($session.PendingFileRenameOperations) { $reasons.Add('PendingFileRenameOperations') }
    }
    catch { }
    return [pscustomobject]@{ Pending = ($reasons.Count -gt 0); Reasons = $reasons.ToArray() }
}

function Get-RecentRestorePoint {
    [CmdletBinding()]
    param()

    try {
        $point = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop |
            Sort-Object -Property CreationTime -Descending | Select-Object -First 1
        if (-not $point) { return $null }
        $created = [Management.ManagementDateTimeConverter]::ToDateTime([string]$point.CreationTime)
        return [pscustomobject]@{
            SequenceNumber = [int]$point.SequenceNumber
            Description = [string]$point.Description
            CreationTime = $created
            RestorePointType = [int]$point.RestorePointType
        }
    }
    catch { return $null }
}

function Get-LocalUpdateStatus {
    <#
        O aplicativo e offline. Uma busca completa de updates poderia consultar a
        Internet; por isso esta funcao informa apenas historico local e reboot pendente.
    #>
    [CmdletBinding()]
    param()

    $lastInstalled = $null
    try {
        $lastInstalled = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
    }
    catch { }
    $pending = Get-PendingRestartStatus
    return [pscustomobject]@{
        OfflineOnly = $true
        PendingSearchStatus = 'Indeterminado sem consulta online'
        RestartPending = $pending.Pending
        RestartReasons = $pending.Reasons
        LastInstalledId = if ($lastInstalled) { [string]$lastInstalled.HotFixID } else { '' }
        LastInstalledOn = if ($lastInstalled) { $lastInstalled.InstalledOn } else { $null }
    }
}

function Get-SystemOverview {
    [CmdletBinding()]
    param()

    $platform = (Get-OptimizerContext).Platform
    $os = $null
    $computer = $null
    $processors = @()
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) } catch { }
    $cpuName = @($processors | Select-Object -ExpandProperty Name -Unique) -join '; '
    if ([string]::IsNullOrWhiteSpace($cpuName)) { $cpuName = [string]$env:PROCESSOR_IDENTIFIER }
    $cpuVendor = if ($cpuName -match '(?i)AMD') { 'AMD' } elseif ($cpuName -match '(?i)Intel') { 'Intel' } else { 'Outro' }
    $memory = Get-MemoryStatus
    $graphics = if (Get-Command Get-GraphicsInformation -ErrorAction SilentlyContinue) {
        $graphicsInformation = Get-GraphicsInformation
        @($graphicsInformation.Gpus)
    }
    else {
        @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; DriverVersion = [string]$_.DriverVersion; Vendor = 'Desconhecido' }
        })
    }
    $storage = @(Get-StorageInventory)
    $power = if (Get-Command Get-PowerPlanState -ErrorAction SilentlyContinue) { Get-PowerPlanState } else { $null }
    $gameMode = if (Get-Command Get-GameModeState -ErrorAction SilentlyContinue) { Get-GameModeState } else { $null }
    $hags = if (Get-Command Get-HagsState -ErrorAction SilentlyContinue) { Get-HagsState } else { $null }
    $metrics = Get-LivePerformanceMetrics
    $batteryPresent = $false
    try { $batteryPresent = $null -ne (Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1) } catch { }
    $physicalCores = if ($processors.Count -gt 0) { [int](($processors | Measure-Object NumberOfCores -Sum).Sum) } else { 0 }
    $logicalProcessors = if ($processors.Count -gt 0) { [int](($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum) } else { [Environment]::ProcessorCount }
    return [pscustomobject]@{
        ComputerName = [Environment]::MachineName
        Manufacturer = if ($computer) { [string]$computer.Manufacturer } else { '' }
        Model = if ($computer) { [string]$computer.Model } else { '' }
        IsLaptop = (($computer -and $computer.PCSystemType -in @(2, 8)) -or $batteryPresent)
        WindowsCaption = if ($os) { [string]$os.Caption } else { [string]$platform.Caption }
        WindowsVersion = if ($os) { [string]$os.Version } else { [string]$platform.Version }
        WindowsBuild = if ($os) { [int]$os.BuildNumber } else { [int]$platform.Build }
        WindowsArchitecture = if ($os) { [string]$os.OSArchitecture } elseif ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
        Processor = $cpuName.Trim()
        ProcessorVendor = $cpuVendor
        PhysicalCores = $physicalCores
        LogicalProcessors = $logicalProcessors
        Memory = $memory
        Graphics = $graphics
        Storage = $storage
        PowerPlan = $power
        GameMode = $gameMode
        Hags = $hags
        Metrics = $metrics
    }
}

function Get-ThresholdScore {
    param([double]$Value, [double]$Good, [double]$Warning, [switch]$HigherIsBetter)
    if ($HigherIsBetter) {
        if ($Value -ge $Good) { return 1.0 }
        if ($Value -le $Warning) { return 0.0 }
        return ($Value - $Warning) / ($Good - $Warning)
    }
    if ($Value -le $Good) { return 1.0 }
    if ($Value -ge $Warning) { return 0.0 }
    return ($Warning - $Value) / ($Warning - $Good)
}

function Get-PerformanceAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    $config = (Get-OptimizerContext).Config.Analysis
    $threshold = $config.Thresholds
    $weights = $config.Weights
    $components = New-Object System.Collections.Generic.List[object]
    function Add-Component([string]$Name, $Value, [double]$Weight, $Ratio, [string]$Reason) {
        if ($null -eq $Value -or $null -eq $Ratio -or $Weight -le 0) { return }
        $safeRatio = [math]::Max(0, [math]::Min(1, [double]$Ratio))
        $components.Add([pscustomobject]@{ Name = $Name; Value = $Value; Weight = $Weight; Ratio = $safeRatio; Points = $Weight * $safeRatio; Reason = $Reason })
    }

    Add-Component 'Inicializacao' $Snapshot.StartupCount ([double]$weights.Startup) `
        (Get-ThresholdScore $Snapshot.StartupCount $threshold.StartupGood $threshold.StartupWarning) 'Menos itens tende a reduzir atividade apos o logon.'
    Add-Component 'CPU em repouso' $Snapshot.CpuPercent ([double]$weights.Cpu) `
        (Get-ThresholdScore $Snapshot.CpuPercent $threshold.IdleCpuGoodPercent $threshold.IdleCpuWarningPercent) 'Amostra instantanea; feche cargas intencionais antes de analisar.'
    Add-Component 'RAM em repouso' $Snapshot.RamPercent ([double]$weights.Ram) `
        (Get-ThresholdScore $Snapshot.RamPercent $threshold.RamGoodPercent $threshold.RamWarningPercent) 'Cache de RAM do Windows e normal e nao deve ser esvaziado artificialmente.'
    Add-Component 'Espaco livre' $Snapshot.DiskFreePercent ([double]$weights.DiskFree) `
        (Get-ThresholdScore $Snapshot.DiskFreePercent $threshold.DiskFreeGoodPercent $threshold.DiskFreeWarningPercent -HigherIsBetter) 'Pouco espaco pode prejudicar updates, pagefile e caches.'

    if ($null -ne $Snapshot.GameModeEnabled) { Add-Component 'Game Mode' $Snapshot.GameModeEnabled ([double]$weights.GameMode) $(if ($Snapshot.GameModeEnabled) { 1 } else { 0 }) 'Recurso suportado pelo Windows; beneficio varia.' }
    if ($null -ne $Snapshot.CaptureDisabled) { Add-Component 'Capturas' $Snapshot.CaptureDisabled ([double]$weights.Capture) $(if ($Snapshot.CaptureDisabled) { 1 } else { 0 }) 'Gravacao ativa pode consumir GPU, CPU e disco.' }
    if ($null -ne $Snapshot.IntegrityHealthy) { Add-Component 'Integridade' $Snapshot.IntegrityHealthy ([double]$weights.Integrity) $(if ($Snapshot.IntegrityHealthy) { 1 } else { 0 }) 'Baseado apenas em verificacoes executadas.' }

    $maximum = if ($components.Count -gt 0) { [double](($components.ToArray() | Measure-Object Weight -Sum).Sum) } else { [double]0 }
    $earned = if ($components.Count -gt 0) { [double](($components.ToArray() | Measure-Object Points -Sum).Sum) } else { [double]0 }
    $score = if ($maximum -gt 0) { [math]::Round(($earned / $maximum) * 100) } else { $null }
    return [pscustomobject]@{
        Score = $score
        Label = if ($null -eq $score) { 'Dados insuficientes' } elseif ($score -ge 85) { 'Pronto para jogar' } elseif ($score -ge 65) { 'Bom, com ajustes possiveis' } elseif ($score -ge 45) { 'Requer atencao' } else { 'Revisao recomendada' }
        Components = $components.ToArray()
        Disclaimer = 'Pontuacao informativa de configuracao; nao estima nem promete FPS.'
    }
}

function New-PerformanceRecommendation {
    param($Id, $Name, $Current, $Proposed, $Benefit, $Risk, [bool]$Restart, $OperationId)
    return [pscustomobject]@{
        Id = $Id; Name = $Name; Current = $Current; Proposed = $Proposed
        ExpectedBenefit = $Benefit; Risk = $Risk; RequiresRestart = $Restart
        OperationId = $OperationId; CanApply = [bool]$OperationId; CanUndo = $false
    }
}

function Get-PerformanceRecommendations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    $recommendations = New-Object System.Collections.Generic.List[object]
    if ($Snapshot.GameModeEnabled -eq $false) {
        $recommendations.Add((New-PerformanceRecommendation 'game-mode' 'Ativar Game Mode' 'Desativado' 'Ativado' 'Priorizacao suportada pelo Windows; resultado varia por jogo.' 'Seguro' $false 'games.game-mode'))
    }
    if ($Snapshot.CaptureDisabled -eq $false) {
        $recommendations.Add((New-PerformanceRecommendation 'capture' 'Revisar capturas em segundo plano' 'Ativas ou indeterminadas' 'Desativadas' 'Evita gravacao concorrente.' 'Seguro' $false 'games.capture'))
    }
    if ($Snapshot.StartupCount -gt (Get-OptimizerContext).Config.Analysis.Thresholds.StartupWarning) {
        $recommendations.Add((New-PerformanceRecommendation 'startup' 'Revisar inicializacao' "$($Snapshot.StartupCount) itens" 'Desativar apenas itens opcionais selecionados' 'Menos atividade apos o logon.' 'Moderado' $false 'startup.review'))
    }
    if ($null -ne $Snapshot.CpuPercent -and $Snapshot.CpuPercent -gt (Get-OptimizerContext).Config.Analysis.Thresholds.IdleCpuWarningPercent) {
        $recommendations.Add((New-PerformanceRecommendation 'cpu' 'Investigar CPU em segundo plano' "$($Snapshot.CpuPercent)%" 'Revisar top processos' 'Identifica carga real sem encerrar processos automaticamente.' 'Seguro' $false 'process.review'))
    }
    if ($null -ne $Snapshot.RamPercent -and $Snapshot.RamPercent -gt (Get-OptimizerContext).Config.Analysis.Thresholds.RamWarningPercent) {
        $recommendations.Add((New-PerformanceRecommendation 'ram' 'Revisar consumo de RAM' "$($Snapshot.RamPercent)%" 'Revisar aplicativos e paginacao' 'Reduz risco de pressao de memoria; sem limpadores falsos.' 'Seguro' $false 'memory.review'))
    }
    if ($null -ne $Snapshot.DiskFreePercent -and $Snapshot.DiskFreePercent -lt (Get-OptimizerContext).Config.Analysis.Thresholds.DiskFreeWarningPercent) {
        $recommendations.Add((New-PerformanceRecommendation 'disk' 'Liberar espaco com seguranca' "$($Snapshot.DiskFreePercent)% livre" 'Limpar apenas temporarios/caches escolhidos' 'Mantem espaco para pagefile, caches e manutencao.' 'Moderado' $false 'storage.cleanup'))
    }
    if ($null -ne $Snapshot.BackgroundApps -and
        $Snapshot.BackgroundApps -gt (Get-OptimizerContext).Config.Analysis.Thresholds.BackgroundAppsWarning -and
        $null -ne $Snapshot.CpuPercent -and $Snapshot.CpuPercent -gt (Get-OptimizerContext).Config.Analysis.Thresholds.IdleCpuWarningPercent) {
        $recommendations.Add((New-PerformanceRecommendation 'background-apps' 'Revisar aplicativos em segundo plano' `
            "$($Snapshot.BackgroundApps) processos opcionais estimados" 'Revisar e fechar somente aplicativos reconhecidos' `
            'Pode liberar CPU e RAM quando os aplicativos estiverem realmente ociosos.' 'Seguro' $false 'process.review'))
    }
    return $recommendations.ToArray()
}

function Invoke-ComputerAnalysis {
    [CmdletBinding()]
    param()

    $overview = Get-SystemOverview
    $startup = if (Get-Command Get-StartupItems -ErrorAction SilentlyContinue) { @(Get-StartupItems) } else { @() }
    $optional = if (Get-Command Get-OptionalServices -ErrorAction SilentlyContinue) { @(Get-OptionalServices) } else { @() }
    $visual = if (Get-Command Get-VisualEffectsState -ErrorAction SilentlyContinue) { Get-VisualEffectsState } else { $null }
    $integrity = if (Get-Command Get-IntegrityCheckState -ErrorAction SilentlyContinue) { Get-IntegrityCheckState } else { $null }
    $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\')
    $systemStorage = @($overview.Storage | Where-Object Drive -eq $systemDrive | Select-Object -First 1)
    if (-not $systemStorage) { $systemStorage = @($overview.Storage | Select-Object -First 1) }
    $backgroundApps = $null
    if (Get-Command Get-ProcessInventory -ErrorAction SilentlyContinue) {
        try {
            $backgroundApps = @((Get-ProcessInventory) | Where-Object {
                -not $_.IsProtected -and $_.SessionId -gt 0 -and $_.Id -ne $PID
            }).Count
        }
        catch { }
    }
    $snapshot = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        StartupCount = @($startup | Where-Object IsEnabled).Count
        ProcessCount = $overview.Metrics.ProcessCount
        CpuPercent = $overview.Metrics.CpuPercent
        RamPercent = $overview.Metrics.RamPercent
        DiskFreePercent = if ($systemStorage) { $systemStorage[0].FreePercent } else { $null }
        PowerPlanName = if ($overview.PowerPlan -and $overview.PowerPlan.ActivePlan) { [string]$overview.PowerPlan.ActivePlan.Name } else { 'Desconhecido' }
        PowerPlanOptimized = if ($overview.PowerPlan -and $overview.PowerPlan.ActivePlan) {
            [string]$overview.PowerPlan.ActivePlan.Name -match '(?i)(alto desempenho|high performance|desempenho maximo|ultimate performance|Windows FPS Optimizer)'
        } else { $null }
        GameModeEnabled = if ($overview.GameMode -and [string]$overview.GameMode.State -in @('Enabled', 'Disabled')) {
            [string]$overview.GameMode.State -eq 'Enabled'
        } else { $null }
        CaptureDisabled = if (Get-Command Get-GameDvrState -ErrorAction SilentlyContinue) {
            $capture = Get-GameDvrState
            if ([string]$capture.State -in @('Disabled', 'Allowed', 'AllowedByDefault')) { [string]$capture.State -eq 'Disabled' } else { $null }
        } else { $null }
        OptionalServicesActive = @($optional | Where-Object Status -eq 'Running').Count
        VisualProfile = if ($visual) { [string]$visual.Profile } else { $null }
        BackgroundApps = $backgroundApps
        BackgroundAppsBasis = 'Estimativa de processos nao protegidos na sessao interativa'
        IntegrityHealthy = if ($integrity) { $integrity.Healthy } else { $null }
        IntegrityStatus = $integrity
    }
    $assessment = Get-PerformanceAssessment -Snapshot $snapshot
    $recommendations = @(Get-PerformanceRecommendations -Snapshot $snapshot)
    Write-OptimizerLog -Name 'Analise do computador' -Category 'Analise' -OldValue '' `
        -NewValue @{ Score = $assessment.Score; Recommendations = $recommendations.Count } -Result 'Success' | Out-Null
    return [pscustomobject]@{
        Overview = $overview
        Snapshot = $snapshot
        Assessment = $assessment
        Recommendations = $recommendations
        Security = [pscustomobject]@{
            Defender = Get-DefenderStatus
            Restart = Get-PendingRestartStatus
            Updates = Get-LocalUpdateStatus
            RestorePoint = Get-RecentRestorePoint
            Integrity = $integrity
        }
    }
}

Export-ModuleMember -Function Get-LivePerformanceMetrics, Get-SystemOverview, Get-PerformanceAssessment,
    Get-PerformanceRecommendations, Invoke-ComputerAnalysis, Get-DefenderStatus,
    Get-PendingRestartStatus, Get-RecentRestorePoint, Get-LocalUpdateStatus
