#requires -Version 5.1

Set-StrictMode -Version Latest

# GUIDs publicos usados pelo powercfg. O modulo nao altera configuracoes ocultas,
# firmware, voltagem, overclock ou qualquer propriedade de dispositivo/rede.
$script:PowerGuids = @{
    BalancedScheme       = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerformance      = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    UltimatePerformance  = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    ProcessorSubgroup    = '54533251-82be-4824-96c1-47b60b740d00'
    ProcessorMinimum     = '893dee8e-2bef-41e0-89c6-b55d0929964c'
    ProcessorMaximum     = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    CoolingPolicy        = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
    SleepSubgroup        = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    SleepIdle            = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
    DisplaySubgroup      = '7516b95f-f776-4464-8c53-06167f40cc99'
    DisplayIdle          = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
}

$script:GamingPlanName = 'Windows FPS Optimizer - Jogos'

function Write-PowerOptimizerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $OldValue,
        $NewValue,
        [ValidateSet('Success', 'Skipped', 'Simulated', 'Warning', 'Error', 'Info', 'Restored')]
        [string]$Result = 'Info',
        [string]$ErrorMessage = '',
        [bool]$RequiresRestart = $false,
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )

    if (-not (Get-Command Write-OptimizerLog -ErrorAction SilentlyContinue)) { return }
    $profile = ''
    try { $profile = [string](Get-OptimizerContext).CurrentProfile } catch { }
    Write-OptimizerLog -Name $Name -Category 'CPU e energia' -OldValue $OldValue `
        -NewValue $NewValue -Result $Result -ErrorMessage $ErrorMessage `
        -RequiresRestart $RequiresRestart -Profile $profile -Level $Level | Out-Null
}

function Invoke-PowerCfg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$Mutating,
        [switch]$RequiresAdministrator
    )

    if (-not (Get-Command Invoke-SafeNativeCommand -ErrorAction SilentlyContinue)) {
        throw 'Core.psm1 deve ser importado antes de PowerOptimizations.psm1.'
    }
    if ($Mutating) { Assert-PowerBackupTransaction | Out-Null }
    return Invoke-SafeNativeCommand -FilePath 'powercfg.exe' -ArgumentList $Arguments `
        -Description $Description -Mutating:$Mutating `
        -RequiresAdministrator:$RequiresAdministrator
}

function ConvertTo-NormalizedPowerGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Guid)

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Guid.Trim('{} '), [ref]$parsed)) {
        throw "GUID de energia invalido: $Guid"
    }
    return $parsed.ToString('D').ToLowerInvariant()
}

function Get-PowerPlanListInternal {
    [CmdletBinding()]
    param()

    $result = Invoke-PowerCfg -Arguments @('/list') -Description 'Listar planos de energia'
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($result.Output)) {
        $match = [regex]::Match([string]$line, '(?i)(?<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\s+\((?<name>.*)\))?\s*\*?\s*$')
        if (-not $match.Success) { continue }
        $guid = (ConvertTo-NormalizedPowerGuid -Guid $match.Groups['guid'].Value)
        if (@($plans | Where-Object { $_.Guid -eq $guid }).Count -gt 0) { continue }
        $plans.Add([pscustomobject]@{
            Guid     = $guid
            Name     = [string]$match.Groups['name'].Value
            IsActive = ([string]$line -match '\*\s*$')
        })
    }
    return @($plans | ForEach-Object { $_ })
}

function Get-ActivePowerPlanInternal {
    [CmdletBinding()]
    param()

    $result = Invoke-PowerCfg -Arguments @('/getactivescheme') -Description 'Consultar plano de energia ativo'
    foreach ($line in @($result.Output)) {
        $match = [regex]::Match([string]$line, '(?i)(?<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\s+\((?<name>.*)\))?\s*$')
        if ($match.Success) {
            return [pscustomobject]@{
                Guid = ConvertTo-NormalizedPowerGuid -Guid $match.Groups['guid'].Value
                Name = [string]$match.Groups['name'].Value
            }
        }
    }
    throw 'Nao foi possivel identificar o plano de energia ativo.'
}

function Get-PowerStatePath {
    [CmdletBinding()]
    param()

    $context = Get-OptimizerContext
    return Join-Path $context.StateRoot 'PowerOptimizationState.json'
}

function New-EmptyPowerState {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        SchemaVersion        = 1
        OriginalActiveScheme = $null
        AppliedActiveScheme  = $null
        Settings             = @()
        CreatedSchemes       = @()
        UpdatedAt            = (Get-Date).ToString('o')
    }
}

function Read-PowerOptimizationState {
    [CmdletBinding()]
    param()

    $path = Get-PowerStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return New-EmptyPowerState }
    try {
        $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $state.Settings) { $state.Settings = @() }
        if ($null -eq $state.CreatedSchemes) { $state.CreatedSchemes = @() }
        return $state
    }
    catch {
        throw "Estado de energia salvo e invalido: $($_.Exception.Message)"
    }
}

function Save-PowerOptimizationState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    $State.UpdatedAt = (Get-Date).ToString('o')
    Save-OptimizerJsonFile -Path (Get-PowerStatePath) -InputObject $State -Depth 12 | Out-Null
}

function Update-PowerStateForRestoredBackupEntry {
    <#
        Reduz o sidecar ao estado liquido depois de restaurar uma unica transacao.
        A funcao e pura em relacao ao Windows; ExistingSchemeGuids e um snapshot
        somente leitura usado para nao esquecer clones que continuem existentes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Entry,
        [string[]]$ExistingSchemeGuids = @()
    )

    $type = [string]$Entry.Type
    if ($type -notin @('PowerPlan', 'PowerSetting')) {
        throw "Tipo de backup de energia invalido: $type"
    }
    $before = $State | ConvertTo-Json -Depth 12 -Compress

    if ($type -eq 'PowerSetting') {
        $original = $Entry.Original
        $scheme = ConvertTo-NormalizedPowerGuid -Guid ([string]$original.SchemeGuid)
        $subGroup = ConvertTo-NormalizedPowerGuid -Guid ([string]$original.SubGroupGuid)
        $setting = ConvertTo-NormalizedPowerGuid -Guid ([string]$original.SettingGuid)
        $matches = @($State.Settings | Where-Object {
            ([string]$_.Key -ieq [string]$Entry.Id) -or
            ((ConvertTo-NormalizedPowerGuid -Guid ([string]$_.SchemeGuid)) -eq $scheme -and
                (ConvertTo-NormalizedPowerGuid -Guid ([string]$_.SubgroupGuid)) -eq $subGroup -and
                (ConvertTo-NormalizedPowerGuid -Guid ([string]$_.SettingGuid)) -eq $setting)
        } | Select-Object -First 1)
        if ($matches.Count -gt 0) {
            $tracked = $matches[0]
            $restoredAC = [int64]$original.AcValueIndex
            $restoredDC = [int64]$original.DcValueIndex
            if ([int64]$tracked.OriginalAC -eq $restoredAC -and
                [int64]$tracked.OriginalDC -eq $restoredDC) {
                $trackedKey = [string]$tracked.Key
                $State.Settings = @($State.Settings | Where-Object { [string]$_.Key -ine $trackedKey })
            }
            else {
                $tracked.AppliedAC = $restoredAC
                $tracked.AppliedDC = $restoredDC
            }
        }
    }
    else {
        $restoredGuid = ConvertTo-NormalizedPowerGuid -Guid ([string]$Entry.Original.ActiveSchemeGuid)
        if (-not [string]::IsNullOrWhiteSpace([string]$State.OriginalActiveScheme)) {
            $baselineGuid = ConvertTo-NormalizedPowerGuid -Guid ([string]$State.OriginalActiveScheme)
            if ($restoredGuid -eq $baselineGuid) {
                $State.OriginalActiveScheme = $null
                $State.AppliedActiveScheme = $null
            }
            else { $State.AppliedActiveScheme = $restoredGuid }
        }

        $existing = @($ExistingSchemeGuids | ForEach-Object {
            ConvertTo-NormalizedPowerGuid -Guid ([string]$_)
        } | Sort-Object -Unique)
        $State.CreatedSchemes = @($State.CreatedSchemes | Where-Object {
            $existing -contains (ConvertTo-NormalizedPowerGuid -Guid ([string]$_.Guid))
        })
    }

    $after = $State | ConvertTo-Json -Depth 12 -Compress
    return [pscustomobject]@{ State = $State; Changed = ($before -cne $after) }
}

