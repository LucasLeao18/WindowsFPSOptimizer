#requires -Version 5.1

Set-StrictMode -Version Latest

$script:PrivacySettingsPages = @{
    General         = 'ms-settings:privacy-general'
    Diagnostics     = 'ms-settings:privacy-feedback'
    ActivityHistory = 'ms-settings:privacy-activityhistory'
    InstalledApps   = 'ms-settings:appsfeatures'
    Start           = 'ms-settings:personalization-start'
}

function Write-PrivacyOptimizerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $OldValue,
        $NewValue,
        [ValidateSet('Success', 'Skipped', 'Simulated', 'Warning', 'Error', 'Info', 'Restored')]
        [string]$Result = 'Info',
        [string]$ErrorMessage = '',
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')][string]$Level = 'Information'
    )

    if (Get-Command Write-OptimizerLog -ErrorAction SilentlyContinue) {
        $profile = ''
        try { $profile = [string](Get-OptimizerContext).CurrentProfile } catch { }
        Write-OptimizerLog -Name $Name -Category 'Privacidade' -OldValue $OldValue -NewValue $NewValue `
            -Result $Result -ErrorMessage $ErrorMessage -RequiresRestart $false `
            -Profile $profile -Level $Level | Out-Null
    }
}

function Get-PrivacyEditionSupport {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    $caption = [string]$platform.Caption
    $editionId = ''
    $productName = ''
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $editionId = [string]$currentVersion.EditionID
        $productName = [string]$currentVersion.ProductName
    }
    catch { }
    $editionText = "$caption $editionId $productName"
    $enterprise = $editionText -match '(?i)Enterprise|Education|IoT'
    $pro = $enterprise -or $editionText -match '(?i)\bPro\b|Professional|Workstation'
    $home = $editionText -match '(?i)\bHome\b|Core|Single Language'
    return [pscustomobject]@{
        Caption       = $caption
        EditionId     = $editionId
        ProductName   = $productName
        IsHome        = [bool]$home
        IsProOrHigher = [bool]$pro
        IsEnterprise  = [bool]$enterprise
        IsKnown       = [bool]($home -or $pro)
    }
}

function Get-PolicyManagementStatus {
    <#
        O Windows nao expoe uma unica propriedade Win32 que cubra todo MDM.
        A deteccao combina dominio, inscricao ativa e tarefas EnterpriseMgmt.
        Nenhum dado de inscricao e alterado e nenhum comando de rede e executado.
    #>
    [CmdletBinding()]
    param()

    $domainJoined = $false
    $domainName = ''
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $domainJoined = [bool]$computer.PartOfDomain
        $domainName = [string]$computer.Domain
    }
    catch { }

    $enterpriseTasks = @()
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            $enterpriseTasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction Stop)
        }
        catch { }
    }

    $activeEnrollments = New-Object System.Collections.Generic.List[object]
    $enrollmentRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $enrollmentRoot) {
        foreach ($key in @(Get-ChildItem -LiteralPath $enrollmentRoot -ErrorAction SilentlyContinue)) {
            try {
                $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $state = $null
                if ($properties.PSObject.Properties['EnrollmentState']) { $state = [int]$properties.EnrollmentState }
                $provider = ''
                if ($properties.PSObject.Properties['ProviderID']) { $provider = [string]$properties.ProviderID }
                $discovery = ''
                if ($properties.PSObject.Properties['DiscoveryServiceFullURL']) { $discovery = [string]$properties.DiscoveryServiceFullURL }
                $upn = ''
                if ($properties.PSObject.Properties['UPN']) { $upn = [string]$properties.UPN }
                # O Windows mantem varias inscricoes internas (Cloud/Local/Deploy Authority)
                # que nao representam MDM. Exigimos um endpoint/usuario de descoberta ou
                # um provedor inequivocamente associado a gerenciamento de dispositivos.
                $providerLooksLikeMdm = $provider -match '(?i)MDM|Intune|Device\s*Management|AirWatch|MobileIron|Workspace\s*ONE|MaaS360|Citrix|VMware'
                if ($state -eq 1 -and ($discovery -or $upn -or $providerLooksLikeMdm)) {
                    $activeEnrollments.Add([pscustomobject]@{
                        Id = [string]$key.PSChildName
                        Provider = $provider
                        State = $state
                    })
                }
            }
            catch { }
        }
    }

    $mdmDetected = ($enterpriseTasks.Count -gt 0 -or $activeEnrollments.Count -gt 0)
    $details = New-Object System.Collections.Generic.List[string]
    if ($domainJoined) { $details.Add("Dominio: $domainName") }
    if ($enterpriseTasks.Count -gt 0) { $details.Add("Tarefas EnterpriseMgmt: $($enterpriseTasks.Count)") }
    if ($activeEnrollments.Count -gt 0) { $details.Add("Inscricoes MDM ativas: $($activeEnrollments.Count)") }
    if ($details.Count -eq 0) { $details.Add('Nenhum indicador ativo de dominio ou MDM foi encontrado.') }

    return [pscustomobject]@{
        IsManaged        = [bool]($domainJoined -or $mdmDetected)
        IsDomainJoined   = $domainJoined
        DomainName       = $domainName
        IsMdmEnrolled    = $mdmDetected
        EnrollmentCount  = $activeEnrollments.Count
        EnterpriseTasks  = $enterpriseTasks.Count
        DetectionDetail  = ($details -join '; ')
        Recommendation   = if ($domainJoined -or $mdmDetected) {
            'Nao sobrescrever politicas sem autorizacao do administrador da organizacao.'
        } else { 'Alteracoes locais podem ser aplicadas com backup.' }
    }
}

