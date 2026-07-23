#requires -Version 5.1

Set-StrictMode -Version Latest

function Test-ProtectedAppxPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($pattern in @((Get-OptimizerContext).Config.Safety.ProtectedAppxPatterns)) {
        if ($Name -like "*$pattern*") { return $true }
    }
    return $false
}

function Test-OptionalAppxPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($pattern in @((Get-OptimizerContext).Config.OptionalAppxPatterns)) {
        if ($Name -like "*$pattern*") { return $true }
    }
    return $false
}

function Get-AppxInventory {
    [CmdletBinding()]
    param([string]$Search = '')

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($package in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
        if ($Search -and $package.Name -notlike "*$Search*" -and $package.PackageFullName -notlike "*$Search*") { continue }
        $protected = Test-ProtectedAppxPackage -Name ([string]$package.Name)
        $optional = Test-OptionalAppxPackage -Name ([string]$package.Name)
        $items.Add([pscustomobject]@{
            Type = 'Appx'
            Name = [string]$package.Name
            DisplayName = [string]$package.Name
            Publisher = [string]$package.Publisher
            Version = [string]$package.Version
            PackageFullName = [string]$package.PackageFullName
            InstallLocation = [string]$package.InstallLocation
            IsFramework = [bool]$package.IsFramework
            IsResourcePackage = [bool]$package.IsResourcePackage
            IsProtected = $protected -or [bool]$package.IsFramework -or [bool]$package.IsResourcePackage
            IsOptional = $optional
            CanRemove = $optional -and -not $protected -and -not $package.IsFramework -and -not $package.IsResourcePackage
            Impact = if ($protected) { 'Componente essencial/protegido' } elseif ($optional) { 'Opcional; recursos associados deixarao de funcionar' } else { 'Nao classificado; somente leitura' }
        })
    }
    return @($items | Sort-Object Name)
}

function Get-Win32InstalledApplications {
    [CmdletBinding()]
    param([string]$Search = '')

    $locations = @(
        [pscustomobject]@{ Scope = 'Computador'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' },
        [pscustomobject]@{ Scope = 'Computador 32-bit'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' },
        [pscustomobject]@{ Scope = 'Usuario'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' }
    )
    $seen = @{}
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($location in $locations) {
        foreach ($entry in @(Get-ItemProperty -Path $location.Path -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace([string]$_.DisplayName) } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, PSChildName)) {
            if ($Search -and $entry.DisplayName -notlike "*$Search*") { continue }
            $key = "{0}|{1}|{2}" -f $entry.DisplayName, $entry.DisplayVersion, $entry.Publisher
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $items.Add([pscustomobject]@{
                Type = 'Win32'; Name = [string]$entry.PSChildName; DisplayName = [string]$entry.DisplayName
                Publisher = [string]$entry.Publisher; Version = [string]$entry.DisplayVersion
                InstallLocation = [string]$entry.InstallLocation; Scope = $location.Scope
                IsProtected = $false; IsOptional = $false; CanRemove = $false
                Impact = 'Desinstalacao deve ser feita pela pagina Aplicativos Instalados.'
            })
        }
    }
    return @($items | Sort-Object DisplayName)
}

function Get-InstalledApplications {
    [CmdletBinding()]
    param([string]$Search = '')
    return @((Get-AppxInventory -Search $Search) + (Get-Win32InstalledApplications -Search $Search))
}

function Remove-OptionalAppxPackageSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageFullName,
        [switch]$Confirmed
    )

    if (-not $Confirmed) { throw 'A remocao de aplicativo exige confirmacao explicita.' }
    $package = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object PackageFullName -eq $PackageFullName | Select-Object -First 1
    if (-not $package) { throw 'Pacote Appx nao encontrado para o usuario atual.' }
    if (Test-ProtectedAppxPackage -Name $package.Name) { throw 'Pacote protegido; a remocao foi bloqueada.' }
    if (-not (Test-OptionalAppxPackage -Name $package.Name)) { throw 'Pacote nao classificado como opcional; use somente leitura.' }
    if ($package.IsFramework -or $package.IsResourcePackage) { throw 'Framework/pacote de recurso protegido.' }

    return Invoke-OptimizerOperation -Name "Remover aplicativo opcional: $($package.Name)" -Risk 'Agressivo' -ScriptBlock {
        $manifestPath = Join-Path ([string]$package.InstallLocation) 'AppxManifest.xml'
        $before = [pscustomobject]@{
            Name = [string]$package.Name; PackageFullName = [string]$package.PackageFullName
            InstallLocation = [string]$package.InstallLocation; ManifestPath = $manifestPath
            PayloadAvailable = (Test-Path -LiteralPath $manifestPath -PathType Leaf)
        }
        if (Get-Command Add-OptimizerBackupEntry -ErrorAction SilentlyContinue) {
            Add-OptimizerBackupEntry -Type 'Appx' -Id ([string]$package.PackageFullName) -Original $before `
                -Applied ([pscustomobject]@{ Installed = $false }) `
                -Metadata @{ Reversibility = 'BestEffort'; OfflineReinstallNotGuaranteed = $true } | Out-Null
        }
        if (-not (Get-OptimizerContext).Simulation) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            if (Get-AppxPackage -Name $package.Name -ErrorAction SilentlyContinue) { throw 'O pacote permaneceu registrado.' }
        }
        Write-OptimizerLog -Name "Remover Appx $($package.Name)" -Category 'Aplicativos' `
            -OldValue 'Installed' -NewValue 'RemovedForCurrentUser' `
            -Result $(if ((Get-OptimizerContext).Simulation) { 'Simulated' } else { 'Success' }) | Out-Null
        return [pscustomobject]@{ Name = $package.Name; Removed = $true; ReinstallOfflineGuaranteed = $false }
    }
}

