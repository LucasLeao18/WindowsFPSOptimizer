<#
.SYNOPSIS
    Validates and builds the Windows FPS Optimizer release locally, with no CI.

.DESCRIPTION
    Runs formatting, lint and tests, builds standalone executables for
    Windows x64, x86 (32-bit) and ARM64 with the static C runtime, verifies
    that no Visual C++ runtime DLL is required, smoke-tests the graphical
    startup paths on the architectures this machine can run, and writes the
    executables plus SHA256SUMS.txt to rust\dist.

    Requirements: rustup (stable) and Visual Studio Build Tools with the
    "Desktop development with C++" workload, including the x86/x64 and ARM64
    MSVC tools and a Windows SDK.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if ((Test-Path $cargoBin) -and -not (($env:PATH -split ';') -contains $cargoBin)) {
    $env:PATH = "$cargoBin;$env:PATH"
}

function Invoke-Checked {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Falhou ($LASTEXITCODE): $File $($Arguments -join ' ')" }
}

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

$targets = [ordered]@{
    'x64'   = 'x86_64-pc-windows-msvc'
    'x86'   = 'i686-pc-windows-msvc'
    'arm64' = 'aarch64-pc-windows-msvc'
}
$version = ((Select-String -LiteralPath Cargo.toml -Pattern '^version\s*=\s*"([^"]+)"' |
    Select-Object -First 1).Matches[0].Groups[1].Value)
$hostArch = $env:PROCESSOR_ARCHITECTURE  # AMD64, x86 or ARM64

Step 'Preparando toolchain'
$targetArgs = @('target', 'add') + @($targets.Values)
Invoke-Checked rustup $targetArgs
Invoke-Checked rustup @('component', 'add', 'rustfmt', 'clippy')

Step 'Formatação e lint'
Invoke-Checked cargo @('fmt', '--all', '--', '--check')
Invoke-Checked cargo @('clippy', '--locked', '--all-targets', '--', '-D', 'warnings')

if (-not $SkipTests) {
    Step 'Testes'
    Invoke-Checked cargo @('test', '--locked')
    $fixture = Join-Path $PSScriptRoot 'target\idle_game.exe'
    Invoke-Checked rustc @('tests\fixtures\idle_game.rs', '-o', $fixture)
    $env:WFO_TEST_GAME = $fixture
    # Integration tests that only touch isolated test processes and read-only state.
    Invoke-Checked cargo @('test', '--locked', '--', '--ignored',
        'launches_fixture_and_restores_session', 'recovers_priority_from_a_reopened_journal',
        'changes_and_restores_own_process_priority', 'terminates_isolated_fixture_after_identity_checks',
        'temporary_sleep_guard_checks_identity_and_stops', 'reads_complete_pagefile_snapshot_without_changes',
        'reads_local_pagefile_management', 'reads_the_local_active_power_plan', 'user_temp_preview_is_read_only',
        'real_machine_preview_is_read_only')
}

Step 'Compilando executáveis'
foreach ($arch in $targets.Keys) {
    Invoke-Checked cargo @('build', '--release', '--locked', '--target', $targets[$arch])
}

