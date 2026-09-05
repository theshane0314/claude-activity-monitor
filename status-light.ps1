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
# Blocks are ordered OLDEST SESSION LEFTMOST, by the creation time of the slot
# file, which is written on a session's first hook. So a session keeps its place
# for as long as it lives and new ones appear on the right, rather than the
# whole display reshuffling whenever a session starts or ends.
#
# An aggregate is still computed (worst state wins: red beats yellow beats
# green). It is what fills the panel when nothing is running, and what `status`
# reports. Green has to mean "nothing is running anywhere".
#
# A session appears on the panel when it first DOES something, not when it is
# created: SessionStart deliberately does not open a slot. See Set-SessionState.
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
# Backend: a Yeelight Cube Smart Lamp Lite "ClydeCube" at 192.168.0.228,
# Yeelight LAN Control on TCP 55443. A 20x5 RGB matrix, driven per pixel, one
# block per session.
#
#     A TP-Link Kasa KL125 backend used to live here and was dropped once the
#     cube took over: it could only ever show the aggregate colour, which is the
#     thing this display exists to stop doing. It is in git history if a
#     single-colour fallback is ever wanted again.
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
#     cannot ask this light what it is showing; it reports the cache and says
#     so. Do not "fix" this by reading SSDP.
#
# GOING DARK. The light is off when there is nothing to report: no session is
# live, the Claude desktop app is closed, or no hook has fired in 20 minutes.
# None of those can be noticed by a hook, because the whole point is that
# nothing is happening and so nothing fires.
#
# `watchdog` is the periodic check, run from a Scheduled Task. It darkens the
# light when a condition is met and otherwise re-asserts the current picture.
# A Scheduled Task cannot repeat faster than once a minute, though, and an app
# close should be instant, so watch-app.ps1 sits resident and polls for the app
# every couple of seconds. See install-watchdog.ps1.
#
# Recent activity wins over the app check on the PERIODIC path, so running
# Claude Code in a terminal with the desktop app closed does not black the light
# out mid-task. Watching the app process actually EXIT is a different and much
# stronger signal, so watch-app.ps1 darkens on that transition regardless; if
# terminal work really is still going, its next hook repaints within seconds.
#
# Usage: status-light.ps1 <red|yellow|green|off|status|watchdog>
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
    [ValidateSet('red', 'yellow', 'green', 'off', 'status', 'watchdog')]
    [string]$State
)

# ---- configuration -------------------------------------------------------
# -- cube --
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
$SummaryRow = $true

# What to show when no session is live. $false fills the panel with the
# aggregate colour (green), preserving the original "green means finished, ready
# for a new task" contract. $true leaves it dark, which is quieter in a dark
# room but indistinguishable from the light being broken.
#
# ON. Green-when-idle meant closing the app left a green panel sitting there for
# minutes until the timeout caught up. The last session ending now goes straight
# to dark, which is the honest reading of "nothing is running".
$IdleDark = $true

$Brightness = 40          # 1-100. On the cube this scales the pixel values
                          # directly, since direct mode has no separate
                          # brightness control: the RGB you send IS the output.
$ConnectMs  = 1000        # give up quietly if the light is slow or offline

# A session that dies without firing SessionEnd (window closed, crash, reboot)
# would otherwise pin the light yellow forever. Anything not heard from in this
# long is treated as gone. Keep it comfortably above the longest gap between two
# hook events in a working session: a foreground Bash call can hold for ten
# minutes, with model thinking either side of it.
$StaleMinutes = 30

# Worst-wins ordering used to combine the live sessions.
$Priority = @{ green = 1; yellow = 2; red = 3 }

# -- going dark --
# No hook in this long and the light goes out. Must be comfortably longer than
# $StaleMinutes, or slots would still be live on a panel that has gone dark.
$DarkAfterMinutes = 20

# Activity newer than this means something is genuinely running, which overrides
# the desktop-app check below. Without it, using Claude Code from a terminal with
# the app closed would black the light out mid-task.
$ActiveGraceMinutes = 2

# Darken when the Claude desktop app is not running. Matched on executable path,
# because the Claude Code CLI is also called claude.exe and must NOT count: the
# app lives under \WindowsApps\Claude_..., the CLI under AppData\Roaming.
$RequireAppRunning = $true
$AppPathMatch = '\\WindowsApps\\Claude'

