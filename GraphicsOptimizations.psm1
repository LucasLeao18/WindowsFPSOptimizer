#requires -Version 5.1

Set-StrictMode -Version Latest

# HAGS, preferencias de GPU e a flag de otimizacao de tela cheia nao possuem
# contrato publico de automacao. Este modulo nao grava as chaves privadas usadas
# por tweaks encontrados na Internet; ele valida o alvo e encaminha o usuario a
# interface oficial do Windows.
$script:GraphicsSettingsUri = 'ms-settings:display-advancedgraphics'
$script:VisualStateFileName = 'GraphicsVisualState.json'

function Write-GraphicsOptimizerLog {
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
    Write-OptimizerLog -Name $Name -Category 'GPU e graficos' -OldValue $OldValue `
        -NewValue $NewValue -Result $Result -ErrorMessage $ErrorMessage `
        -RequiresRestart $RequiresRestart -Profile $profile -Level $Level | Out-Null
}

function Initialize-SystemParametersApi {
    [CmdletBinding()]
    param()

    if ('WindowsFPSOptimizer.Native.SystemParameters' -as [type]) { return }
    $source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WindowsFPSOptimizer.Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct ANIMATIONINFO
    {
        public uint cbSize;
        public int iMinAnimate;
    }

    public static class SystemParameters
    {
        private const uint SPIF_UPDATEINIFILE = 0x0001;
        private const uint SPIF_SENDCHANGE = 0x0002;

        [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]
        private static extern bool SystemParametersInfoGetInt(uint action, uint param, ref int value, uint flags);

        [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]
        private static extern bool SystemParametersInfoSet(uint action, uint param, IntPtr value, uint flags);

        [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]
        private static extern bool SystemParametersInfoGetAnimation(uint action, uint param, ref ANIMATIONINFO value, uint flags);

        [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]
        private static extern bool SystemParametersInfoSetAnimation(uint action, uint param, ref ANIMATIONINFO value, uint flags);

        private static void ThrowLastError(string operation)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        public static bool GetBoolean(uint action)
        {
            int value = 0;
            if (!SystemParametersInfoGetInt(action, 0, ref value, 0)) ThrowLastError("SystemParametersInfo GET");
            return value != 0;
        }

        public static void SetBooleanInUiParam(uint action, bool enabled)
        {
            if (!SystemParametersInfoSet(action, enabled ? 1u : 0u, IntPtr.Zero, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
                ThrowLastError("SystemParametersInfo SET uiParam");
        }

        public static void SetBooleanInPvParam(uint action, bool enabled)
        {
            IntPtr value = enabled ? new IntPtr(1) : IntPtr.Zero;
            if (!SystemParametersInfoSet(action, 0, value, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
                ThrowLastError("SystemParametersInfo SET pvParam");
        }

        public static uint GetUnsigned(uint action)
        {
            int value = 0;
            if (!SystemParametersInfoGetInt(action, 0, ref value, 0)) ThrowLastError("SystemParametersInfo GET UINT");
            return unchecked((uint)value);
        }

        public static void SetUnsigned(uint action, uint value)
        {
            if (!SystemParametersInfoSet(action, value, IntPtr.Zero, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
                ThrowLastError("SystemParametersInfo SET UINT");
        }

        public static bool GetMinimizeAnimation()
        {
            ANIMATIONINFO info = new ANIMATIONINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
            if (!SystemParametersInfoGetAnimation(0x0048, info.cbSize, ref info, 0))
                ThrowLastError("SystemParametersInfo GET ANIMATION");
            return info.iMinAnimate != 0;
        }

        public static void SetMinimizeAnimation(bool enabled)
        {
            ANIMATIONINFO info = new ANIMATIONINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
            info.iMinAnimate = enabled ? 1 : 0;
            if (!SystemParametersInfoSetAnimation(0x0049, info.cbSize, ref info, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE))
                ThrowLastError("SystemParametersInfo SET ANIMATION");
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Get-SystemParameterDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Option)

    $definitions = @{
        WindowAnimations     = @{ Kind = 'Animation'; GetAction = 0x0048; SetAction = 0x0049 }
        FullWindowDrag       = @{ Kind = 'BooleanUi'; GetAction = 0x0026; SetAction = 0x0025 }
        FontSmoothing        = @{ Kind = 'BooleanUi'; GetAction = 0x004A; SetAction = 0x004B }
        MenuAnimations       = @{ Kind = 'BooleanPv'; GetAction = 0x1002; SetAction = 0x1003 }
        ComboBoxAnimations   = @{ Kind = 'BooleanPv'; GetAction = 0x1004; SetAction = 0x1005 }
        SmoothListScrolling  = @{ Kind = 'BooleanPv'; GetAction = 0x1006; SetAction = 0x1007 }
        MenuFade             = @{ Kind = 'BooleanPv'; GetAction = 0x1012; SetAction = 0x1013 }
        SelectionFade        = @{ Kind = 'BooleanPv'; GetAction = 0x1014; SetAction = 0x1015 }
        TooltipAnimations    = @{ Kind = 'BooleanPv'; GetAction = 0x1016; SetAction = 0x1017 }
        TooltipFade          = @{ Kind = 'BooleanPv'; GetAction = 0x1018; SetAction = 0x1019 }
        CursorShadow         = @{ Kind = 'BooleanPv'; GetAction = 0x101A; SetAction = 0x101B }
        DropShadows          = @{ Kind = 'BooleanPv'; GetAction = 0x1024; SetAction = 0x1025 }
        UIEffects            = @{ Kind = 'BooleanPv'; GetAction = 0x103E; SetAction = 0x103F }
        ClientAreaAnimations = @{ Kind = 'BooleanPv'; GetAction = 0x1042; SetAction = 0x1043 }
        MenuDelay            = @{ Kind = 'Unsigned'; GetAction = 0x006A; SetAction = 0x006B }
    }
    if (-not $definitions.ContainsKey($Option)) { throw "Opcao visual sem definicao publica: $Option" }
    return $definitions[$Option]
}

function Get-SystemParameterValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Option)

    Initialize-SystemParametersApi
    $definition = Get-SystemParameterDefinition -Option $Option
    switch ([string]$definition.Kind) {
        'Animation' { return [WindowsFPSOptimizer.Native.SystemParameters]::GetMinimizeAnimation() }
        'Unsigned' { return [int][WindowsFPSOptimizer.Native.SystemParameters]::GetUnsigned([uint32]$definition.GetAction) }
        default { return [WindowsFPSOptimizer.Native.SystemParameters]::GetBoolean([uint32]$definition.GetAction) }
    }
}

function Set-SystemParameterValueRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Option,
        [Parameter(Mandatory = $true)]$Value
    )

    Initialize-SystemParametersApi
    $definition = Get-SystemParameterDefinition -Option $Option
    switch ([string]$definition.Kind) {
        'Animation' { [WindowsFPSOptimizer.Native.SystemParameters]::SetMinimizeAnimation([bool]$Value) }
        'Unsigned' { [WindowsFPSOptimizer.Native.SystemParameters]::SetUnsigned([uint32]$definition.SetAction, [uint32]$Value) }
        'BooleanUi' { [WindowsFPSOptimizer.Native.SystemParameters]::SetBooleanInUiParam([uint32]$definition.SetAction, [bool]$Value) }
        default { [WindowsFPSOptimizer.Native.SystemParameters]::SetBooleanInPvParam([uint32]$definition.SetAction, [bool]$Value) }
    }
}

function Get-VisualStatePath {
    [CmdletBinding()]
    param()

    return Join-Path (Get-OptimizerContext).StateRoot $script:VisualStateFileName
}

function New-VisualState {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Entries       = @()
        UpdatedAt     = (Get-Date).ToString('o')
    }
}

function Read-VisualState {
    [CmdletBinding()]
    param()

    $path = Get-VisualStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return New-VisualState }
    try {
        $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $state.Entries) { $state.Entries = @() }
        return $state
    }
    catch { throw "Estado visual salvo e invalido: $($_.Exception.Message)" }
}

