[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$SkipValidation,
    [string]$CodeSigningCertificateThumbprint
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Execute o build com Windows PowerShell 5.1.' }

# O build usa ZIP, o compilador .NET Framework e APIs inclusas no
# Windows. O launcher final exige UAC antes de extrair o payload PowerShell.

function Assert-NoReparsePointPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    $relativePart = $fullPath.Substring($pathRoot.Length)
    $cursor = $pathRoot
    foreach ($segment in @($relativePart -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Ponto de nova analise recusado no build: '$cursor'."
            }
        }
    }
    return $fullPath
}

function Assert-ChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $parentFull = [IO.Path]::GetFullPath($ParentPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($ChildPath)

    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Caminho fora da area de build: '$childFull'."
    }

    [void](Assert-NoReparsePointPath -Path $ParentPath)
    [void](Assert-NoReparsePointPath -Path $childFull)
    return $childFull
}

function Get-PeMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Cabecalho MZ invalido em '$Path'." }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) {
            throw "Offset PE invalido em '$Path'."
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Assinatura PE invalida em '$Path'." }
        return [UInt16]$reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-PeApplicationManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Leia exclusivamente o recurso Win32 RT_MANIFEST (tipo 24, ID 1). Uma
    # busca textual no EXE inteiro pode encontrar manifests pertencentes ao
    # payload incorporado e, assim, aprovar por engano o launcher externo.
    if (-not ('WindowsFPSOptimizer.Build.NativeResourceReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WindowsFPSOptimizer.Build
{
    public static class NativeResourceReader
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryEx(
            string lpFileName,
            IntPtr hFile,
            UInt32 dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr FindResource(
            IntPtr hModule,
            IntPtr lpName,
            IntPtr lpType);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LoadResource(
            IntPtr hModule,
            IntPtr hResInfo);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UInt32 SizeofResource(
            IntPtr hModule,
            IntPtr hResInfo);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LockResource(IntPtr hResData);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FreeLibrary(IntPtr hModule);
    }
}
'@
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $loadLibraryAsDataFile = [UInt32]0x00000002
    $loadLibraryAsImageResource = [UInt32]0x00000020
    $module = [WindowsFPSOptimizer.Build.NativeResourceReader]::LoadLibraryEx(
        $fullPath,
        [IntPtr]::Zero,
        ($loadLibraryAsDataFile -bor $loadLibraryAsImageResource)
    )
    if ($module -eq [IntPtr]::Zero) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Nao foi possivel abrir os recursos PE de '$fullPath' (Win32: $errorCode)."
    }

    try {
        $resourceInfo = [WindowsFPSOptimizer.Build.NativeResourceReader]::FindResource(
            $module,
            [IntPtr]1,
            [IntPtr]24
        )
        if ($resourceInfo -eq [IntPtr]::Zero) {
            throw "Recurso RT_MANIFEST, ID 1, ausente em '$fullPath'."
        }

        $resourceSize = [WindowsFPSOptimizer.Build.NativeResourceReader]::SizeofResource(
            $module,
            $resourceInfo
        )
        if ($resourceSize -eq 0) {
            throw "Recurso RT_MANIFEST vazio em '$fullPath'."
        }

        $resourceHandle = [WindowsFPSOptimizer.Build.NativeResourceReader]::LoadResource(
            $module,
            $resourceInfo
        )
        $resourcePointer = [WindowsFPSOptimizer.Build.NativeResourceReader]::LockResource(
            $resourceHandle
        )
        if ($resourceHandle -eq [IntPtr]::Zero -or $resourcePointer -eq [IntPtr]::Zero) {
            throw "Nao foi possivel ler o recurso RT_MANIFEST de '$fullPath'."
        }

        $manifestBytes = New-Object byte[] ([int]$resourceSize)
        [Runtime.InteropServices.Marshal]::Copy(
            $resourcePointer,
            $manifestBytes,
            0,
            [int]$resourceSize
        )

        if (
            $manifestBytes.Length -ge 2 -and
            $manifestBytes[0] -eq 0xFF -and
            $manifestBytes[1] -eq 0xFE
        ) {
            return [Text.Encoding]::Unicode.GetString($manifestBytes).Trim([char]0xFEFF, [char]0)
        }
        if (
            $manifestBytes.Length -ge 2 -and
            $manifestBytes[0] -eq 0xFE -and
            $manifestBytes[1] -eq 0xFF
        ) {
            return [Text.Encoding]::BigEndianUnicode.GetString($manifestBytes).Trim([char]0xFEFF, [char]0)
        }

        return (New-Object Text.UTF8Encoding($false, $true)).
            GetString($manifestBytes).
            Trim([char]0xFEFF, [char]0)
    }
    finally {
        [void][WindowsFPSOptimizer.Build.NativeResourceReader]::FreeLibrary($module)
    }
}

