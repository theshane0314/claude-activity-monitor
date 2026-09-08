# status-light.ps1 - drive a physical status light from Claude Code hooks.
#
#   red    = waiting for confirmation
#   yellow = running
#   green  = finished, ready for a new task
#
# EVERY LIVE SESSION GETS ITS OWN BLOCK OF THE PANEL, side by side, with a dark
# column between neighbours so the blocks are countable at a glance.
#
# ALL BLOCKS ARE THE SAME SIZE. Anything that does not divide evenly goes into
# the GAPS, never into a block, so two sessions on the 20-wide panel are 9/2/9
# rather than 10/1/9. Comparing two blocks should never mean asking whether one
# is genuinely bigger or just holding the remainder.
#
# UP TO THREE SESSIONS THE PANEL IS SPLIT LEFT TO RIGHT ONLY, full height each.
# FROM FOUR IT IS SPLIT BOTH WAYS, so four sessions are quadrants: two rows of
# two, each 9x2. Splitting the height any earlier would waste it, since a third
# of a 20-wide panel is still a comfortable block at full height.
#
# The grid grows by columns first and only adds rows when the columns run out,
# up to 20x5, which is one pixel each for 100 sessions. A grid with more cells
# than sessions simply leaves the spare cells dark. Everything is visible at
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
# Backend: a Yeelight Cube Smart Lamp Lite "ClydeCube" at 192.168.0.105,
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
# Usage: status-light.ps1 <red|yellow|green|off|status|watchdog|prune|layout|animate>
#
# MANUAL OVERRIDE. clyde-server.py serves a pixel editor and writes an override
# file that this script honours when it paints. Two modes:
#
#   takeover - the drawing owns the whole panel, and is dropped the moment the
#              session composition changes, so the next thing Claude does takes
#              the panel back.
#              A `pin` of true suspends that expiry, which is what a ticker
#              needs: it then runs until something clears it explicitly, and
#              session state stays off the panel while it does.
#   session  - the drawing takes a SHARE of the panel and every real session
#              shares what is left. The share is share/total parts, so 1/2 gives
#              the drawing half, 2/3 gives it the right two thirds with all the
#              sessions packed into the left third, and 1/(sessions+1) reproduces
#              "just one more session". It survives status changes and is dropped
#              only when the number of real sessions changes, since that is what
#              resizes the sessions' own region underneath it.
#
# See Get-Override. The layout verb exists so the editor never has to reimplement
# Get-Grid and Get-Spans: it asks for the cell size it should draw at.
#
# SCROLLING. An override may carry an optional `scroll` block (speed in UPDATES
# per second, step in columns moved per update, dir left|right, gap in blank
# columns). With it, the drawing's `w` is allowed to be WIDER than the region it
# lands in: a window walks across the canvas, wrapping modulo (w + gap) so the
# tail runs back into the head with `gap` dark columns between, which is what
# makes it a ticker rather than a slide that ends. Without the block nothing
# changes, down to the byte.
#
# IT IS A FLIP-BOARD, NOT A GLIDE, AND THAT IS THE HARDWARE TALKING. The cube
# refuses commands after about 25 to 30 on one connection and refills at roughly
# 68 a minute overall, so a column-per-frame scroll at any readable rate freezes
# the panel within seconds. So an update moves `step` columns (4 by default, one
# character of a 3-wide font plus its spacing) and updates land less than once a
# second. See the scroll configuration block for the measurements.
#
# The scroll is driven by the `animate` verb, a resident loop that holds ONE
# connection open and pushes frames at the scroll rate (arming and pushing must
# share a socket, and reconnecting per frame costs ~150ms). It is started
# automatically by the first ordinary paint that sees a scrolling override, see
# Start-Animator. It spends a BUDGET rather than a frame rate, leaves headroom
# for the ordinary hook paints, and probes for the quota refusal instead of
# pushing into the dark, because update_leds never replies and a refused frame
# is otherwise indistinguishable from a rendered one.
#
# While it runs it touches a heartbeat file every frame, and Set-Cube DEFERS to
# a fresh heartbeat so hook paints stop fighting the animation. Because they
# defer, the animator has to re-read session state itself, which it does once a
# second with the same functions the hook path uses. FRESHNESS is the whole
# check: a heartbeat left behind by a killed animator must never wedge the light,
# so the file merely existing means nothing.
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
    [ValidateSet('red', 'yellow', 'green', 'off', 'status', 'watchdog', 'prune', 'layout', 'animate')]
    [string]$State
)

# ---- configuration -------------------------------------------------------
# -- cube --
$CubeIp     = '192.168.0.105'   # DHCP reservation for E4:B3:23:0D:47:50
$CubePort   = 55443
# Chosen by eye against the cube's diffuser: pure 0x00FF00 green sitting next to
# 0xFFC000 amber read as yellow, so green is pushed toward mint and the amber
# toward orange to keep them apart.
$CubeColors = @{ red = 0xFF0000; yellow = 0xFF7000; green = 0x00FF64 }

# Matrix dimensions. Changing these is the only edit needed for a different
# panel, provided the index formula in Get-PixelIndex still holds.
$MatrixW = 20
$MatrixH = 5

# The cube is mounted upside down (it makes the cable run cleaner). A 180 degree
# rotation inverts BOTH axes, so this is not just a row flip. See Get-PixelIndex.
$Flip180 = $true

# Dark units left between neighbouring blocks. Automatically dropped when the
# blocks would no longer fit, so this is a preference and not a guarantee.
$GapUnits = 1

# Reserve the TOP ROW as a full-width bar showing the worst state across every
# session, with the per-session blocks filling the rows beneath.
#
# OFF. It was tried and it costs a fifth of the panel to say something the
# blocks already say, and with one or two sessions the bar and the blocks are
# the same colour anyway. Each session now gets the full height of its section.
$SummaryRow = $false

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

# ...but only for a session that is IDLE. A session that is working, or waiting
# on an answer, keeps its slot this much longer. Red is the case that matters:
# it fires one hook and then sits silent until you answer it, so the ordinary
# sweep would drop the slot and turn the light off on the one state that most
# needs to stay visible. Still bounded, so a session that dies mid-prompt cannot
# pin the panel red forever.
$StaleMinutesActive = 240

# Worst-wins ordering used to combine the live sessions.
$Priority = @{ green = 1; yellow = 2; red = 3 }

# -- going dark --
# No hook in this long and the light goes out -- but ONLY if every session is
# idle. A yellow or red session is never timed out, however long it has been
# quiet: a long background task and a prompt waiting for an answer both produce
# no hooks at all, and going dark on either would hide exactly what the panel
# exists to show. See Get-DarkReason.
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

# Push the frame again after this long even when nothing changed. The light is
# WRITE-ONLY: there is no way to ask what it is actually showing, so anything
# that desyncs it -- unplugging it to move it, a power cut, someone using the
# Yeelight app -- would otherwise be invisible, and the cache would go on
# skipping the write forever. One frame every couple of minutes is the cost of
# not being able to read the device.
$ReassertSeconds = 120

# Scanning for running background tasks costs a few hundred milliseconds, and
# now has to happen on EVERY hook rather than only on the way to green (see
# Get-Picture), so the answer is cached for this long. Short enough that a
# finished task stops holding a block almost immediately.
$TaskCacheSeconds = 10
$TaskCacheFile = Join-Path $env:TEMP 'claude-status-light.tasks'

# Only probe task files this recent. Every hook instance was opening all 731
# .output files exclusively, and those instances collide with each other: that
# collision is the most likely source of the spurious access-denied that made a
# working session read as idle. Bounded to 24h it is ~127 files here.
#
# The bound uses the NEWER of write and creation time, because a quiet task
# (a long test suite that prints nothing) keeps its creation timestamp and would
# otherwise age out while still running. A command running longer than this
# window is missed and its session shows green; 24h is far beyond any real
# backgrounded command, but that is the trade being made.
$TaskScanMaxAgeHours = 24

# `prune` deletes task .output files older than this. Claude Code already cleans
# up at about 7 days on its own, so this is a BACKSTOP for when that fails, not
# the primary mechanism, and it deliberately does not shorten that retention.
# Lower it only if you are sure you will never want the output back.
$TaskPruneDays = 7

# Written by clyde-server.py, read on every paint. See Get-Override.
$OverrideFile = Join-Path $env:TEMP 'claude-status-light.override'

# -- scrolling --
# Defaults for an override's optional `scroll` block, and the bounds every value
# is clamped into. A drawing that asks for something outside these is clamped
# rather than refused: a ticker running at the wrong speed is still readable,
# and a silently dropped override is not.
#
# THE MEASUREMENTS THAT SET THESE NUMBERS (2026-09-08, refillprobe.py). They are
# not preferences and they are not guesses:
#
#   * A held connection is refused after about 25 to 30 commands, with
#     {"code":-1,"message":"client quota exceeded"}.
#   * The budget is per CONNECTION: a socket opened the instant another is
#     refused is served immediately.
#   * A CLIENT-level cap sits above that. Rotating sockets bought 72 frames over
#     6 seconds and then fresh connections were refused too.
#   * The refill: 58 commands spent, 51 seconds locked out. About 68 commands a
#     MINUTE, which as a one-column-per-frame scroll is 1.1 columns a second.
#   * activate_fx_mode accepts only "direct". Fifteen other mode strings were
#     probed and every one came back "invalid params", so there is no on-device
#     animation to hand the work to.
#
# AND THE REASON THIS WAS EXPENSIVE TO FIND: update_leds NEVER REPLIES, so going
# over the budget is SILENT. The socket keeps accepting frames and the panel
# simply freezes on the last one it rendered. Every instrument built before this
# was measured reported success while the panel was dead, because a probe on a
# FRESH connection gets a FRESH budget and answers "ok" while the held
# connection's frames are being discarded. Any check of "is the cube keeping up"
# has to be made ON THE CONNECTION THAT IS PUSHING. See Test-CubeQuota.
#
# So `speed` keeps its name but now means UPDATES PER SECOND, and each update
# moves `step` columns. At step 4 an update advances exactly one character of a
# 3-wide font plus its spacing, which makes the message walk across the panel a
# character at a time: a flip-board rather than a glide, and the most motion this
# hardware can sustain. step 1 is the honest one-column crawl.
$ScrollDefaultSpeed = 0.7   # UPDATES per second, not columns
$ScrollMinSpeed = 0.05      # one update every 20s, the slowest worth having
$ScrollMaxSpeed = 1.0       # above this the panel freezes; the clamp is the hardware
$ScrollDefaultStep = 4      # columns moved per update: one 3-wide char plus spacing
$ScrollMinStep = 1
$ScrollMaxStep = 8
$ScrollDefaultGap = 8       # blank columns between the tail and the head
$ScrollMinGap = 0
$ScrollMaxGap = 64