function Save-VisualState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    $State.UpdatedAt = (Get-Date).ToString('o')
    Save-OptimizerJsonFile -Path (Get-VisualStatePath) -InputObject $State -Depth 14 | Out-Null
}

function Get-GraphicsObjectPropertyValue {
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Set-GraphicsObjectPropertyValue {
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Value)

    if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject[$Name] = $Value
        return
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value }
    else { $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

function Test-VisualRegistryStateEqual {
    [CmdletBinding()]
    param($Left, $Right)

    $leftExists = [bool](Get-GraphicsObjectPropertyValue $Left 'ValueExisted' $false)
    $rightExists = [bool](Get-GraphicsObjectPropertyValue $Right 'ValueExisted' $false)
    if ($leftExists -ne $rightExists) { return $false }
    if (-not $leftExists) { return $true }
    return ([string](Get-GraphicsObjectPropertyValue $Left 'Kind' '') -eq
            [string](Get-GraphicsObjectPropertyValue $Right 'Kind' '') -and
        (Compare-OptimizerValue (Get-GraphicsObjectPropertyValue $Left 'Value') `
            (Get-GraphicsObjectPropertyValue $Right 'Value')))
}

function Update-VisualStateForRestoredBackupEntry {
    <# Funcao pura que reconcilia uma entrada do sidecar visual. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Entry
    )

    $type = [string]$Entry.Type
    if ($type -notin @('RegistryValue', 'SystemParameter')) {
        throw "Tipo de backup visual invalido: $type"
    }
    $before = $State | ConvertTo-Json -Depth 14 -Compress
    $tracked = @()
    if ($type -eq 'SystemParameter') {
        $option = [string](Get-GraphicsObjectPropertyValue $Entry.Original 'Option' '')
        if ([string]::IsNullOrWhiteSpace($option)) { throw 'Backup visual sem opcao de sistema.' }
        $tracked = @($State.Entries | Where-Object {
            [string]$_.Kind -eq 'SystemParameter' -and [string]$_.Option -eq $option
        } | Select-Object -First 1)
        if ($tracked.Count -gt 0) {
            $restored = Get-GraphicsObjectPropertyValue $Entry.Original 'Value'
            if (Compare-OptimizerValue $restored $tracked[0].Original) {
                $trackedId = [string]$tracked[0].Id
                $State.Entries = @($State.Entries | Where-Object { [string]$_.Id -ne $trackedId })
            }
            else { $tracked[0].Applied = $restored }
        }
    }
    else {
        $path = [string](Get-GraphicsObjectPropertyValue $Entry.Original 'Path' '')
        $name = [string](Get-GraphicsObjectPropertyValue $Entry.Original 'Name' '')
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'Backup visual de Registro sem caminho.' }
        $tracked = @($State.Entries | Where-Object {
            [string]$_.Kind -eq 'Registry' -and [string]$_.Path -ieq $path -and [string]$_.Name -eq $name
        } | Select-Object -First 1)
        if ($tracked.Count -gt 0) {
            $restoredState = $Entry.Original
            if (Test-VisualRegistryStateEqual $restoredState $tracked[0].Original) {
                $trackedId = [string]$tracked[0].Id
                $State.Entries = @($State.Entries | Where-Object { [string]$_.Id -ne $trackedId })
            }
            else {
                $restoredExists = [bool](Get-GraphicsObjectPropertyValue $restoredState 'ValueExisted' $false)
                Set-GraphicsObjectPropertyValue $tracked[0] 'AppliedExists' $restoredExists
                Set-GraphicsObjectPropertyValue $tracked[0] 'Applied' `
                    (Get-GraphicsObjectPropertyValue $restoredState 'Value')
                if ($restoredExists) {
                    Set-GraphicsObjectPropertyValue $tracked[0] 'ValueType' `
                        ([string](Get-GraphicsObjectPropertyValue $restoredState 'Kind' ''))
                }
            }
        }
    }
    $after = $State | ConvertTo-Json -Depth 14 -Compress
    return [pscustomobject]@{ State = $State; Changed = ($before -cne $after) }
}

function Sync-VisualStateAfterBackupRestore {
    <# Chamado pelo BackupManager apenas para resultados Restored/AlreadyRestored. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Restored', 'AlreadyRestored')][string]$Status
    )

    $path = Get-VisualStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Changed = $false; Removed = $false; Status = $Status }
    }
    $state = Read-VisualState
    $updated = Update-VisualStateForRestoredBackupEntry -State $state -Entry $Entry
    if (-not $updated.Changed) {
        return [pscustomobject]@{ Changed = $false; Removed = $false; Status = $Status }
    }
    if (@($state.Entries).Count -gt 0) {
        Save-VisualState -State $state
        return [pscustomobject]@{ Changed = $true; Removed = $false; Status = $Status }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    return [pscustomobject]@{ Changed = $true; Removed = $true; Status = $Status }
}

function Add-GraphicsBackupEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Original,
        [Parameter(Mandatory = $true)]$Applied,
        [hashtable]$Metadata = @{}
    )

    if (-not (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue)) { return }
    try {
        Add-OptimizerBackupEntry -Type $Type -Id $Id -Original $Original `
            -Applied $Applied -Metadata $Metadata | Out-Null
    }
    catch {
        Write-GraphicsOptimizerLog -Name 'Registrar backup grafico' -OldValue $Original `
            -NewValue $Applied -Result 'Warning' -ErrorMessage $_.Exception.Message -Level 'Warning'
        throw
    }
}

function Register-SystemParameterChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Option,
        [Parameter(Mandatory = $true)]$Original,
        [Parameter(Mandatory = $true)]$Applied
    )

    $state = Read-VisualState
    $id = "SystemParameter|$Option"
    $existing = @($state.Entries | Where-Object { [string]$_.Id -eq $id } | Select-Object -First 1)
    if ($existing.Count -eq 0) {
        $state.Entries = @($state.Entries) + @([pscustomobject][ordered]@{
            Id = $id; Kind = 'SystemParameter'; Option = $Option
            Original = $Original; Applied = $Applied
        })
    }
    else { $existing[0].Applied = $Applied }
    Save-VisualState -State $state
    Add-GraphicsBackupEntry -Type 'SystemParameter' -Id $Option `
        -Original ([pscustomobject]@{ Option = $Option; Value = $Original }) `
        -Applied ([pscustomobject]@{ Option = $Option; Value = $Applied }) `
        -Metadata @{ Description = "Efeito visual $Option" }
}

function Register-VisualRegistryChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$OriginalState,
        [Parameter(Mandatory = $true)]$AppliedValue,
        [Parameter(Mandatory = $true)][string]$Type
    )

    $state = Read-VisualState
    $id = "Registry|$Path|$Name"
    $existing = @($state.Entries | Where-Object { [string]$_.Id -eq $id } | Select-Object -First 1)
    if ($existing.Count -eq 0) {
        $state.Entries = @($state.Entries) + @([pscustomobject][ordered]@{
            Id = $id; Kind = 'Registry'; Path = $Path; Name = $Name
            Original = $OriginalState; Applied = $AppliedValue; AppliedExists = $true; ValueType = $Type
        })
    }
    else {
        $existing[0].Applied = $AppliedValue
        Set-GraphicsObjectPropertyValue $existing[0] 'AppliedExists' $true
    }
    Save-VisualState -State $state
}

function Set-SystemParameterOptionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Option,
        [Parameter(Mandatory = $true)]$Value,
        [switch]$SkipStateRegistration
    )

    $before = Get-SystemParameterValue -Option $Option
    if (Compare-OptimizerValue -Left $before -Right $Value) {
        Write-GraphicsOptimizerLog -Name "Efeito visual: $Option" -OldValue $before -NewValue $Value -Result 'Skipped'
        return [pscustomobject]@{ Changed = $false; Result = 'Skipped'; Before = $before; After = $before }
    }
    $context = Get-OptimizerContext
    if (-not $SkipStateRegistration -and -not $context.Simulation) {
        Register-SystemParameterChange -Option $Option -Original $before -Applied $Value
    }
    if ($context.Simulation) {
        Write-GraphicsOptimizerLog -Name "Efeito visual: $Option" -OldValue $before -NewValue $Value -Result 'Simulated'
        return [pscustomobject]@{ Changed = $false; Result = 'Simulated'; Before = $before; After = $null }
    }
    Set-SystemParameterValueRaw -Option $Option -Value $Value
    $after = Get-SystemParameterValue -Option $Option
    if (-not (Compare-OptimizerValue -Left $after -Right $Value)) {
        throw "Falha ao verificar o efeito visual $Option."
    }
    Write-GraphicsOptimizerLog -Name "Efeito visual: $Option" -OldValue $before -NewValue $after -Result 'Success'
    return [pscustomobject]@{ Changed = $true; Result = 'Success'; Before = $before; After = $after }
}