function ConvertTo-CSharpStringValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
}

function Copy-VerifiedBuildInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
    $copiedHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
    if ($copiedHash -ne $ExpectedSha256) {
        throw "O arquivo mudou durante a copia para staging: '$SourcePath'."
    }
}

function Publish-ArtifactSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object[]]$Files
    )

    [void](Assert-NoReparsePointPath -Path $OutputRoot)
    $transactionId = [Guid]::NewGuid().ToString('N')
    $backups = New-Object 'System.Collections.Generic.List[object]'
    $published = New-Object 'System.Collections.Generic.List[string]'
    $prepared = New-Object 'System.Collections.Generic.List[object]'

    try {
        foreach ($mapping in $Files) {
            $source = [IO.Path]::GetFullPath([string]$mapping.Source)
            $destination = Assert-ChildPath -ParentPath $OutputRoot -ChildPath ([string]$mapping.Destination)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Artefato de staging ausente: '$source'."
            }

            # Copie primeiro para o proprio volume de saida. Assim, mesmo quando
            # OutputDirectory estiver em outro disco, uma copia interrompida
            # nunca aparece com o nome final do artefato.
            $preparedPath = Assert-ChildPath -ParentPath $OutputRoot -ChildPath (
                Join-Path $OutputRoot (
                    '.wfpo-stage-' + $transactionId + '-' +
                    [IO.Path]::GetFileName($destination)
                )
            )
            $preparedEntry = [pscustomobject]@{
                Source = $source
                Prepared = $preparedPath
                Destination = $destination
                ExpectedSha256 = if ($mapping.PSObject.Properties['ExpectedSha256']) {
                    [string]$mapping.ExpectedSha256
                }
                else {
                    $null
                }
            }
            [void]$prepared.Add($preparedEntry)
            Copy-Item -LiteralPath $source -Destination $preparedPath -ErrorAction Stop
            [void](Assert-NoReparsePointPath -Path $preparedPath)

            if (-not [string]::IsNullOrWhiteSpace($preparedEntry.ExpectedSha256)) {
                $preparedHash = (Get-FileHash -LiteralPath $preparedPath -Algorithm SHA256).Hash
                if ($preparedHash -ne $preparedEntry.ExpectedSha256) {
                    throw "Hash divergente ao preparar '$destination'."
                }
            }
        }

        foreach ($entry in $prepared) {
            $destination = [string]$entry.Destination
            if (Test-Path -LiteralPath $destination) {
                if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                    throw "O destino de publicacao nao e um arquivo: '$destination'."
                }
                $backup = Assert-ChildPath -ParentPath $OutputRoot -ChildPath (
                    Join-Path $OutputRoot ('.wfpo-backup-' + $transactionId + '-' + [IO.Path]::GetFileName($destination))
                )
                Move-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
                [void]$backups.Add([pscustomobject]@{ Destination = $destination; Backup = $backup })
            }
        }

        foreach ($entry in $prepared) {
            $destination = [string]$entry.Destination
            Move-Item -LiteralPath ([string]$entry.Prepared) -Destination $destination -ErrorAction Stop
            [void]$published.Add($destination)
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.ExpectedSha256)) {
                $publishedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
                if ($publishedHash -ne [string]$entry.ExpectedSha256) {
                    throw "Hash divergente depois de publicar '$destination'."
                }
            }
        }
    }
    catch {
        $publishError = $_
        foreach ($path in $published) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($entry in $prepared) {
            if (Test-Path -LiteralPath $entry.Prepared -PathType Leaf) {
                Remove-Item -LiteralPath $entry.Prepared -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($entry in $backups) {
            if (Test-Path -LiteralPath $entry.Backup -PathType Leaf) {
                try {
                    Move-Item -LiteralPath $entry.Backup -Destination $entry.Destination -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "Falha ao restaurar '$($entry.Destination)': $($_.Exception.Message)"
                }
            }
        }
        throw $publishError
    }

    foreach ($entry in $backups) {
        if (Test-Path -LiteralPath $entry.Backup -PathType Leaf) {
            try { Remove-Item -LiteralPath $entry.Backup -Force -ErrorAction Stop }
            catch { Write-Warning "Backup de publicacao mantido: $($entry.Backup)" }
        }
    }
}

$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'dist'
}
$buildRoot = Assert-ChildPath -ParentPath $projectRoot -ChildPath (
    Join-Path $projectRoot '.build\Native'
)
$packageDirectory = Assert-ChildPath -ParentPath $buildRoot -ChildPath (
    Join-Path $buildRoot 'Package'
)

