#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-RequiredUiParameter {
    param([hashtable]$Parameters, [string]$Name)
    if (-not $Parameters.ContainsKey($Name)) { throw "Parametro obrigatorio ausente: $Name" }
    return $Parameters[$Name]
}

function Restore-LatestOptimizerResource {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceId, [switch]$Force)

    foreach ($backup in @(Get-OptimizerBackups)) {
        try {
            $result = @(Restore-OptimizerBackup -ManifestPath $backup.ManifestPath -EntryId $ResourceId -Force:$Force -Confirm:$false)
            if ($result.Count -gt 0) { return $result }
        }
        catch {
            if ($_.Exception.Message -notmatch 'Nenhum item solicitado') { throw }
        }
    }
    throw "Nenhum backup contem o recurso: $ResourceId"
}

function Get-UiInitialData {
    [CmdletBinding()]
    param()

    $overview = Get-SystemOverview
    return [pscustomobject]@{
        Overview = $overview
        Memory = Get-MemoryStatus
        TopMemory = @(Get-TopMemoryApplications -Top 15)
        PageFile = Get-PageFileConfiguration
        Storage = @(Get-StorageInventory)
        Graphics = @((Get-GraphicsInformation).Gpus)
        GraphicsCache = Get-GraphicsCacheEstimate -Types @('DirectX', 'NVIDIA', 'AMD')
        GameCapabilities = Get-GameOptimizationCapabilities
        PowerCapabilities = Get-PowerCapabilities
        Processes = @(Get-ProcessInventory)
        Services = @(Get-OptionalServices)
        ServiceProfiles = @(Get-ServiceProfiles)
        Startup = @(Get-StartupItems -IncludeDisabled)
        Applications = @(Get-InstalledApplications)
        Tasks = @(Get-ScheduledTaskInventory)
        Privacy = @(Get-PrivacyOptimizationState)
        Games = @(Get-GameProfiles)
        GameSession = Get-ActiveGameSession
        Backups = @(Get-OptimizerBackups -IncludeInvalid)
        Security = [pscustomobject]@{
            Defender = Get-DefenderStatus
            Restart = Get-PendingRestartStatus
            RestorePoint = Get-RecentRestorePoint
            Updates = Get-LocalUpdateStatus
            Integrity = Get-IntegrityCheckState
        }
    }
}

function Get-UiBaselineSnapshot {
    [CmdletBinding()]
    param()

    return [ordered]@{
        PowerPlan = Get-PowerPlanState
        VisualEffects = Get-VisualEffectsState
        OptionalServices = @(Get-OptionalServices -IncludeUnavailable)
        ScheduledTasks = @(Get-ScheduledTaskInventory)
        StartupItems = @(Get-StartupItems -IncludeDisabled)
        PageFile = Get-PageFileConfiguration
        GameMode = Get-GameModeState
        GameCapture = Get-GameDvrState
        Hags = Get-HagsState
        Privacy = @(Get-PrivacyOptimizationState)
        Integrity = Get-IntegrityCheckState
    }
}