function Set-VisualRegistryOptionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('DWord', 'String')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$SkipStateRegistration
    )

    $before = Get-RegistryValueState -Path $Path -Name $Name
    $context = Get-OptimizerContext
    if (-not $SkipStateRegistration -and -not $context.Simulation -and `
        (-not $before.ValueExisted -or -not (Compare-OptimizerValue $before.Value $Value))) {
        Register-VisualRegistryChange -Path $Path -Name $Name -OriginalState $before `
            -AppliedValue $Value -Type $Type
    }
    return Set-SafeRegistryValue -Path $Path -Name $Name -Value $Value -Type $Type `
        -Description $Description
}

function Get-GpuVendor {
    [CmdletBinding()]
    param([string]$Name, [string]$AdapterCompatibility, [string]$PnpDeviceId)

    $text = "$Name $AdapterCompatibility $PnpDeviceId"
    if ($text -match '(?i)(VEN_10DE|NVIDIA)') { return 'NVIDIA' }
    if ($text -match '(?i)(VEN_1002|VEN_1022|AMD|Advanced Micro Devices|Radeon)') { return 'AMD' }
    if ($text -match '(?i)(VEN_8086|Intel)') { return 'Intel' }
    if ($text -match '(?i)Microsoft Basic Display') { return 'MicrosoftBasic' }
    return 'Desconhecido'
}

function Get-DetectedVideoControllers {
    [CmdletBinding()]
    param()

    $controllers = @()
    try { $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) } catch { }
    if ($controllers.Count -gt 0) { return $controllers }

    # Fallback somente leitura para ambientes onde o provedor CIM esta
    # indisponivel. A classe abaixo e exclusivamente a classe Display do PnP.
    $displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $fallback = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $displayClass -ErrorAction SilentlyContinue)) {
            try {
                $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $descriptionProperty = $item.PSObject.Properties['DriverDesc']
                if ($null -eq $descriptionProperty -or `
                    [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) { continue }
                $providerProperty = $item.PSObject.Properties['ProviderName']
                $versionProperty = $item.PSObject.Properties['DriverVersion']
                $dateProperty = $item.PSObject.Properties['DriverDate']
                $deviceProperty = $item.PSObject.Properties['MatchingDeviceId']
                $fallback.Add([pscustomobject]@{
                    Name                        = [string]$descriptionProperty.Value
                    AdapterCompatibility        = if ($providerProperty) { [string]$providerProperty.Value } else { '' }
                    DriverVersion               = if ($versionProperty) { [string]$versionProperty.Value } else { '' }
                    DriverDate                  = if ($dateProperty) { [string]$dateProperty.Value } else { '' }
                    VideoProcessor              = ''
                    AdapterRAM                  = $null
                    PNPDeviceID                 = if ($deviceProperty) { [string]$deviceProperty.Value } else { '' }
                    Status                      = 'Desconhecido'
                    CurrentHorizontalResolution = $null
                    CurrentVerticalResolution   = $null
                })
            }
            catch { continue }
        }
    }
    catch { }
    return @($fallback | ForEach-Object { $_ })
}

