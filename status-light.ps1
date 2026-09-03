# status-light.ps1 - drive a physical status light from Claude Code hooks.
#
#   red    = waiting for confirmation
#   yellow = running
#   green  = finished, ready for a new task
#
# The colour is the WORST state across every live session, not the state of
# whichever hook fired last: red beats yellow beats green. One session finishing
# while another is mid-tool leaves the light yellow, which is the whole point.
# Green has to mean "nothing is running anywhere".
#
# "Working" includes backgrounded commands. A session that launches a test suite
# with run_in_background and then ends its turn fires Stop, but the suite is
# still running and the light must stay yellow until it finishes. See
# Get-RunningTasks for how that is detected.
#
# On a state CHANGE the bulb flashes the new colour a few times, so the change
# is noticeable when other lights are on. A repeat of the current state does
# nothing at all (see the cache note below).
#
# Backend: TP-Link Kasa KL125 ("office 1") over the legacy autokey-XOR
# protocol on TCP 9999. No dependencies, no cloud, no credentials.
#
# Note this is the LEGACY protocol. Newer Kasa/Tapo devices speak KLAP over
# port 80 and require TP-Link cloud credentials; they will not work here.
#
# To swap hardware, replace Send-Kasa and the two payload builders.
#
# Usage: status-light.ps1 <red|yellow|green|off|status>
#
# Run from a hook, the event JSON arrives on stdin and the colour is recorded
# against that session's id. Run by hand with no stdin, the colour is forced
# onto the bulb directly, ignoring what the sessions want.
#
# `status` explains the current colour: every session and what it last asked
# for, every running background task, the combined answer, and what the bulb
# itself reports it is showing.

param(
    [Parameter(Mandatory)]
    [ValidateSet('red', 'yellow', 'green', 'off', 'status')]
    [string]$State
)

# ---- configuration -------------------------------------------------------
$BulbIp     = '192.168.0.103'
$BulbPort   = 9999
$Brightness = 100         # 1-100. Lower this if the room feels flooded.
$ConnectMs  = 1000        # give up quietly if the bulb is slow or offline

$FlashCount = 0           # pulses on a state change. 0 disables flashing.
$FlashMs    = 130         # on/off duration per phase, milliseconds

# A session that dies without firing SessionEnd (window closed, crash, reboot)
# would otherwise pin the light yellow forever. Anything not heard from in this
# long is treated as gone. Keep it comfortably above the longest gap between two
# hook events in a working session: a foreground Bash call can hold for ten
# minutes, with model thinking either side of it.
$StaleMinutes = 30

# Hue/saturation per state. Set green to @{ hue = 0; sat = 0 } for warm white
# if you would rather the light stay usable as a room light when idle.
$Colors = @{
    red    = @{ hue = 0;   sat = 100 }
    yellow = @{ hue = 60;  sat = 100 }
    green  = @{ hue = 120; sat = 100 }
}

# Worst-wins ordering used to combine the live sessions.
$Priority = @{ green = 1; yellow = 2; red = 3 }

$CacheFile = Join-Path $env:TEMP 'claude-status-light.state'   # colour on the bulb
$StateDir  = Join-Path $env:TEMP 'claude-status-light'         # one file per session

# Every decision this script makes, appended per invocation. Worth its keep:
# the light showing the wrong colour is otherwise unfalsifiable after the fact,
# since nothing else records what the sessions looked like at the time. Set to
# '' to disable. Do NOT move it under %LOCALAPPDATA% -- hook processes cannot
# write there (see the note in the README).
$TraceFile = Join-Path $env:TEMP 'claude-status-light-trace.log'
$TraceMaxKB = 1024
# --------------------------------------------------------------------------

function Write-Trace {
    param([string]$Msg)
    if ([string]::IsNullOrEmpty($TraceFile)) { return }
    try {
        $fi = Get-Item -LiteralPath $TraceFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt ($TraceMaxKB * 1KB)) { Remove-Item -LiteralPath $TraceFile -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::AppendAllText($TraceFile, ((Get-Date).ToString('HH:mm:ss.fff') + "  pid=$PID  " + $Msg + "`n"))
    }
    catch { }
}

function ConvertTo-KasaFrame {
    param([string]$Payload)
    # TP-Link autokey XOR cipher, initial key 171, 4-byte big-endian length prefix
    $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
    $frame = New-Object byte[] ($bytes.Length + 4)
    $len = [BitConverter]::GetBytes([int]$bytes.Length)
    [Array]::Reverse($len)
    [Array]::Copy($len, 0, $frame, 0, 4)
    $key = 171
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $key = $key -bxor $bytes[$i]
        $frame[$i + 4] = $key
    }
    return $frame
}