function Test-PowerStateHasNetChanges {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    return (@($State.Settings).Count -gt 0 -or @($State.CreatedSchemes).Count -gt 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$State.OriginalActiveScheme) -or
        -not [string]::IsNullOrWhiteSpace([string]$State.AppliedActiveScheme))
}

function Sync-PowerStateAfterBackupRestore {
    <# Chamado pelo BackupManager apenas para resultados Restored/AlreadyRestored. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Restored', 'AlreadyRestored')][string]$Status
    )

    $path = Get-PowerStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Changed = $false; Removed = $false; Status = $Status }
    }
    $state = Read-PowerOptimizationState
    $existingGuids = @()
    if ([string]$Entry.Type -eq 'PowerPlan' -and @($state.CreatedSchemes).Count -gt 0) {
        $plans = @(Get-PowerPlanListInternal)
        # /list sempre contem ao menos o plano ativo. Uma lista vazia indica que
        # nao foi possivel comprovar ausencias; preserve todos os marcadores.
        if ($plans.Count -eq 0) { throw 'Nao foi possivel verificar os planos de energia existentes.' }
        $existingGuids = @($plans | ForEach-Object { [string]$_.Guid })
    }
    $updated = Update-PowerStateForRestoredBackupEntry -State $state -Entry $Entry `
        -ExistingSchemeGuids $existingGuids
    if (-not $updated.Changed) {
        return [pscustomobject]@{ Changed = $false; Removed = $false; Status = $Status }
    }
    if (Test-PowerStateHasNetChanges -State $state) {
        Save-PowerOptimizationState -State $state
        return [pscustomobject]@{ Changed = $true; Removed = $false; Status = $Status }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    return [pscustomobject]@{ Changed = $true; Removed = $true; Status = $Status }
}

function Invoke-WithPowerStateRollback {
    <#
        Mantem PowerOptimizationState.json alinhado ao rollback do BackupManager em
        operacoes compostas. Se um passo posterior falhar, restaura atomicamente o
        snapshot existente antes de deixar o erro subir para Invoke-OptimizerOperation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    $context = Get-OptimizerContext
    if ($context.Simulation) { return & $ScriptBlock }
    $path = Get-PowerStatePath
    $existed = Test-Path -LiteralPath $path -PathType Leaf
    $snapshot = if ($existed) { Get-Content -LiteralPath $path -Raw -ErrorAction Stop } else { $null }
    try {
        return & $ScriptBlock
    }
    catch {
        $operationError = $_
        try {
            # Um clone que o Windows recusou apagar precisa sobreviver ao rollback do
            # arquivo de estado; sem esse marcador, nao haveria uma nova tentativa
            # segura no botao Restaurar energia.
            $snapshotState = if ($existed) { $snapshot | ConvertFrom-Json -ErrorAction Stop } else { New-EmptyPowerState }
            if ($null -eq $snapshotState.CreatedSchemes) { $snapshotState.CreatedSchemes = @() }
            $originalCreatedGuids = @($snapshotState.CreatedSchemes | ForEach-Object { [string]$_.Guid })
            $recoverySchemes = @()
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try {
                    $currentState = Read-PowerOptimizationState
                    $recoverySchemes = @($currentState.CreatedSchemes | Where-Object {
                        $originalCreatedGuids -notcontains [string]$_.Guid
                    })
                }
                catch { }
            }
            if ($existed) {
                if ($recoverySchemes.Count -gt 0) {
                    $snapshotState.CreatedSchemes = @($snapshotState.CreatedSchemes) + $recoverySchemes
                    Save-PowerOptimizationState -State $snapshotState
                }
                else {
                    $temporary = "$path.$([guid]::NewGuid().ToString('N')).rollback"
                    try {
                        Set-Content -LiteralPath $temporary -Value $snapshot -Encoding UTF8 -ErrorAction Stop
                        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
                    }
                    finally {
                        if (Test-Path -LiteralPath $temporary) {
                            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            elseif ($recoverySchemes.Count -gt 0) {
                $snapshotState.CreatedSchemes = $recoverySchemes
                Save-PowerOptimizationState -State $snapshotState
            }
            elseif (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
        catch {
            Write-PowerOptimizerLog -Name 'Restaurar estado interno de energia apos falha' `
                -OldValue 'Snapshot anterior' -NewValue 'Falha' -Result 'Warning' `
                -ErrorMessage $_.Exception.Message -Level 'Warning'
        }
        throw $operationError
    }
}

function Add-PowerBackupEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Original,
        [Parameter(Mandatory = $true)]$Applied,
        [hashtable]$Metadata = @{}
    )

    if ((Get-OptimizerContext).Simulation) { return }
    Assert-PowerBackupTransaction | Out-Null
    try {
        Add-OptimizerBackupEntry -Type $Type -Id $Id -Original $Original `
            -Applied $Applied -Metadata $Metadata | Out-Null
    }
    catch {
        Write-PowerOptimizerLog -Name 'Registrar backup de energia' -OldValue $Original `
            -NewValue $Applied -Result 'Warning' -ErrorMessage $_.Exception.Message -Level 'Warning'
        throw
    }
}

function Assert-PowerBackupTransaction {
    <# Impede qualquer chamada mutante de powercfg fora de um backup transacional. #>
    [CmdletBinding()]
    param()

    if ((Get-OptimizerContext).Simulation) { return $true }
    foreach ($commandName in @('Add-OptimizerBackupEntry', 'Get-CurrentOptimizerBackup')) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "BackupManager nao esta carregado; alteracao de energia bloqueada ($commandName ausente)."
        }
    }
    if (-not (Get-CurrentOptimizerBackup)) {
        throw 'Nenhuma transacao de backup esta ativa; alteracao de energia bloqueada.'
    }
    return $true
}

function Register-OriginalActivePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$CurrentPlan,
        [Parameter(Mandatory = $true)][string]$AppliedGuid
    )

    if ([string]::IsNullOrWhiteSpace([string]$State.OriginalActiveScheme)) {
        $State.OriginalActiveScheme = [string]$CurrentPlan.Guid
    }
    $created = @($State.CreatedSchemes | Where-Object { [string]$_.Guid -eq $AppliedGuid } | Select-Object -First 1)
    $metadata = @{ Description = 'Plano de energia ativo'; RequiresRestart = $false }
    if ($created.Count -gt 0) { $metadata.CreatedSchemeGuid = $AppliedGuid }
    Add-PowerBackupEntry -Type 'PowerPlan' -Id 'active-plan' `
        -Original ([pscustomobject]@{ ActiveSchemeGuid = [string]$CurrentPlan.Guid }) `
        -Applied ([pscustomobject]@{ ActiveSchemeGuid = $AppliedGuid }) `
        -Metadata $metadata
    $State.AppliedActiveScheme = $AppliedGuid
}