# THE ANIMATOR'S SHARE OF THE DEVICE, in commands per minute, counting EVERY
# command it sends: frames, quota probes and the arming of each connection.
#
# 40 against a measured refill of about 68 leaves 28 a minute for everything
# else, and that headroom is the point rather than politeness. The status light
# still has to paint on hooks, and a hook paint refused on quota leaves the panel
# stuck showing a ticker that has already been taken down: the drawing outlives
# the override that asked for it, and nothing on the device can be read back to
# notice. Spending the whole budget on the animation would make the light lie.
$AnimateMaxCommandsPerMinute = 40

# Pace the frames at this fraction of the ceiling so the hard limiter is a
# BACKSTOP that almost never fires rather than the thing setting the rate. A
# limiter that binds on every frame turns even pacing into a sawtooth, and the
# whole point of the profile instrumentation is to be able to see the pacing.
$AnimatePaceFraction = 0.9

# Send one command that DOES reply after this many commands on a connection, and
# rotate to a fresh one straight after. Two jobs in one command, see
# Test-CubeQuota: it is the only evidence that the frames just pushed were being
# served, AND it re-arms direct mode.
#
# ROTATING PROACTIVELY IS NOT BELT AND BRACES. The connection budget is 25 to 30
# commands, so a connection that is only abandoned once a probe FAILS spends the
# gap between the refusal and the next probe pushing frames into a dead socket:
# at one probe every 20 commands that is up to fifteen frames, about half a
# minute of frozen panel, every single connection. Retiring the connection while
# it is still known good costs one command and cannot freeze anything.
$AnimateProbeEvery = 20

# A fresh connection refused as well means the CLIENT cap is spent, not the
# connection's, and the only cure is time: 51 seconds measured. Waiting it out is
# the fast path. Hammering it keeps the refill from ever arriving, and that is
# what turns a five second stall into a dead panel.
$AnimateQuotaBackoffMs = 55000

# The animator's heartbeat, refreshed every frame with its pid and the time.
# Set-Cube defers to it while it is FRESH. Never treat it as a lock: a process
# that died leaves the file behind, and the age is what makes that harmless.
$AnimateFile = Join-Path $env:TEMP 'claude-status-light.animating'
$AnimateFreshSeconds = 3

# Drop this file to ask a running animator to stop at its next frame. It deletes
# the file itself, so the request cannot outlive the stop it asked for.
$AnimateStopFile = Join-Path $env:TEMP 'claude-status-light.animate-stop'

# NO INTERVAL RE-ARM ANY MORE, and the deletion is deliberate. Direct mode used
# to be re-armed every 30 seconds as insurance against firmware dropping it, on
# the reasoning that the device is write-only and a dropped mode would show up
# only as a panel that had stopped moving.
#
# A RE-ARM COSTS EXACTLY WHAT A FRAME COSTS. At the rate the budget now allows,
# a timer re-arm every 30 seconds is about one command in eighteen spent on
# insurance against something never observed, and every one of those is a frame
# the panel does not get. The quota probe already sends activate_fx_mode on the
# pushing connection every $AnimateProbeEvery commands, which re-arms it as a
# side effect, so the insurance is still there and now costs nothing extra.
# Adding a second re-arm on a timer would be paying twice for one guarantee.

# How often the animator re-reads the sessions. The scroll offset advances every
# frame regardless; this is only about noticing a session starting or turning
# red, which no hook can show while paints are deferring to the animation.
$AnimateStateSeconds = 1

# Frame timing instrumentation for the animator. The panel is write-only, so the
# only way to tell a stutter from a slow scroll is to measure the interval
# between pushes on this side and see what the distribution looks like. Cheap
# (one double appended per frame), and the summary lands in the trace on exit.
$AnimateProfile = $true

# Start the animator from the first ordinary paint that sees a scrolling
# override, so nothing else has to remember to. Guarded twice: `animate` refuses
# to run beside a live heartbeat, and the cooldown below stops a crash-looping
# animator being respawned by every hook.
$AutoAnimate = $true
$AnimateSpawnFile = Join-Path $env:TEMP 'claude-status-light.animspawn'
$AnimateSpawnCooldown = 15

# True only inside the `animate` verb. Set-Cube uses it to tell its own frames
# apart from a hook trying to paint over the animation.
$script:IsAnimator = $false

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

function Open-Cube {
    # A connected socket, or $null. Everything that talks to the cube goes
    # through here, because the ONE connection rule is the thing most easily got
    # wrong: activate_fx_mode arms direct mode for the connection it arrived on,
    # so a frame pushed down a different socket is answered with "illegal
    # request". A hook opens one, sends its two calls and closes it; the animator
    # opens one and keeps it, since reconnecting costs ~150ms and no ticker
    # survives that per frame.
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($CubeIp, $CubePort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs)) { $client.Close(); return $null }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        return [pscustomobject]@{ Client = $client; Stream = $stream }
    }
    catch {
        try { $client.Close() } catch { }
        return $null
    }
}

function Close-Cube {
    param($Conn)
    if ($null -eq $Conn) { return }
    try { $Conn.Client.Close() } catch { }
}

function Send-CubeRaw {
    # One command, and the RAW reply text back, or $null when nothing came.
    #
    # THE REPLY TEXT IS THE ONLY PLACE THE QUOTA REFUSAL EXISTS. It arrives as
    # {"code":-1,"message":"client quota exceeded"}, which is a REPLY and not a
    # silence, so the boolean form below cannot tell it apart from a light that
    # is merely unplugged. Being cut off and being offline call for opposite
    # reactions, so the animator reads the text. See Test-CubeQuota.
    param($Conn, [string]$Json)

    if ($null -eq $Conn) { return $null }
    try {
        $b = [Text.Encoding]::UTF8.GetBytes($Json + [char]13 + [char]10)
        $Conn.Stream.Write($b, 0, $b.Length)
        $Conn.Stream.Flush()
        $rb = New-Object byte[] 1024
        $n = 0
        try { $n = $Conn.Stream.Read($rb, 0, $rb.Length) } catch { return $null }
        if ($n -le 0) { return $null }
        return [Text.Encoding]::UTF8.GetString($rb, 0, $n)
    }
    catch { return $null }
}

function Send-CubeJson {
    # $Read $false for update_leds, which NEVER replies: waiting on it would
    # stall every frame until the read timeout expires.
    param($Conn, [string]$Json, [bool]$Read)

    if ($null -eq $Conn) { return $false }
    if (-not $Read) {
        try {
            $b = [Text.Encoding]::UTF8.GetBytes($Json + [char]13 + [char]10)
            $Conn.Stream.Write($b, 0, $b.Length)
            $Conn.Stream.Flush()
            return $true
        }
        catch { return $false }
    }

    # A write that is never acknowledged is a write that may not have landed,
    # and this light offers no other way to find out.
    $resp = Send-CubeRaw -Conn $Conn -Json $Json
    if ($null -eq $resp) { return $false }
    return ($resp -match '"result"')
}

function Test-CubeQuota {
    # 'ok', 'quota' or 'silent', measured ON THE CONNECTION HANDED IN. This is
    # the animator's only instrument, and the connection is the whole point of
    # it: the budget is per connection, so asking a FRESH socket whether the cube
    # is listening always answers yes and tells you nothing about the socket
    # whose frames are being thrown away.
    #
    # activate_fx_mode is the command used because it replies AND re-arms direct
    # mode, so the probe pays for itself instead of only costing a command.
    param($Conn)

    $resp = Send-CubeRaw -Conn $Conn -Json '{"id":1,"method":"activate_fx_mode","params":[{"mode":"direct"}]}'
    if ($null -eq $resp) { return 'silent' }
    if ($resp -match 'quota') { return 'quota' }
    if ($resp -match '"result"') { return 'ok' }
    return 'silent'
}

function Initialize-CubeDirect {
    # Power on, then arm direct mode, on the connection frames will be pushed
    # down. set_power is a no-op on a light that is already on, and it recovers a
    # panel someone switched off in the Yeelight app without this process being
    # able to see it.
    #
    # The animator does NOT use this. It arms its own connections a command at a
    # time, because every command it sends has to be counted against a budget and
    # because it needs to read the arm's REPLY rather than a boolean: a refusal
    # on a freshly opened socket means the client-level cap is spent, which calls
    # for waiting out the refill rather than reconnecting. See Test-CubeQuota.
    param($Conn)

    [void](Send-CubeJson -Conn $Conn -Json '{"id":1,"method":"set_power","params":["on","smooth",300]}' -Read $true)
    if (-not (Send-CubeJson -Conn $Conn -Json '{"id":1,"method":"activate_fx_mode","params":[{"mode":"direct"}]}' -Read $true)) {
        Write-Trace 'cube: activate_fx_mode refused'
        return $false
    }
    return $true
}

function Push-CubeFrame {
    # The last thing that can be known: update_leds never replies, so a $true
    # here means "written to the socket", not "rendered".
    param($Conn, [string]$Frame)
    return (Send-CubeJson -Conn $Conn -Json ('{"id":1,"method":"update_leds","params":["' + $Frame + '"]}') -Read $false)
}

function Send-Yeelight {
    # One command on its own connection, for the calls that do not need direct
    # mode (set_power off). The cube drops idle connections and there is nothing
    # to gain from holding one open between hook events.
    param([string]$Method, [string]$ParamsJson)

    $conn = Open-Cube
    if ($null -eq $conn) { return $false }
    try {
        $ok = Send-CubeJson -Conn $conn -Json ('{"id":1,"method":"' + $Method + '","params":' + $ParamsJson + '}') -Read $true
        Write-Trace ("cube $Method -> " + $(if ($ok) { 'ok' } else { 'no result' }))
        return $ok
    }
    finally { Close-Cube $conn }
}