if (Test-Path -LiteralPath $buildRoot -PathType Container) {
    # Limpar antes da validacao evita que o validador percorra copias de um
    # pacote anterior. O caminho foi resolvido como filho direto do projeto.
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}

$configPath = Join-Path $projectRoot 'Config.json'
$installerScriptPath = Join-Path $projectRoot 'Installer\Install-WindowsFPSOptimizer.ps1'
$appLauncherSourcePath = Join-Path $projectRoot 'Installer\AppLauncher.cs'
$appManifestPath = Join-Path $projectRoot 'Installer\AppLauncher.manifest'
$setupLauncherSourcePath = Join-Path $projectRoot 'Installer\SetupLauncher.cs'
$setupManifestPath = Join-Path $projectRoot 'Installer\SetupLauncher.manifest'
$validationScriptPath = Join-Path $projectRoot 'Tests\Validate-Project.ps1'
$asyncUiTestPath = Join-Path $projectRoot 'Tests\Test-AsyncUiRunspace.ps1'
$performanceTestPath = Join-Path $projectRoot 'Tests\Test-PerformanceImprovements.ps1'
$experienceTestPath = Join-Path $projectRoot 'Tests\Test-SimplifiedExperience.ps1'
$runtimeFiles = @(
    'WindowsFPSOptimizer.ps1',
    'MainWindow.xaml',
    'Config.json',
    'Core.psm1',
    'SystemAnalysis.psm1',
    'Benchmark.psm1',
    'GameOptimizations.psm1',
    'PowerOptimizations.psm1',
    'GraphicsOptimizations.psm1',
    'StorageOptimizations.psm1',
    'ServiceManager.psm1',
    'StartupManager.psm1',
    'BackupManager.psm1',
    'ProcessManager.psm1',
    'Logging.psm1',
    'Profiles.psm1',
    'WindowsAppsManager.psm1',
    'PrivacyManager.psm1',
    'ScheduledTaskManager.psm1',
    'UIController.psm1',
    'README.md'
)

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Config.json nao foi encontrado em '$projectRoot'."
}
if (-not (Test-Path -LiteralPath $installerScriptPath -PathType Leaf)) {
    throw 'O bootstrap Installer\Install-WindowsFPSOptimizer.ps1 nao foi encontrado.'
}
foreach ($requiredInstallerFile in @(
    $appLauncherSourcePath,
    $appManifestPath,
    $setupLauncherSourcePath,
    $setupManifestPath
)) {
    if (-not (Test-Path -LiteralPath $requiredInstallerFile -PathType Leaf)) {
        throw "Arquivo do instalador ausente: '$requiredInstallerFile'."
    }
}

foreach ($relativePath in $runtimeFiles) {
    $sourcePath = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Arquivo obrigatorio ausente: '$relativePath'."
    }
}

