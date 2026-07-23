[CmdletBinding()]
param(
    [string]$InstallBasePath,
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [switch]$Quiet,
    [switch]$DevelopmentTest,
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Este script e executado pelo pacote IExpress. Ele instala os arquivos em um
# caminho persistente antes de iniciar a interface. Assim, uma eventual
# elevacao por UAC, restauracoes apos reinicializacao e atalhos por jogo nunca
# dependem da pasta temporaria usada pelo autoextrator.

function Test-EnvironmentSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    return ($value -match '^(?i:1|true|yes|sim)$')
}

function Show-InstallerMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Title = 'Windows FPS Optimizer',

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Kind = 'Information',

        [switch]$Force
    )

    if (-not $Force -and $script:IsQuiet) {
        return
    }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $icon = [System.Windows.MessageBoxImage]::$Kind
        [void][System.Windows.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.MessageBoxButton]::OK,
            $icon
        )
    }
    catch {
        if ($Kind -eq 'Error') {
            Write-Error -Message $Message -ErrorAction Continue
        }
        else {
            Write-Host $Message
        }
    }
}

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
                throw "Ponto de nova analise recusado no caminho seguro: '$cursor'."
            }
        }
    }

    return $fullPath
}

function Assert-SafeChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $parentWithoutSeparator = [IO.Path]::GetFullPath($ParentPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $parentFull = $parentWithoutSeparator + [IO.Path]::DirectorySeparatorChar

    $childFull = [IO.Path]::GetFullPath($ChildPath)

    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "O caminho '$childFull' nao pertence ao diretorio permitido '$parentFull'."
    }

    # Contencao lexical nao basta para operacoes destrutivas: uma junction ou
    # link simbolico em qualquer componente poderia redirecionar a operacao.
    [void](Assert-NoReparsePointPath -Path $parentWithoutSeparator)
    [void](Assert-NoReparsePointPath -Path $childFull)

    return $childFull
}

function Remove-SafeDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $safeTarget = Assert-SafeChildPath -ParentPath $ParentPath -ChildPath $TargetPath
    if (Test-Path -LiteralPath $safeTarget -PathType Container) {
        Remove-Item -LiteralPath $safeTarget -Recurse -Force -ErrorAction Stop
    }
}

function Set-AtomicFileReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$DiscardPrefix
    )

    $safeSource = Assert-SafeChildPath -ParentPath $ParentPath -ChildPath $SourcePath
    $safeDestination = Assert-SafeChildPath -ParentPath $ParentPath -ChildPath $DestinationPath
    if (
        -not (Test-Path -LiteralPath $safeSource -PathType Leaf) -or
        -not (Test-Path -LiteralPath $safeDestination -PathType Leaf)
    ) {
        throw 'A substituicao atomica exige dois arquivos existentes.'
    }

    # Windows PowerShell 5.1 nao encaminha $null de forma confiavel ao terceiro
    # argumento de File.Replace. Use um backup descartavel valido e remova-o.
    $discardPath = Assert-SafeChildPath -ParentPath $ParentPath -ChildPath (
        Join-Path $ParentPath (
            $DiscardPrefix + '-' + [Guid]::NewGuid().ToString('N') + '.tmp'
        )
    )
    [IO.File]::Replace($safeSource, $safeDestination, $discardPath)
    if (Test-Path -LiteralPath $discardPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $discardPath -Force
        }
        catch {
            Write-Warning "Um backup atomico descartavel foi mantido em '$discardPath'."
        }
    }
}

function Test-InstallerAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TrustedProgramFilesPath {
    [CmdletBinding()]
    param()

    $view = if ([Environment]::Is64BitOperatingSystem) {
        [Microsoft.Win32.RegistryView]::Registry64
    }
    else {
        [Microsoft.Win32.RegistryView]::Registry32
    }

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        $view
    )
    $currentVersionKey = $null
    try {
        $currentVersionKey = $baseKey.OpenSubKey(
            'SOFTWARE\Microsoft\Windows\CurrentVersion',
            $false
        )
        if ($null -eq $currentVersionKey) {
            throw 'A chave CurrentVersion do Windows nao foi encontrada.'
        }

        $programFilesPath = [string]$currentVersionKey.GetValue(
            'ProgramFilesDir',
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        if ([string]::IsNullOrWhiteSpace($programFilesPath)) {
            throw 'ProgramFilesDir esta vazio no Registro do Windows.'
        }
        if ($programFilesPath.Contains('%')) {
            throw 'ProgramFilesDir contem variaveis de ambiente nao confiaveis.'
        }
        return [IO.Path]::GetFullPath($programFilesPath)
    }
    finally {
        if ($null -ne $currentVersionKey) { $currentVersionKey.Dispose() }
        $baseKey.Dispose()
    }
}