function Get-PixelIndex {
    # x from the LEFT AS VIEWED (0..W-1), y from the TOP AS VIEWED (0..H-1).
    #
    # Native panel order is row-major with each row running RIGHT TO LEFT and no
    # serpentine, so a pixel at (x, y) is at index y*W + (W-1-x).
    #
    # Mounted upside down, a 180 degree rotation puts the physical pixel (a, b)
    # where the viewer sees (W-1-a, H-1-b). Solving for the physical pixel under
    # a viewed (x, y) gives a = W-1-x and b = H-1-y, so
    #     index = (H-1-y)*W + (W-1-(W-1-x)) = (H-1-y)*W + x
    # The right-to-left run and the x inversion cancel, which is why the flipped
    # form looks like an ordinary left-to-right raster.
    param([int]$X, [int]$Y)
    if ($Flip180) { return (($MatrixH - 1 - $Y) * $MatrixW) + $X }
    return ($Y * $MatrixW) + ($MatrixW - 1 - $X)
}

function Get-Spans {
    # Divide $Total units among $Count EQUAL blocks and hand back @(start, length)
    # pairs. Whatever will not divide evenly is spent on the gaps.
    #
    # Blocks of different widths are the thing to avoid: a wider block reads as
    # meaning something, and it does not. So two sessions across 20 columns are
    # 9/2/9, not 10/1/9, and three are 6/1/6/1/6 with nothing left over.
    #
    # The leftover is added to the gaps from the MIDDLE OUTWARDS, so the extra
    # dark space stays centred instead of shoving the whole row to one side.
    #
    # Gaps are dropped wholesale when a block would otherwise be narrower than
    # one unit, since a layout that silently dropped SOME gaps would read as a
    # miscount rather than as deliberately tighter packing.
    param([int]$Count, [int]$Total)

    $spans = New-Object System.Collections.Generic.List[object]
    if ($Count -le 0) { return , $spans }

    $gaps = $Count - 1
    $gap = $GapUnits
    if ($gaps -gt 0 -and [Math]::Floor(($Total - ($gaps * $gap)) / $Count) -lt 1) { $gap = 0 }

    $width = [Math]::Floor(($Total - ($gaps * $gap)) / $Count)
    if ($width -lt 1) { $width = 1 }

    $gapWidths = New-Object 'int[]' ([Math]::Max($gaps, 0))
    for ($i = 0; $i -lt $gaps; $i++) { $gapWidths[$i] = $gap }

    # Widen gaps middle-outwards until the width is fully used.
    $leftover = $Total - ($Count * $width) - ($gaps * $gap)
    if ($gaps -gt 0 -and $leftover -gt 0) {
        $order = New-Object System.Collections.Generic.List[int]
        $mid = [Math]::Floor(($gaps - 1) / 2)
        $order.Add($mid)
        $d = 1
        while ($order.Count -lt $gaps) {
            if (($mid + $d) -lt $gaps) { $order.Add($mid + $d) }
            if ($order.Count -lt $gaps -and ($mid - $d) -ge 0) { $order.Add($mid - $d) }
            $d++
        }
        $k = 0
        while ($leftover -gt 0) {
            $gapWidths[$order[$k % $gaps]]++
            $leftover--
            $k++
        }
    }

    $pos = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $spans.Add(@($pos, $width))
        $pos += $width
        if ($i -lt $gaps) { $pos += $gapWidths[$i] }
    }
    return , $spans
}

function Get-ScrollSpec {
    # The override's optional `scroll` block, clamped, or $null when it is absent
    # or unusable.
    #
    # ABSENT RETURNS $null RATHER THAN A ZERO-SPEED SPEC, deliberately. An
    # override with no scroll key has to render byte for byte the way it did
    # before scrolling existed, and the only way to be sure of that is for the
    # scrolling code never to run at all.
    #
    # Out-of-range values are CLAMPED, not refused. A ticker at the wrong speed
    # is still readable; a drawing that silently failed to appear is not.
    #
    # Idempotent, so it is safe to call on an override that has already been
    # normalised by Get-Override.
    param($Ov)

    if ($null -eq $Ov) { return $null }
    $raw = $null
    try { $raw = $Ov.scroll } catch { return $null }
    if ($null -eq $raw) { return $null }

    # SPEED IS A DOUBLE, and it has to be: the ceiling is 1.0 updates a second
    # and the default is 0.7, so an [int] cast would round every usable value to
    # 1 or to 0 and then clamp the 0 back up. The old code could cast to [int]
    # because a speed below 1 column a second was not worth having; a speed above
    # 1 UPDATE a second is not survivable, which is the opposite problem.
    $speed = [double]$ScrollDefaultSpeed
    $step = $ScrollDefaultStep
    $gap = $ScrollDefaultGap
    $dir = 'left'
    try { if ($null -ne $raw.speed) { $speed = [double]$raw.speed } } catch { }
    try { if ($null -ne $raw.step) { $step = [int]$raw.step } } catch { }
    try { if ($null -ne $raw.gap) { $gap = [int]$raw.gap } } catch { }
    try { if ($null -ne $raw.dir) { $dir = ([string]$raw.dir).Trim().ToLowerInvariant() } } catch { }

    if ($speed -lt $ScrollMinSpeed) { $speed = [double]$ScrollMinSpeed }
    if ($speed -gt $ScrollMaxSpeed) { $speed = [double]$ScrollMaxSpeed }
    if ($step -lt $ScrollMinStep) { $step = $ScrollMinStep }
    if ($step -gt $ScrollMaxStep) { $step = $ScrollMaxStep }
    if ($gap -lt $ScrollMinGap) { $gap = $ScrollMinGap }
    if ($gap -gt $ScrollMaxGap) { $gap = $ScrollMaxGap }
    if ($dir -ne 'right') { $dir = 'left' }

    # A canvas WIDER than the region it lands in is the entire point here, so
    # width is not checked against anything. Height is a different question:
    # there is nowhere for an extra row to go, and scrolling cannot rescue a
    # drawing that is simply too tall.
    $w = 0; $h = 0
    try { $w = [int]$Ov.w; $h = [int]$Ov.h } catch { return $null }
    if ($w -lt 1 -or $h -lt 1 -or $h -gt $MatrixH) { return $null }

    return [pscustomobject]@{ speed = $speed; step = $step; dir = $dir; gap = $gap; loop = $true }
}

function Get-ScrollOffset {
    # `dir: right` is the same walk read backwards, so the offset is negated and
    # the modulo in Set-Pixels brings it back into range. Keeping the sign here
    # means every caller can just hand over a frame counter that only goes up.
    param($Scroll, [int]$Offset)
    if ($null -ne $Scroll -and $Scroll.dir -eq 'right') { return - $Offset }
    return $Offset
}

function Get-AnimateFrameBudgetMs {
    # The shortest interval between frames the command budget can sustain, in
    # milliseconds. Derived, never typed in, because the overhead is structural:
    # a connection spends $AnimateProbeEvery commands in total and only
    # ($AnimateProbeEvery - 2) of them are frames, the other two being the arm
    # and the probe that retires it. So a frame really costs
    # $AnimateProbeEvery / ($AnimateProbeEvery - 2) commands.
    #
    # A configured speed faster than this is SLOWED to it rather than refused.
    # The alternative is a panel that runs beautifully for five seconds and then
    # freezes, which is what this whole change exists to stop.
    $frames = [Math]::Max(1, $AnimateProbeEvery - 2)
    $cmdsPerFrame = $AnimateProbeEvery / [double]$frames
    $framesPerMin = ($AnimateMaxCommandsPerMinute * $AnimatePaceFraction) / $cmdsPerFrame
    if ($framesPerMin -le 0) { return 60000 }
    return [int][Math]::Ceiling(60000.0 / $framesPerMin)
}

function Get-BudgetWaitMs {
    # How long to wait before one more command may be sent, given the times (in
    # milliseconds on any monotonic clock) of the commands already sent inside
    # the last minute. 0 means send now. PRUNES $Times in place, so the queue
    # never grows past the ceiling.
    #
    # A ROLLING WINDOW, not a per-frame delay, because the thing being protected
    # is a refill measured over a minute (58 commands spent, 51 seconds locked
    # out) rather than a rate limit that resets on a tick. A burst that fits the
    # average still exhausts the device, and only the window notices that.
    #
    # Split out and pure so it can be asserted against a simulated clock: the
    # honest test of a limiter is a run it must never exceed, and running one
    # against the real device would cost the very budget it is protecting.
    param([System.Collections.Generic.Queue[double]]$Times, [double]$NowMs, [int]$PerMinute)

    if ($PerMinute -le 0) { return 60000 }
    while ($Times.Count -gt 0 -and ($NowMs - $Times.Peek()) -ge 60000) { [void]$Times.Dequeue() }
    if ($Times.Count -lt $PerMinute) { return 0 }
    $wait = 60000 - ($NowMs - $Times.Peek())
    if ($wait -lt 0) { $wait = 0 }
    return [int][Math]::Ceiling($wait)
}

function Test-AnimatorLive {
    # FRESH, never merely present. A killed animator leaves its heartbeat behind,
    # and treating that file as a lock would wedge the light dark until somebody
    # noticed and deleted it by hand. The age is what makes a corpse harmless.
    try {
        if (-not (Test-Path -LiteralPath $AnimateFile)) { return $false }
        $age = ((Get-Date) - (Get-Item -LiteralPath $AnimateFile).LastWriteTime).TotalSeconds
        return ($age -lt $AnimateFreshSeconds)
    }
    catch { return $false }
}

function Get-AnimatorInfo {
    # pid and heartbeat age for the reporting verbs, or $null when no animator is
    # live. Same freshness rule as Test-AnimatorLive, on purpose: `status` must
    # describe the panel the hooks are actually seeing.
    try {
        if (-not (Test-Path -LiteralPath $AnimateFile)) { return $null }
        $fi = Get-Item -LiteralPath $AnimateFile
        $age = ((Get-Date) - $fi.LastWriteTime).TotalSeconds
        if ($age -ge $AnimateFreshSeconds) { return $null }
        $txt = ''
        try { $txt = (Get-Content -LiteralPath $AnimateFile -Raw -ErrorAction SilentlyContinue) } catch { }
        $ownerPid = 0
        if ($null -ne $txt) {
            $m = [regex]::Match($txt, '\d+')
            if ($m.Success) { $ownerPid = [int]$m.Value }
        }
        return [pscustomobject]@{ pid = $ownerPid; age = $age }
    }
    catch { return $null }
}