# Registre os bytes antes da validacao. Depois dela, cada copia usada no build
# deve manter o mesmo SHA-256, impedindo que uma edicao concorrente produza um
# pacote diferente daquele que acabou de ser validado.
$buildInputPaths = @(
    $installerScriptPath,
    $appLauncherSourcePath,
    $appManifestPath,
    $setupLauncherSourcePath,
    $setupManifestPath,
    $validationScriptPath,
    $asyncUiTestPath,
    $performanceTestPath,
    $experienceTestPath
) + @($runtimeFiles | ForEach-Object { Join-Path $projectRoot $_ })
$buildInputFingerprints = @{}
foreach ($inputPath in $buildInputPaths) {
    $fullInputPath = [IO.Path]::GetFullPath($inputPath)
    $buildInputFingerprints[$fullInputPath] = (
        Get-FileHash -LiteralPath $fullInputPath -Algorithm SHA256
    ).Hash
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$appName = [string]$config.App.Name
$version = [string]$config.App.Version
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
    throw "A versao '$version' em Config.json nao e valida para empacotamento."
}
$numericVersion = [regex]::Match($version, '^([0-9]+)\.([0-9]+)\.([0-9]+)')
$assemblyVersion = '{0}.{1}.{2}.0' -f (
    [UInt16]::Parse($numericVersion.Groups[1].Value),
    [UInt16]::Parse($numericVersion.Groups[2].Value),
    [UInt16]::Parse($numericVersion.Groups[3].Value)
)

$trustedSystemDirectory = [Environment]::SystemDirectory
$trustedWindowsRoot = Split-Path -Parent $trustedSystemDirectory
$nativePowerShell = Join-Path $trustedSystemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
$cscPath = Join-Path $trustedWindowsRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $nativePowerShell -PathType Leaf)) {
    throw 'Windows PowerShell 5.1 nao foi encontrado.'
}
if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
    throw 'O compilador nativo do .NET Framework 4 nao foi encontrado.'
}

if (-not $SkipValidation) {
    if (-not (Test-Path -LiteralPath $validationScriptPath -PathType Leaf)) {
        throw 'O validador Tests\Validate-Project.ps1 nao foi encontrado.'
    }
    if (-not (Test-Path -LiteralPath $asyncUiTestPath -PathType Leaf)) {
        throw 'O teste Tests\Test-AsyncUiRunspace.ps1 nao foi encontrado.'
    }

    Write-Host 'Validando o projeto com Windows PowerShell 5.1...'
    & $nativePowerShell `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $validationScriptPath

    if ($LASTEXITCODE -ne 0) {
        throw "A validacao do projeto falhou com o codigo $LASTEXITCODE."
    }

    Write-Host 'Testando o limite assincrono da interface com Windows PowerShell 5.1...'
    & $nativePowerShell `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $asyncUiTestPath

    if ($LASTEXITCODE -ne 0) {
        throw "O teste assincrono da interface falhou com o codigo $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $performanceTestPath -PathType Leaf)) {
        throw 'O teste Tests\Test-PerformanceImprovements.ps1 nao foi encontrado.'
    }
    Write-Host 'Testando perfis, telemetria e comparacao de capturas...'
    & $nativePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $performanceTestPath
    if ($LASTEXITCODE -ne 0) {
        throw "O teste de desempenho falhou com o codigo $LASTEXITCODE."
    }
    & $nativePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $experienceTestPath
    if ($LASTEXITCODE -ne 0) { throw 'Falha nos testes da interface simplificada.' }
}

[void](New-Item -ItemType Directory -Path $buildRoot -Force)
foreach ($inputPath in $buildInputPaths) {
    $fullInputPath = [IO.Path]::GetFullPath($inputPath)
    $currentHash = (Get-FileHash -LiteralPath $fullInputPath -Algorithm SHA256).Hash
    if ($currentHash -ne [string]$buildInputFingerprints[$fullInputPath]) {
        throw "O arquivo mudou durante a validacao: '$fullInputPath'. Reinicie o build."
    }
}

[void](New-Item -ItemType Directory -Path $packageDirectory -Force)
$stagedOutputDirectory = Assert-ChildPath -ParentPath $buildRoot -ChildPath (
    Join-Path $buildRoot 'Output'
)
[void](New-Item -ItemType Directory -Path $stagedOutputDirectory -Force)

$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void](Assert-NoReparsePointPath -Path $resolvedOutputDirectory)
[void](New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force)
[void](Assert-NoReparsePointPath -Path $resolvedOutputDirectory)

