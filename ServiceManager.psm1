#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-ServiceStartModeCanonical {
    param([string]$StartMode)
    switch -Regex ($StartMode) {
        '^(Auto|Automatic)$' { return 'Automatic' }
        '^(Manual|Demand)$' { return 'Manual' }
        '^Disabled$' { return 'Disabled' }
        default { return 'Manual' }
    }
}

function Test-ProtectedService {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    return @((Get-OptimizerContext).Config.Safety.ProtectedServices) -contains $Name
}

function Get-OptionalServiceDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($definition in @((Get-OptimizerContext).Config.OptionalServices)) {
        if ([string]$definition.Name -ieq $Name) { return $definition }
    }
    return $null
}

function Get-ServiceStateSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $service = Get-Service -Name $Name -ErrorAction Stop
    $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction Stop
    $delayed = $false
    $delayedPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    try {
        $delayedState = Get-RegistryValueState -Path $delayedPath -Name 'DelayedAutoStart'
        $delayed = $delayedState.ValueExisted -and [int]$delayedState.Value -eq 1
    }
    catch { }
    return [pscustomobject]@{
        Name             = $Name
        DisplayName      = [string]$service.DisplayName
        Status           = [string]$service.Status
        StartMode        = Get-ServiceStartModeCanonical ([string]$cim.StartMode)
        DelayedAutoStart = $delayed
        ProcessId        = [int]$cim.ProcessId
    }
}

function Get-OptionalServices {
    [CmdletBinding()]
    param([switch]$IncludeUnavailable)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @((Get-OptimizerContext).Config.OptionalServices)) {
        $name = [string]$definition.Name
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) {
            if ($IncludeUnavailable) {
                $result.Add([pscustomobject]@{
                    Name = $name; Title = [string]$definition.Title; Installed = $false
                    Status = 'Indisponivel'; StartMode = ''; IsProtected = $false
                    Description = [string]$definition.Description; Benefit = [string]$definition.Benefit
                    Problems = [string]$definition.Problems; Restart = [string]$definition.Restart
                    AutoRestoreInGameSession = [bool]$definition.AutoRestoreInGameSession
                })
            }
            continue
        }
        try {
            $state = Get-ServiceStateSnapshot -Name $name
            $result.Add([pscustomobject]@{
                Name = $name; Title = [string]$definition.Title; Installed = $true
                Status = $state.Status; StartMode = $state.StartMode; IsProtected = (Test-ProtectedService $name)
                Description = [string]$definition.Description; Benefit = [string]$definition.Benefit
                Problems = [string]$definition.Problems; Restart = [string]$definition.Restart
                AutoRestoreInGameSession = [bool]$definition.AutoRestoreInGameSession
            })
        }
        catch { }
    }
    return $result.ToArray()
}

function Get-AllServiceInventory {
    [CmdletBinding()]
    param([string]$Search = '')

    $cimByName = @{}
    try {
        Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | ForEach-Object { $cimByName[[string]$_.Name] = $_ }
    }
    catch { }
    $optionalNames = @((Get-OptimizerContext).Config.OptionalServices | ForEach-Object { [string]$_.Name })
    $items = foreach ($service in @(Get-Service -ErrorAction SilentlyContinue)) {
        if ($Search -and $service.Name -notlike "*$Search*" -and $service.DisplayName -notlike "*$Search*") { continue }
        $cim = if ($cimByName.ContainsKey($service.Name)) { $cimByName[$service.Name] } else { $null }
        [pscustomobject]@{
            Name        = $service.Name
            DisplayName = $service.DisplayName
            Description = if ($cim) { [string]$cim.Description } else { '' }
            Status      = [string]$service.Status
            StartMode   = if ($cim) { Get-ServiceStartModeCanonical ([string]$cim.StartMode) } else { 'Desconhecido' }
            IsOptional  = $optionalNames -contains $service.Name
            IsProtected = Test-ProtectedService -Name $service.Name
        }
    }
    return @($items | Sort-Object DisplayName)
}