function Get-GraphicsInformation {
    [CmdletBinding()]
    param()

    $controllers = @()
    try { $controllers = @(Get-DetectedVideoControllers) }
    catch {
        Write-GraphicsOptimizerLog -Name 'Detectar placas de video' -OldValue '' -NewValue '' `
            -Result 'Error' -ErrorMessage $_.Exception.Message -Level 'Error'
    }
    $gpus = New-Object System.Collections.Generic.List[object]
    foreach ($controller in $controllers) {
        $driverDate = $null
        try { $driverDate = [Management.ManagementDateTimeConverter]::ToDateTime([string]$controller.DriverDate) }
        catch {
            try { $driverDate = [datetime]$controller.DriverDate } catch { }
        }
        $ramBytes = $null
        try { if ($null -ne $controller.AdapterRAM) { $ramBytes = [uint64]$controller.AdapterRAM } } catch { }
        $gpus.Add([pscustomobject]@{
            Name                 = [string]$controller.Name
            Vendor               = Get-GpuVendor -Name ([string]$controller.Name) `
                -AdapterCompatibility ([string]$controller.AdapterCompatibility) `
                -PnpDeviceId ([string]$controller.PNPDeviceID)
            DriverVersion        = [string]$controller.DriverVersion
            DriverDate           = $driverDate
            VideoProcessor       = [string]$controller.VideoProcessor
            AdapterRamBytes      = $ramBytes
            AdapterCompatibility = [string]$controller.AdapterCompatibility
            PnpDeviceId          = [string]$controller.PNPDeviceID
            Status               = [string]$controller.Status
            CurrentResolution    = if ($controller.CurrentHorizontalResolution -and $controller.CurrentVerticalResolution) {
                ('{0}x{1}' -f $controller.CurrentHorizontalResolution, $controller.CurrentVerticalResolution)
            } else { '' }
        })
    }
    $hags = Get-HagsState
    return [pscustomobject]@{
        Gpus                              = @($gpus | ForEach-Object { $_ })
        PrimaryGpu                        = @($gpus | Select-Object -First 1)
        Hags                              = $hags
        GraphicsPreferenceAutomation      = $false
        FullscreenPreferenceAutomation    = $false
        AutomaticDriverInstallation       = $false
        OverclockSupportedByApplication   = $false
        SafetyNote                        = 'O aplicativo nao altera clocks, voltagem, BIOS, drivers ou chaves graficas privadas.'
    }
}

function Get-HagsState {
    [CmdletBinding()]
    param()

    $platform = Get-WindowsPlatformInfo
    $controllers = @()
    try { $controllers = @(Get-DetectedVideoControllers) } catch { }
    $hardwareDriver = @($controllers | Where-Object {
        (Get-GpuVendor -Name ([string]$_.Name) -AdapterCompatibility ([string]$_.AdapterCompatibility) -PnpDeviceId ([string]$_.PNPDeviceID)) `
            -notin @('MicrosoftBasic', 'Desconhecido')
    }).Count -gt 0
    $potentiallyAvailable = ($platform.Build -ge 19041 -and $hardwareDriver)
    return [pscustomobject]@{
        State                = 'VerificacaoManualNecessaria'
        IsEnabled            = $null
        SupportedByOS        = ($platform.Build -ge 19041)
        HardwareDriverFound  = $hardwareDriver
        PotentiallyAvailable = $potentiallyAvailable
        AutomationSupported  = $false
        RequiresRestart      = $true
        SettingsUri          = $script:GraphicsSettingsUri
        Reason               = 'O Windows nao publica API para consultar ou alterar HAGS. A disponibilidade e o estado devem ser confirmados em Configuracoes.'
    }
}

