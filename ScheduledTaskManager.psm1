#requires -Version 5.1

Set-StrictMode -Version Latest

function Test-ProtectedScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    foreach ($pattern in @((Get-OptimizerContext).Config.Safety.ProtectedTaskPathPatterns)) {
        if ($TaskPath -like "$pattern*") { return $true }
    }
    return $false
}

function Get-OptionalTaskDefinition {
    param([string]$TaskPath, [string]$TaskName)
    foreach ($definition in @((Get-OptimizerContext).Config.OptionalScheduledTasks)) {
        if ([string]$definition.TaskPath -ieq $TaskPath -and [string]$definition.TaskName -ieq $TaskName) { return $definition }
    }
    return $null
}

function Get-ScheduledTaskStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    return [pscustomobject]@{
        TaskPath = [string]$task.TaskPath
        TaskName = [string]$task.TaskName
        State = [string]$task.State
        Enabled = [bool]$task.Settings.Enabled
    }
}

function Get-ScheduledTaskInventory {
    [CmdletBinding()]
    param([string]$Search = '', [switch]$OptionalOnly)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($Search -and $task.TaskName -notlike "*$Search*" -and $task.TaskPath -notlike "*$Search*") { continue }
        $definition = Get-OptionalTaskDefinition -TaskPath $task.TaskPath -TaskName $task.TaskName
        if ($OptionalOnly -and -not $definition) { continue }
        $info = $null
        try { $info = Get-ScheduledTaskInfo -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop } catch { }
        $classification = if (("$($task.TaskPath)$($task.TaskName)") -match '(?i)(Customer Experience|Application Experience|Feedback|Telemetry|Compatibility Appraiser|DiagTrack)') {
            'Telemetria/compatibilidade'
        }
        elseif (("$($task.TaskPath)$($task.TaskName)") -match '(?i)(Maintenance|Defrag|DiskCleanup|Update|Servicing)') {
            'Manutencao'
        }
        elseif ($definition) { 'Opcional da allowlist' } else { 'Sistema/aplicativo' }
        $items.Add([pscustomobject]@{
            Id = "$($task.TaskPath)|$($task.TaskName)"
            TaskPath = [string]$task.TaskPath
            TaskName = [string]$task.TaskName
            State = [string]$task.State
            Enabled = [bool]$task.Settings.Enabled
            LastRunTime = if ($info) { $info.LastRunTime } else { $null }
            # O Agendador expoe HRESULTs como valores sem sinal de 32 bits
            # (por exemplo, 2147942402). Int64 preserva todos esses codigos e
            # evita overflow em computadores que possuam uma tarefa nesse estado.
            LastTaskResult = if ($info) { [Int64]$info.LastTaskResult } else { $null }
            NextRunTime = if ($info) { $info.NextRunTime } else { $null }
            IsOptional = $null -ne $definition
            IsProtected = Test-ProtectedScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName
            Classification = $classification
            Description = if ($definition) { [string]$definition.Description } elseif ($task.Description) { [string]$task.Description } else { '' }
            Benefit = if ($definition) { [string]$definition.Benefit } else { '' }
            Problems = if ($definition) { [string]$definition.Problems } else { '' }
        })
    }
    return @($items | Sort-Object TaskPath, TaskName)
}

