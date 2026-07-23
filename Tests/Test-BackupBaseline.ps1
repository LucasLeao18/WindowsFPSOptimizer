#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'BackupManager.psm1') -Force -DisableNameChecking
$context = Initialize-OptimizerContext -AppRoot $projectRoot -ConfigPath (Join-Path $projectRoot 'Config.json')
Initialize-OptimizerLogging -RootPath $context.LogRoot -SessionId $context.SessionId | Out-Null

function Remove-LocalBaselineFixture {
    param([string]$Folder, [string]$TransactionId)
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return }
    $resolvedFolder = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath([string]$context.BackupRoot).TrimEnd('\')
    $insideRoot = $resolvedFolder.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    $expectedName = $TransactionId -and [IO.Path]::GetFileName($resolvedFolder) -like "*$TransactionId*"
    if (-not $insideRoot -or -not $expectedName) { throw 'A limpeza da fixture recusou um caminho inesperado.' }
    Remove-Item -LiteralPath $resolvedFolder -Recurse -Force -ErrorAction Stop
}

function Remove-ListedLocalBaselineFixtures {
    foreach ($item in @(Get-OptimizerBackups -IncludeInvalid | Where-Object {
        [string]$_.Name -eq 'Teste local de baseline' -and [string]$_.Profile -eq 'Teste'
    })) {
        if ([string]::IsNullOrWhiteSpace([string]$item.ManifestPath)) { continue }
        Remove-LocalBaselineFixture -Folder (Split-Path -Parent ([string]$item.ManifestPath)) `
            -TransactionId ([string]$item.TransactionId)
    }
}

$preexisting = Get-CurrentOptimizerBackup
if ($preexisting) {
    if ([string]$preexisting.Name -ne 'Teste local de baseline') { throw 'Existe uma transacao real ativa; o teste nao tocara nela.' }
    $preexistingId = [string]$preexisting.TransactionId
    $preexistingFolder = Split-Path -Parent ([string]$preexisting.ManifestPath)
    Complete-OptimizerBackup -Status Failed -ErrorMessage 'Limpeza de fixture interrompida' | Out-Null
    Remove-LocalBaselineFixture -Folder $preexistingFolder -TransactionId $preexistingId
}
Remove-ListedLocalBaselineFixtures
$transactionId = ''
$folder = ''
try {
    $started = Start-OptimizerBackup -Name 'Teste local de baseline' -Profile 'Teste'
    $transactionId = [string]$started.TransactionId
    $folder = Split-Path -Parent ([string]$started.ManifestPath)
    $baseline = Set-OptimizerBackupBaseline -Snapshot ([ordered]@{
        Fixture = 'LocalOnly'; Values = @([pscustomobject]@{ Name = 'Example'; Original = 1 })
    }) -Description 'Fixture local sem alteracao do Windows'
    if (-not [bool]$baseline.Captured) { throw 'O baseline nao foi capturado.' }
    $completed = Complete-OptimizerBackup -Status Completed
    $listed = @(Get-OptimizerBackups -IncludeInvalid | Where-Object TransactionId -eq $transactionId)
    if ($listed.Count -ne 1 -or -not [bool]$listed[0].IsValid -or -not [bool]$listed[0].HasBaseline) {
        throw 'O pacote com baseline nao foi listado como valido.'
    }
    if ([int]$listed[0].EntryCount -ne 0) { throw 'A fixture de baseline criou uma entrada de tweak inexistente.' }
    if (@(Get-OptimizerBackupEntries -ManifestPath ([string]$completed.ManifestPath)).Count -ne 0) {
        throw 'O baseline de auditoria apareceu como entrada restauravel.'
    }
    $staging = Join-Path $context.DataRoot ('BaselineImportFixture-' + [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $folder -Destination $staging -Recurse -Force -ErrorAction Stop
        [IO.File]::AppendAllText((Join-Path $staging 'baseline.json'), "`n ")
        $tamperRejected = $false
        try { Import-OptimizerBackup -Path $staging | Out-Null }
        catch { $tamperRejected = $_.Exception.Message -match '(?i)(baseline|hash|tamanho)' }
        if (-not $tamperRejected) { throw 'A importacao aceitou um baseline adulterado.' }
    }
    finally {
        if (Test-Path -LiteralPath $staging -PathType Container) {
            $resolvedStaging = [IO.Path]::GetFullPath($staging).TrimEnd('\')
            $resolvedData = [IO.Path]::GetFullPath([string]$context.DataRoot).TrimEnd('\')
            if (-not $resolvedStaging.StartsWith($resolvedData + '\', [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($resolvedStaging) -notlike 'BaselineImportFixture-*') {
                throw 'A limpeza da copia adulterada recusou um caminho inesperado.'
            }
            Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction Stop
        }
    }
    Write-Host 'TESTE DE BASELINE APROVADO: somente arquivos locais, sem tweak do Windows.' -ForegroundColor Green
}
finally {
    $active = Get-CurrentOptimizerBackup
    if ($active -and [string]$active.Name -eq 'Teste local de baseline') {
        if (-not $transactionId) { $transactionId = [string]$active.TransactionId }
        if (-not $folder) { $folder = Split-Path -Parent ([string]$active.ManifestPath) }
        try { Complete-OptimizerBackup -Status Failed -ErrorMessage 'Limpeza da fixture de teste' | Out-Null } catch { }
    }
    Remove-LocalBaselineFixture -Folder $folder -TransactionId $transactionId
    Remove-ListedLocalBaselineFixtures
}