function Set-HagsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [switch]$DoNotOpenSettings
    )

    $state = Get-HagsState
    $opened = $false
    if (-not $DoNotOpenSettings) { $opened = Open-GraphicsSettings }
    $result = [pscustomobject]@{
        Result              = 'UnsupportedManual'
        RequestedEnabled    = $Enabled
        Applied             = $false
        SettingsOpened      = $opened
        RequiresRestart     = $true
        Reason              = $state.Reason
    }
    Write-GraphicsOptimizerLog -Name 'Alterar HAGS' -OldValue $state.State -NewValue $Enabled `
        -Result 'Warning' -ErrorMessage $state.Reason -RequiresRestart $true -Level 'Warning'
    return $result
}

function Set-ProgramGpuPreference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Alias('Path')][string]$ExecutablePath,
        [ValidateSet('SystemDefault', 'PowerSaving', 'HighPerformance')]
        [string]$Preference = 'HighPerformance',
        [switch]$DoNotOpenSettings
    )

    if ($ExecutablePath -match '^\\\\' -or -not (Test-SafeExecutablePath -Path $ExecutablePath)) {
        throw "Executavel invalido ou inexistente: $ExecutablePath"
    }
    $resolved = (Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
    $opened = $false
    if (-not $DoNotOpenSettings) { $opened = Open-GraphicsSettings }
    $reason = 'O Windows nao publica API para definir a preferencia grafica por executavel; configure o arquivo validado na pagina aberta.'
    Write-GraphicsOptimizerLog -Name 'Preferencia de GPU por programa' -OldValue 'Desconhecido' `
        -NewValue @{ Path = $resolved; Preference = $Preference } -Result 'Warning' `
        -ErrorMessage $reason -Level 'Warning'
    return [pscustomobject]@{
        Result = 'UnsupportedManual'; Applied = $false; ExecutablePath = $resolved
        RequestedPreference = $Preference; SettingsOpened = $opened; Reason = $reason
    }
}

function Set-FullscreenOptimizationPreference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Alias('Path')][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][bool]$Disable,
        [switch]$OpenFileLocation
    )

    if ($ExecutablePath -match '^\\\\' -or -not (Test-SafeExecutablePath -Path $ExecutablePath)) {
        throw "Executavel invalido ou inexistente: $ExecutablePath"
    }
    $resolved = (Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
    $opened = $false
    if ($OpenFileLocation) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $resolved) -ErrorAction Stop | Out-Null
        $opened = $true
    }
    $reason = 'Nao ha API publica para esta compatibilidade por jogo. Use Propriedades > Compatibilidade no executavel; nenhuma chave privada foi gravada.'
    Write-GraphicsOptimizerLog -Name 'Otimizacao de tela cheia por jogo' -OldValue 'Desconhecido' `
        -NewValue @{ Path = $resolved; Disable = $Disable } -Result 'Warning' `
        -ErrorMessage $reason -Level 'Warning'
    return [pscustomobject]@{
        Result = 'UnsupportedManual'; Applied = $false; ExecutablePath = $resolved
        RequestedDisabled = $Disable; FileLocationOpened = $opened; Reason = $reason
    }
}

function Get-VisualEffectsState {
    [CmdletBinding()]
    param()

    $options = @('WindowAnimations', 'FullWindowDrag', 'FontSmoothing', 'MenuAnimations',
        'ComboBoxAnimations', 'SmoothListScrolling', 'MenuFade', 'SelectionFade',
        'TooltipAnimations', 'TooltipFade', 'CursorShadow', 'DropShadows', 'UIEffects',
        'ClientAreaAnimations', 'MenuDelay')
    $values = [ordered]@{}
    foreach ($option in $options) {
        try { $values[$option] = Get-SystemParameterValue -Option $option }
        catch { $values[$option] = [pscustomobject]@{ Available = $false; Error = $_.Exception.Message } }
    }

    $transparencyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $thumbnailPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $transparency = Get-RegistryValueState -Path $transparencyPath -Name 'EnableTransparency'
    $thumbnails = Get-RegistryValueState -Path $thumbnailPath -Name 'DisableThumbnails'
    $booleanValues = @($options | Where-Object { $_ -ne 'MenuDelay' } | ForEach-Object {
        $candidate = $values[$_]
        if ($candidate -is [bool]) { $candidate }
    })
    $enabledCount = @($booleanValues | Where-Object { $_ -eq $true }).Count
    $disabledCount = @($booleanValues | Where-Object { $_ -eq $false }).Count
    $profile = if ($booleanValues.Count -lt 3) { 'Unknown' }
        elseif (($disabledCount / $booleanValues.Count) -ge 0.8) { 'MaximumPerformance' }
        elseif (($disabledCount / $booleanValues.Count) -ge 0.4) { 'Balanced' }
        else { 'Default' }
    return [pscustomobject]@{
        Profile            = $profile
        AvailableEffects   = $booleanValues.Count
        ActiveEffects      = $enabledCount
        SystemParameters   = [pscustomobject]$values
        TaskbarAnimations  = $values['ClientAreaAnimations']
        ContentAnimations  = $values['ClientAreaAnimations']
        Shadows             = $values['DropShadows']
        Transparency       = if ($transparency.ValueExisted) { [int]$transparency.Value -ne 0 } else { $null }
        TransparencyState  = $transparency
        ThumbnailsEnabled  = if ($thumbnails.ValueExisted) { [int]$thumbnails.Value -eq 0 } else { $null }
        ThumbnailState     = $thumbnails
        RestoreAvailable   = (Test-Path -LiteralPath (Get-VisualStatePath) -PathType Leaf)
    }
}

function Set-VisualEffectOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Transparency', 'Thumbnails', 'WindowAnimations', 'FullWindowDrag',
            'FontSmoothing', 'MenuAnimations', 'ComboBoxAnimations', 'SmoothListScrolling',
            'MenuFade', 'SelectionFade', 'TooltipAnimations', 'TooltipFade', 'CursorShadow',
            'DropShadows', 'Shadows', 'UIEffects', 'ClientAreaAnimations',
            'TaskbarAnimations', 'ContentAnimations', 'MenuDelay')]
        [string]$Option,
        [bool]$Enabled = $true,
        [ValidateRange(0, 4000)][int]$MenuDelayMilliseconds = 100
    )

    $risk = if ($Option -in @('FontSmoothing', 'Thumbnails')) { 'Moderado' } else { 'Seguro' }
    return Invoke-OptimizerOperation -Name "Configurar efeito visual: $Option" -Risk $risk `
        -SkipRestorePoint -ScriptBlock {
            switch ($Option) {
                'Transparency' {
                    Set-VisualRegistryOptionInternal `
                        -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                        -Name 'EnableTransparency' -Value $(if ($Enabled) { 1 } else { 0 }) `
                        -Type 'DWord' -Description 'Configurar transparencia do Windows'
                }
                'Thumbnails' {
                    Set-VisualRegistryOptionInternal `
                        -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
                        -Name 'DisableThumbnails' -Value $(if ($Enabled) { 0 } else { 1 }) `
                        -Type 'DWord' -Description 'Configurar miniaturas do Explorer'
                }
                'MenuDelay' {
                    Set-SystemParameterOptionInternal -Option $Option -Value $MenuDelayMilliseconds
                }
                { $_ -in @('TaskbarAnimations', 'ContentAnimations') } {
                    $mapped = Set-SystemParameterOptionInternal -Option 'ClientAreaAnimations' -Value $Enabled
                    [pscustomobject]@{
                        Changed = $mapped.Changed; Result = $mapped.Result; Before = $mapped.Before; After = $mapped.After
                        RequestedOption = $Option; AppliedPublicParameter = 'ClientAreaAnimations'
                        Note = 'A API publica controla animacoes da area cliente em conjunto, nao apenas a barra de tarefas.'
                    }
                }
                'Shadows' {
                    $mapped = Set-SystemParameterOptionInternal -Option 'DropShadows' -Value $Enabled
                    [pscustomobject]@{
                        Changed = $mapped.Changed; Result = $mapped.Result; Before = $mapped.Before; After = $mapped.After
                        RequestedOption = $Option; AppliedPublicParameter = 'DropShadows'
                    }
                }
                default {
                    Set-SystemParameterOptionInternal -Option $Option -Value $Enabled
                }
            }
        }
}

