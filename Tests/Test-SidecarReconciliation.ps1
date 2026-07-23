#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($module in @('Core.psm1', 'BackupManager.psm1', 'StartupManager.psm1',
        'PowerOptimizations.psm1', 'GraphicsOptimizations.psm1')) {
    Import-Module (Join-Path $projectRoot $module) -Force -DisableNameChecking -ErrorAction Stop
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsFPSOptimizer-Sidecar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force -ErrorAction Stop | Out-Null
try {
    # Contexto minimo para os sidecars: somente a pasta temporaria e escrita.
    & (Get-Module Core) {
        param($StateRoot)
        $script:OptimizerContext = [pscustomobject]@{
            StateRoot = $StateRoot; Simulation = $false; ReadOnly = $false
            CurrentProfile = 'Teste'; IsAdministrator = $false
        }
    } $fixtureRoot

    $schemeA = '11111111-1111-4111-8111-111111111111'
    $schemeB = '22222222-2222-4222-8222-222222222222'
    $schemeC = '33333333-3333-4333-8333-333333333333'
    $subGroup = '44444444-4444-4444-8444-444444444444'
    $setting = '55555555-5555-4555-8555-555555555555'
    $settingKey = "$schemeA|$subGroup|$setting"

    # Energia: A->B (op1), B->C (op2), undo op2 deixa A->B; undo op1 zera.
    $powerState = [pscustomobject][ordered]@{
        SchemaVersion = 1; OriginalActiveScheme = $null; AppliedActiveScheme = $null
        Settings = @([pscustomobject][ordered]@{
            Key = $settingKey; SchemeGuid = $schemeA; SubgroupGuid = $subGroup; SettingGuid = $setting
            OriginalAC = 10; OriginalDC = 11; AppliedAC = 30; AppliedDC = 31; Description = 'fixture'
        })
        CreatedSchemes = @(); UpdatedAt = ''
    }
    $powerOp2 = [pscustomobject]@{
        Type = 'PowerSetting'; Id = $settingKey
        Original = [pscustomobject]@{ SchemeGuid = $schemeA; SubGroupGuid = $subGroup; SettingGuid = $setting; AcValueIndex = 20; DcValueIndex = 21 }
        Applied = [pscustomobject]@{ SchemeGuid = $schemeA; SubGroupGuid = $subGroup; SettingGuid = $setting; AcValueIndex = 30; DcValueIndex = 31 }
    }
    $powerOp1 = [pscustomobject]@{
        Type = 'PowerSetting'; Id = $settingKey
        Original = [pscustomobject]@{ SchemeGuid = $schemeA; SubGroupGuid = $subGroup; SettingGuid = $setting; AcValueIndex = 10; DcValueIndex = 11 }
        Applied = [pscustomobject]@{ SchemeGuid = $schemeA; SubGroupGuid = $subGroup; SettingGuid = $setting; AcValueIndex = 20; DcValueIndex = 21 }
    }
    $powerModule = Get-Module PowerOptimizations
    & $powerModule { param($State, $Entry) Update-PowerStateForRestoredBackupEntry -State $State -Entry $Entry } $powerState $powerOp2 | Out-Null
    Assert-True ($powerState.Settings.Count -eq 1 -and [int]$powerState.Settings[0].OriginalAC -eq 10 -and
        [int]$powerState.Settings[0].AppliedAC -eq 20) 'Undo op2 nao reduziu PowerSetting de A->C para A->B.'
    & $powerModule { param($State, $Entry) Update-PowerStateForRestoredBackupEntry -State $State -Entry $Entry } $powerState $powerOp1 | Out-Null
    Assert-True (@($powerState.Settings).Count -eq 0) 'Undo op1 nao removeu o PowerSetting sem efeito liquido.'

    # Plano ativo e clones: remova do sidecar apenas o clone realmente ausente.
    $planState = [pscustomobject][ordered]@{
        SchemaVersion = 1; OriginalActiveScheme = $schemeA; AppliedActiveScheme = $schemeC; Settings = @()
        CreatedSchemes = @(
            [pscustomobject]@{ Guid = $schemeB; Name = 'Windows FPS Optimizer - B' },
            [pscustomobject]@{ Guid = $schemeC; Name = 'Windows FPS Optimizer - C' }
        ); UpdatedAt = ''
    }
    $planOp2 = [pscustomobject]@{
        Type = 'PowerPlan'; Id = 'active-plan'
        Original = [pscustomobject]@{ ActiveSchemeGuid = $schemeB }
        Applied = [pscustomobject]@{ ActiveSchemeGuid = $schemeC }
    }
    & $powerModule {
        param($State, $Entry, $Existing)
        Update-PowerStateForRestoredBackupEntry -State $State -Entry $Entry -ExistingSchemeGuids $Existing
    } $planState $planOp2 @($schemeB) | Out-Null
    Assert-True ([string]$planState.OriginalActiveScheme -eq $schemeA -and
        [string]$planState.AppliedActiveScheme -eq $schemeB) 'Undo op2 nao reduziu o plano ativo de A->C para A->B.'
    Assert-True (@($planState.CreatedSchemes).Count -eq 1 -and
        [string]$planState.CreatedSchemes[0].Guid -eq $schemeB) 'Clone existente foi esquecido ou clone removido foi mantido.'

    $planOp1 = [pscustomobject]@{
        Type = 'PowerPlan'; Id = 'active-plan'
        Original = [pscustomobject]@{ ActiveSchemeGuid = $schemeA }
        Applied = [pscustomobject]@{ ActiveSchemeGuid = $schemeB }
    }
    $retainedPlanState = $planState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $powerModule {
        param($State, $Entry, $Existing)
        Update-PowerStateForRestoredBackupEntry -State $State -Entry $Entry -ExistingSchemeGuids $Existing
    } $retainedPlanState $planOp1 @($schemeB) | Out-Null
    Assert-True ([string]::IsNullOrWhiteSpace([string]$retainedPlanState.OriginalActiveScheme) -and
        @($retainedPlanState.CreatedSchemes).Count -eq 1) 'Clone nao removido deveria permanecer rastreado.'
    Assert-True ([bool](& $powerModule { param($State) Test-PowerStateHasNetChanges -State $State } $retainedPlanState)) `
        'Um clone ainda existente deve manter o sidecar de energia.'

    & $powerModule {
        param($State, $Entry)
        Update-PowerStateForRestoredBackupEntry -State $State -Entry $Entry -ExistingSchemeGuids @()
    } $planState $planOp1 | Out-Null
    Assert-True (-not [bool](& $powerModule { param($State) Test-PowerStateHasNetChanges -State $State } $planState)) `
        'Undo op1 deveria zerar o sidecar quando todos os clones foram removidos.'

    # Visual: mesma cadeia para SystemParameters e Registro.
    $graphicsModule = Get-Module GraphicsOptimizations
    $visualState = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Entries = @([pscustomobject][ordered]@{
            Id = 'SystemParameter|MenuDelay'; Kind = 'SystemParameter'; Option = 'MenuDelay'
            Original = 400; Applied = 20
        })
        UpdatedAt = ''
    }
    $visualOp2 = [pscustomobject]@{ Type = 'SystemParameter'; Id = 'MenuDelay'; Original = [pscustomobject]@{ Option = 'MenuDelay'; Value = 100 }; Applied = [pscustomobject]@{ Option = 'MenuDelay'; Value = 20 } }
    $visualOp1 = [pscustomobject]@{ Type = 'SystemParameter'; Id = 'MenuDelay'; Original = [pscustomobject]@{ Option = 'MenuDelay'; Value = 400 }; Applied = [pscustomobject]@{ Option = 'MenuDelay'; Value = 100 } }
    & $graphicsModule { param($State, $Entry) Update-VisualStateForRestoredBackupEntry -State $State -Entry $Entry } $visualState $visualOp2 | Out-Null
    Assert-True (@($visualState.Entries).Count -eq 1 -and [int]$visualState.Entries[0].Applied -eq 100 -and
        [int]$visualState.Entries[0].Original -eq 400) 'Undo op2 nao reduziu o estado visual de A->C para A->B.'
    & $graphicsModule { param($State, $Entry) Update-VisualStateForRestoredBackupEntry -State $State -Entry $Entry } $visualState $visualOp1 | Out-Null
    Assert-True (@($visualState.Entries).Count -eq 0) 'Undo op1 nao removeu o SystemParameter sem efeito liquido.'

    $visualRegistryState = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Entries = @([pscustomobject][ordered]@{
            Id = 'Registry|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarAnimations'
            Kind = 'Registry'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            Name = 'TaskbarAnimations'
            Original = [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; ValueExisted = $true; Value = 1; Kind = 'DWord' }
            Applied = 0; AppliedExists = $true; ValueType = 'DWord'
        })
        UpdatedAt = ''
    }
    $registryOp2 = [pscustomobject]@{
        Type = 'RegistryValue'; Id = 'fixture'
        Original = [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; ValueExisted = $true; Value = 2; Kind = 'DWord' }
        Applied = [pscustomobject]@{ ValueExisted = $true; Value = 0; Kind = 'DWord' }
    }
    & $graphicsModule { param($State, $Entry) Update-VisualStateForRestoredBackupEntry -State $State -Entry $Entry } $visualRegistryState $registryOp2 | Out-Null
    Assert-True ([int]$visualRegistryState.Entries[0].Applied -eq 2 -and [bool]$visualRegistryState.Entries[0].AppliedExists) `
        'Undo op2 nao atualizou o valor visual de Registro aplicado.'
    $registryOp1 = [pscustomobject]@{
        Type = 'RegistryValue'; Id = 'fixture'
        Original = [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; ValueExisted = $true; Value = 1; Kind = 'DWord' }
        Applied = [pscustomobject]@{ ValueExisted = $true; Value = 2; Kind = 'DWord' }
    }
    & $graphicsModule { param($State, $Entry) Update-VisualStateForRestoredBackupEntry -State $State -Entry $Entry } $visualRegistryState $registryOp1 | Out-Null
    Assert-True (@($visualRegistryState.Entries).Count -eq 0) 'Undo op1 nao removeu o Registro visual sem efeito liquido.'

    # Restauracao generica de startup deve limpar o registro fantasma do sidecar.
    $startupStatePath = Join-Path $fixtureRoot 'startup-disabled.json'
    @([pscustomobject]@{ Id = 'startup-1'; Name = 'Fixture'; SourceType = 'Registry' }) |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $startupStatePath -Encoding UTF8
    $startupEntry = [pscustomobject]@{ Type = 'StartupRegistry'; Id = 'startup-1' }
    & (Get-Module BackupManager) {
        param($Entry)
        Invoke-BackupSidecarReconciliation -Entry $Entry -Status 'AlreadyRestored'
    } $startupEntry
    Assert-True (@(Get-DisabledStartupState).Count -eq 0) 'Restore generico deixou registro fantasma de startup.'

    # Status de conflito/erro sao recusados antes de qualquer escrita no sidecar.
    @([pscustomobject]@{ Id = 'startup-2'; Name = 'Fixture'; SourceType = 'Registry' }) |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $startupStatePath -Encoding UTF8
    $beforeConflict = Get-Content -LiteralPath $startupStatePath -Raw
    foreach ($status in @('Conflict', 'Error')) {
        $rejected = $false
        try { Sync-StartupStateAfterBackupRestore -Entry ([pscustomobject]@{ Type = 'StartupRegistry'; Id = 'startup-2' }) -Status $status }
        catch { $rejected = $true }
        Assert-True $rejected "Status $status deveria ser recusado pelo reconciliador."
        Assert-True ((Get-Content -LiteralPath $startupStatePath -Raw) -ceq $beforeConflict) `
            "Status $status alterou indevidamente o sidecar."
    }

    # Os reconciliadores removem o arquivo quando nao resta efeito liquido.
    $powerPath = Join-Path $fixtureRoot 'PowerOptimizationState.json'
    $powerFileState = [pscustomobject][ordered]@{
        SchemaVersion = 1; OriginalActiveScheme = $null; AppliedActiveScheme = $null
        Settings = @([pscustomobject][ordered]@{
            Key = $settingKey; SchemeGuid = $schemeA; SubgroupGuid = $subGroup; SettingGuid = $setting
            OriginalAC = 10; OriginalDC = 11; AppliedAC = 20; AppliedDC = 21; Description = 'fixture'
        }); CreatedSchemes = @(); UpdatedAt = ''
    }
    $powerFileState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $powerPath -Encoding UTF8
    Sync-PowerStateAfterBackupRestore -Entry $powerOp1 -Status Restored | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $powerPath)) 'Sidecar de energia vazio nao foi removido.'

    $visualPath = Join-Path $fixtureRoot 'GraphicsVisualState.json'
    [pscustomobject][ordered]@{
        SchemaVersion = 1; Entries = @([pscustomobject]@{
            Id = 'SystemParameter|MenuDelay'; Kind = 'SystemParameter'; Option = 'MenuDelay'; Original = 400; Applied = 100
        }); UpdatedAt = ''
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $visualPath -Encoding UTF8
    Sync-VisualStateAfterBackupRestore -Entry $visualOp1 -Status AlreadyRestored | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $visualPath)) 'Sidecar visual vazio nao foi removido.'

    Write-Host 'TESTE DE RECONCILIACAO APROVADO: fixtures locais, sem tweaks reais.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