$ActivityFile = Join-Path $env:TEMP 'claude-status-light.activity'
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

    $last = Get-LastActivity
    if ($null -eq $last) { "activity  : never recorded" }
    else { "activity  : {0:HH:mm:ss}, {1:n1} min ago" -f $last, ((Get-Date) - $last).TotalMinutes }
    "app       : " + $(if (Test-AppRunning) { 'desktop app running' } else { 'desktop app NOT running' })
    $reason = Get-DarkReason
    "dark      : " + $(if ($null -ne $reason) { "YES - $reason" } else { 'no' })

    $pic = Get-Picture
    "aggregate : " + $pic.Aggregate
    "cache     : " + $(if (Test-Path $CacheFile) { (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '(none)' })

    # What the panel is being asked to render, which is not the same thing as
    # the aggregate.
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
        "display   : $n block(s) left to right, oldest first, $gapped"
        "            $desc"
        if ($SummaryRow) { "            top row = worst state summary" }
    }

    # This firmware cannot be asked what it is showing: get_prop never answers
    # and its SSDP reply is a hardcoded stub. Reachability is the only thing
    # that can honestly be checked, so check that and say so.
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
    #
    # SessionStart does NOT open one, which is the less obvious half. Reopening
    # the desktop app restores every previous conversation tab and each fires
    # SessionStart, which planted a green slot per restored tab: the panel showed
    # three sessions when only one was in use. A session that exists but has
    # never done anything is not work to report. It earns its block on the first
    # hook that means something is happening, and keeps it until SessionEnd.
    #
    # SessionStart still UPDATES a slot that already exists, rather than being
    # ignored outright, so it can never strand a stale colour.
    param([string]$Key, [string]$Want, [string]$HookName)

    $f = Join-Path $StateDir ($Key + '.state')

    if ($HookName -eq 'SessionEnd') {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        return
    }
    if ($HookName -eq 'SessionStart' -and -not (Test-Path -LiteralPath $f)) { return }

    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
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

function Update-Activity {
    # Touched on every hook event, whatever it asked for. This is the only
    # record of "something happened", and it has to survive SessionEnd deleting
    # the last slot, so it cannot be derived from the slot files.
    try { [System.IO.File]::WriteAllText($ActivityFile, (Get-Date).Ticks.ToString()) }
    catch { }
}

function Get-LastActivity {
    try {
        $fi = Get-Item -LiteralPath $ActivityFile -ErrorAction Stop
        return $fi.LastWriteTime
    }
    catch { return $null }
}

function Test-AppRunning {
    # The desktop app only. Get-Process is used rather than CIM because this runs
    # on a schedule and Win32_Process is markedly slower; .Path throws for
    # processes owned by another user, which simply means it is not ours.
    foreach ($p in @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -match $AppPathMatch) { return $true } } catch { }
    }
    return $false
}

function Get-DarkReason {
    # $null to show the normal picture, otherwise why the light should be off.
    $last = Get-LastActivity
    if ($null -eq $last) { return 'no activity ever recorded' }

    $idle = ((Get-Date) - $last).TotalMinutes
    # Something is actively running: that outranks everything, including the app
    # check, so a terminal session with the app closed still lights the panel.
    if ($idle -le $ActiveGraceMinutes) { return $null }

    if ($RequireAppRunning -and -not (Test-AppRunning)) { return 'desktop app closed' }
    if ($idle -ge $DarkAfterMinutes) { return ('idle {0:n0} min' -f $idle) }
    return $null
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

    # Oldest first: CreationTime is when the session fired its FIRST hook, and
    # Set-Content on an existing file leaves it alone, so a session holds its
    # position for life. Name breaks ties so the order is never arbitrary.
    $files = @(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime, Name)
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

    $states = @()
    if ($null -ne $Slots) { $states = @($Slots | ForEach-Object { $_.State }) }
    $ok = Set-Cube -States $states -Aggregate $Want

    if (-not $ok) {
        # Light unreachable: undo the claim so the next hook retries rather than
        # believing the light is already showing this state.
        if ($null -ne $prev) { Set-Content -Path $CacheFile -Value $prev.Trim() -NoNewline }
        elseif (Test-Path $CacheFile) { Remove-Item $CacheFile -Force -ErrorAction SilentlyContinue }
    }
}

if ($State -eq 'status') { Show-Status; exit 0 }

if ($State -eq 'watchdog') {
    # Run on a schedule. Nothing else can notice the app closing or the room
    # going quiet, because both are the absence of hook events.
    $mtx = New-Object System.Threading.Mutex($false, 'ClaudeStatusLight')
    $held = $false
    try {
        try { $held = $mtx.WaitOne(3000) } catch { $held = $false }
        $reason = Get-DarkReason
        if ($null -ne $reason) {
            Write-Trace ("watchdog: dark ($reason)")
            Set-Light -Want 'off' -Slots $null
        }
        else {
            # Not dark: re-assert the picture. Cheap, because Set-Light skips
            # the write when the composition is unchanged, and it repaints the
            # panel if the light was power-cycled or darkened behind our back.
            $pic = Get-Picture
            Set-Light -Want $pic.Aggregate -Slots $pic.Slots
        }
    }
    catch { Write-Trace ('watchdog EXCEPTION: ' + $_.Exception.Message) }
    finally {
        if ($held) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
    exit 0
}

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
            Update-Activity
            Set-SessionState -Key $key -Want $State -HookName $hookName
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