function Set-VisualEffectsProfile {
    [CmdletBinding()]
    param(
        [ValidateSet('Seguro', 'Equilibrado', 'MaximoDesempenho', 'Automatico',
            'Safe', 'Balanced', 'MaximumPerformance', 'MaximumFPS', 'Automatic')]
        [string]$Profile = 'Equilibrado'
    )

    switch ($Profile) {
        'Safe' { $Profile = 'Seguro' }
        'Balanced' { $Profile = 'Equilibrado' }
        { $_ -in @('MaximumPerformance', 'MaximumFPS') } { $Profile = 'MaximoDesempenho' }
        'Automatic' { $Profile = 'Automatico' }
    }
    if ($Profile -eq 'Automatico') {
        $isLaptop = $false
        try { $isLaptop = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
        $Profile = if ($isLaptop) { 'Equilibrado' } else { 'MaximoDesempenho' }
    }
    $risk = if ($Profile -eq 'MaximoDesempenho') { 'Moderado' } else { 'Seguro' }
    return Invoke-OptimizerOperation -Name "Aplicar perfil visual $Profile" -Risk $risk `
        -SkipRestorePoint -ScriptBlock {
            $changes = New-Object System.Collections.Generic.List[object]
            $changes.Add((Set-VisualRegistryOptionInternal `
                -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                -Name 'EnableTransparency' -Value 0 -Type 'DWord' `
                -Description 'Desativar transparencia no perfil visual'))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'WindowAnimations' -Value $false))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'ClientAreaAnimations' -Value $false))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'MenuAnimations' -Value $false))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'MenuFade' -Value $false))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'SelectionFade' -Value $false))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'TooltipAnimations' -Value $false))
            $changes.Add((Set-SystemParameterOptionInternal -Option 'TooltipFade' -Value $false))

            if ($Profile -eq 'Seguro') {
                $changes.Add((Set-SystemParameterOptionInternal -Option 'MenuDelay' -Value 150))
            }
            elseif ($Profile -eq 'Equilibrado') {
                $changes.Add((Set-SystemParameterOptionInternal -Option 'ComboBoxAnimations' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'SmoothListScrolling' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'FullWindowDrag' -Value $true))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'MenuDelay' -Value 100))
            }
            else {
                $changes.Add((Set-SystemParameterOptionInternal -Option 'UIEffects' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'ComboBoxAnimations' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'SmoothListScrolling' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'CursorShadow' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'DropShadows' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'FullWindowDrag' -Value $false))
                $changes.Add((Set-SystemParameterOptionInternal -Option 'MenuDelay' -Value 20))
            }

            # Miniaturas e suavizacao de fontes permanecem opcoes individuais por
            # terem custo/beneficio ruim e impacto direto em legibilidade/usabilidade.
            return [pscustomobject]@{
                Profile = $Profile; Changes = @($changes | ForEach-Object { $_ })
                PreservedOptions = @('Thumbnails', 'FontSmoothing')
            }
        }
}

function Restore-VisualEffects {
    [CmdletBinding()]
    param([switch]$Force)

    return Invoke-OptimizerOperation -Name 'Restaurar efeitos visuais anteriores' -Risk 'Seguro' `
        -SkipRestorePoint -ScriptBlock {
            $path = Get-VisualStatePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return [pscustomobject]@{ Result = 'Skipped'; Reason = 'Nenhum estado visual salvo.' }
            }
            $state = Read-VisualState
            $restored = New-Object System.Collections.Generic.List[object]
            $conflicts = New-Object System.Collections.Generic.List[object]
            foreach ($entry in @($state.Entries)) {
                if ([string]$entry.Kind -eq 'SystemParameter') {
                    $current = Get-SystemParameterValue -Option ([string]$entry.Option)
                    if (Compare-OptimizerValue $current $entry.Original) {
                        $restored.Add([string]$entry.Id)
                        continue
                    }
                    if (-not $Force -and -not (Compare-OptimizerValue $current $entry.Applied)) {
                        $conflicts.Add([pscustomobject]@{ Id = $entry.Id; Current = $current; Applied = $entry.Applied })
                        continue
                    }
                    Set-SystemParameterOptionInternal -Option ([string]$entry.Option) `
                        -Value $entry.Original -SkipStateRegistration | Out-Null
                    $restored.Add([string]$entry.Id)
                }
                elseif ([string]$entry.Kind -eq 'Registry') {
                    $current = Get-RegistryValueState -Path ([string]$entry.Path) -Name ([string]$entry.Name)
                    $originalMatches = if ([bool]$entry.Original.ValueExisted) {
                        $current.ValueExisted -and (Compare-OptimizerValue $current.Value $entry.Original.Value)
                    }
                    else { -not $current.ValueExisted }
                    if ($originalMatches) {
                        $restored.Add([string]$entry.Id)
                        continue
                    }
                    $appliedExists = [bool](Get-GraphicsObjectPropertyValue $entry 'AppliedExists' $true)
                    $matchesApplied = if ($appliedExists) {
                        $current.ValueExisted -and (Compare-OptimizerValue $current.Value $entry.Applied)
                    }
                    else { -not $current.ValueExisted }
                    if (-not $Force -and -not $matchesApplied) {
                        $conflicts.Add([pscustomobject]@{ Id = $entry.Id; Current = $current.Value; Applied = $entry.Applied })
                        continue
                    }
                    if ([bool]$entry.Original.ValueExisted) {
                        Set-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                            -Value $entry.Original.Value -Type ([string]$entry.Original.Kind) `
                            -Description ("Restaurar " + [string]$entry.Name) | Out-Null
                    }
                    else {
                        Remove-SafeRegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) `
                            -Description ("Restaurar " + [string]$entry.Name) | Out-Null
                    }
                    $restored.Add([string]$entry.Id)
                }
            }
            $context = Get-OptimizerContext
            if (-not $context.Simulation -and $conflicts.Count -eq 0) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
            Write-GraphicsOptimizerLog -Name 'Restaurar efeitos visuais' -OldValue $state `
                -NewValue @{ Restored = $restored.Count; Conflicts = $conflicts.Count } `
                -Result $(if ($conflicts.Count -gt 0) { 'Warning' } else { 'Restored' }) `
                -ErrorMessage $(if ($conflicts.Count -gt 0) { 'Mudancas posteriores do usuario foram preservadas.' } else { '' }) `
                -Level $(if ($conflicts.Count -gt 0) { 'Warning' } else { 'Information' })
            return [pscustomobject]@{
                Result = if ($context.Simulation) { 'Simulated' } elseif ($conflicts.Count -gt 0) { 'Partial' } else { 'Restored' }
                Restored = @($restored | ForEach-Object { $_ })
                Conflicts = @($conflicts | ForEach-Object { $_ })
            }
        }
}

function Get-GraphicsSystemParameterBackupState {
    <# Contrato fechado usado por BackupManager; Option passa pela allowlist. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    if ($null -eq $Entry.Original -or [string]::IsNullOrWhiteSpace([string]$Entry.Original.Option)) {
        throw 'Entrada SystemParameter sem Option original.'
    }
    $option = [string]$Entry.Original.Option
    $null = Get-SystemParameterDefinition -Option $option
    return [pscustomobject]@{ Option = $option; Value = Get-SystemParameterValue -Option $option }
}

function Restore-GraphicsSystemParameterBackupEntry {
    <# Nao interpreta comandos do manifesto; aceita somente opcoes da allowlist. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    if ($null -eq $Entry.Original -or [string]::IsNullOrWhiteSpace([string]$Entry.Original.Option)) {
        throw 'Entrada SystemParameter sem estado original valido.'
    }
    $option = [string]$Entry.Original.Option
    $null = Get-SystemParameterDefinition -Option $option
    $result = Set-SystemParameterOptionInternal -Option $option `
        -Value $Entry.Original.Value -SkipStateRegistration
    return [pscustomobject]@{ Option = $option; Result = $result.Result; State = $result.After }
}

function Get-GraphicsCacheLocations {
    [CmdletBinding()]
    param()

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $common = [Environment]::GetFolderPath('CommonApplicationData')
    $vendors = @()
    try {
        $vendors = @(Get-DetectedVideoControllers | ForEach-Object {
            Get-GpuVendor -Name ([string]$_.Name) -AdapterCompatibility ([string]$_.AdapterCompatibility) -PnpDeviceId ([string]$_.PNPDeviceID)
        } | Select-Object -Unique)
    }
    catch { }
    $locations = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($local)) {
        $locations.Add([pscustomobject]@{ Type = 'DirectX'; Vendor = 'Microsoft'; Path = (Join-Path $local 'D3DSCache'); RequiresAdministrator = $false })
        if ($vendors -contains 'NVIDIA') {
            $locations.Add([pscustomobject]@{ Type = 'NVIDIA'; Vendor = 'NVIDIA'; Path = (Join-Path $local 'NVIDIA\DXCache'); RequiresAdministrator = $false })
            $locations.Add([pscustomobject]@{ Type = 'NVIDIA'; Vendor = 'NVIDIA'; Path = (Join-Path $local 'NVIDIA\GLCache'); RequiresAdministrator = $false })
        }
        if ($vendors -contains 'AMD') {
            $locations.Add([pscustomobject]@{ Type = 'AMD'; Vendor = 'AMD'; Path = (Join-Path $local 'AMD\DxCache'); RequiresAdministrator = $false })
            $locations.Add([pscustomobject]@{ Type = 'AMD'; Vendor = 'AMD'; Path = (Join-Path $local 'AMD\GLCache'); RequiresAdministrator = $false })
            $locations.Add([pscustomobject]@{ Type = 'AMD'; Vendor = 'AMD'; Path = (Join-Path $local 'AMD\VkCache'); RequiresAdministrator = $false })
        }
    }
    if (($vendors -contains 'NVIDIA') -and -not [string]::IsNullOrWhiteSpace($common)) {
        $locations.Add([pscustomobject]@{ Type = 'NVIDIA'; Vendor = 'NVIDIA'; Path = (Join-Path $common 'NVIDIA Corporation\NV_Cache'); RequiresAdministrator = $true })
    }
    foreach ($location in $locations) {
        Add-Member -InputObject $location -NotePropertyName Exists -NotePropertyValue `
            (Test-Path -LiteralPath $location.Path -PathType Container)
    }
    return @($locations | ForEach-Object { $_ })
}

function Test-ApprovedGraphicsCachePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try { $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    foreach ($location in @(Get-GraphicsCacheLocations)) {
        try { $approved = [IO.Path]::GetFullPath([string]$location.Path).TrimEnd('\') } catch { continue }
        if ($candidate.Equals($approved, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
            }
            return $true
        }
    }
    return $false
}

function Get-ApprovedCacheFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [datetime]$OlderThan = [datetime]::MaxValue
    )

    if (-not (Test-ApprovedGraphicsCachePath -Path $Root)) { throw "Diretorio de cache nao aprovado: $Root" }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $files = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) {
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($item.FullName) }
            }
            elseif (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and `
                $item.LastWriteTime -le $OlderThan) { $files.Add($item) }
        }
    }
    return @($files | ForEach-Object { $_ })
}