function Get-PowerSettingIndexInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubgroupGuid,
        [Parameter(Mandatory = $true)][string]$SettingGuid
    )

    $scheme = ConvertTo-NormalizedPowerGuid -Guid $SchemeGuid
    $setting = ConvertTo-NormalizedPowerGuid -Guid $SettingGuid

    # A classe CIM evita depender do idioma da saida textual do powercfg.
    try {
        $indices = @(Get-CimInstance -Namespace 'root/cimv2/power' `
            -ClassName 'Win32_PowerSettingDataIndex' -ErrorAction Stop)
        $ac = $null
        $dc = $null
        foreach ($item in $indices) {
            $instance = ([string]$item.InstanceID).ToLowerInvariant()
            if (-not $instance.Contains($scheme) -or -not $instance.Contains($setting)) { continue }
            if ($instance -match '\\ac\\') { $ac = [int64]$item.SettingIndexValue }
            elseif ($instance -match '\\dc\\') { $dc = [int64]$item.SettingIndexValue }
        }
        if ($null -ne $ac -and $null -ne $dc) {
            return [pscustomobject]@{ AC = [int]$ac; DC = [int]$dc; Source = 'CIM'; Supported = $true }
        }
    }
    catch { }

    # Fallback: para uma consulta de uma unica configuracao, os dois ultimos
    # indices hexadecimais sao os valores AC e DC atuais em todas as traducoes.
    try {
        $query = Invoke-PowerCfg -Arguments @('/query', $scheme, $SubgroupGuid, $setting) `
            -Description 'Consultar configuracao do plano de energia'
        $matches = [regex]::Matches(($query.Output -join "`n"), '(?i)0x[0-9a-f]{8}')
        if ($matches.Count -ge 2) {
            $acValue = [Convert]::ToInt32($matches[$matches.Count - 2].Value.Substring(2), 16)
            $dcValue = [Convert]::ToInt32($matches[$matches.Count - 1].Value.Substring(2), 16)
            return [pscustomobject]@{ AC = $acValue; DC = $dcValue; Source = 'powercfg'; Supported = $true }
        }
    }
    catch { }
    return [pscustomobject]@{ AC = $null; DC = $null; Source = 'Unavailable'; Supported = $false }
}

function Register-PowerSettingChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubgroupGuid,
        [Parameter(Mandatory = $true)][string]$SettingGuid,
        [Parameter(Mandatory = $true)]$Original,
        [Parameter(Mandatory = $true)][int]$AppliedAC,
        [Parameter(Mandatory = $true)][int]$AppliedDC,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $key = '{0}|{1}|{2}' -f $SchemeGuid, $SubgroupGuid, $SettingGuid
    $existing = @($State.Settings | Where-Object { [string]$_.Key -eq $key } | Select-Object -First 1)
    if ($existing.Count -eq 0) {
        $entry = [pscustomobject][ordered]@{
            Key          = $key
            SchemeGuid   = $SchemeGuid
            SubgroupGuid = $SubgroupGuid
            SettingGuid  = $SettingGuid
            OriginalAC   = [int]$Original.AC
            OriginalDC   = [int]$Original.DC
            AppliedAC    = $AppliedAC
            AppliedDC    = $AppliedDC
            Description  = $Description
        }
        $State.Settings = @($State.Settings) + @($entry)
    }
    else {
        $existing[0].AppliedAC = $AppliedAC
        $existing[0].AppliedDC = $AppliedDC
    }
    # O arquivo de estado preserva o primeiro baseline para o botao "Restaurar
    # energia". Cada transacao, contudo, precisa capturar o valor corrente para que
    # "Desfazer ultima" reverta somente a alteracao mais recente. O BackupManager
    # deduplica repeticoes dentro da mesma transacao preservando o primeiro Original.
    Add-PowerBackupEntry -Type 'PowerSetting' -Id $key `
        -Original ([pscustomobject]@{
            SchemeGuid = $SchemeGuid; SubGroupGuid = $SubgroupGuid; SettingGuid = $SettingGuid
            AcValueIndex = [int]$Original.AC; DcValueIndex = [int]$Original.DC
        }) `
        -Applied ([pscustomobject]@{
            SchemeGuid = $SchemeGuid; SubGroupGuid = $SubgroupGuid; SettingGuid = $SettingGuid
            AcValueIndex = $AppliedAC; DcValueIndex = $AppliedDC
        }) `
        -Metadata @{ Description = $Description }
}

function Set-PowerSettingInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubgroupGuid,
        [Parameter(Mandatory = $true)][string]$SettingGuid,
        [Parameter(Mandatory = $true)][ValidateRange(0, 86400)][int]$ACValue,
        [Parameter(Mandatory = $true)][ValidateRange(0, 86400)][int]$DCValue,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$SkipStateRegistration
    )

    $scheme = ConvertTo-NormalizedPowerGuid -Guid $SchemeGuid
    $subgroup = ConvertTo-NormalizedPowerGuid -Guid $SubgroupGuid
    $setting = ConvertTo-NormalizedPowerGuid -Guid $SettingGuid
    $before = Get-PowerSettingIndexInternal -SchemeGuid $scheme -SubgroupGuid $subgroup -SettingGuid $setting
    if (-not $before.Supported) { throw "$Description nao e suportada por este computador/plano." }
    if ([int]$before.AC -eq $ACValue -and [int]$before.DC -eq $DCValue) {
        Write-PowerOptimizerLog -Name $Description -OldValue $before -NewValue $before -Result 'Skipped'
        return [pscustomobject]@{ Changed = $false; Result = 'Skipped'; Before = $before; After = $before }
    }

    $context = Get-OptimizerContext
    $pendingState = $null
    if (-not $SkipStateRegistration -and -not $context.Simulation) {
        $state = Read-PowerOptimizationState
        Register-PowerSettingChange -State $state -SchemeGuid $scheme -SubgroupGuid $subgroup `
            -SettingGuid $setting -Original $before -AppliedAC $ACValue -AppliedDC $DCValue `
            -Description $Description
        # O estado persistente so e publicado depois que ambos os indices forem
        # aplicados e relidos. O manifesto transacional ja foi gravado acima.
        $pendingState = $state
    }

    Invoke-PowerCfg -Arguments @('/setacvalueindex', $scheme, $subgroup, $setting, [string]$ACValue) `
        -Description "$Description (AC)" -Mutating -RequiresAdministrator | Out-Null
    Invoke-PowerCfg -Arguments @('/setdcvalueindex', $scheme, $subgroup, $setting, [string]$DCValue) `
        -Description "$Description (bateria)" -Mutating -RequiresAdministrator | Out-Null

    if ($context.Simulation) {
        Write-PowerOptimizerLog -Name $Description -OldValue $before `
            -NewValue @{ AC = $ACValue; DC = $DCValue } -Result 'Simulated'
        return [pscustomobject]@{ Changed = $false; Result = 'Simulated'; Before = $before; After = $null }
    }

    $after = Get-PowerSettingIndexInternal -SchemeGuid $scheme -SubgroupGuid $subgroup -SettingGuid $setting
    if (-not $after.Supported -or [int]$after.AC -ne $ACValue -or [int]$after.DC -ne $DCValue) {
        throw "Falha ao verificar $Description depois da aplicacao."
    }
    if ($pendingState) { Save-PowerOptimizationState -State $pendingState }
    Write-PowerOptimizerLog -Name $Description -OldValue $before -NewValue $after -Result 'Success'
    return [pscustomobject]@{ Changed = $true; Result = 'Success'; Before = $before; After = $after }
}