$packageInstallerName = 'Install-WindowsFPSOptimizer.ps1'
Copy-VerifiedBuildInput `
    -SourcePath $installerScriptPath `
    -DestinationPath (Join-Path $packageDirectory $packageInstallerName) `
    -ExpectedSha256 ([string]$buildInputFingerprints[[IO.Path]::GetFullPath($installerScriptPath)])
foreach ($relativePath in $runtimeFiles) {
    $runtimeSourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
    Copy-VerifiedBuildInput `
        -SourcePath $runtimeSourcePath `
        -DestinationPath (Join-Path $packageDirectory ([IO.Path]::GetFileName($relativePath))) `
        -ExpectedSha256 ([string]$buildInputFingerprints[$runtimeSourcePath])
}

$compilerInputDirectory = Assert-ChildPath -ParentPath $buildRoot -ChildPath (
    Join-Path $buildRoot 'CompilerInputs'
)
[void](New-Item -ItemType Directory -Path $compilerInputDirectory -Force)
$stagedLauncherSourcePath = Join-Path $compilerInputDirectory 'SetupLauncher.cs'
$stagedSetupManifestPath = Join-Path $compilerInputDirectory 'SetupLauncher.manifest'
Copy-VerifiedBuildInput `
    -SourcePath $setupLauncherSourcePath `
    -DestinationPath $stagedLauncherSourcePath `
    -ExpectedSha256 ([string]$buildInputFingerprints[[IO.Path]::GetFullPath($setupLauncherSourcePath)])
Copy-VerifiedBuildInput `
    -SourcePath $setupManifestPath `
    -DestinationPath $stagedSetupManifestPath `
    -ExpectedSha256 ([string]$buildInputFingerprints[[IO.Path]::GetFullPath($setupManifestPath)])
$setupLauncherSourcePath = $stagedLauncherSourcePath
$setupManifestPath = $stagedSetupManifestPath

# O WinExe hospeda o motor do Windows PowerShell na propria thread STA.
$stagedAppSource = Join-Path $compilerInputDirectory 'AppLauncher.cs'
$stagedAppManifest = Join-Path $compilerInputDirectory 'AppLauncher.manifest'
Copy-VerifiedBuildInput -SourcePath $appLauncherSourcePath -DestinationPath $stagedAppSource `
    -ExpectedSha256 ([string]$buildInputFingerprints[[IO.Path]::GetFullPath($appLauncherSourcePath)])
Copy-VerifiedBuildInput -SourcePath $appManifestPath -DestinationPath $stagedAppManifest `
    -ExpectedSha256 ([string]$buildInputFingerprints[[IO.Path]::GetFullPath($appManifestPath)])
$appLauncherSourcePath = $stagedAppSource
$appManifestPath = $stagedAppManifest
$appLauncherText = [IO.File]::ReadAllText($appLauncherSourcePath).Replace('__ASSEMBLY_VERSION__', $assemblyVersion)
$generatedAppSource = Join-Path $compilerInputDirectory 'AppLauncher.generated.cs'
[IO.File]::WriteAllText($generatedAppSource, $appLauncherText, [Text.UTF8Encoding]::new($true))
$appLauncherPath = Join-Path $packageDirectory 'WindowsFPSOptimizer.exe'
& $cscPath /nologo /target:winexe /platform:anycpu /optimize+ /warnaserror+ `
    /reference:System.Windows.Forms.dll "/reference:$([PowerShell].Assembly.Location)" `
    "/win32manifest:$appManifestPath" "/out:$appLauncherPath" $generatedAppSource
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o aplicativo grafico.' }
$packageRuntimeFiles = @($runtimeFiles) + 'WindowsFPSOptimizer.exe'

$manifestFiles = foreach ($fileName in @($packageInstallerName) + $packageRuntimeFiles) {
    $flatName = [IO.Path]::GetFileName($fileName)
    $packagePath = Join-Path $packageDirectory $flatName
    $item = Get-Item -LiteralPath $packagePath
    [ordered]@{
        Path = $flatName
        Length = [Int64]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    }
}

$packageManifest = [ordered]@{
    SchemaVersion = 1
    AppName = $appName
    Version = $version
    CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Files = @($manifestFiles)
}
$manifestOutputPath = Join-Path $packageDirectory 'PackageManifest.json'
$packageManifest | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $manifestOutputPath -Encoding UTF8

