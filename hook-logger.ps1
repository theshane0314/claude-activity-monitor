$ErrorActionPreference = 'Stop'
trap { exit 0 }

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
try { $j = ConvertFrom-Json $raw } catch { exit 0 }

$dir = Join-Path $env:LOCALAPPDATA 'ClaudeActivityMonitor'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$log = Join-Path $dir 'activity.jsonl'

function Trunc($s, $n) {
    if ($null -eq $s) { return '' }
    $s = ([string]$s) -replace '\s+', ' '
    $s = $s.Trim()
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + '...' }
    return $s
}

$ev = [string]$j.hook_event_name
$tool = [string]$j.tool_name
$ti = $j.tool_input
$detail = ''

if ($ev -eq 'UserPromptSubmit') {
    $detail = Trunc $j.prompt 400
}
elseif ($ev -eq 'Notification') {
    $detail = Trunc $j.message 400
}
elseif ($ev -eq 'SessionStart') {
    $detail = Trunc $j.source 100
}
elseif ($ev -eq 'SessionEnd') {
    $detail = Trunc $j.reason 100
}
elseif ($ev -in @('PreCompact', 'PostCompact')) {
    $detail = Trunc $j.trigger 100
}
elseif ($null -ne $ti) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('description', 'command', 'file_path', 'notebook_path', 'pattern', 'query', 'url', 'skill', 'prompt', 'message', 'title', 'caption')) {
        $p = $ti.PSObject.Properties[$k]
        if ($p -and $p.Value) { $parts.Add((Trunc $p.Value 220)) }
    }
    if ($parts.Count -eq 0) {
        try { $parts.Add((Trunc (ConvertTo-Json $ti -Compress -Depth 3) 300)) } catch { }
    }
    $detail = Trunc ($parts -join ' | ') 400
}

if ($ev -eq 'PostToolUseFailure' -and $j.error) {
    $detail = Trunc ("$detail || ERR: $($j.error)") 400
}

if ($ev -eq 'PostToolUse' -and $null -ne $j.tool_response) {
    $tr = $j.tool_response
    $outTxt = ''
    foreach ($k in @('stdout', 'output', 'content', 'stderr', 'error', 'file_path', 'filePath')) {
        $p = $tr.PSObject.Properties[$k]
        if ($p -and $p.Value -is [string] -and $p.Value.Trim()) { $outTxt = $p.Value; break }
    }
    if ($outTxt) { $detail = Trunc ("$detail  =>  $outTxt") 400 }
}

$sid = [string]$j.session_id
if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }

$rec = [ordered]@{
    ts     = (Get-Date).ToString('o')
    ev     = $ev
    sid    = $sid
    tool   = $tool
    detail = $detail
    cwd    = [string]$j.cwd
}
$line = (ConvertTo-Json $rec -Compress -Depth 3) + "`n"

$mtx = New-Object System.Threading.Mutex($false, 'ClaudeActivityMonitorLog')
$got = $false
try {
    $got = $mtx.WaitOne(3000)
    $fi = Get-Item -LiteralPath $log -ErrorAction SilentlyContinue
    if ($fi -and $fi.Length -gt 10MB) {
        Move-Item -LiteralPath $log -Destination (Join-Path $dir 'activity.prev.jsonl') -Force
    }
    [System.IO.File]::AppendAllText($log, $line, (New-Object System.Text.UTF8Encoding($false)))
}
finally {
    if ($got) { $mtx.ReleaseMutex() }
    $mtx.Dispose()
}
exit 0
