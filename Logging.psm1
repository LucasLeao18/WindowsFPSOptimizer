#requires -Version 5.1

Set-StrictMode -Version Latest

$script:LogRoot = $null
$script:SessionId = [guid]::NewGuid().ToString('N')
$script:LogCallback = $null

function Invoke-WithLogMutex {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
    $mutex = New-Object Threading.Mutex($false, 'Local\WindowsFPSOptimizer.Logging')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Tempo limite ao aguardar o arquivo de log.' }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Initialize-OptimizerLogging {
    <#
        Inicializa um arquivo JSON Lines para dados estruturados e um TXT legivel.
        JSON Lines evita reescrever todo o historico a cada evento e tolera melhor
        uma interrupcao inesperada do aplicativo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,

        [string]$SessionId = ([guid]::NewGuid().ToString('N'))
    )

    $script:LogRoot = $RootPath
    $script:SessionId = $SessionId
    if (-not (Test-Path -LiteralPath $script:LogRoot)) {
        New-Item -ItemType Directory -Path $script:LogRoot -Force -ErrorAction Stop | Out-Null
    }

    return [pscustomobject]@{
        RootPath  = $script:LogRoot
        SessionId = $script:SessionId
        JsonlPath = (Join-Path $script:LogRoot 'optimizer.jsonl')
        TextPath  = (Join-Path $script:LogRoot 'optimizer.log')
    }
}

function Set-OptimizerLogCallback {
    <# Permite que a interface receba eventos sem acoplar o modulo a WPF. #>
    [CmdletBinding()]
    param([AllowNull()][scriptblock]$Callback)

    $script:LogCallback = $Callback
}

function ConvertTo-LogText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    try {
        return ($Value | ConvertTo-Json -Depth 12 -Compress)
    }
    catch {
        return [string]$Value
    }
}

function Write-OptimizerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Name,
        [string]$Category = 'Geral',
        [AllowNull()]$OldValue,
        [AllowNull()]$NewValue,
        [ValidateSet('Success', 'Skipped', 'Simulated', 'Warning', 'Error', 'Info', 'Restored')]
        [string]$Result = 'Info',
        [AllowEmptyString()][string]$ErrorMessage = '',
        [bool]$RequiresRestart = $false,
        [string]$Profile = '',
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information',
        [hashtable]$Details
    )

    if ([string]::IsNullOrWhiteSpace($script:LogRoot)) {
        $fallback = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WindowsFPSOptimizer\Logs'
        Initialize-OptimizerLogging -RootPath $fallback -SessionId $script:SessionId | Out-Null
    }

    $entry = [ordered]@{
        Timestamp       = (Get-Date).ToString('o')
        SessionId       = $script:SessionId
        Name            = $Name
        Category        = $Category
        PreviousValue   = (ConvertTo-LogText -Value $OldValue)
        NewValue        = (ConvertTo-LogText -Value $NewValue)
        Result          = $Result
        Error           = $ErrorMessage
        RequiresRestart = $RequiresRestart
        Profile         = $Profile
        Level           = $Level
        Details         = if ($Details) { $Details } else { @{} }
    }

    $jsonPath = Join-Path $script:LogRoot 'optimizer.jsonl'
    $textPath = Join-Path $script:LogRoot 'optimizer.log'
    $jsonLine = ([pscustomobject]$entry | ConvertTo-Json -Depth 12 -Compress)
    $textLine = '{0} [{1}] [{2}] {3} | resultado={4} | anterior={5} | novo={6}{7}' -f `
        $entry.Timestamp, $entry.Level, $entry.Category, $entry.Name, $entry.Result,
        $entry.PreviousValue, $entry.NewValue,
        $(if ($entry.Error) { ' | erro=' + $entry.Error } else { '' })

    Invoke-WithLogMutex -ScriptBlock {
        Add-Content -LiteralPath $jsonPath -Value $jsonLine -Encoding UTF8 -ErrorAction Stop
        Add-Content -LiteralPath $textPath -Value $textLine -Encoding UTF8 -ErrorAction Stop
    } | Out-Null

    $objectEntry = [pscustomobject]$entry
    if ($script:LogCallback) {
        try { & $script:LogCallback $objectEntry } catch { }
    }
    return $objectEntry
}

function Get-OptimizerLogEntries {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 100000)][int]$Last = 500,
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($script:LogRoot)) { return @() }
    $path = Join-Path $script:LogRoot 'optimizer.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $items = New-Object System.Collections.Generic.List[object]
    Get-Content -LiteralPath $path -Tail $Last -ErrorAction SilentlyContinue | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        try {
            $item = $_ | ConvertFrom-Json -ErrorAction Stop
            if (-not $SessionId -or $item.SessionId -eq $SessionId) { $items.Add($item) }
        }
        catch { }
    }
    return $items.ToArray()
}

function Export-OptimizerLogReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [ValidateSet('TXT', 'CSV', 'JSON', 'HTML')][string]$Format,
        [ValidateRange(1, 1000000)][int]$Last = 100000
    )

    $entries = @(Get-OptimizerLogEntries -Last $Last)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }

    switch ($Format) {
        'TXT' {
            $lines = $entries | ForEach-Object {
                '{0} [{1}] {2}/{3}: {4} (anterior: {5}; novo: {6}; erro: {7})' -f `
                    $_.Timestamp, $_.Result, $_.Category, $_.Name, $_.Level,
                    $_.PreviousValue, $_.NewValue, $_.Error
            }
            Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -ErrorAction Stop
        }
        'CSV' {
            $entries | Select-Object Timestamp, SessionId, Category, Name, PreviousValue,
                NewValue, Result, Error, RequiresRestart, Profile, Level |
                Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        }
        'JSON' {
            $entries | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        }
        'HTML' {
            $style = @'
<style>
body{font-family:"Segoe UI",sans-serif;background:#0b1220;color:#e5e7eb;margin:24px}
h1{font-size:24px}table{border-collapse:collapse;width:100%;font-size:13px}
th,td{border:1px solid #334155;padding:8px;text-align:left;vertical-align:top}
th{background:#172033;color:#fff}tr:nth-child(even){background:#111a2a}
.meta{color:#a7b0bf;margin-bottom:16px}
</style>
'@
            $pre = '<h1>Relatorio - Windows FPS Optimizer</h1><p class="meta">Gerado em {0}; {1} eventos.</p>' -f `
                (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $entries.Count
            $entries | Select-Object Timestamp, Category, Name, PreviousValue, NewValue,
                Result, Error, RequiresRestart, Profile |
                ConvertTo-Html -Head $style -PreContent $pre |
                Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        }
    }

    return Get-Item -LiteralPath $Path -ErrorAction Stop
}

Export-ModuleMember -Function Initialize-OptimizerLogging, Set-OptimizerLogCallback,
    Write-OptimizerLog, Get-OptimizerLogEntries, Export-OptimizerLogReport