function Get-PrivacyPolicyCatalog {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{
            Name = 'TailoredExperiences'; Title = 'Experiencias personalizadas com dados de diagnostico'
            Description = 'Impede o uso de dados de diagnostico para experiencias e recomendacoes personalizadas.'
            Benefit = 'Privacidade e menos conteudo personalizado; impacto de desempenho nao comprovado.'
            Risk = 'Seguro'; Compatibility = 'ProPlus'; MinimumBuild = 15063; IsPolicy = $true
            Entries = @([pscustomobject]@{
                Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
                Name = 'DisableTailoredExperiencesWithDiagnosticData'; Type = 'DWord'; ProtectedValue = 1
                RequiresAdministrator = $false
            })
        },
        [pscustomobject]@{
            Name = 'ThirdPartySuggestions'; Title = 'Sugestoes de terceiros'
            Description = 'Desativa sugestoes de software e conteudo de terceiros nas experiencias do Windows.'
            Benefit = 'Menos sugestoes promocionais; nao bloqueia necessariamente sugestoes da Microsoft.'
            Risk = 'Seguro'; Compatibility = 'ProPlus'; MinimumBuild = 14393; IsPolicy = $true
            Entries = @([pscustomobject]@{
                Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
                Name = 'DisableThirdPartySuggestions'; Type = 'DWord'; ProtectedValue = 1
                RequiresAdministrator = $false
            })
        },
        [pscustomobject]@{
            Name = 'AdvertisingId'; Title = 'Identificacao de publicidade'
            Description = 'Desativa o identificador de publicidade do Windows por politica documentada.'
            Benefit = 'Privacidade. Nao produz ganho mensuravel de FPS.'
            Risk = 'Seguro'; Compatibility = 'ProPlus'; MinimumBuild = 14393; IsPolicy = $true
            Entries = @([pscustomobject]@{
                Path = 'HKLM:\Software\Policies\Microsoft\Windows\AdvertisingInfo'
                Name = 'DisabledByGroupPolicy'; Type = 'DWord'; ProtectedValue = 1
                RequiresAdministrator = $true
            })
        },
        [pscustomobject]@{
            Name = 'ActivityHistory'; Title = 'Historico de atividades'
            Description = 'Desativa feed, publicacao e upload de atividades usando as politicas oficiais.'
            Benefit = 'Privacidade; o upload ja foi descontinuado em builds atualizadas e o impacto em desempenho e minimo.'
            Risk = 'Moderado'; Compatibility = 'ProPlus'; MinimumBuild = 17134; IsPolicy = $true
            Entries = @(
                [pscustomobject]@{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; Type = 'DWord'; ProtectedValue = 0; RequiresAdministrator = $true },
                [pscustomobject]@{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Type = 'DWord'; ProtectedValue = 0; RequiresAdministrator = $true },
                [pscustomobject]@{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; Type = 'DWord'; ProtectedValue = 0; RequiresAdministrator = $true }
            )
        },
        [pscustomobject]@{
            Name = 'OptionalDiagnostics'; Title = 'Dados de diagnostico opcionais'
            Description = 'Limita a coleta ao nivel obrigatorio usando AllowTelemetry=1.'
            Benefit = 'Reduz dados opcionais; pode limitar informacoes usadas para diagnosticar falhas.'
            Risk = 'Moderado'; Compatibility = 'ProPlus'; MinimumBuild = 15063; IsPolicy = $true
            Entries = @([pscustomobject]@{
                Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'
                Name = 'AllowTelemetry'; Type = 'DWord'; ProtectedValue = 1
                RequiresAdministrator = $true
            })
        },
        [pscustomobject]@{
            Name = 'WindowsTips'; Title = 'Dicas do Windows'
            Description = 'Desativa dicas e recomendacoes de introducao pela politica DisableSoftLanding.'
            Benefit = 'Menos sugestoes ocasionais; impacto de desempenho pequeno ou inexistente.'
            Risk = 'Seguro'; Compatibility = 'EnterpriseOnly'; MinimumBuild = 14393; IsPolicy = $true
            Entries = @([pscustomobject]@{
                Path = 'HKLM:\Software\Policies\Microsoft\Windows\CloudContent'
                Name = 'DisableSoftLanding'; Type = 'DWord'; ProtectedValue = 1
                RequiresAdministrator = $true
            })
        },
        [pscustomobject]@{
            Name = 'WindowsConsumerFeatures'; Title = 'Recursos de consumo do Windows'
            Description = 'Desativa sugestoes e provisionamento promocional cobertos pela politica oficial.'
            Benefit = 'Menos recomendacoes promocionais; nao deve ser apresentado como aumento de FPS.'
            Risk = 'Moderado'; Compatibility = 'EnterpriseOnly'; MinimumBuild = 14393; IsPolicy = $true
            Entries = @([pscustomobject]@{
                Path = 'HKLM:\Software\Policies\Microsoft\Windows\CloudContent'
                Name = 'DisableWindowsConsumerFeatures'; Type = 'DWord'; ProtectedValue = 1
                RequiresAdministrator = $true
            })
        },
        [pscustomobject]@{
            Name = 'StartRecommendations'; Title = 'Recomendacoes do menu Iniciar'
            Description = 'Controla dicas, atalhos, novos aplicativos e outras recomendacoes no menu Iniciar do Windows 11.'
            Benefit = 'Interface mais limpa; nao ha ganho direto de FPS.'
            Risk = 'Seguro'; Compatibility = 'Windows11'; MinimumBuild = 22000; IsPolicy = $false
            Entries = @([pscustomobject]@{
                Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Name = 'Start_IrisRecommendations'; Type = 'DWord'; ProtectedValue = 0
                RequiresAdministrator = $false
            })
        }
    )
}

