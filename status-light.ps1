# status-light.ps1 - drive a physical status light from Claude Code hooks.
#
#   red    = waiting for confirmation
#   yellow = running
#   green  = finished, ready for a new task
#
# EVERY LIVE SESSION GETS ITS OWN BLOCK OF THE PANEL, side by side, with one
# dark column between neighbours so the blocks are countable at a glance. The
# cube is a 20x5 matrix, so one session fills all 20 columns, two take 10 and 9
# either side of a gap, three take 6/6/6, and so on. Everything is visible at
# once; nothing has to be waited for.
#
# The separators are dropped only when they no longer fit, since a gap costs a
# column: past 10 sessions the blocks go shoulder to shoulder, and past 20 they
# are allocated per pixel (down a column, then right) so all 100 LEDs can carry
# 100 sessions at once.
#
# An aggregate is still computed (worst state wins: red beats yellow beats
# green). It is what the kasa backend shows, since a single-colour bulb cannot
# do better, and what the cube shows when there is one session or none. Green
# has to mean "nothing is running anywhere".
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
# Backend: set $Backend in the configuration block below.
#
#   'cube' (default) - Yeelight Cube Smart Lamp Lite "ClydeCube" at
#     192.168.0.228, Yeelight LAN Control on TCP 55443. A 20x5 RGB matrix,
#     driven per pixel, one block per session.
#
#     The matrix methods are UNDOCUMENTED and absent from the SSDP 'support:'
#     header, which is empty on this device. Do not conclude from that header
#     that they are unavailable. The sequence is: activate_fx_mode
#     {"mode":"direct"}, then update_leds with a base64 RGB frame, BOTH ON THE
#     SAME CONNECTION -- arming on one connection and pushing on another is
#     rejected with "illegal request". update_leds never replies, so only the
#     arming step can be checked. A pushed frame persists after the connection
#     closes, which is why short-lived hook processes can drive it with no
#     daemon holding a socket open.
#
#     Geometry, established by photographing calibration frames: 20 wide, 5
#     tall, row 0 at the top, pixel index running RIGHT TO LEFT along each row,
#     and NOT serpentine (every row starts at the same edge). That is
#         index = row * 20 + (19 - x)
#     with x measured from the left. Verified against a rendered 6/7/7 column
#     split, which appeared left to right in the expected order.
#
#     Its firmware (model CubeLite, fw 1.0.0) is WRITE-ONLY. get_prop never
#     answers, and the SSDP reply is a hardcoded stub that does not change when
#     the light does, so it cannot be trusted as state. That means `status`
#     cannot ask this light what it is showing the way it can the Kasa bulb; it
#     reports the cache and says so. Do not "fix" this by reading SSDP.
#
#   'kasa' - TP-Link Kasa KL125 ("office 1") over the legacy autokey-XOR
#     protocol on TCP 9999. No dependencies, no cloud, no credentials. Shows the
#     aggregate colour only, and can be queried for what it is really showing.
#
#     Note this is the LEGACY protocol. Newer Kasa/Tapo devices speak KLAP over
#     port 80 and require TP-Link cloud credentials; they will not work here.
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
$Backend    = 'cube'          # 'cube' (Yeelight ClydeCube) or 'kasa' (KL125)

# -- cube backend --
$CubeIp     = '192.168.0.228'
$CubePort   = 55443
$CubeColors = @{ red = 0xFF0000; yellow = 0xFFC000; green = 0x00FF00 }

# Matrix dimensions. Changing these is the only edit needed for a different
# panel, provided the index formula in Get-PixelIndex still holds.
$MatrixW = 20
$MatrixH = 5

# Dark units left between neighbouring blocks. Automatically dropped when the
# blocks would no longer fit, so this is a preference and not a guarantee.
$GapUnits = 1