function Set-ActivePowerPlanInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Guid,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$SkipStateRegistration
    )

    $target = ConvertTo-NormalizedPowerGuid -Guid $Guid
    $plans = @(Get-PowerPlanListInternal)
    $context = Get-OptimizerContext
    if (@($plans | Where-Object { $_.Guid -eq $target }).Count -eq 0 -and -not $context.Simulation) {
        throw "Plano de energia nao encontrado: $target"
    }
    $current = Get-ActivePowerPlanInternal
    if ($current.Guid -eq $target) {
        Write-PowerOptimizerLog -Name $Description -OldValue $current -NewValue $current -Result 'Skipped'
        return [pscustomobject]@{ Changed = $false; Result = 'Skipped'; Before = $current; After = $current }
    }

    $pendingState = $null
    if (-not $SkipStateRegistration -and -not $context.Simulation) {
        $state = Read-PowerOptimizationState
        Register-OriginalActivePlan -State $state -CurrentPlan $current -AppliedGuid $target
        # O plano ainda nao foi alterado; publique o estado somente apos verificar
        # que /setactive realmente deixou o GUID solicitado ativo.
        $pendingState = $state
    }
    Invoke-PowerCfg -Arguments @('/setactive', $target) -Description $Description `
        -Mutating -RequiresAdministrator | Out-Null
    if ($context.Simulation) {
        Write-PowerOptimizerLog -Name $Description -OldValue $current -NewValue $target -Result 'Simulated'
        return [pscustomobject]@{ Changed = $false; Result = 'Simulated'; Before = $current; After = $null }
    }
    $after = Get-ActivePowerPlanInternal
    if ($after.Guid -ne $target) { throw 'O plano solicitado nao ficou ativo.' }
    if ($pendingState) { Save-PowerOptimizationState -State $pendingState }
    Write-PowerOptimizerLog -Name $Description -OldValue $current -NewValue $after -Result 'Success'
    return [pscustomobject]@{ Changed = $true; Result = 'Success'; Before = $current; After = $after }
}

function New-PowerSchemeCloneInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceGuid,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Description = 'Plano criado pelo Windows FPS Optimizer'
    )

    $destination = [guid]::NewGuid().ToString('D')
    $context = Get-OptimizerContext
    if ($context.Simulation) {
        Invoke-PowerCfg -Arguments @('/duplicatescheme', $SourceGuid, $destination) `
            -Description "Criar plano de energia $Name" -Mutating -RequiresAdministrator | Out-Null
        Invoke-PowerCfg -Arguments @('/changename', $destination, $Name, $Description) `
            -Description "Nomear plano de energia $Name" -Mutating -RequiresAdministrator | Out-Null
        return [pscustomobject]@{ Guid = $destination; Name = $Name; IsActive = $false; Simulated = $true }
    }

    Assert-PowerBackupTransaction | Out-Null
    $activeBeforeCreation = Get-ActivePowerPlanInternal
    $state = Read-PowerOptimizationState
    # O manifesto vem antes do primeiro comando mutante. O arquivo de estado, por
    # outro lado, so recebe o GUID depois que o clone e o nome foram verificados.
    Add-PowerBackupEntry -Type 'PowerPlan' -Id 'active-plan' `
        -Original ([pscustomobject]@{ ActiveSchemeGuid = $activeBeforeCreation.Guid }) `
        -Applied ([pscustomobject]@{ ActiveSchemeGuid = $activeBeforeCreation.Guid }) `
        -Metadata @{ Description = $Description; CreatedSchemeGuid = $destination }

    try {
        Invoke-PowerCfg -Arguments @('/duplicatescheme', $SourceGuid, $destination) `
            -Description "Criar plano de energia $Name" -Mutating -RequiresAdministrator | Out-Null
        Invoke-PowerCfg -Arguments @('/changename', $destination, $Name, $Description) `
            -Description "Nomear plano de energia $Name" -Mutating -RequiresAdministrator | Out-Null
        $created = @(Get-PowerPlanListInternal | Where-Object { $_.Guid -eq $destination } | Select-Object -First 1)
        if ($created.Count -eq 0 -or [string]$created[0].Name -ne $Name) {
            throw 'O clone do plano de energia nao foi encontrado com o nome esperado apos sua criacao.'
        }
        if (@($state.CreatedSchemes | Where-Object { [string]$_.Guid -eq $destination }).Count -eq 0) {
            $state.CreatedSchemes = @($state.CreatedSchemes) + @([pscustomobject]@{
                Guid = $destination; Name = $Name; SourceGuid = $SourceGuid
            })
        }
        Save-PowerOptimizationState -State $state
        return $created[0]
    }
    catch {
        $originalError = $_
        $cleanupSucceeded = $false
        try {
            $exists = @((Get-PowerPlanListInternal) | Where-Object { $_.Guid -eq $destination }).Count -gt 0
            if ($exists) {
                Invoke-PowerCfg -Arguments @('/delete', $destination) `
                    -Description "Reverter criacao incompleta do plano $Name" `
                    -Mutating -RequiresAdministrator | Out-Null
            }
            $cleanupSucceeded = (@((Get-PowerPlanListInternal) | Where-Object { $_.Guid -eq $destination }).Count -eq 0)
        }
        catch {
            Write-PowerOptimizerLog -Name 'Limpar plano criado parcialmente' -OldValue $destination `
                -NewValue 'Pendente' -Result 'Warning' -ErrorMessage $_.Exception.Message -Level 'Warning'
        }
        if (-not $cleanupSucceeded) {
            # Se o Windows recusou a limpeza imediata, mantenha o GUID no estado para
            # que Restaurar energia possa tentar remove-lo posteriormente.
            try {
                if (@($state.CreatedSchemes | Where-Object { [string]$_.Guid -eq $destination }).Count -eq 0) {
                    $state.CreatedSchemes = @($state.CreatedSchemes) + @([pscustomobject]@{
                        Guid = $destination; Name = $Name; SourceGuid = $SourceGuid
                    })
                }
                Save-PowerOptimizationState -State $state
            }
            catch { }
        }
        throw $originalError
    }
}

function Remove-NewPowerSchemeInternal {
    <#
        Compensacao local para o intervalo entre criar um clone e ativa-lo. O GUID e
        gerado pelo proprio processo e a rotina so e chamada enquanto a transacao que
        registrou CreatedSchemeGuid continua ativa.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Guid,
        [Parameter(Mandatory = $true)][string]$FallbackGuid,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $target = ConvertTo-NormalizedPowerGuid -Guid $Guid
    $fallback = ConvertTo-NormalizedPowerGuid -Guid $FallbackGuid
    Assert-PowerBackupTransaction | Out-Null
    $active = Get-ActivePowerPlanInternal
    if ($active.Guid -eq $target) {
        Invoke-PowerCfg -Arguments @('/setactive', $fallback) `
            -Description "Restaurar plano anterior apos falha: $Description" `
            -Mutating -RequiresAdministrator | Out-Null
    }
    if (@((Get-PowerPlanListInternal) | Where-Object { $_.Guid -eq $target }).Count -gt 0) {
        Invoke-PowerCfg -Arguments @('/delete', $target) `
            -Description "Remover clone apos falha: $Description" `
            -Mutating -RequiresAdministrator | Out-Null
    }
    if (@((Get-PowerPlanListInternal) | Where-Object { $_.Guid -eq $target }).Count -gt 0) {
        throw "O plano criado parcialmente nao pode ser removido: $target"
    }

    $state = Read-PowerOptimizationState
    $state.CreatedSchemes = @($state.CreatedSchemes | Where-Object { [string]$_.Guid -ne $target })
    if ([string]$state.AppliedActiveScheme -eq $target) { $state.AppliedActiveScheme = $fallback }
    Save-PowerOptimizationState -State $state
}

function Get-ComputerPowerFormFactor {
    [CmdletBinding()]
    param()

    $battery = @()
    $enclosures = @()
    try { $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) } catch { }
    try { $enclosures = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop) } catch { }
    $portableTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isPortableChassis = $false
    foreach ($enclosure in $enclosures) {
        foreach ($type in @($enclosure.ChassisTypes)) {
            if ($portableTypes -contains [int]$type) { $isPortableChassis = $true }
        }
    }
    return [pscustomobject]@{
        IsLaptop       = ($battery.Count -gt 0 -or $isPortableChassis)
        BatteryPresent = ($battery.Count -gt 0)
        ChassisTypes   = @($enclosures | ForEach-Object { @($_.ChassisTypes) })
    }
}

function Get-PowerCapabilities {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    $formFactor = Get-ComputerPowerFormFactor
    $processors = @()
    try { $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) } catch { }
    $cpuNames = @($processors | ForEach-Object { [string]$_.Name })
    $vendorText = @($processors | ForEach-Object { [string]$_.Manufacturer }) -join ' '
    if ($cpuNames.Count -eq 0) {
        try {
            $cpuRegistry = Get-ItemProperty -LiteralPath `
                'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
            $cpuNames = @([string]$cpuRegistry.ProcessorNameString)
            $vendorText = [string]$cpuRegistry.VendorIdentifier
        }
        catch { }
    }
    $manufacturer = if ((($cpuNames -join ' ') + ' ' + $vendorText) -match '(?i)(AMD|AuthenticAMD)') { 'AMD' } `
        elseif ((($cpuNames -join ' ') + ' ' + $vendorText) -match '(?i)(Intel|GenuineIntel)') { 'Intel' } else { 'Outro/Desconhecido' }
    $plans = @(Get-PowerPlanListInternal)
    $sleepOutput = @()
    try {
        $sleepOutput = @((Invoke-PowerCfg -Arguments @('/availablesleepstates') `
            -Description 'Consultar estados de suspensao').Output)
    }
    catch { }

    $active = Get-ActivePowerPlanInternal
    $cooling = Get-PowerSettingIndexInternal -SchemeGuid $active.Guid `
        -SubgroupGuid $script:PowerGuids.ProcessorSubgroup -SettingGuid $script:PowerGuids.CoolingPolicy
    return [pscustomobject]@{
        SupportedWindows          = [bool]$platform.IsSupported
        IsLaptop                 = [bool]$formFactor.IsLaptop
        BatteryPresent           = [bool]$formFactor.BatteryPresent
        ProcessorManufacturer    = $manufacturer
        ProcessorNames           = $cpuNames
        HighPerformanceAvailable = (@($plans | Where-Object {
            $_.Guid -eq $script:PowerGuids.HighPerformance -or $_.Name -eq 'Windows FPS Optimizer - Alto Desempenho'
        }).Count -gt 0)
        UltimateAvailable        = (@($plans | Where-Object {
            $_.Guid -eq $script:PowerGuids.UltimatePerformance -or $_.Name -eq 'Windows FPS Optimizer - Desempenho Maximo'
        }).Count -gt 0)
        CoolingPolicyAvailable   = [bool]$cooling.Supported
        PerDeviceSelectiveSuspendSupported = $false
        AvailableSleepStatesText = ($sleepOutput -join [Environment]::NewLine)
        ThermalWarning           = 'Planos agressivos aumentam consumo, temperatura, ruido e podem reduzir desempenho se houver throttling.'
        SafetyLimits             = @('Sem overclock', 'Sem BIOS', 'Sem voltagem', 'Sem configuracoes de rede', 'Sem Registro PnP de suspensao seletiva')
    }
}

function Get-PowerPlanState {
    [CmdletBinding()]
    param()

    $active = Get-ActivePowerPlanInternal
    return [pscustomobject]@{
        ActivePlan      = $active
        Plans           = @(Get-PowerPlanListInternal)
        ProcessorMin    = Get-PowerSettingIndexInternal -SchemeGuid $active.Guid -SubgroupGuid $script:PowerGuids.ProcessorSubgroup -SettingGuid $script:PowerGuids.ProcessorMinimum
        ProcessorMax    = Get-PowerSettingIndexInternal -SchemeGuid $active.Guid -SubgroupGuid $script:PowerGuids.ProcessorSubgroup -SettingGuid $script:PowerGuids.ProcessorMaximum
        CoolingPolicy   = Get-PowerSettingIndexInternal -SchemeGuid $active.Guid -SubgroupGuid $script:PowerGuids.ProcessorSubgroup -SettingGuid $script:PowerGuids.CoolingPolicy
        DisplayTimeout  = Get-PowerSettingIndexInternal -SchemeGuid $active.Guid -SubgroupGuid $script:PowerGuids.DisplaySubgroup -SettingGuid $script:PowerGuids.DisplayIdle
        SleepTimeout    = Get-PowerSettingIndexInternal -SchemeGuid $active.Guid -SubgroupGuid $script:PowerGuids.SleepSubgroup -SettingGuid $script:PowerGuids.SleepIdle
        Capabilities    = Get-PowerCapabilities
    }
}

function Set-HighPerformancePlan {
    [CmdletBinding()]
    param()

    return Invoke-OptimizerOperation -Name 'Ativar plano Alto Desempenho' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $activeBefore = Get-ActivePowerPlanInternal
            $createdByCall = $false
            $plan = @(Get-PowerPlanListInternal | Where-Object {
                $_.Guid -eq $script:PowerGuids.HighPerformance -or $_.Name -eq 'Windows FPS Optimizer - Alto Desempenho'
            } | Select-Object -First 1)
            if ($plan.Count -eq 0) {
                $plan = @(New-PowerSchemeCloneInternal -SourceGuid $script:PowerGuids.HighPerformance `
                    -Name 'Windows FPS Optimizer - Alto Desempenho')
                $createdByCall = $true
            }
            try {
                Set-ActivePowerPlanInternal -Guid $plan[0].Guid -Description 'Ativar plano Alto Desempenho'
            }
            catch {
                $activationError = $_
                if ($createdByCall) {
                    try {
                        Remove-NewPowerSchemeInternal -Guid ([string]$plan[0].Guid) `
                            -FallbackGuid ([string]$activeBefore.Guid) -Description 'Alto Desempenho'
                    }
                    catch {
                        Write-PowerOptimizerLog -Name 'Compensar criacao do plano Alto Desempenho' `
                            -OldValue $plan[0].Guid -NewValue 'Pendente' -Result 'Warning' `
                            -ErrorMessage $_.Exception.Message -Level 'Warning'
                    }
                }
                throw $activationError
            }
        }
        }
}

function Enable-UltimatePerformancePlan {
    [CmdletBinding()]
    param()

    return Invoke-OptimizerOperation -Name 'Ativar plano Desempenho Maximo' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $activeBefore = Get-ActivePowerPlanInternal
            $createdByCall = $false
            $plan = @(Get-PowerPlanListInternal | Where-Object {
                $_.Guid -eq $script:PowerGuids.UltimatePerformance -or $_.Name -eq 'Windows FPS Optimizer - Desempenho Maximo'
            } | Select-Object -First 1)
            if ($plan.Count -eq 0) {
                try {
                    $plan = @(New-PowerSchemeCloneInternal -SourceGuid $script:PowerGuids.UltimatePerformance `
                        -Name 'Windows FPS Optimizer - Desempenho Maximo')
                    $createdByCall = $true
                }
                catch {
                    $failureMessage = $_.Exception.Message
                    Write-PowerOptimizerLog -Name 'Plano Desempenho Maximo indisponivel' -OldValue '' `
                        -NewValue 'Alto Desempenho' -Result 'Warning' -ErrorMessage $failureMessage `
                        -Level 'Warning'
                    $fallback = Set-HighPerformancePlan
                    return [pscustomobject]@{
                        Result = 'FallbackHighPerformance'; Fallback = $true
                        Reason = $failureMessage; Activation = $fallback
                    }
                }
            }
            try {
                Set-ActivePowerPlanInternal -Guid $plan[0].Guid -Description 'Ativar plano Desempenho Maximo'
            }
            catch {
                $activationError = $_
                if ($createdByCall) {
                    try {
                        Remove-NewPowerSchemeInternal -Guid ([string]$plan[0].Guid) `
                            -FallbackGuid ([string]$activeBefore.Guid) -Description 'Desempenho Maximo'
                    }
                    catch {
                        Write-PowerOptimizerLog -Name 'Compensar criacao do plano Desempenho Maximo' `
                            -OldValue $plan[0].Guid -NewValue 'Pendente' -Result 'Warning' `
                            -ErrorMessage $_.Exception.Message -Level 'Warning'
                    }
                }
                throw $activationError
            }
        }
        }
}

function New-GamingPowerPlan {
    [CmdletBinding()]
    param([switch]$Activate)

    return Invoke-OptimizerOperation -Name 'Criar plano de energia para jogos' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $activeBefore = Get-ActivePowerPlanInternal
            $existing = @(Get-PowerPlanListInternal | Where-Object { $_.Name -eq $script:GamingPlanName } | Select-Object -First 1)
            if ($existing.Count -eq 0 -and -not $Activate) {
                throw 'A criacao de um novo plano sem ativa-lo foi bloqueada porque esse estado nao pode ser desfeito com seguranca pelo manifesto atual. Use -Activate.'
            }
            $created = ($existing.Count -eq 0)
            $plan = if (-not $created) { $existing[0] } else {
                $highSource = @(Get-PowerPlanListInternal | Where-Object {
                    $_.Guid -eq $script:PowerGuids.HighPerformance -or $_.Name -eq 'Windows FPS Optimizer - Alto Desempenho'
                } | Select-Object -First 1)
                $source = if ($highSource.Count -gt 0) { [string]$highSource[0].Guid } else { $script:PowerGuids.BalancedScheme }
                New-PowerSchemeCloneInternal -SourceGuid $source -Name $script:GamingPlanName
            }
            $activation = $null
            if ($Activate) {
                try {
                    $activation = Set-ActivePowerPlanInternal -Guid $plan.Guid -Description 'Ativar plano personalizado para jogos'
                }
                catch {
                    $activationError = $_
                    if ($created) {
                        try {
                            Remove-NewPowerSchemeInternal -Guid ([string]$plan.Guid) `
                                -FallbackGuid ([string]$activeBefore.Guid) -Description $script:GamingPlanName
                        }
                        catch {
                            Write-PowerOptimizerLog -Name 'Compensar criacao do plano personalizado' `
                                -OldValue $plan.Guid -NewValue 'Pendente' -Result 'Warning' `
                                -ErrorMessage $_.Exception.Message -Level 'Warning'
                        }
                    }
                    throw $activationError
                }
            }
            return [pscustomobject]@{
                Guid = [string]$plan.Guid; Name = [string]$plan.Name
                IsActive = [bool]$Activate; Created = $created; Activation = $activation
                Simulated = [bool](Get-OptimizerContext).Simulation
                RestoreFunction = 'Restore-PreviousPowerPlan'
            }
        }
        }
}