function Get-PrivacyPolicyDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)

    $definitions = @(Get-PrivacyPolicyCatalog | Where-Object { $_.Name -eq $Name })
    if ($definitions.Count -ne 1) { throw "A configuracao de privacidade '$Name' nao esta na allowlist documentada." }
    return $definitions[0]
}

function Get-PrivacyPolicyCompatibility {
    param([Parameter(Mandatory = $true)]$Definition)

    $platform = Get-WindowsPlatformInfo
    $edition = Get-PrivacyEditionSupport
    $supported = [bool]($platform.IsSupported -and $platform.Build -ge [int]$Definition.MinimumBuild)
    $reason = ''
    if (-not $supported) { $reason = 'Build do Windows nao suportado para esta configuracao.' }
    elseif ([string]$Definition.Compatibility -eq 'Windows11' -and -not $platform.IsWindows11) {
        $supported = $false; $reason = 'Configuracao disponivel somente no Windows 11.'
    }
    elseif ([string]$Definition.Compatibility -eq 'ProPlus' -and -not $edition.IsProOrHigher) {
        $supported = $false; $reason = 'Politica suportada apenas em Pro, Enterprise, Education ou IoT.'
    }
    elseif ([string]$Definition.Compatibility -eq 'EnterpriseOnly' -and -not $edition.IsEnterprise) {
        $supported = $false; $reason = 'Politica suportada apenas em Enterprise, Education ou IoT.'
    }
    if ($supported) { $reason = 'Compativel com esta edicao e build.' }
    return [pscustomobject]@{ Supported = $supported; Reason = $reason; Platform = $platform; Edition = $edition }
}

