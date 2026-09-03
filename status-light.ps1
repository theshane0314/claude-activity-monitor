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
# Usage: status-light.ps1 <red|yellow|green|off>
#
# Run from a hook, the event JSON arrives on stdin and the colour is recorded
# against that session's id. Run by hand with no stdin, the colour is forced
# onto the bulb directly, ignoring what the sessions want.

param(
    [Parameter(Mandatory)]
    [ValidateSet('red', 'yellow', 'green', 'off')]
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
# --------------------------------------------------------------------------

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

function Get-HookEvent {
    # Hooks deliver their event JSON on stdin. A manual run has no stdin at all,
    # and reading it would block on the console, so check before reading.
    if (-not [Console]::IsInputRedirected) { return $null }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return (ConvertFrom-Json $raw) } catch { return $null }
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

try {
    $hookEvent = Get-HookEvent
    $key = Get-SessionKey -Event $hookEvent
    $hookName = ''
    if ($null -ne $hookEvent) { $hookName = [string]$hookEvent.hook_event_name }

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
            Set-Light -Want (Get-AggregateState)
        }
    }
    finally {
        if ($held) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
}
catch {
    # A status light must never break a hook.
}

exit 0