function Set-ProcessorPowerState {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 100)][int]$MinimumAC = 5,
        [ValidateRange(0, 100)][int]$MinimumDC = 5,
        [ValidateRange(1, 100)][int]$MaximumAC = 100,
        [ValidateRange(1, 100)][int]$MaximumDC = 100,
        [string]$SchemeGuid
    )

    if ($MinimumAC -gt $MaximumAC -or $MinimumDC -gt $MaximumDC) {
        throw 'O estado minimo do processador nao pode exceder o estado maximo.'
    }
    if ($MinimumAC -gt 50 -or $MinimumDC -gt 50) {
        Write-PowerOptimizerLog -Name 'Estado minimo elevado do processador' -OldValue '' `
            -NewValue @{ AC = $MinimumAC; DC = $MinimumDC } -Result 'Warning' `
            -ErrorMessage 'Valores altos aumentam consumo e temperatura e podem piorar o boost sustentado.' -Level 'Warning'
    }
    return Invoke-OptimizerOperation -Name 'Configurar estados do processador' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $target = if ([string]::IsNullOrWhiteSpace($SchemeGuid)) { (Get-ActivePowerPlanInternal).Guid } else { ConvertTo-NormalizedPowerGuid -Guid $SchemeGuid }
            $min = Set-PowerSettingInternal -SchemeGuid $target -SubgroupGuid $script:PowerGuids.ProcessorSubgroup `
                -SettingGuid $script:PowerGuids.ProcessorMinimum -ACValue $MinimumAC -DCValue $MinimumDC `
                -Description 'Estado minimo do processador'
            $max = Set-PowerSettingInternal -SchemeGuid $target -SubgroupGuid $script:PowerGuids.ProcessorSubgroup `
                -SettingGuid $script:PowerGuids.ProcessorMaximum -ACValue $MaximumAC -DCValue $MaximumDC `
                -Description 'Estado maximo do processador'
            Invoke-PowerCfg -Arguments @('/setactive', $target) -Description 'Atualizar plano apos alterar processador' `
                -Mutating -RequiresAdministrator | Out-Null
            [pscustomobject]@{ Minimum = $min; Maximum = $max; SchemeGuid = $target }
        }
        }
}

function Set-CoolingPolicy {
    [CmdletBinding()]
    param(
        [ValidateSet('Active', 'Passive')][string]$ACPolicy = 'Active',
        [ValidateSet('Active', 'Passive')][string]$DCPolicy = 'Passive',
        [string]$SchemeGuid
    )

    return Invoke-OptimizerOperation -Name 'Configurar politica de resfriamento' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $target = if ([string]::IsNullOrWhiteSpace($SchemeGuid)) { (Get-ActivePowerPlanInternal).Guid } else { ConvertTo-NormalizedPowerGuid -Guid $SchemeGuid }
            $acValue = if ($ACPolicy -eq 'Active') { 1 } else { 0 }
            $dcValue = if ($DCPolicy -eq 'Active') { 1 } else { 0 }
            $result = Set-PowerSettingInternal -SchemeGuid $target -SubgroupGuid $script:PowerGuids.ProcessorSubgroup `
                -SettingGuid $script:PowerGuids.CoolingPolicy -ACValue $acValue -DCValue $dcValue `
                -Description 'Politica de resfriamento do sistema'
            Invoke-PowerCfg -Arguments @('/setactive', $target) -Description 'Atualizar politica de resfriamento' `
                -Mutating -RequiresAdministrator | Out-Null
            return $result
        }
        }
}

