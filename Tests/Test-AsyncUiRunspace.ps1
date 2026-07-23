#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScriptPath = Join-Path $projectRoot 'WindowsFPSOptimizer.ps1'
$mainSource = Get-Content -LiteralPath $mainScriptPath -Raw -Encoding UTF8

if ($mainSource -match '\$output\[0\]\.BaseObject|\$_\.BaseObject') {
    throw 'A interface voltou a acessar BaseObject diretamente.'
}
if (
    $mainSource -notmatch '\$result\s*=\s*if\s*\(\$output\.Count\s*-eq\s*1\)\s*\{\s*\$output\[0\]\s*\}\s*else\s*\{\s*@\(\$output\)\s*\}'
) {
    throw 'A normalizacao segura da saida assincrona nao foi encontrada.'
}
if (
    $mainSource -notmatch '\$task\.ActionId\s*-eq\s*''Metrics''' -or
    $mainSource -notmatch 'MetricsRetryAfter' -or
    $mainSource -notmatch 'MetricsFailureCount' -or
    $mainSource -notmatch 'Set-MetricsRetryBackoff' -or
    $mainSource -notmatch 'Write-OptimizerLog'
) {
    throw 'A protecao contra repeticao silenciosa de erros esta incompleta.'
}
if ($mainSource -notmatch '\$retryStepsSeconds\s*=\s*@\(15,\s*30,\s*60,\s*120,\s*240,\s*300\)') {
    throw 'O backoff progressivo e limitado das metricas nao foi encontrado.'
}
if (
    $mainSource -notmatch '\$metricsTimer\.Add_Tick\(\{\s*try\s*\{' -or
    $mainSource -notmatch "Phase\s*'ScheduleOrBeginInvoke'"
) {
    throw 'Falhas sincronas ao iniciar as metricas podem escapar do temporizador.'
}
if (
    $mainSource -notmatch "Phase\s*'PollTimer'" -or
    $mainSource -notmatch "Phase\s*'PostOperationRefresh'" -or
    $mainSource -notmatch "Phase\s*'InitialRender'" -or
    $mainSource -notmatch '\[object\]::ReferenceEquals\(\$script:ActiveTask,\s*\$task\)' -or
    $mainSource -notmatch 'Write-UiBackgroundFailure'
) {
    throw 'Um callback automatico da interface ainda pode propagar sua propria falha.'
}

function Invoke-AsyncResultProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $powerShell = [PowerShell]::Create()
    try {
        [void]$powerShell.AddScript($ScriptBlock)
        $handle = $powerShell.BeginInvoke()
        $output = @($powerShell.EndInvoke($handle))
        if ($powerShell.Streams.Error.Count -gt 0) {
            throw $powerShell.Streams.Error[0].Exception
        }

        return $(if ($output.Count -eq 1) { $output[0] } else { @($output) })
    }
    finally {
        $powerShell.Dispose()
    }
}

$single = Invoke-AsyncResultProbe -ScriptBlock {
    [pscustomobject]@{
        ProcessCount = 42
        CpuPercent = 7
    }
}
if ($single.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
    throw "Tipo unico inesperado: $($single.GetType().FullName)."
}
if ([int]$single.ProcessCount -ne 42 -or [int]$single.CpuPercent -ne 7) {
    throw 'O resultado unico perdeu propriedades.'
}

$multiple = @(
    Invoke-AsyncResultProbe -ScriptBlock {
        [pscustomobject]@{ Id = 1 }
        [pscustomobject]@{ Id = 2 }
    }
)
if ($multiple.Count -ne 2 -or [int]$multiple[0].Id -ne 1 -or [int]$multiple[1].Id -ne 2) {
    throw 'A colecao assincrona nao foi preservada.'
}

$empty = @(Invoke-AsyncResultProbe -ScriptBlock { return })
if ($empty.Count -ne 0) {
    throw 'Uma operacao sem saida deveria retornar uma colecao vazia.'
}

Write-Host 'TESTE DE RUNSPACE DA UI APROVADO: saidas 0/1/N sem acesso direto a BaseObject.'