function Update-AnimatorHeartbeat {
    # Rewritten every frame. The CONTENT is for a human reading the file; the
    # timestamp is what Set-Cube actually tests.
    try { [System.IO.File]::WriteAllText($AnimateFile, ("$PID " + (Get-Date).ToString('o'))) }
    catch { }
}

function Start-Animator {
    # Nothing else starts the scroll, so the first ordinary paint that sees a
    # scrolling override launches one detached and gets on with its own frame.
    #
    # Two guards, because a spawn from a hook path could otherwise become a
    # process storm: `animate` refuses to start beside a live heartbeat, and this
    # cooldown stops an animator that dies immediately being relaunched by every
    # PreToolUse and PostToolUse in the meantime.
    if (-not $AutoAnimate) { return }
    if ([string]::IsNullOrEmpty($PSCommandPath)) { return }
    try {
        if (Test-Path -LiteralPath $AnimateSpawnFile) {
            $age = ((Get-Date) - (Get-Item -LiteralPath $AnimateSpawnFile).LastWriteTime).TotalSeconds
            if ($age -lt $AnimateSpawnCooldown) { return }
        }
        [System.IO.File]::WriteAllText($AnimateSpawnFile, (Get-Date).ToString('o'))

        # Relaunch the SAME host that is running this script. A 5.1 hook that
        # shelled out to a pwsh that is not installed, or the reverse, would fail
        # in a way nothing here could see.
        $exe = $null
        try { $exe = (Get-Process -Id $PID).Path } catch { }
        if ([string]::IsNullOrEmpty($exe)) { $exe = 'powershell.exe' }

        Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"'), 'animate') | Out-Null
        Write-Trace 'animator: spawned for scrolling override'
    }
    catch { Write-Trace ('animator: spawn failed - ' + $_.Exception.Message) }
}