function Get-PrivacyOptimizationState {
    [CmdletBinding()]
    param([string]$Name)

    $management = Get-PolicyManagementStatus
    $definitions = if ($Name) { @(Get-PrivacyPolicyDefinition -Name $Name) } else { @(Get-PrivacyPolicyCatalog) }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($definition in $definitions) {
        $compatibility = Get-PrivacyPolicyCompatibility -Definition $definition
        $entries = New-Object System.Collections.Generic.List[object]
        $allProtected = $true
        $anyPresent = $false
        foreach ($entry in @($definition.Entries)) {
            $state = Get-RegistryValueState -Path ([string]$entry.Path) -Name ([string]$entry.Name)
            if ($state.ValueExisted) { $anyPresent = $true }
            if (-not $state.ValueExisted -or -not (Compare-OptimizerValue $state.Value $entry.ProtectedValue)) { $allProtected = $false }
            $entries.Add([pscustomobject]@{
                Path = [string]$entry.Path; Name = [string]$entry.Name
                ValueExisted = [bool]$state.ValueExisted; Value = $state.Value; Kind = $state.Kind
                ProtectedValue = $entry.ProtectedValue
            })
        }
        $stateLabel = if (-not $compatibility.Supported) { 'Unsupported' } `
            elseif ($allProtected) { 'Protected' } elseif ($anyPresent) { 'ConfiguredOther' } else { 'NotConfigured' }
        $managedBlocked = [bool]($definition.IsPolicy -and $management.IsManaged)
        $result.Add([pscustomobject]@{
            Name = [string]$definition.Name; Title = [string]$definition.Title
            Description = [string]$definition.Description; Benefit = [string]$definition.Benefit
            Risk = [string]$definition.Risk; State = $stateLabel
            Supported = [bool]$compatibility.Supported; CompatibilityReason = [string]$compatibility.Reason
            IsPolicy = [bool]$definition.IsPolicy; ManagedDevice = [bool]$management.IsManaged
            ManagedWriteBlocked = $managedBlocked; Entries = $entries.ToArray()
            RequiresRestart = $false
        })
    }
    return $result.ToArray()
}

function Set-DocumentedPrivacyProtection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Disabled,
        [switch]$AllowManagedDevice
    )

    $definition = Get-PrivacyPolicyDefinition -Name $Name
    $compatibility = Get-PrivacyPolicyCompatibility -Definition $definition
    if (-not $compatibility.Supported) {
        $state = @(Get-PrivacyOptimizationState -Name $Name)[0]
        Write-PrivacyOptimizerLog -Name $definition.Title -OldValue $state.State -NewValue 'Unsupported' `
            -Result 'Skipped' -ErrorMessage $compatibility.Reason
        return $state
    }
    $management = Get-PolicyManagementStatus
    if ($definition.IsPolicy -and $management.IsManaged -and -not $AllowManagedDevice) {
        throw "O computador aparenta ser gerenciado por dominio ou MDM. '$($definition.Title)' nao sera sobrescrita sem confirmacao explicita."
    }
    $requiresAdministrator = @($definition.Entries | Where-Object { $_.RequiresAdministrator }).Count -gt 0
    $operationName = $(if ($Disabled) { "Aplicar: $($definition.Title)" } else { "Devolver ao usuario: $($definition.Title)" })
    return Invoke-OptimizerOperation -Name $operationName -Risk ([string]$definition.Risk) `
        -RequiresAdministrator:$requiresAdministrator -SkipRestorePoint -ScriptBlock {
            $changes = New-Object System.Collections.Generic.List[object]
            foreach ($entry in @($definition.Entries)) {
                if ($Disabled) {
                    $changes.Add((Set-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                        -Value $entry.ProtectedValue -Type ([string]$entry.Type) `
                        -RequiresAdministrator:([bool]$entry.RequiresAdministrator) -Description $definition.Title))
                }
                else {
                    # Remover volta a "Nao configurado"; escrever zero deixaria o dispositivo gerenciado.
                    $changes.Add((Remove-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                        -RequiresAdministrator:([bool]$entry.RequiresAdministrator) -Description ("Remover politica: " + $definition.Title)))
                }
            }
            return [pscustomobject]@{
                Name = $definition.Name; Disabled = $Disabled; Changes = $changes.ToArray()
                State = @(Get-PrivacyOptimizationState -Name $definition.Name)[0]
            }
        }
}

function Set-TailoredExperiencesDisabled {
    [CmdletBinding()]
    param([bool]$Disabled = $true, [switch]$AllowManagedDevice)
    return Set-DocumentedPrivacyProtection -Name TailoredExperiences -Disabled $Disabled -AllowManagedDevice:$AllowManagedDevice
}