function Invoke-KasaSequence {
    # Sends every payload over ONE connection, reading each reply before moving
    # on. Reading matters: closing the socket straight after a write races the
    # device and the last command gets dropped.
    param([string[]]$Payloads, [int[]]$DelaysMs)

    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($BulbIp, $BulbPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { return $false }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000

        for ($p = 0; $p -lt $Payloads.Count; $p++) {
            $frame = ConvertTo-KasaFrame -Payload $Payloads[$p]
            $stream.Write($frame, 0, $frame.Length)
            $stream.Flush()

            # drain the reply so the command is known to have landed
            $hdr = New-Object byte[] 4
            $got = 0
            while ($got -lt 4) {
                $n = $stream.Read($hdr, $got, 4 - $got)
                if ($n -le 0) { return $false }
                $got += $n
            }
            [Array]::Reverse($hdr)
            $rlen = [BitConverter]::ToInt32($hdr, 0)
            if ($rlen -gt 0 -and $rlen -lt 65536) {
                $rbuf = New-Object byte[] $rlen
                $got = 0
                while ($got -lt $rlen) {
                    $n = $stream.Read($rbuf, $got, $rlen - $got)
                    if ($n -le 0) { break }
                    $got += $n
                }
            }

            if ($null -ne $DelaysMs -and $p -lt $DelaysMs.Count -and $DelaysMs[$p] -gt 0) {
                Start-Sleep -Milliseconds $DelaysMs[$p]
            }
        }
        return $true
    }
    finally {
        $client.Close()
    }
}

function Get-ColorPayload {
    param([string]$State)
    $c = $Colors[$State]
    '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{' +
    '"ignore_default":1,"on_off":1,"mode":"normal",' +
    '"hue":' + $c.hue + ',"saturation":' + $c.sat + ',' +
    '"brightness":' + $Brightness + ',"color_temp":0,"transition_period":0}}}'
}

function Get-OffPayload {
    '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"on_off":0,"transition_period":0}}}'
}

function ConvertFrom-KasaFrame {
    param([byte[]]$Buf)
    $key = 171
    $out = New-Object byte[] $Buf.Length
    for ($i = 0; $i -lt $Buf.Length; $i++) { $out[$i] = $Buf[$i] -bxor $key; $key = $Buf[$i] }
    return [Text.Encoding]::UTF8.GetString($out)
}

function Show-Status {
    # Answers "why is the light that colour" without needing a debugging session.
    "sessions:"
    $any = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue)) {
        $any = $true
        $age = ((Get-Date) - $f.LastWriteTime).TotalMinutes
        $stale = if ($age -gt $StaleMinutes) { '  STALE, ignored' } else { '' }
        "  {0}  {1,-7}  last hook {2:n1} min ago{3}" -f $f.BaseName.Substring(0, [Math]::Min(8, $f.BaseName.Length)), (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue), $age, $stale
    }
    if (-not $any) { "  (none)" }

    "running tasks:"
    $tasks = @(Get-RunningTasks)
    if ($tasks.Count -eq 0) { "  (none)" } else { $tasks | ForEach-Object { "  $_" } }

    "aggregate : " + (Get-AggregateState)
    "cache     : " + $(if (Test-Path $CacheFile) { (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '(none)' })

    # Ask the bulb what it is actually showing. The cache is only a belief, and
    # a silent failure (bulb offline, address reused by another device) shows up
    # here as the two disagreeing.
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($BulbIp, $BulbPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { "bulb      : UNREACHABLE at $BulbIp`:$BulbPort"; return }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $frame = ConvertTo-KasaFrame -Payload '{"system":{"get_sysinfo":{}}}'
        $stream.Write($frame, 0, $frame.Length)
        $stream.Flush()

        $hdr = New-Object byte[] 4; $got = 0
        while ($got -lt 4) { $n = $stream.Read($hdr, $got, 4 - $got); if ($n -le 0) { break }; $got += $n }
        [Array]::Reverse($hdr)
        $rlen = [BitConverter]::ToInt32($hdr, 0)
        $rbuf = New-Object byte[] $rlen; $got = 0
        while ($got -lt $rlen) { $n = $stream.Read($rbuf, $got, $rlen - $got); if ($n -le 0) { break }; $got += $n }
        $info = (ConvertFrom-Json (ConvertFrom-KasaFrame -Buf $rbuf)).system.get_sysinfo
        $ls = $info.light_state
        if ($ls.on_off -eq 0) { "bulb      : {0} is OFF" -f $info.alias }
        else {
            $name = 'hue ' + $ls.hue
            foreach ($k in $Colors.Keys) { if ($Colors[$k].hue -eq $ls.hue -and $Colors[$k].sat -eq $ls.saturation) { $name = $k } }
            if ($ls.saturation -eq 0) { $name = 'white' }
            "bulb      : {0} is showing {1}" -f $info.alias, $name
        }
    }
    catch { "bulb      : error talking to $BulbIp - $($_.Exception.Message)" }
    finally { $client.Close() }
}