function Set-ProtectedDirectoryAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-InstallerAdministrator)) {
        throw 'Somente um administrador pode proteger a pasta do aplicativo.'
    }

    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $inheritance = (
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    )
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $system,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        $allow
    )))
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $administrators,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        $allow
    )))
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $users,
        (
            [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
            [Security.AccessControl.FileSystemRights]::Synchronize
        ),
        $inheritance,
        $propagation,
        $allow
    )))

    (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).SetAccessControl($security)
}

function Set-ProtectedFileAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $system,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $allow
    )))
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $administrators,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $allow
    )))
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $users,
        (
            [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
            [Security.AccessControl.FileSystemRights]::Synchronize
        ),
        $allow
    )))

    (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).SetAccessControl($security)
}

function New-OptimizerShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [Parameter(Mandatory = $true)]
        [string]$ApplicationDirectory
    )

    $shortcutDirectory = Split-Path -Parent $ShortcutPath
    if (-not (Test-Path -LiteralPath $shortcutDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $shortcutDirectory -Force)
    }

    # O atalho e aberto pelo Explorer de 64 bits; por isso, System32 e o destino
    # persistente correto, independentemente da arquitetura do instalador.
    $nativeSystemDirectory = [Environment]::SystemDirectory
    $shortcutPowerShell = Join-Path $nativeSystemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
    $mainScript = Join-Path $ApplicationDirectory 'WindowsFPSOptimizer.ps1'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $mainScript.Replace('"', '""')

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $shortcutPowerShell
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $ApplicationDirectory
        $shortcut.Description = 'Otimizador seguro do Windows para jogos'
        $shortcut.WindowStyle = 1
        $shortcut.IconLocation = (Join-Path $nativeSystemDirectory 'shell32.dll') + ',238'
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

$script:IsQuiet = $Quiet
$ValidateOnly = $ValidateOnly -or (Test-EnvironmentSwitch -Name 'WFPO_INSTALL_VALIDATE_ONLY')

$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$manifestPath = Join-Path $packageRoot 'PackageManifest.json'
$stagingPath = $null
$previousPath = $null
$targetPath = $null
$appBasePath = $null
$targetWasMoved = $false
$newTargetInstalled = $false
$installCommitted = $false
$currentTempPath = $null
$currentPath = $null
$currentBackupPath = $null
$currentPublished = $false
$currentExistedBefore = $false
$currentRollbackSucceeded = $true
$receiptPath = $null
$receiptTempPath = $null
$receiptBackupPath = $null
$receiptPublished = $false
$receiptExistedBefore = $false

