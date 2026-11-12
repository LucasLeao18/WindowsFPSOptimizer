#requires -Version 5.1

Set-StrictMode -Version Latest

function Import-FrameTimeCapture {
    <# Le CSV do PresentMon com MsBetweenPresents (milissegundos).
       Nao inicia captura, instala drivers ou muda configuracoes do computador. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Nullable[int]]$ProcessId,
        [string]$SwapChainAddress = '',
        [ValidateRange(0, 1000000)][int]$WarmupFrames = 0
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -ne '.csv') { throw 'Selecione um arquivo CSV do PresentMon.' }
    if ($file.Length -gt 128MB) { throw 'O CSV excede o limite de 128 MB. Use uma captura menor.' }
    $frames = New-Object 'System.Collections.Generic.List[double]'
    $identities = @{}
    $rows = 0
    $selected = 0
    $zeroFrames = 0
    $application = ''
    $identity = ''
    $headers = @()
    $hasProcessFilter = $null -ne $ProcessId

    Import-Csv -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction Stop | ForEach-Object {
        $row = $_
        $rows++
        if ($rows -gt 2000000) { throw 'O CSV excede dois milhoes de linhas. Use uma captura menor.' }
        if ($rows -eq 1) {
            $headers = @($row.PSObject.Properties.Name)
            if ($headers -notcontains 'MsBetweenPresents') {
                throw 'Coluna MsBetweenPresents ausente. Exporte CSV do PresentMon com --v1_metrics; separador virgula e decimais com ponto.'
            }
            if ($hasProcessFilter -and $headers -notcontains 'ProcessID') { throw 'O CSV nao possui ProcessID para filtrar.' }
            if ($SwapChainAddress -and $headers -notcontains 'SwapChainAddress') { throw 'O CSV nao possui SwapChainAddress para filtrar.' }
        }
        if ($hasProcessFilter -and [string]$row.ProcessID -ne [string]$ProcessId) { return }
        if ($SwapChainAddress -and [string]$row.SwapChainAddress -ne $SwapChainAddress) { return }

        $parts = foreach ($column in @('Application', 'ProcessID', 'SwapChainAddress')) {
            if ($headers -contains $column) { [string]$row.$column } else { '(nao informado)' }
        }
        $identity = $parts -join '|'
        $identities[$identity] = $true
        if ($identities.Count -gt 1) {
            throw 'O CSV mistura aplicativos, processos ou swap chains. Capture apenas o jogo ou use -ProcessId e -SwapChainAddress ao importar pelo modulo.'
        }
        if ($headers -contains 'Application') { $application = [string]$row.Application }

        $value = [double]0
        $valid = [double]::TryParse([string]$row.MsBetweenPresents,
            [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)
        if (-not $valid -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 600000) {
            throw "MsBetweenPresents invalido na linha de dados $rows. Esperado numero finito de 0 a 600000 ms."
        }
        # PresentMon pode emitir zero quando ainda nao existe um quadro anterior.
        if ($value -eq 0) { $zeroFrames++; return }
        $selected++
        if ($selected -le $WarmupFrames) { return }
        $frames.Add($value)
    }
    if ($frames.Count -lt 2) { throw 'A captura precisa de pelo menos dois intervalos validos apos filtros e aquecimento.' }

    $sorted = $frames.ToArray()
    [Array]::Sort($sorted)
    $total = [double]0
    foreach ($frame in $sorted) { $total += $frame }
    $slowCount = [int][math]::Ceiling($sorted.Length * 0.01)
    $slowTotal = [double]0
    for ($index = $sorted.Length - $slowCount; $index -lt $sorted.Length; $index++) { $slowTotal += $sorted[$index] }
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if ($sorted.Length -lt 1000) { $warnings.Add('Menos de 1000 quadros: 1% low e percentis podem variar muito.') }
    if ($headers -notcontains 'ProcessID' -or $headers -notcontains 'SwapChainAddress') {
        $warnings.Add('CSV sem identidade completa: confirme que os intervalos pertencem a um unico processo e swap chain.')
    }
    return [pscustomobject]@{
        Path = $file.FullName; Application = $application; Identity = $identity
        Metric = 'MsBetweenPresents'; FrameCount = $sorted.Length
        DurationSeconds = $total / 1000; AverageFps = 1000.0 * $sorted.Length / $total
        OnePercentLowFps = 1000.0 * $slowCount / $slowTotal
        AverageFrameTimeMs = $total / $sorted.Length
        P95FrameTimeMs = $sorted[[int][math]::Ceiling($sorted.Length * 0.95) - 1]
        P99FrameTimeMs = $sorted[[int][math]::Ceiling($sorted.Length * 0.99) - 1]
        SlowestFrameTimeMs = $sorted[$sorted.Length - 1]
        ZeroIntervalsSkipped = $zeroFrames; WarmupFramesSkipped = $WarmupFrames
        Warnings = $warnings.ToArray()
        Method = 'FPS = 1000/media dos intervalos; 1% low = 1000/media dos ceil(N*0.01) intervalos mais lentos; percentis nearest-rank.'
    }
}

function Compare-FrameTimeCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    if ($Before.Metric -ne $After.Metric) { throw 'As capturas usam metricas diferentes.' }
    if ($Before.Application -and $After.Application -and $Before.Application -ne $After.Application) {
        throw 'As capturas pertencem a aplicativos diferentes. Compare o mesmo jogo.'
    }
    $definitions = @(
        @('FPS medio', 'AverageFps', 'FPS', $true),
        @('1% low', 'OnePercentLowFps', 'FPS', $true),
        @('Tempo medio', 'AverageFrameTimeMs', 'ms', $false),
        @('Tempo P95', 'P95FrameTimeMs', 'ms', $false),
        @('Tempo P99', 'P99FrameTimeMs', 'ms', $false),
        @('Pior quadro', 'SlowestFrameTimeMs', 'ms', $false)
    )
    $metrics = foreach ($definition in $definitions) {
        $property = [string]$definition[1]
        $old = [double]$Before.$property
        $new = [double]$After.$property
        if ($old -le 0 -or $new -le 0 -or [double]::IsInfinity($old) -or [double]::IsInfinity($new) -or
            [double]::IsNaN($old) -or [double]::IsNaN($new)) { throw 'Resumo de captura invalido.' }
        [pscustomobject]@{
            Name = $definition[0]; Before = $old; After = $new; Unit = $definition[2]
            ChangePercent = [math]::Round((($new / $old) - 1) * 100, 2)
            BetterWhen = if ($definition[3]) { 'Maior' } else { 'Menor' }
        }
    }
    $warnings = @($Before.Warnings) + @($After.Warnings)
    if ([math]::Abs($After.DurationSeconds / $Before.DurationSeconds - 1) -gt 0.1) {
        $warnings += 'Duracoes diferem mais de 10%; repita o mesmo percurso e tempo de captura.'
    }
    return [pscustomobject]@{
        Before = $Before; After = $After; Metrics = @($metrics)
        Warnings = @($warnings | Select-Object -Unique)
        Disclaimer = 'Intervalos de apresentacao nao medem latencia de entrada nem FPS exibido com geracao de quadros. Repita 3 a 5 capturas alternadas antes/depois, com o mesmo jogo, cena, resolucao, limite de FPS e temperatura. Uma comparacao isolada nao comprova ganho.'
    }
}

Export-ModuleMember -Function Import-FrameTimeCapture, Compare-FrameTimeCapture