function Get-HookEvent {
    # Hooks deliver their event JSON on stdin. A manual run has no stdin at all,
    # and reading it would block on the console, so check before reading.
    if (-not [Console]::IsInputRedirected) { Write-Trace 'stdin NOT redirected'; return $null }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Trace 'stdin empty'; return $null }
    Write-Trace ('stdin len=' + $raw.Length)
    try { return (ConvertFrom-Json $raw) } catch { Write-Trace 'json parse FAILED'; return $null }
}

function Get-SessionKey {
    param($Event)
    if ($null -eq $Event) { return $null }
    $sid = [string]$Event.session_id
    # Every session shares one slot when the id is missing, which is exactly the
    # old last-writer-wins behaviour. Degraded, but never wrong for one session.
    if ([string]::IsNullOrWhiteSpace($sid)) { return 'unknown' }
    $sid = $sid -replace '[^0-9A-Za-z_-]', ''
    if ($sid.Length -eq 0) { return 'unknown' }
    if ($sid.Length -gt 64) { $sid = $sid.Substring(0, 64) }
    return $sid
}

function Set-SessionState {
    # SessionEnd retires the slot outright: an ended session must not hold the
    # light at anything, not even green.
    param([string]$Key, [string]$Want, [bool]$Ended)
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $f = Join-Path $StateDir ($Key + '.state')
    if ($Ended) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        return
    }
    Set-Content -LiteralPath $f -Value $Want -NoNewline
}

function Get-RunningTasks {
    # Claude Code gives every backgrounded command a task id and streams its
    # output to %TEMP%\claude\<project>\<session>\tasks\<id>.output, holding that
    # file open for as long as the command runs. So a task output file that is
    # still locked for writing IS a running task.
    #
    # This is the only reliable signal available. The process table cannot answer
    # it: a backgrounded command is orphaned the moment its launching shell
    # exits, so its parent chain no longer reaches the session, and telling real
    # work apart from the idle session shell, the MCP servers and the hook
    # processes would need a name-and-age guess that goes stale the first time
    # any of them changes.
    #
    # Every session is scanned, not just the ones with a slot, because a task
    # outlives the turn that started it and can outlive the slot's staleness
    # sweep. Roughly 200 ms over a few hundred files, and only ever paid on the
    # transition to green.
    param([switch]$StopAtFirst)

    $found = New-Object System.Collections.Generic.List[string]
    $root = Join-Path $env:TEMP 'claude'
    if (-not (Test-Path -LiteralPath $root)) { return $found }

    foreach ($proj in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($sess in @(Get-ChildItem -LiteralPath $proj.FullName -Directory -ErrorAction SilentlyContinue)) {
            $tasks = Join-Path $sess.FullName 'tasks'
            if (-not (Test-Path -LiteralPath $tasks)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $tasks -Filter '*.output' -File -ErrorAction SilentlyContinue)) {
                $locked = $false
                try {
                    $fs = [System.IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'None')
                    $fs.Close()
                }
                # A file that vanished or cannot be reached is not a running task.
                # Only a sharing violation means someone else still holds it.
                catch [System.IO.FileNotFoundException] { }
                catch [System.IO.DirectoryNotFoundException] { }
                catch [System.UnauthorizedAccessException] { }
                catch [System.IO.IOException] { $locked = $true }
                catch { }

                if ($locked) {
                    $found.Add(($sess.Name.Substring(0, [Math]::Min(8, $sess.Name.Length))) + '/' + $f.BaseName)
                    if ($StopAtFirst) { return $found }
                }
            }
        }
    }
    return $found
}