function Set-ThirdPartySuggestionsDisabled {
    [CmdletBinding()]
    param([bool]$Disabled = $true, [switch]$AllowManagedDevice)
    return Set-DocumentedPrivacyProtection -Name ThirdPartySuggestions -Disabled $Disabled -AllowManagedDevice:$AllowManagedDevice
}

function Set-AdvertisingIdDisabled {
    [CmdletBinding()]
    param([bool]$Disabled = $true, [switch]$AllowManagedDevice)
    $result = Set-DocumentedPrivacyProtection -Name AdvertisingId -Disabled $Disabled -AllowManagedDevice:$AllowManagedDevice
    if (-not $Disabled) {
        Write-PrivacyOptimizerLog -Name 'Reativar identificacao de publicidade' -OldValue 'Disabled' -NewValue 'UserControl' `
            -Result 'Warning' -ErrorMessage 'O identificador anterior nao pode ser recuperado; o Windows pode criar um novo.' -Level 'Warning'
    }
    return $result
}

function Set-ActivityHistoryDisabled {
    [CmdletBinding()]
    param([bool]$Disabled = $true, [switch]$AllowManagedDevice)
    return Set-DocumentedPrivacyProtection -Name ActivityHistory -Disabled $Disabled -AllowManagedDevice:$AllowManagedDevice
}

function Set-WindowsTipsDisabled {
    [CmdletBinding()]
    param([bool]$Disabled = $true, [switch]$AllowManagedDevice)
    return Set-DocumentedPrivacyProtection -Name WindowsTips -Disabled $Disabled -AllowManagedDevice:$AllowManagedDevice
}

function Set-WindowsConsumerFeaturesDisabled {
    [CmdletBinding()]
    param([bool]$Disabled = $true, [switch]$AllowManagedDevice)
    return Set-DocumentedPrivacyProtection -Name WindowsConsumerFeatures -Disabled $Disabled -AllowManagedDevice:$AllowManagedDevice
}

function Set-OptionalDiagnosticLevel {
    [CmdletBinding()]
    param(
        [ValidateSet('Required', 'Optional', 'UserControl')][string]$Level = 'Required',
        [switch]$AllowManagedDevice
    )

    $definition = Get-PrivacyPolicyDefinition -Name OptionalDiagnostics
    $compatibility = Get-PrivacyPolicyCompatibility -Definition $definition
    if (-not $compatibility.Supported) { return @(Get-PrivacyOptimizationState -Name OptionalDiagnostics)[0] }
    $management = Get-PolicyManagementStatus
    if ($management.IsManaged -and -not $AllowManagedDevice) {
        throw 'O computador aparenta ser gerenciado por dominio ou MDM. O nivel de diagnostico nao sera sobrescrito.'
    }
    return Invoke-OptimizerOperation -Name 'Configurar dados de diagnostico' -Risk 'Moderado' `
        -RequiresAdministrator -SkipRestorePoint -ScriptBlock {
            $entry = @($definition.Entries)[0]
            if ($Level -eq 'UserControl') {
                $change = Remove-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                    -RequiresAdministrator -Description 'Devolver nivel de diagnostico ao usuario'
            }
            else {
                $value = if ($Level -eq 'Required') { 1 } else { 3 }
                $change = Set-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                    -Value $value -Type DWord -RequiresAdministrator `
                    -Description $(if ($Level -eq 'Required') { 'Usar somente dados de diagnostico obrigatorios' } else { 'Permitir dados de diagnostico opcionais' })
            }
            return [pscustomobject]@{ Level = $Level; Change = $change; State = @(Get-PrivacyOptimizationState -Name OptionalDiagnostics)[0] }
        }
}

function Set-StartRecommendationsEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    $definition = Get-PrivacyPolicyDefinition -Name StartRecommendations
    $compatibility = Get-PrivacyPolicyCompatibility -Definition $definition
    if (-not $compatibility.Supported) { return @(Get-PrivacyOptimizationState -Name StartRecommendations)[0] }
    $entry = @($definition.Entries)[0]
    return Invoke-OptimizerOperation -Name $(if ($Enabled) { 'Ativar recomendacoes do menu Iniciar' } else { 'Desativar recomendacoes do menu Iniciar' }) `
        -Risk 'Seguro' -SkipRestorePoint -ScriptBlock {
            Set-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                -Value $(if ($Enabled) { 1 } else { 0 }) -Type DWord `
                -Description $(if ($Enabled) { 'Ativar recomendacoes do menu Iniciar' } else { 'Desativar recomendacoes do menu Iniciar' })
        }
}

function Get-BackgroundAppsPrivacyState {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    return [pscustomobject]@{
        Name = 'BackgroundApps'; State = $(if ($platform.IsSupported) { 'Manual' } else { 'Unsupported' })
        CanAutomate = $false
        SettingsPage = if ($platform.IsWindows11) { 'ms-settings:appsfeatures' } else { 'ms-settings:privacy-backgroundapps' }
        Reason = 'Ajustar por aplicativo evita quebrar notificacoes, sincronizacao, autenticacao, launchers e Gaming Services. O bloqueio global nao e aplicado.'
    }
}

function Open-PrivacySettings {
    [CmdletBinding()]
    param([ValidateSet('General', 'Diagnostics', 'ActivityHistory', 'BackgroundApps', 'InstalledApps', 'Start')][string]$Page = 'General')

    $platform = Get-WindowsPlatformInfo
    if (-not $platform.IsSupported) { return [pscustomobject]@{ State = 'Unsupported'; Opened = $false; Page = $Page } }
    $uri = if ($Page -eq 'BackgroundApps') {
        if ($platform.IsWindows11) { 'ms-settings:appsfeatures' } else { 'ms-settings:privacy-backgroundapps' }
    }
    else { [string]$script:PrivacySettingsPages[$Page] }
    if ((Get-OptimizerContext).Simulation) {
        Write-PrivacyOptimizerLog -Name "Abrir configuracoes de privacidade: $Page" -OldValue '' -NewValue $uri -Result 'Simulated'
        return [pscustomobject]@{ State = 'Manual'; Opened = $false; Page = $Page; Uri = $uri; Simulated = $true }
    }
    try {
        Start-Process -FilePath $uri -ErrorAction Stop | Out-Null
        Write-PrivacyOptimizerLog -Name "Abrir configuracoes de privacidade: $Page" -OldValue '' -NewValue $uri -Result 'Success'
        return [pscustomobject]@{ State = 'Manual'; Opened = $true; Page = $Page; Uri = $uri }
    }
    catch {
        Write-PrivacyOptimizerLog -Name "Abrir configuracoes de privacidade: $Page" -OldValue '' -NewValue $uri `
            -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
        throw
    }
}

function Invoke-SafePrivacyProfile {
    [CmdletBinding()]
    param(
        [ValidateSet('Safe', 'Balanced')][string]$Profile = 'Safe',
        [switch]$AllowManagedDevice
    )

    $requiresAdministrator = (Get-PrivacyEditionSupport).IsProOrHigher
    return Invoke-OptimizerOperation -Name "Perfil de privacidade $Profile" `
        -Risk $(if ($Profile -eq 'Balanced') { 'Moderado' } else { 'Seguro' }) `
        -RequiresAdministrator:$requiresAdministrator -ScriptBlock {
            $results = New-Object System.Collections.Generic.List[object]
            $results.Add((Set-TailoredExperiencesDisabled -Disabled $true -AllowManagedDevice:$AllowManagedDevice))
            $results.Add((Set-ThirdPartySuggestionsDisabled -Disabled $true -AllowManagedDevice:$AllowManagedDevice))
            if ((Get-PrivacyEditionSupport).IsProOrHigher) {
                $results.Add((Set-AdvertisingIdDisabled -Disabled $true -AllowManagedDevice:$AllowManagedDevice))
            }
            if ($Profile -eq 'Balanced' -and (Get-PrivacyEditionSupport).IsProOrHigher) {
                $results.Add((Set-ActivityHistoryDisabled -Disabled $true -AllowManagedDevice:$AllowManagedDevice))
                $results.Add((Set-OptionalDiagnosticLevel -Level Required -AllowManagedDevice:$AllowManagedDevice))
            }
            if ((Get-WindowsPlatformInfo).IsWindows11) {
                $results.Add((Set-StartRecommendationsEnabled -Enabled $false))
            }
            return $results.ToArray()
        }
}

Export-ModuleMember -Function Get-PolicyManagementStatus, Get-PrivacyPolicyCatalog,
    Get-PrivacyOptimizationState, Set-TailoredExperiencesDisabled,
    Set-ThirdPartySuggestionsDisabled, Set-AdvertisingIdDisabled,
    Set-ActivityHistoryDisabled, Set-OptionalDiagnosticLevel,
    Set-WindowsTipsDisabled, Set-WindowsConsumerFeaturesDisabled,
    Set-StartRecommendationsEnabled, Get-BackgroundAppsPrivacyState,
    Open-PrivacySettings, Invoke-SafePrivacyProfile