$artifactFileName = "WindowsFPSOptimizer-{0}-Setup.exe" -f $version
$targetExePath = Join-Path $resolvedOutputDirectory $artifactFileName
$targetHashPath = $targetExePath + '.sha256.txt'
$targetBuildInfoPath = Join-Path $resolvedOutputDirectory 'WindowsFPSOptimizer-BuildInfo.json'
$stagedExePath = Join-Path $stagedOutputDirectory $artifactFileName
$stagedHashPath = $stagedExePath + '.sha256.txt'
$stagedBuildInfoPath = Join-Path $stagedOutputDirectory 'WindowsFPSOptimizer-BuildInfo.json'
$innerExePath = Join-Path $stagedOutputDirectory 'WindowsFPSOptimizer-Payload.zip'

Write-Host 'Validando o pacote sem instalar...'
& $nativePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $packageDirectory $packageInstallerName) -ValidateOnly -Quiet
if ($LASTEXITCODE -ne 0) { throw 'O pacote falhou na validacao do manifesto.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($packageDirectory, $innerExePath)
$innerHash = (Get-FileHash -LiteralPath $innerExePath -Algorithm SHA256).Hash
$launcherTemplate = Get-Content -LiteralPath $setupLauncherSourcePath -Raw -Encoding UTF8
$generatedLauncherSource = $launcherTemplate.
    Replace('__APP_NAME__', (ConvertTo-CSharpStringValue -Value $appName)).
    Replace('__APP_VERSION__', (ConvertTo-CSharpStringValue -Value $version)).
    Replace('__ASSEMBLY_VERSION__', $assemblyVersion).
    Replace('__PAYLOAD_SHA256__', $innerHash)
if ($generatedLauncherSource -match '__(?:APP|ASSEMBLY|PAYLOAD)_') {
    throw 'Nem todos os placeholders do launcher foram substituidos.'
}

$generatedLauncherPath = Join-Path $buildRoot 'SetupLauncher.generated.cs'
$generatedLauncherSource | Set-Content -LiteralPath $generatedLauncherPath -Encoding UTF8

$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu32bitpreferred',
    '/optimize+',
    '/warnaserror+',
    ('/win32manifest:{0}' -f $setupManifestPath),
    ('/resource:{0},WindowsFPSOptimizer.Payload' -f $innerExePath),
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Security.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll',
    ('/out:{0}' -f $stagedExePath),
    $generatedLauncherPath
)

Write-Host 'Compilando launcher administrativo nativo do .NET Framework...'
$compilerOutput = @(& $cscPath @compilerArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "O compilador C# falhou:`n$($compilerOutput -join [Environment]::NewLine)"
}
if (-not (Test-Path -LiteralPath $stagedExePath -PathType Leaf)) {
    throw 'O compilador terminou sem criar o launcher EXE.'
}
if ((Get-PeMachine -Path $stagedExePath) -ne 0x014C) {
    throw 'O launcher final nao possui cabecalho PE x86 compativel.'
}

$launcherManifestText = Get-PeApplicationManifest -Path $stagedExePath
try {
    [xml]$launcherManifest = $launcherManifestText
}
catch {
    throw "O recurso RT_MANIFEST do launcher nao e XML valido: $($_.Exception.Message)"
}
$requestedExecutionLevel = $launcherManifest.SelectSingleNode(
    "//*[local-name()='requestedExecutionLevel']"
)
if (
    $null -eq $requestedExecutionLevel -or
    $requestedExecutionLevel.GetAttribute('level') -ne 'requireAdministrator'
) {
    throw 'O RT_MANIFEST do launcher nao exige requestedExecutionLevel=requireAdministrator.'
}