# Reserve the TOP ROW as a full-width bar showing the worst state across every
# session, with the per-session blocks filling the rows beneath. One red pixel
# among a hundred is easy to miss; a red stripe across the top is not. Off by
# default, which gives the plain "every session gets an equal block" layout.
$SummaryRow = $false

# What to show when no session is live. $false fills the panel with the
# aggregate colour (green), preserving the original "green means finished, ready
# for a new task" contract. $true leaves it dark, which is quieter in a dark
# room but indistinguishable from the light being broken.
$IdleDark = $false

# -- kasa backend --
$BulbIp     = '192.168.0.103'
$BulbPort   = 9999
$Brightness = 40          # 1-100. On the cube this scales the pixel values
                          # directly, since direct mode has no separate
                          # brightness control: the RGB you send IS the output.
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

function Send-Yeelight {
    # One command per connection. The cube drops idle connections and there is
    # nothing to gain from holding one open between hook events.
    param([string]$Method, [string]$ParamsJson)

    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($CubeIp, $CubePort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { return $false }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000

        $msg = '{"id":1,"method":"' + $Method + '","params":' + $ParamsJson + '}' + [char]13 + [char]10
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        # Read the reply. A write that is never acknowledged is a write that may
        # not have landed, and this light offers no other way to find out.
        $buf = New-Object byte[] 1024
        $n = 0
        try { $n = $stream.Read($buf, 0, $buf.Length) } catch { return $false }
        if ($n -le 0) { return $false }
        $reply = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        Write-Trace ("cube $Method -> " + $reply.Trim())
        return ($reply -match '"result"')
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-PixelIndex {
    # x from the LEFT (0..W-1), y from the TOP (0..H-1). See the geometry note
    # at the top of the file: rows run right to left and are not serpentine.
    param([int]$X, [int]$Y)
    return ($Y * $MatrixW) + ($MatrixW - 1 - $X)
}

function Get-Spans {
    # Divide $Total units among $Count blocks, leaving $GapUnits dark between
    # neighbours, and hand back @(start, length) pairs.
    #
    # Three sessions across 20 columns spend 2 columns on gaps, leaving 18, so
    # 6/6/6 exactly. Any remainder goes to the leftmost blocks, which keeps the
    # whole width used rather than leaving a ragged dark edge.
    #
    # Gaps are dropped wholesale when they no longer fit, because a layout that
    # silently drops SOME gaps would read as a miscount rather than as a
    # deliberately tighter packing.
    param([int]$Count, [int]$Total)

    $gap = $GapUnits
    if (($Count + ($gap * ($Count - 1))) -gt $Total) { $gap = 0 }

    $usable = $Total - ($gap * ($Count - 1))
    $base = [Math]::Floor($usable / $Count)
    $rem = $usable - ($base * $Count)

    $spans = New-Object System.Collections.Generic.List[object]
    $pos = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $len = $base + $(if ($i -lt $rem) { 1 } else { 0 })
        $spans.Add(@($pos, $len))
        $pos += $len + $gap
    }
    # Comma is load-bearing: PowerShell unrolls a returned collection, and with
    # exactly ONE session that handed the caller the bare (start,length) pair
    # instead of a list holding it, so nothing was drawn at all.
    return , $spans
}

function Set-Block {
    # Paint columns $X0..$X1 inclusive over rows $Y0..$Y1 inclusive.
    param([byte[]]$Buf, [int]$X0, [int]$X1, [int]$Y0, [int]$Y1, [int]$Rgb)

    # $Brightness is the only dimming available in direct mode: the pixel values
    # ARE the output, so scale them rather than sending a set_bright.
    $r = [int](((($Rgb -shr 16) -band 0xFF) * $Brightness) / 100)
    $g = [int](((($Rgb -shr 8) -band 0xFF) * $Brightness) / 100)
    $b = [int]((($Rgb -band 0xFF) * $Brightness) / 100)

    for ($x = $X0; $x -le $X1; $x++) {
        for ($y = $Y0; $y -le $Y1; $y++) {
            $o = (Get-PixelIndex -X $x -Y $y) * 3
            $Buf[$o] = [byte]$r; $Buf[$o + 1] = [byte]$g; $Buf[$o + 2] = [byte]$b
        }
    }
}

function Get-MatrixFrame {
    # One contiguous block per session, left to right, as base64 RGB.
    #
    # Up to $MatrixW sessions get whole columns. Past that the columns run out
    # and pixels are allocated individually in column-major order (down a
    # column, then right), so blocks stay contiguous down to one pixel each.
    param([string[]]$States, [string]$Idle = 'green')

    $states = @($States)
    $buf = New-Object 'byte[]' ($MatrixW * $MatrixH * 3)   # zeroed == all off
    $n = $states.Count
    if ($n -eq 0) {
        if ($IdleDark) { return [Convert]::ToBase64String($buf) }
        $c = $CubeColors[$Idle]
        if ($null -eq $c) { $c = $CubeColors['green'] }
        Set-Block -Buf $buf -X0 0 -X1 ($MatrixW - 1) -Y0 0 -Y1 ($MatrixH - 1) -Rgb $c
        return [Convert]::ToBase64String($buf)
    }

    function Get-Rgb {
        param([string]$S)
        $c = $CubeColors[$S]
        if ($null -eq $c) { return $CubeColors['green'] }
        return $c
    }

    $top = 0
    if ($SummaryRow) {
        $worst = 'green'
        foreach ($s in $states) { if ($Priority[$s] -gt $Priority[$worst]) { $worst = $s } }
        Set-Block -Buf $buf -X0 0 -X1 ($MatrixW - 1) -Y0 0 -Y1 0 -Rgb (Get-Rgb $worst)
        $top = 1
    }
    $rows = $MatrixH - $top

    if ($n -le $MatrixW) {
        $spans = Get-Spans -Count $n -Total $MatrixW
        for ($i = 0; $i -lt $n; $i++) {
            $sp = $spans[$i]
            if ($sp[1] -le 0) { continue }
            Set-Block -Buf $buf -X0 $sp[0] -X1 ($sp[0] + $sp[1] - 1) `
                -Y0 $top -Y1 ($MatrixH - 1) -Rgb (Get-Rgb $states[$i])
        }
        return [Convert]::ToBase64String($buf)
    }

    $slots = $MatrixW * $rows
    if ($n -gt $slots) { $n = $slots }
    $spans = Get-Spans -Count $n -Total $slots
    for ($i = 0; $i -lt $n; $i++) {
        $sp = $spans[$i]
        $rgb = Get-Rgb $states[$i]
        for ($s = $sp[0]; $s -lt ($sp[0] + $sp[1]); $s++) {
            $x = [Math]::Floor($s / $rows)
            $y = $top + ($s % $rows)
            Set-Block -Buf $buf -X0 $x -X1 $x -Y0 $y -Y1 $y -Rgb $rgb
        }
    }
    return [Convert]::ToBase64String($buf)
}

function Set-Cube {
    # $States is one entry per live session, already ordered. Empty means
    # nothing is running anywhere.
    #
    # Everything goes over ONE connection: arming with activate_fx_mode on a
    # different connection from the update_leds push is rejected outright.
    param([string[]]$States, [string]$Aggregate)

    if ($Aggregate -eq 'off') {
        return (Send-Yeelight -Method 'set_power' -ParamsJson '["off","smooth",500]')
    }

    $frame = Get-MatrixFrame -States $States -Idle $Aggregate

    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($CubeIp, $CubePort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { return $false }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000

        $send = {
            param([string]$Json, [bool]$Read)
            $b = [Text.Encoding]::UTF8.GetBytes($Json + [char]13 + [char]10)
            $stream.Write($b, 0, $b.Length)
            $stream.Flush()
            if (-not $Read) { return $true }
            $rb = New-Object byte[] 1024
            try { $n = $stream.Read($rb, 0, $rb.Length) } catch { return $false }
            if ($n -le 0) { return $false }
            return ([Text.Encoding]::UTF8.GetString($rb, 0, $n) -match '"result"')
        }

        [void](& $send '{"id":1,"method":"set_power","params":["on","smooth",300]}' $true)
        if (-not (& $send '{"id":1,"method":"activate_fx_mode","params":[{"mode":"direct"}]}' $true)) {
            Write-Trace 'cube: activate_fx_mode refused'
            return $false
        }
        # update_leds never replies, so this is the last thing that can be known.
        [void](& $send ('{"id":1,"method":"update_leds","params":["' + $frame + '"]}') $false)
        Write-Trace ('cube: pushed frame for ' + @($States).Count + ' session(s)')
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
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

    $pic = Get-Picture
    "aggregate : " + $pic.Aggregate
    "cache     : " + $(if (Test-Path $CacheFile) { (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '(none)' })
    "backend   : " + $Backend

    # What the light is being asked to render, which for the cube is not the
    # same thing as the aggregate.
    if ($Backend -eq 'cube') {
        $states = @($pic.Slots | ForEach-Object { $_.State })
        $n = $states.Count
        if ($n -eq 0) { "display   : all off (no live sessions)" }
        else {
            $rows = $MatrixH - $(if ($SummaryRow) { 1 } else { 0 })
            $unit = if ($n -le $MatrixW) { 'col' } else { 'px' }
            $total = if ($n -le $MatrixW) { $MatrixW } else { $MatrixW * $rows }
            $spans = Get-Spans -Count $n -Total $total
            $desc = (0..($n - 1) | ForEach-Object { "" + $states[$_] + '=' + $spans[$_][1] + $unit }) -join ', '
            $gapped = if (($n + ($GapUnits * ($n - 1))) -le $total) { 'with gaps' } else { 'no room for gaps' }
            "display   : $n block(s) left to right, $gapped"
            "            $desc"
            if ($SummaryRow) { "            top row = worst state summary" }
        }
    }

    if ($Backend -eq 'cube') {
        # This firmware cannot be asked what it is showing: get_prop never
        # answers and its SSDP reply is a hardcoded stub. Reachability is the
        # only thing that can honestly be checked, so check that and say so.
        $c = New-Object Net.Sockets.TcpClient
        try {
            $ar = $c.BeginConnect($CubeIp, $CubePort, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) {
                "cube      : UNREACHABLE at $CubeIp`:$CubePort (LAN Control off, or offline)"
            }
            else {
                $c.EndConnect($ar)
                "cube      : reachable at $CubeIp`:$CubePort"
                "            (write-only firmware: cannot read back what it is showing)"
            }
        }
        catch { "cube      : error talking to $CubeIp - $($_.Exception.Message)" }
        finally { $c.Close() }
        return
    }

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

function Get-Picture {
    # The whole state of the world in one pass: one slot per live session,
    # ordered stably by session key so the cycle does not reshuffle between hook
    # events, plus the worst-wins aggregate over all of them.
    #
    # Get-RunningTasks costs a few hundred milliseconds, so it is still only run
    # when every session already looks idle. That keeps the common case (some
    # session mid-tool) free, while green still means nothing is running.
    $slots = New-Object System.Collections.Generic.List[object]
    $best = 'green'
    $cut = (Get-Date).AddMinutes(-$StaleMinutes)

    $files = @(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        if ($f.LastWriteTime -lt $cut) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $s = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $s) { continue }
        $s = $s.Trim()
        if (-not $Priority.ContainsKey($s)) { continue }
        $slots.Add([pscustomobject]@{
                Key   = $f.BaseName.Substring(0, [Math]::Min(8, $f.BaseName.Length))
                State = $s
            })
        if ($Priority[$s] -gt $Priority[$best]) { $best = $s }
    }

    if ($best -eq 'green') {
        # Every agent is idle, but a backgrounded command one of them launched
        # may still be running. Attribute each to its own session where we can,
        # so the cycle shows WHICH session is still busy and not just that one is.
        $busy = @{}
        foreach ($t in @(Get-RunningTasks)) { $busy[($t -split '/')[0]] = $true }
        if ($busy.Count -gt 0) {
            $best = 'yellow'
            foreach ($sl in $slots) { if ($busy.ContainsKey($sl.Key)) { $sl.State = 'yellow' } }
            # A task can outlive the session slot that started it. Still work.
            foreach ($k in $busy.Keys) {
                if (-not ($slots | Where-Object { $_.Key -eq $k })) {
                    $slots.Add([pscustomobject]@{ Key = $k; State = 'yellow' })
                }
            }
        }
    }

    return [pscustomobject]@{ Slots = $slots; Aggregate = $best }
}