function Set-OptionalServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('StopOnly', 'Disabled', 'Manual', 'Automatic', 'Start')][string]$DesiredState
    )

    $definition = Get-OptionalServiceDefinition -Name $Name
    if (-not $definition) { throw "O servico $Name nao pertence a allowlist opcional." }
    if (Test-ProtectedService -Name $Name) { throw "O servico $Name pertence a lista protegida." }
    return Invoke-OptimizerOperation -Name "Servico opcional: $Name -> $DesiredState" `
        -Risk 'Moderado' -RequiresAdministrator -ScriptBlock {
        $before = Get-ServiceStateSnapshot -Name $Name
        $appliedStart = $before.StartMode
        $appliedStatus = $before.Status
        switch ($DesiredState) {
            'StopOnly' { $appliedStatus = 'Stopped' }
            'Disabled' { $appliedStart = 'Disabled'; $appliedStatus = 'Stopped' }
            'Manual' { $appliedStart = 'Manual' }
            'Automatic' { $appliedStart = 'Automatic' }
            'Start' { $appliedStatus = 'Running' }
        }
        if ($before.StartMode -eq $appliedStart -and $before.Status -eq $appliedStatus) {
            return [pscustomobject]@{ Changed = $false; State = $before; Result = 'NoChange' }
        }
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'Service' -Id $Name -Original $before `
                -Applied ([pscustomobject]@{ Name = $Name; StartMode = $appliedStart; Status = $appliedStatus }) `
                -Metadata @{ Title = [string]$definition.Title; AutoRestore = [bool]$definition.AutoRestoreInGameSession } | Out-Null
        }
        if (-not (Get-OptimizerContext).Simulation) {
            switch ($DesiredState) {
                'StopOnly' { Stop-Service -Name $Name -ErrorAction Stop }
                'Disabled' {
                    if ((Get-Service -Name $Name).Status -ne 'Stopped') { Stop-Service -Name $Name -ErrorAction Stop }
                    Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
                }
                'Manual' { Set-Service -Name $Name -StartupType Manual -ErrorAction Stop }
                'Automatic' { Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop }
                'Start' { Start-Service -Name $Name -ErrorAction Stop }
            }
            $after = Get-ServiceStateSnapshot -Name $Name
            if ($after.StartMode -ne $appliedStart -or $after.Status -ne $appliedStatus) {
                throw "A verificacao do servico divergiu: $($after.StartMode)/$($after.Status)."
            }
        }
        Write-OptimizerLog -Name "Alterar servico $Name" -Category 'Servicos' -OldValue $before `
            -NewValue @{ StartMode = $appliedStart; Status = $appliedStatus } `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) | Out-Null
        return [pscustomobject]@{ Changed = $true; Name = $Name; StartMode = $appliedStart; Status = $appliedStatus }
    }
}

function Suspend-OptionalServicesForSession {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($Names | Sort-Object -Unique)) {
        try { $results.Add((Set-OptionalServiceState -Name $name -DesiredState StopOnly)) }
        catch { $results.Add([pscustomobject]@{ Name = $name; Result = 'Error'; Error = $_.Exception.Message }) }
    }
    return $results.ToArray()
}

function Save-ServiceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[\p{L}\p{N} _.-]{1,50}$')][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Services
    )

    Assert-OptimizerMutationAllowed -Operation 'Salvar perfil de servicos' | Out-Null
    foreach ($serviceName in $Services) {
        if (-not (Get-OptionalServiceDefinition -Name $serviceName)) { throw "Servico fora da allowlist: $serviceName" }
    }
    $path = Join-Path (Get-OptimizerContext).StateRoot 'service-profiles.json'
    $profiles = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($property in $raw.PSObject.Properties) { $profiles[$property.Name] = @($property.Value) }
        }
        catch { }
    }
    $profiles[$Name] = @($Services | Sort-Object -Unique)
    if (-not (Get-OptimizerContext).Simulation) { Save-OptimizerJsonFile -Path $path -InputObject $profiles | Out-Null }
    return [pscustomobject]@{ Name = $Name; Services = $profiles[$Name] }
}

function Get-ServiceProfiles {
    [CmdletBinding()]
    param()

    $path = Join-Path (Get-OptimizerContext).StateRoot 'service-profiles.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @($raw.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Services = @($_.Value) } })
    }
    catch { return @() }
}

function Apply-ServiceProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [ValidateSet('StopOnly', 'Disabled')][string]$Mode = 'StopOnly')

    $profile = @(Get-ServiceProfiles | Where-Object Name -eq $Name | Select-Object -First 1)
    if (-not $profile) { throw "Perfil de servicos nao encontrado: $Name" }
    if ($Mode -eq 'StopOnly') {
        return Suspend-OptionalServicesForSession -Names @($profile[0].Services)
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($serviceName in @($profile[0].Services | Sort-Object -Unique)) {
        try { $results.Add((Set-OptionalServiceState -Name ([string]$serviceName) -DesiredState Disabled)) }
        catch { $results.Add([pscustomobject]@{ Name = [string]$serviceName; Result = 'Error'; Error = $_.Exception.Message }) }
    }
    return $results.ToArray()
}

function Restore-ServiceBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    Assert-OptimizerMutationAllowed -RequiresAdministrator -Operation 'Restaurar servico' | Out-Null
    $name = [string]$Entry.Id
    if (Test-ProtectedService -Name $name) { return [pscustomobject]@{ Status = 'Blocked'; Reason = 'Servico protegido' } }
    $current = Get-ServiceStateSnapshot -Name $name
    $original = $Entry.Original
    $applied = $Entry.Applied
    $currentMatchesApplied = ($current.StartMode -eq [string]$applied.StartMode -and $current.Status -eq [string]$applied.Status)
    $currentMatchesOriginal = ($current.StartMode -eq [string]$original.StartMode -and $current.Status -eq [string]$original.Status)
    if ($currentMatchesOriginal) { return [pscustomobject]@{ Status = 'NoChange'; Name = $name } }
    if (-not $Force -and -not $currentMatchesApplied) {
        return [pscustomobject]@{ Status = 'Conflict'; Name = $name; Current = $current; Applied = $applied; Original = $original }
    }
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]@{ Status = 'Simulated'; Name = $name } }

    Set-Service -Name $name -StartupType ([string]$original.StartMode) -ErrorAction Stop
    $service = Get-Service -Name $name -ErrorAction Stop
    if ([string]$original.Status -eq 'Running' -and $service.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop }
    elseif ([string]$original.Status -eq 'Stopped' -and $service.Status -ne 'Stopped') { Stop-Service -Name $name -ErrorAction Stop }
    $after = Get-ServiceStateSnapshot -Name $name
    return [pscustomobject]@{ Status = 'Restored'; Name = $name; State = $after }
}

Export-ModuleMember -Function Test-ProtectedService, Get-OptionalServices, Get-AllServiceInventory,
    Get-ServiceStateSnapshot, Set-OptionalServiceState, Suspend-OptionalServicesForSession,
    Save-ServiceProfile, Get-ServiceProfiles, Apply-ServiceProfile, Restore-ServiceBackupEntry