Step 'Verificando dependências de runtime'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -property installationPath
$msvc = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$dumpbin = @('Hostx64\x64', 'Hostarm64\arm64', 'Hostx86\x86') |
    ForEach-Object { Join-Path $msvc.FullName "bin\$_\dumpbin.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin.exe não encontrado.' }
$expectedMachine = @{ 'x64' = 'x64'; 'x86' = 'x86'; 'arm64' = 'ARM64' }
foreach ($arch in $targets.Keys) {
    $exe = "target\$($targets[$arch])\release\windows-fps-optimizer.exe"
    $imports = (& $dumpbin /nologo /dependents $exe) -join "`n"
    if ($imports -match '(?i)\b(vcruntime|msvcp|concrt|ucrtbase|api-ms-win-crt)[a-z0-9_\-]*\.dll\b') {
        throw "$arch exige uma DLL de runtime separada:`n$imports"
    }
    $headers = (& $dumpbin /nologo /headers $exe) -join "`n"
    if ($headers -notmatch "machine \($($expectedMachine[$arch])\)") { throw "$arch tem arquitetura inesperada." }
    Write-Host "  $arch OK: sem DLLs de runtime do Visual C++"
}

Step 'Smoke test da interface'
$runnable = switch ($hostArch) {
    'AMD64' { @('x64', 'x86') }
    'ARM64' { @('arm64', 'x64', 'x86') }
    default { @('x86') }
}
foreach ($arch in $runnable) {
    $exe = (Resolve-Path "target\$($targets[$arch])\release\windows-fps-optimizer.exe").Path
    $env:WFO_SMOKE_LOG = Join-Path $env:TEMP "wfo-smoke-$arch.log"
    Remove-Item -LiteralPath $env:WFO_SMOKE_LOG -ErrorAction SilentlyContinue
    foreach ($arguments in @('--smoke-test', '--smoke-test --renderer-fallback', '--smoke-test --native-fallback')) {
        $process = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw "Smoke test expirou ($arch): $arguments" }
        if ($process.ExitCode -ne 0) {
            if (Test-Path $env:WFO_SMOKE_LOG) { Get-Content $env:WFO_SMOKE_LOG }
            throw "Smoke test falhou ($arch, código $($process.ExitCode)): $arguments"
        }
        Write-Host "  $arch OK: $arguments"
    }
    Remove-Item Env:WFO_SMOKE_LOG
}

Step 'Monitor de sessão independente'
$exe = (Resolve-Path "target\$($targets['x64'])\release\windows-fps-optimizer.exe").Path
if ($hostArch -eq 'x86') { $exe = (Resolve-Path "target\$($targets['x86'])\release\windows-fps-optimizer.exe").Path }
$previousLocal = $env:LOCALAPPDATA
$testLocal = Join-Path $env:TEMP ('wfo-monitor-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $testLocal 'WindowsFPSOptimizerRust\State'
New-Item -ItemType Directory -Path $state -Force | Out-Null
$fixtureProcess = $null; $monitor = $null
try {
    $fixturePath = Join-Path $PSScriptRoot 'target\idle_game.exe'
    if (-not (Test-Path $fixturePath)) { Invoke-Checked rustc @('tests\fixtures\idle_game.rs', '-o', $fixturePath) }
    $env:LOCALAPPDATA = $testLocal
    $fixtureProcess = Start-Process -FilePath $fixturePath -WindowStyle Hidden -PassThru
    $identity = @{ pid = $fixtureProcess.Id; created = $fixtureProcess.StartTime.ToFileTimeUtc() }
    $record = @{ schema = 1; process = $identity; original = 'Normal'; applied = 'AboveNormal'; phase = 'Applied' }
    $journal = Join-Path $state 'session.json'
    [IO.File]::WriteAllText($journal, ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    $monitor = Start-Process -FilePath $exe -ArgumentList '--session-monitor' -WindowStyle Hidden -PassThru
    if (-not $monitor.WaitForExit(30000)) { throw 'O monitor não terminou após o jogo de teste.' }
    if ($monitor.ExitCode -ne 0 -or (Test-Path -LiteralPath $journal)) { throw 'O monitor não finalizou o registro da sessão.' }
    Write-Host '  OK'
} finally {
    $env:LOCALAPPDATA = $previousLocal
    if ($monitor -and -not $monitor.HasExited) { $monitor.Kill() }
    if ($fixtureProcess -and -not $fixtureProcess.HasExited) { $fixtureProcess.Kill() }
    Remove-Item -LiteralPath $testLocal -Recurse -Force -ErrorAction SilentlyContinue
}

Step 'Montando dist'
$dist = Join-Path $PSScriptRoot 'dist'
if (Test-Path $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null
foreach ($arch in $targets.Keys) {
    $name = "WindowsFPSOptimizer-$version-$arch.exe"
    Copy-Item -LiteralPath "target\$($targets[$arch])\release\windows-fps-optimizer.exe" -Destination (Join-Path $dist $name)
}
$sums = Get-ChildItem -LiteralPath $dist -File | Sort-Object Name | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
}
# LF line endings so that sha256sum -c also works outside Windows.
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))
$sums | ForEach-Object { Write-Host "  $_" }
Write-Host "`nRelease $version pronta em $dist" -ForegroundColor Green