try {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'O manifesto do pacote nao foi encontrado. O instalador esta incompleto.'
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1) {
        throw "Versao de manifesto nao suportada: $($manifest.SchemaVersion)."
    }

    $version = [string]$manifest.Version
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw "Versao de aplicativo invalida no manifesto: '$version'."
    }

    $manifestFiles = @($manifest.Files)
    if ($manifestFiles.Count -lt 1) {
        throw 'O manifesto nao contem arquivos para instalar.'
    }

    # Valide o pacote antes do UAC para falhar cedo e novamente no processo
    # elevado. A copia ao staging tambem sera validada depois, fechando a janela
    # entre leitura da origem e persistencia do destino.
    foreach ($fileEntry in $manifestFiles) {
        $relativePath = [string]$fileEntry.Path
        if (
            [string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            [IO.Path]::GetFileName($relativePath) -ne $relativePath -or
            $relativePath -in @('.', '..')
        ) {
            throw "Caminho inseguro encontrado no manifesto: '$relativePath'."
        }

        $sourcePath = Assert-SafeChildPath -ParentPath $packageRoot -ChildPath (
            Join-Path $packageRoot $relativePath
        )
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Arquivo ausente no pacote: '$relativePath'."
        }

        $sourceItem = Get-Item -LiteralPath $sourcePath
        if ($sourceItem.Length -ne [Int64]$fileEntry.Length) {
            throw "Tamanho invalido para '$relativePath'."
        }
        if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne [string]$fileEntry.Sha256) {
            throw "Falha de integridade em '$relativePath'."
        }
    }

    if ($ValidateOnly) {
        Write-Host "Pacote $version validado: $($manifestFiles.Count) arquivos integros."
        exit 0
    }

    if ($DevelopmentTest) {
        if ([string]::IsNullOrWhiteSpace($InstallBasePath)) {
            throw 'DevelopmentTest exige InstallBasePath explicito.'
        }

        # Uma instalacao de desenvolvimento e somente para testes automatizados.
        # Nao crie atalhos nem abra codigo fora do Program Files.
        $NoLaunch = $true
        $NoShortcuts = $true
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($InstallBasePath)) {
            throw 'Um caminho personalizado so e permitido com DevelopmentTest.'
        }

        if (-not (Test-InstallerAdministrator)) {
            throw (
                'O instalador PowerShell nao pode elevar codigo extraido de uma pasta temporaria. ' +
                'Execute o arquivo Setup.exe original, que solicita UAC antes da extracao.'
            )
        }

        $programFilesPath = Get-TrustedProgramFilesPath
        $InstallBasePath = Join-Path $programFilesPath 'WindowsFPSOptimizer'
    }

    $installRoot = [IO.Path]::GetFullPath($InstallBasePath)
    $appBasePath = Join-Path $installRoot 'App'
    [void](Assert-NoReparsePointPath -Path $installRoot)
    [void](Assert-NoReparsePointPath -Path $appBasePath)

    [void](New-Item -ItemType Directory -Path $installRoot -Force)
    if (-not $DevelopmentTest) {
        Set-ProtectedDirectoryAcl -Path $installRoot
    }

    [void](New-Item -ItemType Directory -Path $appBasePath -Force)
    if (-not $DevelopmentTest) {
        Set-ProtectedDirectoryAcl -Path $appBasePath
    }
    [void](Assert-NoReparsePointPath -Path $appBasePath)

    $targetPath = Assert-SafeChildPath -ParentPath $appBasePath -ChildPath (Join-Path $appBasePath $version)
    $stagingPath = Assert-SafeChildPath -ParentPath $appBasePath -ChildPath (
        Join-Path $appBasePath ('.staging-' + [Guid]::NewGuid().ToString('N'))
    )
    [void](New-Item -ItemType Directory -Path $stagingPath -Force)

    foreach ($fileEntry in $manifestFiles) {
        $relativePath = [string]$fileEntry.Path

        $sourcePath = Assert-SafeChildPath -ParentPath $packageRoot -ChildPath (
            Join-Path $packageRoot $relativePath
        )
        $destinationPath = Join-Path $stagingPath $relativePath
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

        $destinationItem = Get-Item -LiteralPath $destinationPath
        if ($destinationItem.Length -ne [Int64]$fileEntry.Length) {
            throw "Tamanho divergente depois da copia de '$relativePath'."
        }
        if ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne [string]$fileEntry.Sha256) {
            throw "Falha de integridade depois da copia de '$relativePath'."
        }
        if (-not $DevelopmentTest) {
            Set-ProtectedFileAcl -Path $destinationPath
        }
    }

    $installedMainScript = Join-Path $stagingPath 'WindowsFPSOptimizer.ps1'
    if (-not (Test-Path -LiteralPath $installedMainScript -PathType Leaf)) {
        throw 'O script principal nao esta presente no pacote validado.'
    }

    $installMetadata = [ordered]@{
        SchemaVersion = 1
        AppName = [string]$manifest.AppName
        Version = $version
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        ManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        InstallPath = $targetPath
    }
    $installMetadata | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $stagingPath 'InstallMetadata.json') -Encoding UTF8
    if (-not $DevelopmentTest) {
        Set-ProtectedFileAcl -Path (Join-Path $stagingPath 'InstallMetadata.json')
        Set-ProtectedDirectoryAcl -Path $stagingPath
    }

    # A troca por diretorios deixa a instalacao antiga intacta ate que todos os
    # arquivos novos tenham sido copiados e validados.
    if (Test-Path -LiteralPath $targetPath -PathType Container) {
        $previousPath = Assert-SafeChildPath -ParentPath $appBasePath -ChildPath (
            Join-Path $appBasePath ('.previous-' + [Guid]::NewGuid().ToString('N'))
        )
        Move-Item -LiteralPath $targetPath -Destination $previousPath
        $targetWasMoved = $true
    }

    Move-Item -LiteralPath $stagingPath -Destination $targetPath
    $stagingPath = $null
    $newTargetInstalled = $true
    if (-not $DevelopmentTest) {
        Set-ProtectedDirectoryAcl -Path $targetPath
    }

    $currentInstall = [ordered]@{
        SchemaVersion = 1
        Version = $version
        InstallPath = $targetPath
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    # Atualize o ponteiro Current.json atomicamente. Se a gravacao falhar, o
    # arquivo anterior permanece intacto e o catch restaura o diretorio antigo.
    $currentPath = Assert-SafeChildPath -ParentPath $appBasePath -ChildPath (
        Join-Path $appBasePath 'Current.json'
    )
    if (
        (Test-Path -LiteralPath $currentPath) -and
        -not (Test-Path -LiteralPath $currentPath -PathType Leaf)
    ) {
        throw "Current.json deve ser um arquivo comum: '$currentPath'."
    }
    $currentExistedBefore = Test-Path -LiteralPath $currentPath -PathType Leaf
    $currentTempPath = Assert-SafeChildPath -ParentPath $appBasePath -ChildPath (
        Join-Path $appBasePath ('.current-' + [Guid]::NewGuid().ToString('N') + '.json')
    )
    $currentInstall | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $currentTempPath -Encoding UTF8

    if (-not $DevelopmentTest) {
        Set-ProtectedFileAcl -Path $currentTempPath
        if ($currentExistedBefore) {
            Set-ProtectedFileAcl -Path $currentPath
        }
    }

    if ($currentExistedBefore) {
        $currentBackupPath = Assert-SafeChildPath -ParentPath $appBasePath -ChildPath (
            Join-Path $appBasePath ('.current-backup-' + [Guid]::NewGuid().ToString('N') + '.json')
        )
        [IO.File]::Replace($currentTempPath, $currentPath, $currentBackupPath)
    }
    else {
        Move-Item -LiteralPath $currentTempPath -Destination $currentPath
    }
    $currentTempPath = $null
    $currentPublished = $true

    # O recibo faz parte da mesma transacao que o diretorio da versao e o
    # ponteiro Current.json. O launcher externo so anuncia sucesso depois de
    # validar esse arquivo; portanto, ele precisa existir antes do commit.
    $postInstallWarnings = New-Object 'System.Collections.Generic.List[string]'
    $installSession = [Environment]::GetEnvironmentVariable('WFPO_INSTALL_SESSION', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($installSession)) {
        if ($installSession -notmatch '^[A-Fa-f0-9]{32}$') {
            throw 'O identificador da sessao do instalador e invalido.'
        }

        $receiptDirectory = Join-Path $installRoot 'InstallReceipts'
        [void](Assert-NoReparsePointPath -Path $receiptDirectory)
        [void](New-Item -ItemType Directory -Path $receiptDirectory -Force)
        [void](Assert-NoReparsePointPath -Path $receiptDirectory)
        if (-not $DevelopmentTest) {
            Set-ProtectedDirectoryAcl -Path $receiptDirectory
        }

        $receiptPath = Assert-SafeChildPath -ParentPath $receiptDirectory -ChildPath (
            Join-Path $receiptDirectory ($installSession + '.json')
        )
        if (
            (Test-Path -LiteralPath $receiptPath) -and
            -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)
        ) {
            throw "O caminho reservado ao recibo nao e um arquivo: '$receiptPath'."
        }

        $receiptTempPath = Assert-SafeChildPath -ParentPath $receiptDirectory -ChildPath (
            Join-Path $receiptDirectory (
                '.receipt-' + $installSession + '-' + [Guid]::NewGuid().ToString('N') + '.json'
            )
        )
        $receipt = [ordered]@{
            SchemaVersion = 1
            Session = $installSession
            Success = $true
            Version = $version
            InstallPath = $targetPath
            CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
            Warnings = @()
        }
        $receipt | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $receiptTempPath -Encoding UTF8
        if (-not $DevelopmentTest) {
            Set-ProtectedFileAcl -Path $receiptTempPath
        }

        $receiptExistedBefore = Test-Path -LiteralPath $receiptPath -PathType Leaf
        if ($receiptExistedBefore) {
            $receiptBackupPath = Assert-SafeChildPath -ParentPath $receiptDirectory -ChildPath (
                Join-Path $receiptDirectory (
                    '.receipt-backup-' + $installSession + '-' +
                    [Guid]::NewGuid().ToString('N') + '.json'
                )
            )
            [IO.File]::Replace($receiptTempPath, $receiptPath, $receiptBackupPath)
        }
        else {
            Move-Item -LiteralPath $receiptTempPath -Destination $receiptPath
        }
        $receiptTempPath = $null
        $receiptPublished = $true
    }

    $installCommitted = $true

    if ($null -ne $currentBackupPath -and (Test-Path -LiteralPath $currentBackupPath -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $currentBackupPath -Force
            $currentBackupPath = $null
        }
        catch {
            Write-Warning "O backup temporario de Current.json foi mantido: $($_.Exception.Message)"
        }
    }

    if ($targetWasMoved -and (Test-Path -LiteralPath $previousPath -PathType Container)) {
        try {
            Remove-SafeDirectory -ParentPath $appBasePath -TargetPath $previousPath
            $previousPath = $null
        }
        catch {
            # Uma instancia antiga ainda aberta pode manter algum arquivo em uso.
            # A pasta anterior e segura e pode ser removida numa instalacao futura.
            Write-Warning "A versao anterior foi mantida em '$previousPath': $($_.Exception.Message)"
        }
    }

    if ($null -ne $receiptBackupPath -and (Test-Path -LiteralPath $receiptBackupPath -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $receiptBackupPath -Force
            $receiptBackupPath = $null
        }
        catch {
            Write-Warning "O backup temporario do recibo foi mantido: $($_.Exception.Message)"
        }
    }

    # Atalhos sao conveniencias pos-commit. Criar somente depois do recibo evita
    # deixar atalhos apontando para uma versao revertida se o commit falhar.
    if (-not $NoShortcuts) {
        try {
            $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
            $programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)

            if (-not [string]::IsNullOrWhiteSpace($desktopPath)) {
                New-OptimizerShortcut `
                    -ShortcutPath (Join-Path $desktopPath 'Windows FPS Optimizer.lnk') `
                    -ApplicationDirectory $targetPath
            }

            if (-not [string]::IsNullOrWhiteSpace($programsPath)) {
                New-OptimizerShortcut `
                    -ShortcutPath (Join-Path $programsPath 'Windows FPS Optimizer.lnk') `
                    -ApplicationDirectory $targetPath
            }
        }
        catch {
            [void]$postInstallWarnings.Add("Atalhos nao puderam ser criados: $($_.Exception.Message)")
        }
    }

    # Atualize os avisos sem invalidar o recibo de commit ja publicado. Se essa
    # atualizacao cosmetica falhar, o recibo original continua valido.
    if ($receiptPublished -and $postInstallWarnings.Count -gt 0) {
        $receiptUpdateTempPath = $null
        try {
            $receipt['Warnings'] = @($postInstallWarnings)
            $receiptUpdateTempPath = Assert-SafeChildPath -ParentPath $receiptDirectory -ChildPath (
                Join-Path $receiptDirectory (
                    '.receipt-update-' + $installSession + '-' +
                    [Guid]::NewGuid().ToString('N') + '.json'
                )
            )
            $receipt | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath $receiptUpdateTempPath -Encoding UTF8
            if (-not $DevelopmentTest) {
                Set-ProtectedFileAcl -Path $receiptUpdateTempPath
            }
            Set-AtomicFileReplacement `
                -ParentPath $receiptDirectory `
                -SourcePath $receiptUpdateTempPath `
                -DestinationPath $receiptPath `
                -DiscardPrefix '.receipt-update-discard'
            $receiptUpdateTempPath = $null
        }
        catch {
            Write-Warning "Os avisos nao puderam ser anexados ao recibo: $($_.Exception.Message)"
            if (
                $null -ne $receiptUpdateTempPath -and
                (Test-Path -LiteralPath $receiptUpdateTempPath -PathType Leaf)
            ) {
                Remove-Item -LiteralPath $receiptUpdateTempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $successMessage = (
        "Windows FPS Optimizer $version foi instalado com sucesso.`n`n" +
        "Local: $targetPath`n" +
        "O modo de simulacao permanece ativado por padrao."
    )
    if ($postInstallWarnings.Count -gt 0) {
        $successMessage += "`n`nAvisos:`n- " + ($postInstallWarnings -join "`n- ")
    }

    Show-InstallerMessage -Message (
        $successMessage
    )
    exit 0
}
catch {
    $failureMessage = $_.Exception.Message

    if ($null -ne $receiptTempPath) {
        try {
            if (Test-Path -LiteralPath $receiptTempPath -PathType Leaf) {
                Remove-Item -LiteralPath $receiptTempPath -Force
            }
        }
        catch {
            Write-Warning "Nao foi possivel remover o recibo temporario: $($_.Exception.Message)"
        }
    }

    if (
        -not $installCommitted -and
        $receiptPublished -and
        $null -ne $receiptPath
    ) {
        try {
            if (
                $receiptExistedBefore -and
                $null -ne $receiptBackupPath -and
                (Test-Path -LiteralPath $receiptBackupPath -PathType Leaf)
            ) {
                if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
                    Set-AtomicFileReplacement `
                        -ParentPath (Split-Path -Parent $receiptPath) `
                        -SourcePath $receiptBackupPath `
                        -DestinationPath $receiptPath `
                        -DiscardPrefix '.receipt-rollback-discard'
                }
                else {
                    Move-Item -LiteralPath $receiptBackupPath -Destination $receiptPath
                }
            }
            elseif (
                -not $receiptExistedBefore -and
                (Test-Path -LiteralPath $receiptPath -PathType Leaf)
            ) {
                Remove-Item -LiteralPath $receiptPath -Force
            }
            $receiptPublished = $false
        }
        catch {
            $failureMessage += "`nA restauracao do recibo de instalacao falhou: $($_.Exception.Message)"
        }
    }

    if ($null -ne $stagingPath -and $null -ne $appBasePath) {
        try {
            Remove-SafeDirectory -ParentPath $appBasePath -TargetPath $stagingPath
        }
        catch {
            Write-Warning "Nao foi possivel remover o staging: $($_.Exception.Message)"
        }
    }

    if ($null -ne $currentTempPath -and $null -ne $appBasePath) {
        try {
            if (Test-Path -LiteralPath $currentTempPath -PathType Leaf) {
                Remove-Item -LiteralPath $currentTempPath -Force
            }
        }
        catch {
            Write-Warning "Nao foi possivel remover o ponteiro temporario: $($_.Exception.Message)"
        }
    }

    if (
        -not $installCommitted -and
        $currentPublished -and
        $null -ne $currentPath
    ) {
        $currentRollbackSucceeded = $false
        try {
            if ($currentExistedBefore) {
                if (
                    $null -eq $currentBackupPath -or
                    -not (Test-Path -LiteralPath $currentBackupPath -PathType Leaf)
                ) {
                    throw 'O backup anterior de Current.json nao esta disponivel.'
                }

                if (Test-Path -LiteralPath $currentPath) {
                    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
                        throw 'Current.json deixou de ser um arquivo durante o rollback.'
                    }
                    Set-AtomicFileReplacement `
                        -ParentPath $appBasePath `
                        -SourcePath $currentBackupPath `
                        -DestinationPath $currentPath `
                        -DiscardPrefix '.current-rollback-discard'
                }
                else {
                    Move-Item -LiteralPath $currentBackupPath -Destination $currentPath
                }
            }
            elseif (Test-Path -LiteralPath $currentPath) {
                if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
                    throw 'Current.json deixou de ser um arquivo durante o rollback.'
                }
                Remove-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            }
            $currentRollbackSucceeded = $true
        }
        catch {
            $failureMessage += "`nA restauracao de Current.json falhou: $($_.Exception.Message)"
        }
    }

    # Antes do commit, remova a versao nova e restaure integralmente a anterior.
    if (
        -not $installCommitted -and
        $newTargetInstalled -and
        $currentRollbackSucceeded -and
        $null -ne $targetPath -and
        $null -ne $appBasePath -and
        (Test-Path -LiteralPath $targetPath -PathType Container)
    ) {
        try {
            Remove-SafeDirectory -ParentPath $appBasePath -TargetPath $targetPath
        }
        catch {
            $failureMessage += "`nA remocao da instalacao incompleta falhou: $($_.Exception.Message)"
        }
    }

    if (
        -not $installCommitted -and
        $currentRollbackSucceeded -and
        $targetWasMoved -and
        $null -ne $previousPath -and
        $null -ne $targetPath -and
        (Test-Path -LiteralPath $previousPath -PathType Container) -and
        -not (Test-Path -LiteralPath $targetPath)
    ) {
        try {
            Move-Item -LiteralPath $previousPath -Destination $targetPath
        }
        catch {
            $failureMessage += "`nA restauracao automatica da versao anterior tambem falhou: $($_.Exception.Message)"
        }
    }

    $displayFailure = "O Windows FPS Optimizer nao foi instalado.`n`nDetalhes: $failureMessage"
    if ($script:IsQuiet) {
        Write-Error -Message $displayFailure -ErrorAction Continue
    }
    else {
        Show-InstallerMessage `
            -Title 'Falha na instalacao' `
            -Kind Error `
            -Force `
            -Message $displayFailure
    }
    exit 1
}