# Carregue uma copia em memoria somente para confirmar que o recurso embutido
# possui exatamente o mesmo SHA-256 do ZIP validado.
$launcherBytes = [IO.File]::ReadAllBytes($stagedExePath)
$launcherAssembly = [Reflection.Assembly]::Load($launcherBytes)
$portableKinds = [Reflection.PortableExecutableKinds]0
$runtimeMachine = [Reflection.ImageFileMachine]::I386
$launcherAssembly.ManifestModule.GetPEKind([ref]$portableKinds, [ref]$runtimeMachine)
if (
    ($portableKinds -band [Reflection.PortableExecutableKinds]::ILOnly) -eq 0 -or
    ($portableKinds -band [Reflection.PortableExecutableKinds]::Preferred32Bit) -eq 0 -or
    ($portableKinds -band [Reflection.PortableExecutableKinds]::Required32Bit) -ne 0 -or
    $runtimeMachine -ne [Reflection.ImageFileMachine]::I386
) {
    throw "CorFlags inesperados no launcher: '$portableKinds' / '$runtimeMachine'."
}
$payloadStream = $launcherAssembly.GetManifestResourceStream('WindowsFPSOptimizer.Payload')
if ($null -eq $payloadStream) {
    throw 'O recurso WindowsFPSOptimizer.Payload nao foi incorporado.'
}
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $embeddedHash = [BitConverter]::ToString($sha256.ComputeHash($payloadStream)).Replace('-', '')
}
finally {
    $sha256.Dispose()
    $payloadStream.Dispose()
}
if ($embeddedHash -ne $innerHash) {
    throw 'O hash do payload embutido diverge do ZIP validado.'
}

if (-not [string]::IsNullOrWhiteSpace($CodeSigningCertificateThumbprint)) {
    $certificate = Get-ChildItem -LiteralPath Cert:\CurrentUser\My |
        Where-Object Thumbprint -eq $CodeSigningCertificateThumbprint |
        Select-Object -First 1
    if ($null -eq $certificate) {
        throw "Certificado '$CodeSigningCertificateThumbprint' nao encontrado em Cert:\CurrentUser\My."
    }

    $signature = Set-AuthenticodeSignature `
        -LiteralPath $stagedExePath `
        -Certificate $certificate `
        -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid') {
        throw "A assinatura do EXE falhou: $($signature.StatusMessage)"
    }
}

$exeHash = (Get-FileHash -LiteralPath $stagedExePath -Algorithm SHA256).Hash
("$exeHash  " + $artifactFileName) |
    Set-Content -LiteralPath $stagedHashPath -Encoding ASCII

$artifactInfo = [ordered]@{
    AppName = $appName
    Version = $version
    ExeFileName = $artifactFileName
    Length = (Get-Item -LiteralPath $stagedExePath).Length
    Sha256 = $exeHash
    Signed = -not [string]::IsNullOrWhiteSpace($CodeSigningCertificateThumbprint)
    AuthenticodeStatus = if ([string]::IsNullOrWhiteSpace($CodeSigningCertificateThumbprint)) {
        'NotSigned'
    }
    else {
        'Valid'
    }
    BootstrapMachine = 'I386-AnyCPU32BitPreferred'
    RequiresAdministrator = $true
    PayloadFormat = 'ZIP'
    ConsoleWindows = $false
    InnerPayloadSha256 = $innerHash
    BuiltAtUtc = [DateTime]::UtcNow.ToString('o')
}
$artifactInfo | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $stagedBuildInfoPath -Encoding UTF8

$stagedHashFileHash = (Get-FileHash -LiteralPath $stagedHashPath -Algorithm SHA256).Hash
$stagedBuildInfoHash = (Get-FileHash -LiteralPath $stagedBuildInfoPath -Algorithm SHA256).Hash

# Somente agora, depois de compilar, validar, opcionalmente assinar e gerar os
# metadados coerentes, troque o conjunto publicado. Qualquer falha restaura a
# versao anterior e seus sidecars.
Publish-ArtifactSet -OutputRoot $resolvedOutputDirectory -Files @(
    [pscustomobject]@{
        Source = $stagedExePath
        Destination = $targetExePath
        ExpectedSha256 = $exeHash
    },
    [pscustomobject]@{
        Source = $stagedHashPath
        Destination = $targetHashPath
        ExpectedSha256 = $stagedHashFileHash
    },
    [pscustomobject]@{
        Source = $stagedBuildInfoPath
        Destination = $targetBuildInfoPath
        ExpectedSha256 = $stagedBuildInfoHash
    }
)

Write-Host ''
Write-Host 'Build concluido com sucesso.'
Write-Host "EXE: $targetExePath"
Write-Host "SHA-256: $exeHash"