function Get-AggregateState {
    # Worst state across every session still checking in. No sessions at all
    # means nothing is running, which is green.
    $best = 'green'
    $cut = (Get-Date).AddMinutes(-$StaleMinutes)
    $files = @(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        if ($f.LastWriteTime -lt $cut) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $s = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $s) { continue }
        $s = $s.Trim()
        if (-not $Priority.ContainsKey($s)) { continue }
        if ($Priority[$s] -gt $Priority[$best]) { $best = $s }
    }

    # Every agent is idle, but a backgrounded command it launched may still be
    # running. Only worth asking here, on the way to green.
    if ($best -eq 'green' -and @(Get-RunningTasks -StopAtFirst).Count -gt 0) { $best = 'yellow' }

    return $best
}

function Set-Light {
    param([string]$Want)

    # Skip everything when the light already shows this state. PreToolUse and
    # PostToolUse fire constantly, so without this the bulb would take a TCP
    # connection per tool call -- and would flash on every one of them.
    if (Test-Path $CacheFile) {
        $last = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $last -and $last.Trim() -eq $Want) { return }
    }

    # Build the whole sequence up front: settle on the new colour, then pulse it.
    $payloads = New-Object System.Collections.Generic.List[string]
    $delays = New-Object System.Collections.Generic.List[int]

    if ($Want -eq 'off') {
        $payloads.Add((Get-OffPayload)); $delays.Add(0)
    }
    else {
        $color = Get-ColorPayload -State $Want
        $off = Get-OffPayload
        $payloads.Add($color); $delays.Add($(if ($FlashCount -gt 0) { $FlashMs } else { 0 }))
        for ($i = 0; $i -lt $FlashCount; $i++) {
            $payloads.Add($off);   $delays.Add($FlashMs)
            $payloads.Add($color); $delays.Add($(if ($i -lt ($FlashCount - 1)) { $FlashMs } else { 0 }))
        }
    }

    # Claim the state BEFORE the ~1s flash. PreToolUse and PostToolUse both ask
    # for yellow milliseconds apart; without this the second call would still
    # see a stale cache and flash on top of the first.
    $prev = $null
    if (Test-Path $CacheFile) {
        $prev = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
    }
    Set-Content -Path $CacheFile -Value $Want -NoNewline

    if (-not (Invoke-KasaSequence -Payloads $payloads.ToArray() -DelaysMs $delays.ToArray())) {
        # Bulb unreachable: undo the claim so the next hook retries rather than
        # believing the light is already showing this state.
        if ($null -ne $prev) { Set-Content -Path $CacheFile -Value $prev.Trim() -NoNewline }
        elseif (Test-Path $CacheFile) { Remove-Item $CacheFile -Force -ErrorAction SilentlyContinue }
    }
}

if ($State -eq 'status') { Show-Status; exit 0 }

try {
    Write-Trace ("ENTER state=$State temp=$env:TEMP")
    $hookEvent = Get-HookEvent
    $key = Get-SessionKey -Event $hookEvent
    $hookName = ''
    if ($null -ne $hookEvent) { $hookName = [string]$hookEvent.hook_event_name }
    Write-Trace ("key=$key hook=$hookName")

    # Recording, combining and pushing has to be one critical section. Sessions
    # fire hooks concurrently, and two interleaved runs can otherwise push their
    # colours out of order and leave the bulb showing the loser.
    $mtx = New-Object System.Threading.Mutex($false, 'ClaudeStatusLight')
    $held = $false
    try {
        try { $held = $mtx.WaitOne(3000) } catch { $held = $false }

        if ($null -eq $key) {
            # Manual run: no session asked for this, so do as told.
            Set-Light -Want $State
        }
        elseif ($State -eq 'off') {
            # An explicit blackout. Forget every session so the next hook event
            # rebuilds the picture from scratch.
            Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue
            Set-Light -Want 'off'
        }
        else {
            Set-SessionState -Key $key -Want $State -Ended ($hookName -eq 'SessionEnd')
            $agg = Get-AggregateState
            Write-Trace ("slots=[" + (($(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -EA SilentlyContinue) | ForEach-Object { $_.BaseName.Substring(0, [Math]::Min(8, $_.BaseName.Length)) + '=' + (Get-Content $_.FullName -Raw -EA SilentlyContinue) }) -join ' ') + "] agg=$agg")
            Set-Light -Want $agg
        }
    }
    finally {
        if ($held) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
}
catch {
    # A status light must never break a hook. But a swallowed error leaves the
    # bulb on the wrong colour with nothing to show for it, so it gets recorded
    # before it is dropped.
    Write-Trace ('EXCEPTION line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.Exception.Message)
}

exit 0