function Get-GraphicsCacheEstimate {
    [CmdletBinding()]
    param(
        [ValidateSet('DirectX', 'NVIDIA', 'AMD')][string[]]$Types = @('DirectX', 'NVIDIA', 'AMD'),
        [ValidateRange(0, 87600)][int]$MinimumAgeHours = 0
    )

    $cutoff = if ($MinimumAgeHours -eq 0) { [datetime]::MaxValue } else { (Get-Date).AddHours(-$MinimumAgeHours) }
    $items = New-Object System.Collections.Generic.List[object]
    [uint64]$totalBytes = 0
    [int]$totalFiles = 0
    foreach ($location in @(Get-GraphicsCacheLocations | Where-Object { $Types -contains $_.Type })) {
        $bytes = [uint64]0
        $files = @()
        $errorMessage = ''
        if ($location.Exists) {
            try {
                $files = @(Get-ApprovedCacheFiles -Root $location.Path -OlderThan $cutoff)
                foreach ($file in $files) { try { $bytes += [uint64]$file.Length } catch { } }
            }
            catch { $errorMessage = $_.Exception.Message }
        }
        $totalBytes += $bytes
        $totalFiles += $files.Count
        $items.Add([pscustomobject]@{
            Type = $location.Type; Vendor = $location.Vendor; Path = $location.Path
            Exists = $location.Exists; FileCount = $files.Count; Bytes = $bytes
            Megabytes = [math]::Round($bytes / 1MB, 2)
            RequiresAdministrator = $location.RequiresAdministrator; Error = $errorMessage
        })
    }
    return [pscustomobject]@{
        TotalBytes = $totalBytes; TotalMegabytes = [math]::Round($totalBytes / 1MB, 2)
        TotalFiles = $totalFiles; MinimumAgeHours = $MinimumAgeHours
        Locations = @($items | ForEach-Object { $_ })
        Warning = 'Caches serao recompilados. A primeira execucao de jogos pode apresentar mais stutter.'
    }
}