function Set-DisplayAndSleepTimeout {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 1440)][int]$DisplayMinutesAC = 20,
        [ValidateRange(0, 1440)][int]$DisplayMinutesDC = 10,
        [ValidateRange(0, 1440)][int]$SleepMinutesAC = 0,
        [ValidateRange(0, 1440)][int]$SleepMinutesDC = 30,
        [string]$SchemeGuid
    )

    return Invoke-OptimizerOperation -Name 'Configurar tela e suspensao' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $target = if ([string]::IsNullOrWhiteSpace($SchemeGuid)) { (Get-ActivePowerPlanInternal).Guid } else { ConvertTo-NormalizedPowerGuid -Guid $SchemeGuid }
            $display = Set-PowerSettingInternal -SchemeGuid $target -SubgroupGuid $script:PowerGuids.DisplaySubgroup `
                -SettingGuid $script:PowerGuids.DisplayIdle -ACValue ($DisplayMinutesAC * 60) `
                -DCValue ($DisplayMinutesDC * 60) -Description 'Tempo para desligar a tela'
            $sleep = Set-PowerSettingInternal -SchemeGuid $target -SubgroupGuid $script:PowerGuids.SleepSubgroup `
                -SettingGuid $script:PowerGuids.SleepIdle -ACValue ($SleepMinutesAC * 60) `
                -DCValue ($SleepMinutesDC * 60) -Description 'Tempo para suspender o computador'
            Invoke-PowerCfg -Arguments @('/setactive', $target) -Description 'Atualizar tempos de energia' `
                -Mutating -RequiresAdministrator | Out-Null
            [pscustomobject]@{ Display = $display; Sleep = $sleep; SchemeGuid = $target }
        }
        }
}

function Set-GameSessionPower {
    [CmdletBinding()]
    param(
        [ValidateSet('None', 'HighPerformance', 'Ultimate', 'Custom')]
        [string]$Plan = 'HighPerformance',
        [switch]$PreventSleep
    )

    if ($Plan -eq 'None' -and -not $PreventSleep) {
        return [pscustomobject]@{
            Result = 'Skipped'; Reason = 'Nenhuma alteracao de energia solicitada.'
            Activation = $null; SleepAdjustment = $null
        }
    }

    return Invoke-OptimizerOperation -Name 'Ativar energia para sessao de jogo' -Risk 'Moderado' `
        -RequiresAdministrator -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $before = Get-PowerPlanState
            $activation = $null
            if ($Plan -ne 'None') {
                switch ($Plan) {
                    'Ultimate' { $activation = Enable-UltimatePerformancePlan }
                    'Custom' {
                        $custom = New-GamingPowerPlan -Activate
                        $activation = [pscustomobject]@{ Plan = $custom; Result = 'Success' }
                    }
                    default { $activation = Set-HighPerformancePlan }
                }
            }
            $sleepResult = $null
            if ($PreventSleep) {
                $current = Get-PowerPlanState
                $screenAC = if ($current.DisplayTimeout.Supported) { [int]$current.DisplayTimeout.AC } else { 1200 }
                $screenDC = if ($current.DisplayTimeout.Supported) { [int]$current.DisplayTimeout.DC } else { 600 }
                $sleepResult = Set-PowerSettingInternal -SchemeGuid $current.ActivePlan.Guid `
                    -SubgroupGuid $script:PowerGuids.SleepSubgroup -SettingGuid $script:PowerGuids.SleepIdle `
                    -ACValue 0 -DCValue 0 -Description 'Impedir suspensao durante a sessao de jogo'
                Invoke-PowerCfg -Arguments @('/setactive', $current.ActivePlan.Guid) `
                    -Description 'Aplicar suspensao da sessao de jogo' -Mutating -RequiresAdministrator | Out-Null
                # As variaveis mantem o valor de tela visivel no token sem altera-lo.
                $null = $screenAC
                $null = $screenDC
            }
            [pscustomobject]@{
                StartedAt       = (Get-Date)
                PreviousState   = $before
                Activation      = $activation
                SleepAdjustment = $sleepResult
                RestoreFunction = 'Restore-PreviousPowerPlan'
            }
        }
        }
}

function Restore-PreviousPowerPlan {
    [CmdletBinding()]
    param([switch]$Force)

    return Invoke-OptimizerOperation -Name 'Restaurar configuracoes anteriores de energia' `
        -Risk 'Seguro' -RequiresAdministrator -SkipRestorePoint -ScriptBlock {
        return Invoke-WithPowerStateRollback -ScriptBlock {
            $statePath = Get-PowerStatePath
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
                Write-PowerOptimizerLog -Name 'Restaurar energia' -OldValue '' -NewValue '' -Result 'Skipped'
                return [pscustomobject]@{ Result = 'Skipped'; Reason = 'Nenhum estado de energia salvo.' }
            }
            $state = Read-PowerOptimizationState
            $restored = New-Object System.Collections.Generic.List[object]
            $conflicts = New-Object System.Collections.Generic.List[object]

            foreach ($entry in @($state.Settings)) {
                $current = Get-PowerSettingIndexInternal -SchemeGuid ([string]$entry.SchemeGuid) `
                    -SubgroupGuid ([string]$entry.SubgroupGuid) -SettingGuid ([string]$entry.SettingGuid)
                if (-not $current.Supported) {
                    $conflicts.Add([pscustomobject]@{ Type = 'PowerSetting'; Key = $entry.Key; Reason = 'Configuracao nao esta disponivel no plano atual.' })
                    continue
                }
                $matchesOriginal = ([int]$current.AC -eq [int]$entry.OriginalAC -and `
                    [int]$current.DC -eq [int]$entry.OriginalDC)
                if ($matchesOriginal) {
                    $restored.Add([pscustomobject]@{ Type = 'PowerSetting'; Key = $entry.Key; Result = 'AlreadyRestored' })
                    continue
                }
                $matchesApplied = ([int]$current.AC -eq [int]$entry.AppliedAC -and [int]$current.DC -eq [int]$entry.AppliedDC)
                if (-not $Force -and -not $matchesApplied) {
                    $conflicts.Add([pscustomobject]@{ Type = 'PowerSetting'; Key = $entry.Key; Current = $current; Applied = @{ AC = $entry.AppliedAC; DC = $entry.AppliedDC } })
                    continue
                }
                $result = Set-PowerSettingInternal -SchemeGuid ([string]$entry.SchemeGuid) `
                    -SubgroupGuid ([string]$entry.SubgroupGuid) -SettingGuid ([string]$entry.SettingGuid) `
                    -ACValue ([int]$entry.OriginalAC) -DCValue ([int]$entry.OriginalDC) `
                    -Description ("Restaurar " + [string]$entry.Description) -SkipStateRegistration
                $restored.Add($result)
            }

            $original = [string]$state.OriginalActiveScheme
            if (-not [string]::IsNullOrWhiteSpace($original)) {
                $currentPlan = Get-ActivePowerPlanInternal
                $alreadyOriginal = ($currentPlan.Guid -eq $original)
                $canRestorePlan = $alreadyOriginal -or $Force -or [string]::IsNullOrWhiteSpace([string]$state.AppliedActiveScheme) `
                    -or $currentPlan.Guid -eq [string]$state.AppliedActiveScheme
                $originalExists = (@((Get-PowerPlanListInternal) | Where-Object { $_.Guid -eq $original }).Count -gt 0)
                if ($alreadyOriginal) {
                    $restored.Add([pscustomobject]@{ Type = 'PowerActiveScheme'; Guid = $original; Result = 'AlreadyRestored' })
                }
                elseif (-not $originalExists) {
                    $conflicts.Add([pscustomobject]@{ Type = 'PowerActiveScheme'; Current = $currentPlan.Guid; Original = $original; Reason = 'Plano original nao existe mais.' })
                }
                elseif ($canRestorePlan) {
                    $restored.Add((Set-ActivePowerPlanInternal -Guid $original `
                        -Description 'Restaurar plano de energia anterior' -SkipStateRegistration))
                }
                elseif (-not $canRestorePlan) {
                    $conflicts.Add([pscustomobject]@{ Type = 'PowerActiveScheme'; Current = $currentPlan.Guid; Applied = $state.AppliedActiveScheme; Original = $original })
                }
            }

            $activeNow = (Get-ActivePowerPlanInternal).Guid
            foreach ($created in @($state.CreatedSchemes)) {
                $guid = [string]$created.Guid
                if ($activeNow -eq $guid) { continue }
                $createdPlan = @((Get-PowerPlanListInternal) | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1)
                if ($createdPlan.Count -eq 0) { continue }
                $expectedName = [string]$created.Name
                if (-not $Force -and ([string]::IsNullOrWhiteSpace($expectedName) -or
                        [string]$createdPlan[0].Name -ne $expectedName -or
                        $expectedName -notlike 'Windows FPS Optimizer*')) {
                    $conflicts.Add([pscustomobject]@{
                        Type = 'CreatedPowerScheme'; Guid = $guid; CurrentName = [string]$createdPlan[0].Name
                        ExpectedName = $expectedName; Reason = 'O plano criado foi renomeado ou nao possui a marca esperada.'
                    })
                    continue
                }
                Invoke-PowerCfg -Arguments @('/delete', $guid) -Description "Remover plano criado pelo otimizador: $guid" `
                    -Mutating -RequiresAdministrator | Out-Null
                $restored.Add([pscustomobject]@{ Type = 'DeletedCreatedScheme'; Guid = $guid })
            }

            $context = Get-OptimizerContext
            if (-not $context.Simulation -and $conflicts.Count -eq 0) {
                Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
            }
            Write-PowerOptimizerLog -Name 'Restaurar configuracoes de energia' -OldValue $state `
                -NewValue @{ Restored = $restored.Count; Conflicts = $conflicts.Count } `
                -Result $(if ($conflicts.Count -gt 0) { 'Warning' } else { 'Restored' }) `
                -ErrorMessage $(if ($conflicts.Count -gt 0) { 'Itens alterados depois da otimizacao nao foram sobrescritos.' } else { '' }) `
                -Level $(if ($conflicts.Count -gt 0) { 'Warning' } else { 'Information' })
            return [pscustomobject]@{
                Result = if ($context.Simulation) { 'Simulated' } elseif ($conflicts.Count -gt 0) { 'Partial' } else { 'Restored' }
                Restored = @($restored | ForEach-Object { $_ })
                Conflicts = @($conflicts | ForEach-Object { $_ })
            }
        }
        }
}

function Open-PowerOptions {
    [CmdletBinding()]
    param()

    Start-Process -FilePath 'control.exe' -ArgumentList '/name Microsoft.PowerOptions' -ErrorAction Stop | Out-Null
    Write-PowerOptimizerLog -Name 'Abrir Opcoes de Energia' -OldValue '' -NewValue 'control.exe' -Result 'Success'
    return $true
}

Export-ModuleMember -Function Get-PowerCapabilities, Get-PowerPlanState,
    Set-HighPerformancePlan, Enable-UltimatePerformancePlan, New-GamingPowerPlan,
    Set-ProcessorPowerState, Set-CoolingPolicy, Set-DisplayAndSleepTimeout,
    Set-GameSessionPower, Restore-PreviousPowerPlan, Open-PowerOptions,
    Sync-PowerStateAfterBackupRestore