function New-UiManualBaselineBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $backup = Start-OptimizerBackup -Name $Name -Profile $Profile -CreateRestorePoint
    $resultProperty = $backup.PSObject.Properties['Result']
    if ($resultProperty -and [string]$resultProperty.Value -eq 'Simulated') {
        return [pscustomobject]@{
            Result = 'Simulated'; Succeeded = $true; BaselineCaptured = $false
            RestorePointSucceeded = $false; ManifestPath = ''; Message = 'Simulacao: nenhum arquivo ou ponto de restauracao foi criado.'
        }
    }

    try {
        $baseline = Set-OptimizerBackupBaseline -Snapshot (Get-UiBaselineSnapshot) `
            -Description 'Inventario de servicos, tarefas, energia, visuais, inicializacao e memoria virtual'
        $restorePoint = $backup.RestorePoint
        $completed = Complete-OptimizerBackup -Status Completed
        $pointSucceeded = [bool]$restorePoint.Succeeded
        $pointError = [string]$restorePoint.Error
        $message = if ($pointSucceeded) {
            'Baseline JSON e ponto de restauracao criados. Alteracoes futuras do aplicativo continuarao recebendo entradas reversiveis proprias.'
        }
        else {
            "O baseline JSON foi criado, mas o Windows nao criou o ponto de restauracao: $pointError"
        }
        return [pscustomobject]@{
            Result = $(if ($pointSucceeded) { 'BaselineAndRestorePointCreated' } else { 'BaselineCreatedRestorePointFailed' })
            Succeeded = $true
            BaselineCaptured = [bool]$baseline.Captured
            RestorePointSucceeded = $pointSucceeded
            RestorePointError = $pointError
            ManifestPath = [string]$completed.ManifestPath
            Message = $message
        }
    }
    catch {
        $errorText = $_.Exception.Message
        $pointSucceeded = [bool]$backup.RestorePoint.Succeeded
        $pointSuffix = if ($pointSucceeded) { ' O ponto de restauracao do Windows foi criado.' } else { " O ponto de restauracao tambem falhou: $($backup.RestorePoint.Error)" }
        try { Complete-OptimizerBackup -Status Failed -ErrorMessage $errorText | Out-Null } catch { }
        return [pscustomobject]@{
            Result = 'BaselineFailed'; Succeeded = $false; BaselineCaptured = $false
            RestorePointSucceeded = $pointSucceeded; ManifestPath = [string]$backup.ManifestPath
            Message = "Falha ao capturar o baseline: $errorText$pointSuffix"
        }
    }
}

function Invoke-UIAction {
    <#
        Dispatcher fechado usado pelos runspaces da interface. ActionId nunca e lido de
        Config.json/backup; somente os handlers codificados no aplicativo chegam aqui.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ActionId,
        [hashtable]$Parameters = @{}
    )

    switch ($ActionId) {
        'InitialData' { return Get-UiInitialData }
        'Analyze' { return Invoke-ComputerAnalysis }
        'Metrics' { return Get-LivePerformanceMetrics }
        'Memory' {
            return [pscustomobject]@{ Memory = Get-MemoryStatus; Top = @(Get-TopMemoryApplications -Top 25); PageFile = Get-PageFileConfiguration }
        }
        'Processes' { return @(Get-ProcessInventory -Search ([string]$Parameters.Search)) }
        'Services' {
            if ([bool]$Parameters.ShowAll) { return @(Get-AllServiceInventory -Search ([string]$Parameters.Search)) }
            return @(Get-OptionalServices -IncludeUnavailable)
        }
        'ServiceProfiles' { return @(Get-ServiceProfiles) }
        'Startup' { return @(Get-StartupItems -IncludeDisabled) }
        'Storage' { return @(Get-StorageInventory) }
        'CleanupEstimate' { return @(Get-SafeCleanupEstimate -MinimumAgeDays 7 -Categories ([string[]]$Parameters.Categories)) }
        'Graphics' { return [pscustomobject]@{ Adapters = @((Get-GraphicsInformation).Gpus); Hags = Get-HagsState; Visual = Get-VisualEffectsState } }
        'GraphicsCacheEstimate' { return Get-GraphicsCacheEstimate -Types ([string[]]$Parameters.Types) }
        'Applications' { return @(Get-InstalledApplications -Search ([string]$Parameters.Search)) }
        'Tasks' { return @(Get-ScheduledTaskInventory -Search ([string]$Parameters.Search)) }
        'Security' {
            return [pscustomobject]@{ Defender = Get-DefenderStatus; Restart = Get-PendingRestartStatus; RestorePoint = Get-RecentRestorePoint; Updates = Get-LocalUpdateStatus; Integrity = Get-IntegrityCheckState }
        }
        'Games' { return @(Get-GameProfiles) }
        'VisualPreview' {
            $current = Get-VisualEffectsState
            $profile = if ([string]$Parameters.Profile -eq 'MaximumPerformance') { 'MaximumPerformance' } else { 'Balanced' }
            $proposed = [ordered]@{
                Transparency = $false; WindowAnimations = $false; ClientAreaAnimations = $false
                MenuAnimations = $false; MenuFade = $false; SelectionFade = $false
                TooltipAnimations = $false; TooltipFade = $false
            }
            if ($profile -eq 'Balanced') {
                $proposed.ComboBoxAnimations = $false; $proposed.SmoothListScrolling = $false
                $proposed.FullWindowDrag = $true; $proposed.MenuDelay = 100
            }
            else {
                $proposed.UIEffects = $false; $proposed.ComboBoxAnimations = $false
                $proposed.SmoothListScrolling = $false; $proposed.CursorShadow = $false
                $proposed.DropShadows = $false; $proposed.FullWindowDrag = $false
                $proposed.MenuDelay = 20
            }
            return [pscustomobject]@{ Profile = $profile; Current = $current; Proposed = [pscustomobject]$proposed; Preserved = @('Thumbnails', 'FontSmoothing') }
        }
        'Power' { return [pscustomobject]@{ Capabilities = Get-PowerCapabilities; Plan = Get-PowerPlanState } }
        'Backups' { return @(Get-OptimizerBackups -IncludeInvalid) }
        'BackupEntries' {
            return @(Get-OptimizerBackupEntries -ManifestPath ([string](Get-RequiredUiParameter $Parameters 'ManifestPath')))
        }

        'CreateBackup' {
            return New-UiManualBaselineBackup -Name 'Backup manual com baseline' -Profile 'Manual'
        }
        'QuickOptimize' { return Invoke-QuickOptimization -SelectedStartupIds ([string[]]$Parameters.StartupIds) }
        'ApplyProfile' {
            return Invoke-OptimizationProfile -Name ([string](Get-RequiredUiParameter $Parameters 'Name')) `
                -SelectedServices ([string[]]$Parameters.Services) -SelectedTaskIds ([string[]]$Parameters.Tasks) `
                -SelectedStartupIds ([string[]]$Parameters.StartupIds) -IncludeCleanup:([bool]$Parameters.IncludeCleanup) `
                -Confirmed:([bool]$Parameters.Confirmed) -ConfirmedIrreversible:([bool]$Parameters.ConfirmedIrreversible) `
                -GameExecutable ([string]$Parameters.GameExecutable)
        }
        'UndoLast' { return Undo-LastOptimizerBackup -Force:([bool]$Parameters.Force) }
        'RestoreAll' { return Restore-AllOptimizerBackups -Force:([bool]$Parameters.Force) }
        'RestoreManifest' { return Restore-OptimizerBackup -ManifestPath ([string](Get-RequiredUiParameter $Parameters 'ManifestPath')) -Force:([bool]$Parameters.Force) -Confirm:$false }
        'RestoreBackupItem' {
            return Restore-OptimizerBackupItem -ManifestPath ([string](Get-RequiredUiParameter $Parameters 'ManifestPath')) `
                -EntryId ([string](Get-RequiredUiParameter $Parameters 'EntryId')) `
                -Force:([bool]$Parameters.Force) -Confirm:$false
        }
        'ImportBackup' { return Import-OptimizerBackup -Path ([string](Get-RequiredUiParameter $Parameters 'Path')) }
        'ExportReport' {
            return Export-OptimizerLogReport -Path ([string](Get-RequiredUiParameter $Parameters 'Path')) -Format ([string](Get-RequiredUiParameter $Parameters 'Format'))
        }

        'EnableGameMode' { return Set-GameMode -Enabled $true }
        'DisableGameDvr' { return Set-GameDvrEnabled -Enabled $false }
        'StartGameSession' {
            $executable = [string](Get-RequiredUiParameter $Parameters 'ExecutablePath')
            return Invoke-TransientGameProfile -ExecutablePath $executable `
                -Priority ([string]$Parameters.Priority) -SuspendServices ([string[]]$Parameters.Services) `
                -PowerPlan ([string]$Parameters.PowerPlan) -PreventSleep ([bool]$Parameters.PreventSleep) `
                -ReduceVisualEffects ([bool]$Parameters.ReduceVisualEffects) `
                -UseConfiguredProcessList ([bool]$Parameters.CloseProcesses) `
                -OpenDoNotDisturbSettings ([bool]$Parameters.OpenDoNotDisturbSettings)
        }
        'StopGameSession' { return Stop-GameSession -Force:([bool]$Parameters.Force) }
        'AddGame' { return Add-GameProfile -ExecutablePath ([string](Get-RequiredUiParameter $Parameters 'ExecutablePath')) -Name ([string]$Parameters.Name) }
        'UpdateGame' {
            return Set-GameProfile -Id ([string](Get-RequiredUiParameter $Parameters 'Id')) `
                -Name ([string]$Parameters.Name) -Arguments ([string]$Parameters.Arguments) `
                -Priority ([string]$Parameters.Priority) -SuspendServices ([string[]]$Parameters.Services) `
                -PowerPlan ([string]$Parameters.PowerPlan) -PreventSleep ([bool]$Parameters.PreventSleep) `
                -ReduceVisualEffects ([bool]$Parameters.ReduceVisualEffects) `
                -OpenDoNotDisturbSettings ([bool]$Parameters.OpenDoNotDisturbSettings) `
                -UseConfiguredProcessList ([bool]$Parameters.UseConfiguredProcessList)
        }
        'DetectGames' { return @(Find-InstalledGames -MaximumResults 300) }
        'RemoveGame' { return Remove-GameProfile -Id ([string](Get-RequiredUiParameter $Parameters 'Id')) }
        'GameFullscreen' {
            return Set-FullscreenOptimizationPreference `
                -ExecutablePath ([string](Get-RequiredUiParameter $Parameters 'ExecutablePath')) -Disable $true -OpenFileLocation
        }
        'CreateGameShortcut' { return New-GameProfileShortcut -ProfileId ([string](Get-RequiredUiParameter $Parameters 'Id')) -DestinationPath ([string]$Parameters.DestinationPath) -Force:([bool]$Parameters.Force) }

        'HighPerformance' { return Set-HighPerformancePlan }
        'UltimatePerformance' { return Enable-UltimatePerformancePlan }
        'CreateGamingPlan' { return New-GamingPowerPlan -Activate }
        'RestorePower' { return Restore-PreviousPowerPlan -Force:([bool]$Parameters.Force) }
        'ProcessorPower' {
            $result = Set-ProcessorPowerState -MinimumAC ([int]$Parameters.MinimumAC) -MaximumAC ([int]$Parameters.MaximumAC) `
                -MinimumDC ([int]$Parameters.MinimumDC) -MaximumDC ([int]$Parameters.MaximumDC)
            $cooling = if ([bool]$Parameters.ApplyCooling) {
                Set-CoolingPolicy -ACPolicy ([string]$Parameters.CoolingAC) -DCPolicy ([string]$Parameters.CoolingDC)
            } else { [pscustomobject]@{ Result = 'Unsupported'; Reason = 'Politica de resfriamento indisponivel.' } }
            return [pscustomobject]@{ Processor = $result; Cooling = $cooling }
        }
        'SleepSettings' {
            return Set-DisplayAndSleepTimeout -DisplayMinutesAC ([int]$Parameters.DisplayAC) `
                -DisplayMinutesDC ([int]$Parameters.DisplayDC) -SleepMinutesAC ([int]$Parameters.SleepAC) `
                -SleepMinutesDC ([int]$Parameters.SleepDC)
        }

        'VisualProfile' { return Set-VisualEffectsProfile -Profile ([string](Get-RequiredUiParameter $Parameters 'Profile')) }
        'VisualOption' {
            return Set-VisualEffectOption -Option ([string](Get-RequiredUiParameter $Parameters 'Option')) `
                -Enabled ([bool]$Parameters.Enabled) -MenuDelayMilliseconds ([int]$Parameters.MenuDelay)
        }
        'VisualOptions' {
            return Invoke-OptimizerOperation -Name 'Aplicar opcoes visuais selecionadas' -Risk 'Moderado' -ScriptBlock {
                $changes = New-Object System.Collections.Generic.List[object]
                foreach ($option in @($Parameters.Options)) {
                    $menuDelay = 100
                    if ($option -is [Collections.IDictionary] -and $option.Contains('MenuDelay')) {
                        $menuDelay = [int]$option['MenuDelay']
                    }
                    elseif ($option.PSObject.Properties['MenuDelay']) { $menuDelay = [int]$option.MenuDelay }
                    $changes.Add((Set-VisualEffectOption -Option ([string]$option.Option) `
                        -Enabled ([bool]$option.Enabled) -MenuDelayMilliseconds $menuDelay))
                }
                return $changes.ToArray()
            }
        }
        'RestoreVisual' { return Restore-VisualEffects -Force:([bool]$Parameters.Force) }
        'ClearGraphicsCache' {
            return Clear-GraphicsCaches -Types ([string[]]$Parameters.Types) -MinimumAgeHours ([int]$Parameters.MinimumAgeHours) -UserConfirmed
        }

        'StopProcess' {
            return Stop-SelectedProcess -Id ([int](Get-RequiredUiParameter $Parameters 'Id')) `
                -ExpectedStartTime ([string]$Parameters.StartTime) -AllowRestart:([bool]$Parameters.AllowRestart)
        }
        'ProcessPriority' {
            return Set-SelectedProcessPriority -Id ([int](Get-RequiredUiParameter $Parameters 'Id')) `
                -ExpectedStartTime ([string]$Parameters.StartTime) -Priority ([string]$Parameters.Priority)
        }
        'ProcessLists' { return Set-ProcessListState -Allowed ([string[]]$Parameters.Allowed) -CloseBeforeGame ([string[]]$Parameters.CloseBeforeGame) }
        'AutomaticPageFile' { return Set-AutomaticPageFile }
        'CustomPageFile' {
            return Set-CustomPageFile -Path ([string]$Parameters.Path) -InitialSizeMB ([int]$Parameters.InitialSizeMB) -MaximumSizeMB ([int]$Parameters.MaximumSizeMB)
        }

        'Cleanup' { return Invoke-SafeCleanup -Categories ([string[]]$Parameters.Categories) -MinimumAgeDays 7 -Confirmed }
        'RecycleBin' { return Clear-RecycleBinSafe -DriveLetter ([string]$Parameters.DriveLetter) -Confirmed }
        'OptimizeVolume' { return Invoke-VolumeOptimizationSafe -DriveLetter ([string]$Parameters.DriveLetter) }
        'ComponentCleanup' { return Invoke-ComponentCleanupSafe -Confirmed }
        'SfcVerify' { return Invoke-SystemFileCheck -Mode VerifyOnly }
        'SfcScan' { return Invoke-SystemFileCheck -Mode ScanNow }
        'DismCheck' { return Invoke-DismHealthCheck -Mode CheckHealth }
        'DismScan' { return Invoke-DismHealthCheck -Mode ScanHealth }
        'DismRestore' { return Invoke-DismHealthCheck -Mode RestoreHealth -Source ([string]$Parameters.Source) -Confirmed }
        'DiskScan' { return Invoke-DiskScan -DriveLetter ([string]$Parameters.DriveLetter) }

        'SetService' { return Set-OptionalServiceState -Name ([string]$Parameters.Name) -DesiredState ([string]$Parameters.DesiredState) }
        'RestoreService' { return Restore-LatestOptimizerResource -ResourceId ([string]$Parameters.Name) -Force:([bool]$Parameters.Force) }
        'SaveServiceProfile' {
            return Save-ServiceProfile -Name ([string](Get-RequiredUiParameter $Parameters 'Name')) `
                -Services ([string[]]$Parameters.Services)
        }
        'ApplyServiceProfile' {
            return Apply-ServiceProfile -Name ([string](Get-RequiredUiParameter $Parameters 'Name')) `
                -Mode ([string](Get-RequiredUiParameter $Parameters 'Mode'))
        }
        'DisableStartup' { return Disable-StartupItem -Id ([string]$Parameters.Id) }
        'DisableStartupMany' {
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($id in ([string[]]$Parameters.Ids)) { $results.Add((Disable-StartupItem -Id $id)) }
            return $results.ToArray()
        }
        'RestoreStartup' { return Restore-StartupItem -Id ([string]$Parameters.Id) -Force:([bool]$Parameters.Force) }
        'RestoreStartupMany' {
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($id in ([string[]]$Parameters.Ids)) { $results.Add((Restore-StartupItem -Id $id -Force:([bool]$Parameters.Force))) }
            return $results.ToArray()
        }
        'RestoreAllStartup' { return Restore-AllStartupItems -Force:([bool]$Parameters.Force) }
        'RemoveAppx' { return Remove-OptionalAppxPackageSafe -PackageFullName ([string]$Parameters.PackageFullName) -Confirmed }
        'RestoreAppx' { return Restore-LatestOptimizerResource -ResourceId ([string]$Parameters.PackageFullName) -Force:([bool]$Parameters.Force) }
        'SetTask' { return Set-OptionalScheduledTaskState -TaskPath ([string]$Parameters.TaskPath) -TaskName ([string]$Parameters.TaskName) -Enabled ([bool]$Parameters.Enabled) }
        'RestoreTask' { return Restore-LatestOptimizerResource -ResourceId ("{0}|{1}" -f $Parameters.TaskPath, $Parameters.TaskName) -Force:([bool]$Parameters.Force) }
        'RestoreTaskMany' {
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($id in ([string[]]$Parameters.Ids)) { $results.Add((Restore-LatestOptimizerResource -ResourceId $id -Force:([bool]$Parameters.Force))) }
            return $results.ToArray()
        }
        'RestoreAllTasks' {
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($task in @(Get-ScheduledTaskInventory -OptionalOnly)) {
                $id = "{0}|{1}" -f $task.TaskPath, $task.TaskName
                try { $results.Add((Restore-LatestOptimizerResource -ResourceId $id -Force:([bool]$Parameters.Force))) }
                catch { $results.Add([pscustomobject]@{ Id = $id; Status = 'NoBackup'; Error = $_.Exception.Message }) }
            }
            return $results.ToArray()
        }

        'ApplyPrivacy' {
            $results = New-Object System.Collections.Generic.List[object]
            if ([bool]$Parameters.Tailored) { $results.Add((Set-TailoredExperiencesDisabled -Disabled $true)) }
            if ([bool]$Parameters.ThirdParty) { $results.Add((Set-ThirdPartySuggestionsDisabled -Disabled $true)) }
            if ([bool]$Parameters.Advertising) { $results.Add((Set-AdvertisingIdDisabled -Disabled $true)) }
            if ([bool]$Parameters.Activity) { $results.Add((Set-ActivityHistoryDisabled -Disabled $true)) }
            if ([bool]$Parameters.Diagnostics) { $results.Add((Set-OptionalDiagnosticLevel -Level Required)) }
            if ([bool]$Parameters.WindowsTips) { $results.Add((Set-WindowsTipsDisabled -Disabled $true)) }
            if ([bool]$Parameters.ConsumerFeatures) { $results.Add((Set-WindowsConsumerFeaturesDisabled -Disabled $true)) }
            if ([bool]$Parameters.StartRecommendations) { $results.Add((Set-StartRecommendationsEnabled -Enabled $false)) }
            return $results.ToArray()
        }

        'CreateRestorePoint' {
            return New-UiManualBaselineBackup -Name 'Ponto de restauracao e baseline manual' -Profile 'Seguranca'
        }
        'InvokeGameProfile' { return Invoke-GameProfile -ProfileId ([string](Get-RequiredUiParameter $Parameters 'Id')) }
        default { throw "Acao de interface nao permitida: $ActionId" }
    }
}

Export-ModuleMember -Function Invoke-UIAction, Get-UiInitialData, Restore-LatestOptimizerResource