function Restore-AppxBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [switch]$Force)

    Assert-OptimizerMutationAllowed -Operation 'Reinstalar aplicativo opcional' | Out-Null
    $original = $Entry.Original
    if (Get-AppxPackage -Name ([string]$original.Name) -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ Status = 'NoChange'; Name = $original.Name }
    }
    if (-not (Test-Path -LiteralPath ([string]$original.ManifestPath) -PathType Leaf)) {
        return [pscustomobject]@{
            Status = 'NotReversibleOffline'; Name = $original.Name
            Reason = 'O payload local nao existe mais. A reinstalacao exigira Microsoft Store/Internet.'
        }
    }
    if ((Get-OptimizerContext).Simulation) { return [pscustomobject]@{ Status = 'Simulated'; Name = $original.Name } }
    Add-AppxPackage -Register ([string]$original.ManifestPath) -DisableDevelopmentMode -ErrorAction Stop
    if (-not (Get-AppxPackage -Name ([string]$original.Name) -ErrorAction SilentlyContinue)) { throw 'Nao foi possivel verificar o registro do Appx.' }
    return [pscustomobject]@{ Status = 'RestoredBestEffort'; Name = $original.Name }
}

function Open-InstalledAppsSettings {
    [CmdletBinding()]
    param()
    Start-Process 'ms-settings:appsfeatures' -ErrorAction Stop | Out-Null
    return [pscustomobject]@{ Status = 'Opened'; Uri = 'ms-settings:appsfeatures' }
}

function Open-BackgroundAppSettings {
    [CmdletBinding()]
    param()
    Start-Process 'ms-settings:appsfeatures' -ErrorAction Stop | Out-Null
    return [pscustomobject]@{
        Status = 'Manual'; Uri = 'ms-settings:appsfeatures'
        Message = 'No Windows 11, a permissao de segundo plano e configurada nas opcoes avancadas de cada aplicativo.'
    }
}

Export-ModuleMember -Function Get-AppxInventory, Get-Win32InstalledApplications, Get-InstalledApplications,
    Test-ProtectedAppxPackage, Remove-OptionalAppxPackageSafe, Restore-AppxBackupEntry,
    Open-InstalledAppsSettings, Open-BackgroundAppSettings