function Set-OptionalScheduledTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $definition = Get-OptionalTaskDefinition -TaskPath $TaskPath -TaskName $TaskName
    if (-not $definition) { throw 'A tarefa nao pertence a allowlist opcional.' }
    if (Test-ProtectedScheduledTask -TaskPath $TaskPath -TaskName $TaskName) { throw 'A tarefa pertence a lista protegida.' }
    return Invoke-OptimizerOperation -Name "Tarefa agendada: $TaskPath$TaskName" -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        $before = Get-ScheduledTaskStateSnapshot -TaskPath $TaskPath -TaskName $TaskName
        if ($before.Enabled -eq $Enabled) { return [pscustomobject]@{ Changed = $false; State = $before; Result = 'NoChange' } }
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'ScheduledTask' -Id "$TaskPath|$TaskName" -Original $before `
                -Applied ([pscustomobject]@{ TaskPath = $TaskPath; TaskName = $TaskName; Enabled = $Enabled }) `
                -Metadata @{ Description = [string]$definition.Description; Benefit = [string]$definition.Benefit; Problems = [string]$definition.Problems } | Out-Null
        }
        if (-not (Get-OptimizerContext).Simulation) {
            if ($Enabled) { Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
            $after = Get-ScheduledTaskStateSnapshot -TaskPath $TaskPath -TaskName $TaskName
            if ($after.Enabled -ne $Enabled) { throw 'A verificacao da tarefa divergiu do estado solicitado.' }
        }
        Write-OptimizerLog -Name "Alterar tarefa $TaskPath$TaskName" -Category 'Tarefas' `
            -OldValue $before.Enabled -NewValue $Enabled `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) | Out-Null
        return [pscustomobject]@{ Changed = $true; TaskPath = $TaskPath; TaskName = $TaskName; Enabled = $Enabled }
    }
}

function Restore-ScheduledTaskBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    Assert-OptimizerMutationAllowed -RequiresAdministrator -Operation 'Restaurar tarefa agendada' | Out-Null
    $original = $Entry.Original
    $applied = $Entry.Applied
    $path = [string]$original.TaskPath
    $name = [string]$original.TaskName
    if (Test-ProtectedScheduledTask -TaskPath $path -TaskName $name) { return [pscustomobject]@{ Status = 'Blocked'; Id = $Entry.Id } }
    try { $current = Get-ScheduledTaskStateSnapshot -TaskPath $path -TaskName $name }
    catch { return [pscustomobject]@{ Status = 'Unavailable'; Id = $Entry.Id; Error = $_.Exception.Message } }
    if ($current.Enabled -eq [bool]$original.Enabled) { return [pscustomobject]@{ Status = 'NoChange'; Id = $Entry.Id } }
    if (-not $Force -and $current.Enabled -ne [bool]$applied.Enabled) {
        return [pscustomobject]@{ Status = 'Conflict'; Id = $Entry.Id; Current = $current.Enabled; Applied = $applied.Enabled; Original = $original.Enabled }
    }
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]@{ Status = 'Simulated'; Id = $Entry.Id } }
    if ([bool]$original.Enabled) { Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null }
    return [pscustomobject]@{ Status = 'Restored'; Id = $Entry.Id }
}

function Save-ScheduledTaskProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[\p{L}\p{N} _.-]{1,50}$')][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$TaskIds
    )

    Assert-OptimizerMutationAllowed -Operation 'Salvar perfil de tarefas' | Out-Null
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($id in $TaskIds) {
        $parts = $id -split '\|', 2
        if ($parts.Count -ne 2 -or -not (Get-OptionalTaskDefinition -TaskPath $parts[0] -TaskName $parts[1])) { throw "Tarefa fora da allowlist: $id" }
        $valid.Add($id)
    }
    $path = Join-Path (Get-OptimizerContext).StateRoot 'task-profiles.json'
    $profiles = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($property in $raw.PSObject.Properties) { $profiles[$property.Name] = @($property.Value) }
        }
        catch { }
    }
    $profiles[$Name] = $valid.ToArray()
    if (-not (Get-OptimizerContext).Simulation) { Save-OptimizerJsonFile -Path $path -InputObject $profiles | Out-Null }
    return [pscustomobject]@{ Name = $Name; Tasks = $valid.ToArray() }
}

Export-ModuleMember -Function Test-ProtectedScheduledTask, Get-ScheduledTaskInventory,
    Set-OptionalScheduledTaskState, Restore-ScheduledTaskBackupEntry, Save-ScheduledTaskProfile