function Clear-GraphicsCaches {
    [CmdletBinding()]
    param(
        [ValidateSet('DirectX', 'NVIDIA', 'AMD')][string[]]$Types = @('DirectX'),
        [ValidateRange(0, 87600)][int]$MinimumAgeHours = 0,
        [Parameter(Mandatory = $true)][Alias('Confirmed')][switch]$UserConfirmed
    )

    if (-not $UserConfirmed) { throw 'A limpeza de cache exige confirmacao explicita.' }
    $estimate = Get-GraphicsCacheEstimate -Types $Types -MinimumAgeHours $MinimumAgeHours
    $requiresAdmin = @($estimate.Locations | Where-Object { $_.Exists -and $_.RequiresAdministrator }).Count -gt 0
    return Invoke-OptimizerOperation -Name 'Limpar caches graficos confirmados' -Risk 'Moderado' `
        -RequiresAdministrator:$requiresAdmin -SkipRestorePoint -ScriptBlock {
            $context = Get-OptimizerContext
            $manifestPath = Join-Path $context.StateRoot ('GraphicsCacheCleanup-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
            if (-not $context.Simulation) {
                Save-OptimizerJsonFile -Path $manifestPath -InputObject ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('o'); Reversible = $false
                    Estimate = $estimate; Confirmed = $true
                }) -Depth 12 | Out-Null
                Add-GraphicsBackupEntry -Type 'CleanupManifest' -Id ([IO.Path]::GetFileName($manifestPath)) `
                    -Original ([pscustomobject]@{ Paths = @($estimate.Locations.Path); Bytes = $estimate.TotalBytes }) `
                    -Applied ([pscustomobject]@{ Deleted = $true; Reversible = $false }) `
                    -Metadata @{ ManifestPath = $manifestPath; Description = 'Caches graficos; conteudo regeneravel e nao restauravel' }
            }

            $outcomes = New-Object System.Collections.Generic.List[object]
            foreach ($location in @($estimate.Locations | Where-Object { $_.Exists })) {
                if (-not (Test-ApprovedGraphicsCachePath -Path $location.Path)) {
                    throw "Caminho deixou de pertencer a allowlist de caches: $($location.Path)"
                }
                $cutoff = if ($MinimumAgeHours -eq 0) { [datetime]::MaxValue } else { (Get-Date).AddHours(-$MinimumAgeHours) }
                $files = @(Get-ApprovedCacheFiles -Root $location.Path -OlderThan $cutoff)
                [uint64]$removedBytes = 0
                [int]$removedFiles = 0
                $errors = New-Object System.Collections.Generic.List[string]
                foreach ($file in $files) {
                    if ($context.Simulation) {
                        $removedFiles++
                        $removedBytes += [uint64]$file.Length
                        continue
                    }
                    try {
                        $length = [uint64]$file.Length
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        $removedFiles++
                        $removedBytes += $length
                    }
                    catch { $errors.Add("$($file.FullName): $($_.Exception.Message)") }
                }
                $outcome = [pscustomobject]@{
                    Type = $location.Type; Path = $location.Path; FilesRemoved = $removedFiles
                    BytesRemoved = $removedBytes
                    Errors = @($errors | ForEach-Object { $_ })
                    Result = if ($context.Simulation) { 'Simulated' } elseif ($errors.Count -gt 0) { 'Partial' } else { 'Success' }
                }
                $outcomes.Add($outcome)
                Write-GraphicsOptimizerLog -Name "Limpar cache $($location.Type)" `
                    -OldValue @{ Files = $files.Count; Bytes = $location.Bytes } -NewValue $outcome `
                    -Result $(if ($context.Simulation) { 'Simulated' } elseif ($errors.Count -gt 0) { 'Warning' } else { 'Success' }) `
                    -ErrorMessage ($errors -join [Environment]::NewLine) `
                    -Level $(if ($errors.Count -gt 0) { 'Warning' } else { 'Information' })
            }
            return [pscustomobject]@{
                Result = if ($context.Simulation) { 'Simulated' } else { 'Completed' }
                Estimate = $estimate; ManifestPath = if ($context.Simulation) { $null } else { $manifestPath }
                Outcomes = @($outcomes | ForEach-Object { $_ }); Reversible = $false
            }
        }
}

function Open-GraphicsSettings {
    [CmdletBinding()]
    param()

    Start-Process -FilePath $script:GraphicsSettingsUri -ErrorAction Stop | Out-Null
    Write-GraphicsOptimizerLog -Name 'Abrir Configuracoes de Graficos' -OldValue '' `
        -NewValue $script:GraphicsSettingsUri -Result 'Success'
    return $true
}

Export-ModuleMember -Function Get-GraphicsInformation, Get-HagsState, Set-HagsState,
    Set-ProgramGpuPreference, Set-FullscreenOptimizationPreference,
    Get-VisualEffectsState, Set-VisualEffectsProfile, Set-VisualEffectOption,
    Restore-VisualEffects, Get-GraphicsSystemParameterBackupState,
    Restore-GraphicsSystemParameterBackupEntry, Sync-VisualStateAfterBackupRestore,
    Get-GraphicsCacheEstimate,
    Clear-GraphicsCaches, Open-GraphicsSettings