function Get-AggregateState { return (Get-Picture).Aggregate }

function Get-CacheKey {
    # What is on the light, as a string. For the cube this has to describe the
    # whole composition, not just the aggregate: going from two yellow sessions
    # to three is a real change that a bare 'yellow' would hide.
    param([string]$Want, $Slots)

    if ($Backend -ne 'cube') { return $Want }
    if ($Want -eq 'off') { return 'cube:off' }
    $states = @()
    if ($null -ne $Slots) { $states = @($Slots | ForEach-Object { $_.State }) }
    if ($states.Count -eq 0) { return "cube:none:$Want" }
    return 'cube:bands:' + ($states -join ',')
}

function Set-Light {
    param([string]$Want, $Slots)

    $key = Get-CacheKey -Want $Want -Slots $Slots

    # Skip everything when the light already shows this. PreToolUse and
    # PostToolUse fire constantly, so without this the light would take a TCP
    # connection per tool call -- and would flash on every one of them.
    if (Test-Path $CacheFile) {
        $last = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $last -and $last.Trim() -eq $key) { return }
    }

    # Claim the state BEFORE the write. PreToolUse and PostToolUse both ask for
    # yellow milliseconds apart; without this the second sees a stale cache.
    $prev = $null
    if (Test-Path $CacheFile) {
        $prev = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
    }
    Set-Content -Path $CacheFile -Value $key -NoNewline

    $ok = $false
    if ($Backend -eq 'cube') {
        $states = @()
        if ($null -ne $Slots) { $states = @($Slots | ForEach-Object { $_.State }) }
        $ok = Set-Cube -States $states -Aggregate $Want
    }
    else {
        $ok = Set-Kasa -Want $Want
    }

    if (-not $ok) {
        # Light unreachable: undo the claim so the next hook retries rather than
        # believing the light is already showing this state.
        if ($null -ne $prev) { Set-Content -Path $CacheFile -Value $prev.Trim() -NoNewline }
        elseif (Test-Path $CacheFile) { Remove-Item $CacheFile -Force -ErrorAction SilentlyContinue }
    }
}

function Set-Kasa {
    param([string]$Want)

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

    return (Invoke-KasaSequence -Payloads $payloads.ToArray() -DelaysMs $delays.ToArray())
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
            # Manual run: no session asked for this, so do as told. No slots,
            # which the cube renders as a solid colour.
            Set-Light -Want $State -Slots $null
        }
        elseif ($State -eq 'off') {
            # An explicit blackout. Forget every session so the next hook event
            # rebuilds the picture from scratch.
            Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue
            Set-Light -Want 'off' -Slots $null
        }
        else {
            Set-SessionState -Key $key -Want $State -Ended ($hookName -eq 'SessionEnd')
            $pic = Get-Picture
            Write-Trace ("slots=[" + (($pic.Slots | ForEach-Object { $_.Key + '=' + $_.State }) -join ' ') + "] agg=" + $pic.Aggregate)
            Set-Light -Want $pic.Aggregate -Slots $pic.Slots
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