function Get-Override {
    # The manual drawing, or $null. Expires it in place when it no longer
    # applies, so nothing else has to think about staleness.
    #
    # The two modes expire on different things ON PURPOSE. A takeover is a
    # deliberate "show me this instead", so ANY change to what the sessions would
    # have shown ends it. A session drawing is meant to sit alongside real work
    # for as long as that work runs, so it survives colour changes and ends only
    # when the session COUNT changes, because that is what resizes every cell and
    # would leave the drawing the wrong shape.
    param([string[]]$States)

    if (-not (Test-Path -LiteralPath $OverrideFile)) { return $null }

    try { $ov = Get-Content -LiteralPath $OverrideFile -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch {
        Write-Trace 'override: unreadable, dropping'
        Remove-Item -LiteralPath $OverrideFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    # PINNED overrides do not expire. A ticker is the case that needs it: the
    # takeover rule below ends a drawing the moment the sessions change, which is
    # right for "show me this instead" and wrong for something meant to run all
    # day. Measured 2026-09-08: a ticker survived 20 seconds and was then dropped
    # by a composition change, which from the outside looks exactly like the
    # freeze it had just stopped doing.
    #
    # The cost is real and deliberate: while a takeover is pinned, session state
    # is NOT on the panel at all. Nothing expires it, so it takes an explicit
    # clear (DELETE /api/override, or ticker.py --clear) to get the light back.
    $pinned = $false
    if ($null -ne $ov.PSObject.Properties['pin']) { $pinned = [bool]$ov.pin }

    $states = @($States)
    $drop = $null
    if ($ov.mode -eq 'takeover') {
        if (-not $pinned -and $ov.signature -ne ($states -join ',')) { $drop = 'composition changed' }
    }
    elseif ($ov.mode -eq 'session') {
        if (-not $pinned -and [int]$ov.sessions -ne $states.Count) { $drop = 'session count changed' }
    }
    else { $drop = "unknown mode '$($ov.mode)'" }

    if ($null -ne $drop) {
        Write-Trace "override: dropped ($drop)"
        Remove-Item -LiteralPath $OverrideFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Normalise the optional scroll block ONCE, here, so every reader downstream
    # gets clamped values and nothing has to re-validate. A scroll block that
    # cannot be honoured is replaced by $null rather than dropping the whole
    # override: the drawing still has something to show, it just holds still.
    #
    # Note what is NOT checked: a `w` wider than the region the drawing lands in
    # used to be nothing but a clipping accident, and with a scroll block it is
    # the point of the exercise. Only the height still has to fit.
    $hadScroll = ($null -ne $ov.PSObject.Properties['scroll']) -and ($null -ne $ov.scroll)
    $spec = Get-ScrollSpec -Ov $ov
    if ($hadScroll -and $null -eq $spec) {
        Write-Trace "override: scroll block unusable (h=$($ov.h) must be 1..$MatrixH), drawing will hold still"
    }
    Add-Member -InputObject $ov -NotePropertyName 'scroll' -NotePropertyValue $spec -Force

    return $ov
}

function Set-Pixels {
    # Blit a w*h block of raw RGB (base64) into the panel at $X0,$Y0.
    #
    # TWO PATHS, and the plain one is left exactly as it was on purpose. Without
    # -Scroll this is the original blit: anything falling outside the panel is
    # clipped rather than wrapping onto the next row, and the bytes it writes
    # must stay identical to what they were before scrolling existed, because an
    # override with no scroll block is far and away the common case.
    #
    # With -Scroll the canvas is deliberately wider than the region it is painted
    # into, and a window $RegionW wide walks across it. Source columns are taken
    # modulo ($W + $Gap), so the columns past the end of the canvas are blank:
    # that is what puts $Gap dark columns between the tail and the head, and it
    # is the difference between a ticker and a slide that runs out.
    param([byte[]]$Buf, [string]$B64, [int]$W, [int]$H, [int]$X0, [int]$Y0,
        [switch]$Scroll, [int]$RegionW = 0, [int]$Offset = 0, [int]$Gap = 0)

    try { $src = [Convert]::FromBase64String($B64) } catch { return $false }
    if ($src.Length -lt ($W * $H * 3)) { return $false }

    if (-not $Scroll) {
        for ($yy = 0; $yy -lt $H; $yy++) {
            for ($xx = 0; $xx -lt $W; $xx++) {
                $x = $X0 + $xx
                $y = $Y0 + $yy
                if ($x -lt 0 -or $x -ge $MatrixW -or $y -lt 0 -or $y -ge $MatrixH) { continue }
                $s = ((($yy * $W) + $xx) * 3)
                $o = (Get-PixelIndex -X $x -Y $y) * 3
                # Scaled like every other colour: $Brightness is the panel's
                # output level, not a property of what is being drawn.
                $Buf[$o] = [byte][int](($src[$s] * $Brightness) / 100)
                $Buf[$o + 1] = [byte][int](($src[$s + 1] * $Brightness) / 100)
                $Buf[$o + 2] = [byte][int](($src[$s + 2] * $Brightness) / 100)
            }
        }
        return $true
    }

    # Default the window to "from here to the right edge", which is what the old
    # clipping behaviour amounted to for a takeover.
    if ($RegionW -le 0) { $RegionW = $MatrixW - $X0 }
    $span = $W + $Gap
    if ($span -lt 1) { return $false }

    # PowerShell's % keeps the sign of the DIVIDEND, so a `right` scroll would
    # index off the front of the canvas without this second modulo.
    $off = ((($Offset % $span) + $span) % $span)

    for ($yy = 0; $yy -lt $H; $yy++) {
        for ($dx = 0; $dx -lt $RegionW; $dx++) {
            $x = $X0 + $dx
            $y = $Y0 + $yy
            if ($x -lt 0 -or $x -ge $MatrixW -or $y -lt 0 -or $y -ge $MatrixH) { continue }
            $o = (Get-PixelIndex -X $x -Y $y) * 3
            $sx = (($off + $dx) % $span)
            if ($sx -ge $W) {
                # A gap column. Written as black rather than skipped: this region
                # is repainted every frame, and skipping would smear the previous
                # frame's pixels through the gap.
                $Buf[$o] = 0; $Buf[$o + 1] = 0; $Buf[$o + 2] = 0
                continue
            }
            $s = ((($yy * $W) + $sx) * 3)
            $Buf[$o] = [byte][int](($src[$s] * $Brightness) / 100)
            $Buf[$o + 1] = [byte][int](($src[$s + 1] * $Brightness) / 100)
            $Buf[$o + 2] = [byte][int](($src[$s + 2] * $Brightness) / 100)
        }
    }
    return $true
}

function Get-Grid {
    # Columns and rows of session cells for $Count sessions, within a region
    # $Width wide (the whole panel unless a drawing has claimed part of it).
    #
    # ON THE FULL PANEL: one row up to three, because a third of a 20-wide panel
    # at full height reads better than a sixth of it half-height. Two rows from
    # four, which makes four sessions quadrants.
    #
    # IN A NARROW REGION the opposite is true, and the same rule would be wrong.
    # Two sessions sharing a 6-wide strip side by side are 3x5 slivers; stacked
    # they are 6x2 blocks, which match the landscape shape of the panel and read
    # far better. So a narrow region stacks first and only adds columns when it
    # runs out of rows.
    param([int]$Count, [int]$Width = $MatrixW)

    if ($Count -le 0) { return @(1, 1) }

    if ($Width -lt ($MatrixW / 2)) {
        $rows = [Math]::Min($Count, $MatrixH)
        $cols = [Math]::Ceiling($Count / $rows)
        return @($cols, $rows)
    }

    $rows = if ($Count -le 3) { 1 } else { 2 }
    while ($rows -lt $MatrixH -and [Math]::Ceiling($Count / $rows) -gt $Width) { $rows++ }
    $cols = [Math]::Ceiling($Count / $rows)
    if ($cols -lt 1) { $cols = 1 }
    return @($cols, $rows)
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
    # One equal cell per session on a grid, as base64 RGB. See Get-Grid for how
    # the grid is chosen and Get-Spans for how each axis is divided.
    #
    # $Offset is the scroll position in columns and only means anything when the
    # override carries a scroll block. It counts UP whatever the direction is;
    # Get-ScrollOffset turns it round for `dir: right`, so a caller only ever has
    # to hand over a frame counter. At 0, with no scroll block, this composes
    # exactly the frame it always did.
    param([string[]]$States, [string]$Idle = 'green', $Override = $null, [int]$Offset = 0)

    $states = @($States)
    $buf = New-Object 'byte[]' ($MatrixW * $MatrixH * 3)   # zeroed == all off
    $n = $states.Count
    if ($n -eq 0 -and $null -eq $Override) {
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
    $avail = $MatrixH - $top

    # Scrolling applies to BOTH modes, so the spec is read once here. $null means
    # a static drawing and the original blit, unchanged.
    $scroll = Get-ScrollSpec -Ov $Override

    # A takeover owns the panel outright, so nothing below runs. Scrolling, it
    # walks the canvas across the full width.
    if ($null -ne $Override -and $Override.mode -eq 'takeover') {
        if ($null -ne $scroll) {
            $ok = Set-Pixels -Buf $buf -B64 $Override.pixels -W ([int]$Override.w) -H ([int]$Override.h) `
                -X0 0 -Y0 $top -Scroll -RegionW $MatrixW `
                -Offset (Get-ScrollOffset -Scroll $scroll -Offset $Offset) -Gap ([int]$scroll.gap)
        }
        else {
            $ok = Set-Pixels -Buf $buf -B64 $Override.pixels -W ([int]$Override.w) -H ([int]$Override.h) -X0 0 -Y0 $top
        }
        if ($ok) { return [Convert]::ToBase64String($buf) }
        Write-Trace 'override: takeover pixels rejected, falling through'
    }

    # A session drawing takes a SHARE of the width, and the real sessions lay
    # themselves out inside whatever is left. The drawing is on the RIGHT because
    # sessions are ordered oldest-first from the left, so the panel keeps reading
    # left to right by age with the manual block on the end.
    $regionX0 = 0
    $regionW = $MatrixW
    if ($null -ne $Override -and $Override.mode -eq 'session') {
        $total = [int]$Override.total
        $share = [int]$Override.share
        if ($total -lt 2) { $total = 2 }
        if ($share -lt 1) { $share = 1 }
        if ($share -ge $total) { $share = $total - 1 }

        $parts = Get-Spans -Count $total -Total $MatrixW
        $sesParts = $total - $share
        $regionX0 = $parts[0][0]
        $regionW = ($parts[$sesParts - 1][0] + $parts[$sesParts - 1][1]) - $regionX0

        $drawX0 = $parts[$sesParts][0]
        $drawX1 = $parts[$total - 1][0] + $parts[$total - 1][1] - 1

        # Scrolling here is confined to the drawing's own share of the width. The
        # window is the share, NOT the rest of the panel: without an explicit
        # region the walk would run on over the sessions laid out to its left.
        if ($null -ne $scroll) {
            $ok = Set-Pixels -Buf $buf -B64 $Override.pixels -W ([int]$Override.w) -H ([int]$Override.h) `
                -X0 $drawX0 -Y0 $top -Scroll -RegionW ($drawX1 - $drawX0 + 1) `
                -Offset (Get-ScrollOffset -Scroll $scroll -Offset $Offset) -Gap ([int]$scroll.gap)
        }
        else {
            $ok = Set-Pixels -Buf $buf -B64 $Override.pixels -W ([int]$Override.w) `
                -H ([int]$Override.h) -X0 $drawX0 -Y0 $top
        }
        if (-not $ok) { Write-Trace 'override: session pixels rejected' }

        # Nothing running: the drawing is the whole point, so stop here rather
        # than painting an empty region beside it.
        if ($n -eq 0) { return [Convert]::ToBase64String($buf) }
    }

    # More sessions than cells cannot be drawn; the newest are dropped rather
    # than silently merged, which would be a lie about how many are running.
    if ($n -gt ($regionW * $avail)) { $n = $regionW * $avail }

    $grid = Get-Grid -Count $n -Width $regionW
    $cols = $grid[0]
    $gridRows = $grid[1]
    if ($gridRows -gt $avail) { $gridRows = $avail }

    # Both axes divided by the same rule, so cells are equal in both directions
    # and the leftover lands in the gaps.
    # Divided within the sessions' region, which is the whole panel unless a
    # drawing has claimed part of it.
    $xs = Get-Spans -Count $cols -Total $regionW
    $ys = Get-Spans -Count $gridRows -Total $avail

    # Reading order: oldest session top-left, filling right then down.
    for ($i = 0; $i -lt $n; $i++) {
        $cx = $i % $cols
        $cy = [Math]::Floor($i / $cols)
        if ($cy -ge $gridRows) { break }
        $sx = $xs[$cx]
        $sy = $ys[$cy]
        if ($sx[1] -le 0 -or $sy[1] -le 0) { continue }

        Set-Block -Buf $buf -X0 ($regionX0 + $sx[0]) -X1 ($regionX0 + $sx[0] + $sx[1] - 1) `
            -Y0 ($top + $sy[0]) -Y1 ($top + $sy[0] + $sy[1] - 1) `
            -Rgb (Get-Rgb $states[$i])
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

    # DEFER TO A LIVE ANIMATION. The animator repaints the whole panel every
    # frame from freshly read session state, so a hook painting here would only
    # flicker one static frame into the middle of the scroll and be overwritten
    # milliseconds later. Freshness is the entire test: a heartbeat left behind
    # by a killed animator is stale within seconds and stops mattering, which is
    # why this is not a lock.
    #
    # $false rather than $true so Set-Light unwinds its cache claim: nothing was
    # painted, and the next hook after the animation ends has to repaint.
    if (-not $script:IsAnimator -and (Test-AnimatorLive)) {
        Write-Trace 'cube: deferring, animator heartbeat is fresh'
        return $false
    }

    if ($Aggregate -eq 'off') {
        return (Send-Yeelight -Method 'set_power' -ParamsJson '["off","smooth",500]')
    }

    $ov = Get-Override -States $States
    $frame = Get-MatrixFrame -States $States -Idle $Aggregate -Override $ov

    # A scrolling override with nobody driving it would show one frozen window
    # onto the canvas, which looks like a bug rather than a feature. Start the
    # animator and push this frame anyway, so something is on the panel even if
    # the spawn fails.
    if (-not $script:IsAnimator -and $null -ne (Get-ScrollSpec -Ov $ov)) { Start-Animator }

    $conn = Open-Cube
    if ($null -eq $conn) { return $false }
    try {
        if (-not (Initialize-CubeDirect -Conn $conn)) { return $false }
        [void](Push-CubeFrame -Conn $conn -Frame $frame)
        Write-Trace ('cube: pushed frame for ' + @($States).Count + ' session(s)')
        return $true
    }
    catch { return $false }
    finally { Close-Cube $conn }
}

function Show-Status {
    # Answers "why is the light that colour" without needing a debugging session.
    "sessions:"
    $any = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue)) {
        $any = $true
        $age = ((Get-Date) - $f.LastWriteTime).TotalMinutes
        $slotState = (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $slotState) { $slotState = $slotState.Trim() }
        $limit = if ($slotState -eq 'green') { $StaleMinutes } else { $StaleMinutesActive }
        $stale = if ($age -gt $limit) { "  STALE (>$limit min), ignored" } else { '' }
        "  {0}  {1,-7}  last hook {2:n1} min ago{3}" -f $f.BaseName.Substring(0, [Math]::Min(8, $f.BaseName.Length)), (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue), $age, $stale
    }
    if (-not $any) { "  (none)" }

    "running tasks:"
    $tasks = @(Get-RunningTasks)
    if ($tasks.Count -eq 0) { "  (none)" } else { $tasks | ForEach-Object { "  $_" } }

    # Computed here, before anything reports on it, and WITHOUT -Force. An
    # earlier version forced a rescan at this point, which overwrote the busy
    # cache before Get-Picture read it: `status` then showed a different picture
    # from the one the hooks would actually paint.
    $pic = Get-Picture
    $busy = Get-BusySessions
    "busy      : " + $(if ($busy.Count -eq 0) { '(no session has a running background task)' }
        else { ($busy.Keys | Sort-Object) -join ', ' })

    $last = Get-LastActivity
    if ($null -eq $last) { "activity  : never recorded" }
    else { "activity  : {0:HH:mm:ss}, {1:n1} min ago" -f $last, ((Get-Date) - $last).TotalMinutes }
    "app       : " + $(if (Test-AppRunning) { 'desktop app running' } else { 'desktop app NOT running' })
    $reason = Get-DarkReason
    "dark      : " + $(if ($null -ne $reason) { "YES - $reason" } else { 'no' })

    "aggregate : " + $pic.Aggregate
    "cache     : " + $(if (Test-Path $CacheFile) { (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '(none)' })

    # Whether an animation is running, and on what. These verbs exist so nothing
    # else has to guess, and "the panel is moving" is not something a hook paint
    # or the cache line can tell you: while it runs, hook paints are deferring
    # and the cache is describing a frame nobody pushed.
    $anim = Get-AnimatorInfo
    if ($null -eq $anim) { "animation : not running" }
    else { "animation : running (pid {0}, heartbeat {1:n1}s ago)" -f $anim.pid, $anim.age }

    $ovScroll = Get-Override -States @($pic.Slots | ForEach-Object { $_.State })
    $scSpec = Get-ScrollSpec -Ov $ovScroll
    if ($null -eq $scSpec) { "scroll    : none (no override, or it holds still)" }
    else {
        # Both halves of the rate, because neither is the whole answer: the
        # updates are what the device is charged for and the columns are what the
        # eye sees, and the budget can slow the first without touching the second.
        "scroll    : {0:n2} update/s x {1} col = {2:n1} col/s {3}, gap {4}, canvas {5}x{6} on a {7}-wide panel" -f `
            $scSpec.speed, $scSpec.step, ($scSpec.speed * $scSpec.step), $scSpec.dir, $scSpec.gap,
        $ovScroll.w, $ovScroll.h, $MatrixW
        $bMs = Get-AnimateFrameBudgetMs
        $wantMs = [int][Math]::Round(1000.0 / [double]$scSpec.speed)
        if ($wantMs -lt $bMs) {
            "            budget slows this to {0:n2} update/s ({1}ms): {2} cmd/min ceiling" -f `
            (1000.0 / $bMs), $bMs, $AnimateMaxCommandsPerMinute
        }
    }

    # What the panel is being asked to render, which is not the same thing as
    # the aggregate.
    $states = @($pic.Slots | ForEach-Object { $_.State })
    $n = $states.Count
    if ($n -eq 0) { "display   : all off (no live sessions)" }
    else {
        $avail = $MatrixH - $(if ($SummaryRow) { 1 } else { 0 })

        # The manual drawing is part of what is on the panel, so it has to be
        # part of what `status` describes. Reporting the session count alone
        # would disagree with the panel whenever a drawing is up.
        $ovs = Get-Override -States $states
        if ($null -ne $ovs -and $ovs.mode -eq 'takeover') {
            "display   : manual drawing, whole panel ($($ovs.w)x$($ovs.h))"
            "            clears when the session composition changes"
            return
        }

        $regionW = $MatrixW
        if ($null -ne $ovs -and $ovs.mode -eq 'session') {
            $ps = Get-Spans -Count ([int]$ovs.total) -Total $MatrixW
            $sesParts = [int]$ovs.total - [int]$ovs.share
            $regionW = ($ps[$sesParts - 1][0] + $ps[$sesParts - 1][1]) - $ps[0][0]
            "display   : drawing takes $($ovs.share)/$($ovs.total) on the right ($($ovs.w)x$($ovs.h))"
            "            $n session(s) share the left ${regionW} of $MatrixW columns"
        }

        $grid = Get-Grid -Count $n -Width $regionW
        $cols = $grid[0]; $gridRows = [Math]::Min($grid[1], $avail)
        $xs = Get-Spans -Count $cols -Total $regionW
        $ys = Get-Spans -Count $gridRows -Total $avail
        $cells = $cols * $gridRows
        $where = if ($regionW -eq $MatrixW) { 'display   : ' } else { '            ' }
        "$where$n session(s) on a ${cols}x${gridRows} grid, cells $($xs[0][1])x$($ys[0][1]), oldest top-left"
        if ($cells -gt $n) { "            $($cells - $n) spare cell(s) left dark" }
        for ($r = 0; $r -lt $gridRows; $r++) {
            $row = @()
            for ($c = 0; $c -lt $cols; $c++) {
                $i = ($r * $cols) + $c
                $row += $(if ($i -lt $states.Count) { $states[$i] }
                    elseif ($i -lt $n) { 'DRAWING' } else { '-' })
            }
            "            [" + ($row -join ' ') + "]"
        }
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
    # sweep. Files older than $TaskScanMaxAgeHours are skipped without being
    # opened, which is most of them.
    param([switch]$StopAtFirst)

    $found = New-Object System.Collections.Generic.List[string]
    $root = Join-Path $env:TEMP 'claude'
    if (-not (Test-Path -LiteralPath $root)) { return $found }
    $cut = (Get-Date).AddHours(-$TaskScanMaxAgeHours)

    foreach ($proj in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($sess in @(Get-ChildItem -LiteralPath $proj.FullName -Directory -ErrorAction SilentlyContinue)) {
            $tasks = Join-Path $sess.FullName 'tasks'
            if (-not (Test-Path -LiteralPath $tasks)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $tasks -Filter '*.output' -File -ErrorAction SilentlyContinue)) {
                # Newer of the two: a task that has printed nothing still has a
                # fresh creation time, and would otherwise be skipped while live.
                $newest = if ($f.LastWriteTime -gt $f.CreationTime) { $f.LastWriteTime } else { $f.CreationTime }
                if ($newest -lt $cut) { continue }

                $locked = $false
                try {
                    $fs = [System.IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'None')
                    $fs.Close()
                }
                # A file that VANISHED is not a running task. Anything else that
                # stops us opening a file we just enumerated means something else
                # has it, which is exactly what we are looking for.
                #
                # UnauthorizedAccessException used to be swallowed here as
                # "cannot be reached", and that was the bug: a genuinely held
                # task file reported access-denied rather than sharing-violation
                # (observed on a live 13-minute suite, while a probe from another
                # process saw a plain sharing violation on the SAME file at the
                # same moment). Treating that as idle made a working session go
                # green. Access denied on a file that is sitting right there is
                # not evidence of idleness.
                catch [System.IO.FileNotFoundException] { }
                catch [System.IO.DirectoryNotFoundException] { }
                catch [System.UnauthorizedAccessException] { $locked = $true }
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

    if ($idle -ge $DarkAfterMinutes) {
        # Quiet is not the same as finished. A session running a long background
        # task fires no hooks while it runs, and a session waiting on
        # confirmation fires one and then nothing until it is answered. Timing
        # either out would turn the light off precisely when it has something to
        # say, so the idle timeout only applies when every session is green.
        #
        # The app-closed check above still wins: if the app is gone there is
        # nobody to answer the prompt anyway.
        $agg = (Get-Picture).Aggregate
        if ($agg -ne 'green') { return $null }
        return ('idle {0:n0} min' -f $idle)
    }
    return $null
}

function Get-BusySessions {
    # Sessions with a backgrounded command still running, as a hashtable keyed by
    # the short session id.
    #
    # Get-RunningTasks walks every session's task directory and is far too
    # expensive to run on each PreToolUse and PostToolUse, so the result is
    # cached for $TaskCacheSeconds. That is the price of needing the answer on
    # every hook instead of only when everything looked idle.
    param([switch]$Force)

    if (-not $Force -and (Test-Path -LiteralPath $TaskCacheFile)) {
        try {
            $age = ((Get-Date) - (Get-Item -LiteralPath $TaskCacheFile).LastWriteTime).TotalSeconds
            if ($age -lt $TaskCacheSeconds) {
                $cached = @{}
                foreach ($line in @(Get-Content -LiteralPath $TaskCacheFile -ErrorAction SilentlyContinue)) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { $cached[$line.Trim()] = $true }
                }
                return $cached
            }
        }
        catch { }
    }

    $busy = @{}
    foreach ($t in @(Get-RunningTasks)) { $busy[($t -split '/')[0]] = $true }
    # Written even when empty: the file's timestamp IS the cache, so skipping the
    # write on "no tasks" would rescan on every single hook.
    try { Set-Content -LiteralPath $TaskCacheFile -Value ($busy.Keys -join "`n") -NoNewline }
    catch { }
    return $busy
}

function Get-Picture {
    # The whole state of the world in one pass: one slot per live session,
    # ordered oldest first, plus the worst-wins aggregate over all of them.
    $slots = New-Object System.Collections.Generic.List[object]
    $cutIdle = (Get-Date).AddMinutes(-$StaleMinutes)
    $cutActive = (Get-Date).AddMinutes(-$StaleMinutesActive)

    # Oldest first: CreationTime is when the session fired its FIRST hook, and
    # Set-Content on an existing file leaves it alone, so a session holds its
    # position for life. Name breaks ties so the order is never arbitrary.
    $files = @(Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime, Name)
    foreach ($f in $files) {
        # Read BEFORE deciding to sweep: how long a slot may sit silent depends
        # on what it says. An idle session is forgotten after $StaleMinutes, but
        # a working or waiting one is kept for $StaleMinutesActive, because
        # silence is what those states look like from the outside.
        $s = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $s) { continue }
        $s = $s.Trim()
        if (-not $Priority.ContainsKey($s)) { continue }

        $cut = if ($s -eq 'green') { $cutIdle } else { $cutActive }
        if ($f.LastWriteTime -lt $cut) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $slots.Add([pscustomobject]@{
                Key   = $f.BaseName.Substring(0, [Math]::Min(8, $f.BaseName.Length))
                State = $s
            })
    }

    # A session that ended its turn but left a backgrounded command running is
    # still working, and its block has to say so.
    #
    # THIS RUNS ALWAYS, not only when the whole picture looks idle. It used to be
    # gated on the aggregate being green, which was right when the light showed a
    # single worst-wins colour: the only question was whether green was really
    # green. With one block per session that gate is wrong, and wrong silently --
    # a session sitting green with a live background task kept its green block
    # for as long as ANY OTHER session was yellow, because the other session's
    # yellow made the aggregate yellow and suppressed the scan entirely.
    $busy = Get-BusySessions
    if ($busy.Count -gt 0) {
        # Only green is promoted. A session waiting on confirmation is red and
        # stays red: red outranks working.
        foreach ($sl in $slots) {
            if ($sl.State -eq 'green' -and $busy.ContainsKey($sl.Key)) { $sl.State = 'yellow' }
        }
        # A task can outlive the session slot that started it. Still work.
        foreach ($k in $busy.Keys) {
            if (-not ($slots | Where-Object { $_.Key -eq $k })) {
                $slots.Add([pscustomobject]@{ Key = $k; State = 'yellow' })
            }
        }
    }

    # Aggregate last, over the slots as finally decided, so a promoted session
    # counts toward it.
    $best = 'green'
    foreach ($sl in $slots) { if ($Priority[$sl.State] -gt $Priority[$best]) { $best = $sl.State } }

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
    $ov = Get-Override -States $states
    $ovKey = if ($null -eq $ov) { '' } else { ':ov=' + $ov.mode + '/' + $ov.stamp }
    if ($states.Count -eq 0 -and $ovKey -eq '') { return "cube:none:$Want" }
    return 'cube:bands:' + ($states -join ',') + $ovKey
}

function Set-Light {
    param([string]$Want, $Slots)

    $key = Get-CacheKey -Want $Want -Slots $Slots

    # Skip when the light already shows this AND we pushed recently. PreToolUse
    # and PostToolUse fire constantly, so without the cache the light would take
    # a TCP connection per tool call. But the cache is only a belief about a
    # device that cannot be read back, so it expires: see $ReassertSeconds.
    if (Test-Path $CacheFile) {
        $last = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $last -and $last.Trim() -eq $key) {
            $age = ((Get-Date) - (Get-Item $CacheFile).LastWriteTime).TotalSeconds
            if ($age -lt $ReassertSeconds) { return }
            Write-Trace ('re-asserting after {0:n0}s' -f $age)
        }
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

if ($State -eq 'layout') {
    # What the editor needs to draw the right shape, so the layout maths lives
    # here only. `cell` is the size a drawing gets in session mode, which is the
    # cell for one MORE session than are currently running.
    $pic = Get-Picture
    $states = @($pic.Slots | ForEach-Object { $_.State })
    $avail = $MatrixH - $(if ($SummaryRow) { 1 } else { 0 })

    function Get-CellSize {
        param([int]$Count)
        if ($Count -le 0) { return @{ w = $MatrixW; h = $avail; cols = 0; rows = 0 } }
        $g = Get-Grid -Count $Count
        $r = [Math]::Min($g[1], $avail)
        $xs = Get-Spans -Count $g[0] -Total $MatrixW
        $ys = Get-Spans -Count $r -Total $avail
        return @{ w = $xs[0][1]; h = $ys[0][1]; cols = $g[0]; rows = $r }
    }

    $ov = Get-Override -States $states
    [pscustomobject]@{
        panel     = @{ w = $MatrixW; h = $MatrixH; usable_h = $avail }
        sessions  = @($pic.Slots | ForEach-Object { @{ key = $_.Key; state = $_.State } })
        aggregate = $pic.Aggregate
        current   = Get-CellSize -Count $states.Count
        # Every split the editor can offer, with the canvas each would give.
        # share/total parts go to the drawing, the rest to the sessions.
        #
        # ONLY REDUCED FRACTIONS, and ordered by how much of the panel they take.
        # Generating every share/total pair produced 2/4 alongside 1/2, which is
        # the same split written twice, and left the list in denominator order
        # rather than size order.
        splits    = @(
            $seen = @{}
            $out = foreach ($t in 2..4) {
                foreach ($sh in 1..($t - 1)) {
                    $a = $sh; $b = $t
                    while ($b -ne 0) { $tmp = $b; $b = $a % $b; $a = $tmp }
                    if ($a -ne 1) { continue }          # not in lowest terms
                    $key = "$sh/$t"
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true

                    $ps = Get-Spans -Count $t -Total $MatrixW
                    $x0 = $ps[$t - $sh][0]
                    $x1 = $ps[$t - 1][0] + $ps[$t - 1][1] - 1
                    [pscustomobject]@{
                        share = $sh; total = $t; w = ($x1 - $x0 + 1); h = $avail
                        label = "$sh/$t of the panel"
                        frac  = ($sh / $t)
                    }
                }
            }
            $out | Sort-Object frac
        )
        canvas    = @{
            takeover = @{ w = $MatrixW; h = $avail }
            session  = Get-CellSize -Count ($states.Count + 1)
        }
        colors     = $CubeColors
        brightness = $Brightness
        override   = $(if ($null -eq $ov) { $null } else { @{ mode = $ov.mode; w = $ov.w; h = $ov.h; stamp = $ov.stamp } })
        # The scroll block AS CLAMPED, not as written: the editor should be shown
        # what will actually happen, not what it asked for. Bounds are included
        # so it can range its own controls without hardcoding them here twice.
        scroll     = $(
            $sc = Get-ScrollSpec -Ov $ov
            if ($null -eq $sc) { $null } else { @{ speed = $sc.speed; dir = $sc.dir; gap = $sc.gap; loop = $true } }
        )
        scroll_limits = @{
            speed_min = $ScrollMinSpeed; speed_max = $ScrollMaxSpeed; speed_default = $ScrollDefaultSpeed
            gap_min   = $ScrollMinGap; gap_max = $ScrollMaxGap; gap_default = $ScrollDefaultGap
            dirs      = @('left', 'right')
        }
        # Whether the resident loop is actually driving the panel right now.
        animating  = $(
            $ai = Get-AnimatorInfo
            if ($null -eq $ai) { $null } else { @{ pid = $ai.pid; heartbeat_age = [Math]::Round($ai.age, 2) } }
        )
        dark       = Get-DarkReason
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

if ($State -eq 'prune') {
    # Delete task .output files older than $TaskPruneDays, skipping any that are
    # still held: a locked file is a running command whatever its age says.
    $root = Join-Path $env:TEMP 'claude'
    if (-not (Test-Path -LiteralPath $root)) { "no task root at $root"; exit 0 }
    $cut = (Get-Date).AddDays(-$TaskPruneDays)
    $n = 0; $bytes = 0; $skipped = 0; $seen = 0

    foreach ($proj in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($sess in @(Get-ChildItem -LiteralPath $proj.FullName -Directory -ErrorAction SilentlyContinue)) {
            $tasks = Join-Path $sess.FullName 'tasks'
            if (-not (Test-Path -LiteralPath $tasks)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $tasks -Filter '*.output' -File -ErrorAction SilentlyContinue)) {
                $seen++
                $newest = if ($f.LastWriteTime -gt $f.CreationTime) { $f.LastWriteTime } else { $f.CreationTime }
                if ($newest -ge $cut) { continue }
                # Never delete something still open, however old it looks.
                try { $h = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $h.Close() }
                catch { $skipped++; continue }
                $size = $f.Length
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++; $bytes += $size }
                catch { $skipped++ }
            }
        }
    }
    "scanned $seen task files, older than $TaskPruneDays days: deleted $n ({0:n1} MB), skipped $skipped" -f ($bytes / 1MB)
    Write-Trace "prune: deleted $n skipped $skipped of $seen"
    exit 0
}

if ($State -eq 'status') { Show-Status; exit 0 }

if ($State -eq 'animate') {
    # THE RESIDENT LOOP. Everything else in this script is a short-lived process
    # that paints once and exits; this one stays and pushes frames.
    #
    # It holds ONE connection for the whole run. That is not an optimisation: the
    # firmware arms direct mode per connection, so arming on one socket and
    # pushing on another is answered with "illegal request", and reconnecting
    # costs about 150ms, which at any readable scroll rate is most of the frame
    # budget. See Open-Cube.
    $script:IsAnimator = $true

    if (Test-AnimatorLive) {
        # Two animators would push interleaved frames from independently
        # advancing offsets, and the panel would stutter rather than scroll.
        $other = Get-AnimatorInfo
        "already animating (pid {0}, heartbeat {1:n1}s ago), nothing to do" -f $other.pid, $other.age
        Write-Trace 'animate: refused, another animator is live'
        exit 0
    }
    Remove-Item -LiteralPath $AnimateStopFile -Force -ErrorAction SilentlyContinue

    $pic = Get-Picture
    $states = @($pic.Slots | ForEach-Object { $_.State })
    $ov = Get-Override -States $states
    $scroll = Get-ScrollSpec -Ov $ov
    if ($null -eq $scroll) {
        "no scrolling override to animate"
        Write-Trace 'animate: nothing to animate'
        exit 0
    }

    "animating $($ov.mode) $($ov.w)x$($ov.h) at $($scroll.speed) update/s x $($scroll.step) col $($scroll.dir), gap $($scroll.gap)"
    Write-Trace ("animate: start mode=$($ov.mode) canvas=$($ov.w)x$($ov.h) " +
        "speed=$($scroll.speed) step=$($scroll.step) dir=$($scroll.dir) gap=$($scroll.gap)")

    # Consecutive connect-or-arm failures, for the backoff. A device that has
    # decided to stop answering needs to be LEFT ALONE to recover, and retrying
    # flat out at the frame rate is the one behaviour guaranteed to keep it
    # quiet. This is the SHORT backoff, for a socket that would not open or an
    # arm that went unanswered; a quota refusal is a different failure with a
    # different cure and gets $AnimateQuotaBackoffMs instead.
    $failures = 0
    function Get-Backoff {
        param([int]$N)
        $ms = 500 * [Math]::Pow(2, [Math]::Min($N, 4))   # 0.5s, 1, 2, 4, 8s and hold
        return [int][Math]::Min($ms, 8000)
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # THE BUDGET. Every command this loop sends is stamped into this queue and
    # Get-BudgetWaitMs holds the loop when a minute's worth is already in flight.
    # It counts FRAMES, PROBES AND ARMS alike, because the device counts them
    # alike: a limiter that only paced the frames would be describing a rate the
    # device never sees.
    $cmdTimes = New-Object 'System.Collections.Generic.Queue[double]'
    $script:animCmdCount = 0
    function Wait-CubeBudget {
        # Block until there is room for one more command, then record it. Called
        # immediately BEFORE each send, never after: recording a command that has
        # not gone yet is the safe direction to be wrong in.
        param([string]$What = 'command')
        $said = $false
        while ($true) {
            $w = Get-BudgetWaitMs -Times $cmdTimes -NowMs $sw.Elapsed.TotalMilliseconds `
                -PerMinute $AnimateMaxCommandsPerMinute
            if ($w -le 0) { break }
            if (-not $said) {
                Write-Trace ("animate: budget full ({0}/min), holding {1}ms before {2}" -f `
                        $AnimateMaxCommandsPerMinute, $w, $What)
                $said = $true
            }
            Start-Sleep -Milliseconds ([Math]::Min($w, 1000))
        }
        [void]$cmdTimes.Enqueue($sw.Elapsed.TotalMilliseconds)
        $script:animCmdCount++
    }

    # The floor the budget puts under the frame interval, and the frame interval
    # itself. A speed the budget cannot afford is SLOWED, and said so in the
    # trace: a ticker running slower than asked is still a ticker, and a ticker
    # that spends the device's whole minute is a frozen panel plus a status light
    # that can no longer paint.
    $minFrameMs = Get-AnimateFrameBudgetMs
    function Get-FrameMs {
        param($Sc)
        $want = [int][Math]::Round(1000.0 / [double]$Sc.speed)
        if ($want -lt $minFrameMs) {
            # The concatenation is parenthesised because -f BINDS TIGHTER THAN +:
            # without the brackets it formats only the last literal and the {0}
            # in the first one is printed verbatim.
            Write-Trace (("animate: {0:n2} update/s wants {1}ms, budget allows {2}ms " +
                    "({3} cmd/min ceiling) - slowing to the budget") -f $Sc.speed, $want, $minFrameMs,
                $AnimateMaxCommandsPerMinute)
            return $minFrameMs
        }
        return $want
    }

    $conn = $null
    $offset = 0          # COLUMNS, and it now moves by $step rather than by one
    $frames = 0
    $connCmds = 0        # commands spent on the connection currently held
    $poweredOn = $false
    $holdUntilMs = -1.0  # quota lockout: no commands at all until the clock passes this
    $stateAt = Get-Date
    $exitReason = 'stopped'
    $intervals = New-Object 'System.Collections.Generic.List[double]'
    $lastFrameMs = -1.0
    $nextMs = 0.0
    $step = [int]$scroll.step
    $frameMs = Get-FrameMs $scroll
    $prevSpeed = [double]$scroll.speed
    $prevStep = $step
    Write-Trace (("animate: pacing {0}ms/update, {1} col/update, ceiling {2} cmd/min, " +
            "probe+rotate every {3} commands") -f $frameMs, $step, $AnimateMaxCommandsPerMinute, $AnimateProbeEvery)

    try {
        while ($true) {
            # ---- re-read the world, about once a second ----------------------
            # Hook paints are deferring to this process, so nothing else is going
            # to notice a session starting, finishing or turning red. The SAME
            # functions the hook path uses are called here, which is what keeps
            # the rules intact: yellow and red never time out, $IdleDark still
            # applies, and Get-DarkReason still owns every reason to go out.
            if (((Get-Date) - $stateAt).TotalSeconds -ge $AnimateStateSeconds) {
                $stateAt = Get-Date

                if (Test-Path -LiteralPath $AnimateStopFile) {
                    Remove-Item -LiteralPath $AnimateStopFile -Force -ErrorAction SilentlyContinue
                    $exitReason = 'asked to stop'
                    break
                }

                $dark = Get-DarkReason
                if ($null -ne $dark) { $exitReason = "dark ($dark)"; break }

                $pic = Get-Picture
                $states = @($pic.Slots | ForEach-Object { $_.State })
                $ov = Get-Override -States $states
                $scroll = Get-ScrollSpec -Ov $ov
                if ($null -eq $scroll) { $exitReason = 'override gone, expired, or no longer scrolling'; break }

                # The editor can change the speed or the step under a running
                # animation. Recomputed only on an actual change, so the "slowing
                # to the budget" trace is one line per change rather than one a
                # second for as long as the ticker runs.
                if ([double]$scroll.speed -ne $prevSpeed -or [int]$scroll.step -ne $prevStep) {
                    $prevSpeed = [double]$scroll.speed
                    $prevStep = [int]$scroll.step
                    $step = $prevStep
                    $frameMs = Get-FrameMs $scroll
                    Write-Trace ("animate: respaced to {0}ms/update, {1} col/update" -f $frameMs, $step)
                }
            }

            # ---- a quota lockout is served by WAITING -------------------------
            # Nothing is sent at all while this holds, not even a probe. The cap
            # that was hit is the client-level one and it refills on a clock (51
            # seconds measured), so every command sent in the meantime is a
            # command that does not land and may push the refill further out.
            # The state re-read above still runs, so a stop request, the override
            # going away and the panel going dark are all still noticed.
            #
            # The heartbeat is deliberately NOT refreshed here. It goes stale
            # within seconds, hook paints stop deferring, and that is correct: a
            # process that is not painting must not hold the panel.
            if ($holdUntilMs -gt $sw.Elapsed.TotalMilliseconds) {
                Start-Sleep -Milliseconds 250
                continue
            }
            if ($holdUntilMs -ge 0) {
                $holdUntilMs = -1.0
                $nextMs = $sw.Elapsed.TotalMilliseconds   # resync the pacing after the wait
                Write-Trace 'animate: quota backoff over, resuming'
            }

            # ---- connection, armed one command at a time ----------------------
            if ($null -eq $conn) {
                $conn = Open-Cube
                if ($null -eq $conn) { Start-Sleep -Milliseconds (Get-Backoff $failures); $failures++; continue }
                $connCmds = 0

                # set_power on the FIRST connection only. It is there to recover a
                # panel someone switched off in the Yeelight app, which is a
                # start-of-run question; paying it again on every rotation would
                # spend one frame in twenty asking a panel that is visibly being
                # written to whether it is on.
                if (-not $poweredOn) {
                    Wait-CubeBudget 'set_power'
                    [void](Send-CubeJson -Conn $conn -Json '{"id":1,"method":"set_power","params":["on","smooth",300]}' -Read $true)
                    $connCmds++
                    $poweredOn = $true
                }

                # Arming IS the quota probe: activate_fx_mode is the command that
                # replies, so the arm doubles as the answer to "is this socket
                # being served".
                Wait-CubeBudget 'arm'
                $armState = Test-CubeQuota -Conn $conn
                $connCmds++
                if ($armState -eq 'quota') {
                    # A FRESH connection refused means the client-level cap is
                    # spent, not this socket's. Reconnecting cannot help; only the
                    # refill can.
                    Write-Trace ("animate: fresh connection refused on quota, backing off {0}ms" -f $AnimateQuotaBackoffMs)
                    Close-Cube $conn; $conn = $null
                    $holdUntilMs = $sw.Elapsed.TotalMilliseconds + $AnimateQuotaBackoffMs
                    continue
                }
                if ($armState -ne 'ok') {
                    Close-Cube $conn; $conn = $null
                    Start-Sleep -Milliseconds (Get-Backoff $failures)
                    $failures++
                    continue
                }
                $failures = 0
                Write-Trace 'animate: connected and armed'
            }

            # ---- one frame ---------------------------------------------------
            Wait-CubeBudget 'frame'
            $frame = Get-MatrixFrame -States $states -Idle $pic.Aggregate -Override $ov -Offset $offset
            $pushed = Push-CubeFrame -Conn $conn -Frame $frame
            $connCmds++
            if (-not $pushed) {
                # A socket error is the only failure a PUSH can report, because
                # update_leds never replies: a frame refused on quota looks
                # exactly like a frame that landed. That is what the probe below
                # is for, and it is why this branch is about broken sockets only.
                Write-Trace 'animate: push failed, reconnecting'
                Close-Cube $conn; $conn = $null
                Start-Sleep -Milliseconds (Get-Backoff $failures)
                $failures++
                continue
            }

            # The heartbeat goes down AFTER a successful push, so it only ever
            # claims the panel while frames are genuinely landing.
            Update-AnimatorHeartbeat
            $offset += $step
            $frames++

            # ---- probe, then retire the connection ---------------------------
            # ONE command that actually answers, ON THE SOCKET THE FRAMES WENT
            # DOWN. It says whether the frames just pushed were being served, and
            # it is the only thing that can: a probe on a new socket gets a new
            # budget and always says yes.
            if ($connCmds -ge ($AnimateProbeEvery - 1)) {
                Wait-CubeBudget 'probe'
                $probe = Test-CubeQuota -Conn $conn
                $connCmds++
                if ($probe -eq 'quota') {
                    # Frames pushed since the refusal began were discarded and the
                    # panel has been frozen on the last one that landed. Nothing
                    # can recover those; what matters is saying so, because a
                    # frozen panel with a healthy-looking log is the exact failure
                    # this instrument exists to end.
                    Write-Trace (("animate: QUOTA on the pushing connection after {0} commands, " +
                            "frames since the last probe may not have rendered") -f $connCmds)
                }
                elseif ($probe -ne 'ok') {
                    Write-Trace 'animate: probe went unanswered on the pushing connection'
                }
                # Rotate either way. The connection has spent its budget: keeping
                # it would mean pushing into a socket whose remaining credit is
                # unknown and unreadable.
                Close-Cube $conn; $conn = $null
            }

            if ($AnimateProfile) {
                $nowMs = $sw.Elapsed.TotalMilliseconds
                if ($lastFrameMs -ge 0) { [void]$intervals.Add($nowMs - $lastFrameMs) }
                $lastFrameMs = $nowMs
            }

            # Paced against a stopwatch rather than by sleeping a fixed amount,
            # because composing and pushing a frame is not free and the drift
            # would otherwise accumulate into a visibly slow ticker.
            $nextMs += $frameMs
            $wait = [int]($nextMs - $sw.Elapsed.TotalMilliseconds)
            if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
            elseif ($wait -lt -1000) { $nextMs = $sw.Elapsed.TotalMilliseconds }   # fell far behind, resync
        }
    }
    catch {
        $exitReason = 'error: ' + $_.Exception.Message
        Write-Trace ('animate EXCEPTION line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.Exception.Message)
    }
    finally {
        if ($null -ne $conn) { Close-Cube $conn }
        # Released before the final paint, so that paint is an ordinary one and
        # does not defer to a heartbeat this process has already abandoned.
        Remove-Item -LiteralPath $AnimateFile -Force -ErrorAction SilentlyContinue
    }

    # The SUSTAINED COMMAND RATE, which is the number the device cares about and
    # the one no earlier version of this loop could state. Frames alone would
    # understate it by every probe and every arm.
    $ranMin = [Math]::Max(0.0001, $sw.Elapsed.TotalMinutes)
    $rate = $script:animCmdCount / $ranMin
    Write-Trace (("animate: exit after $frames frame(s), $offset column(s), " +
            "$script:animCmdCount command(s) in {0:n1}s = {1:n1} cmd/min " +
            "(ceiling $AnimateMaxCommandsPerMinute) ($exitReason)") -f $sw.Elapsed.TotalSeconds, $rate)
    "stopped after $frames frame(s) / $offset column(s): $exitReason"
    "  {0} command(s) in {1:n1}s = {2:n1} cmd/min against a {3} ceiling" -f `
        $script:animCmdCount, $sw.Elapsed.TotalSeconds, $rate, $AnimateMaxCommandsPerMinute

    if ($AnimateProfile -and $intervals.Count -gt 2) {
        # What a stutter looks like in numbers: the median sits on the frame
        # budget while p95 and max run far past it. Even pacing keeps them close.
        $sorted = @($intervals | Sort-Object)
        $pick = { param($q) $sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Floor($sorted.Count * $q))] }
        $late = @($intervals | Where-Object { $_ -gt ($frameMs * 1.5) }).Count
        $summary = ("animate timing: n={0} budget={1}ms min={2:n0} p50={3:n0} p95={4:n0} max={5:n0} late(>1.5x)={6} ({7:n1}%)" -f `
            $intervals.Count, $frameMs, $sorted[0], (& $pick 0.5), (& $pick 0.95), $sorted[-1],
            $late, (100.0 * $late / $intervals.Count))
        Write-Trace $summary
        $summary
    }

    # ONE final ordinary paint, so the panel is left showing the current picture
    # rather than whatever frame the loop happened to stop on. The cache is
    # dropped first: it is only ever a belief about a panel that cannot be read
    # back, and this process has been pushing frames it never saw, so leaving it
    # in place could skip the repaint entirely.
    Remove-Item -LiteralPath $CacheFile -Force -ErrorAction SilentlyContinue
    $dark = Get-DarkReason
    if ($null -ne $dark) { Set-Light -Want 'off' -Slots $null }
    else {
        $pic = Get-Picture
        Set-Light -Want $pic.Aggregate -Slots $pic.Slots
    }
    exit 0
}

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
