# watch-app.ps1 - sits resident and darkens the status light the moment the
# Claude desktop app exits.
#
# WHY THIS EXISTS SEPARATELY FROM THE WATCHDOG. A Scheduled Task cannot repeat
# more often than once a minute, so the periodic `status-light.ps1 watchdog` can
# be up to a minute late, and the activity grace pushes that out further. Closing
# the app measurably left the panel lit for about four minutes. Watching the
# process table every couple of seconds costs almost nothing and makes it
# instant.
#
# The app EXITING is a much stronger signal than "the app is not running", which
# is why this darkens on the transition without consulting the activity grace.
# The grace exists so that terminal-only Claude Code use is not blacked out
# mid-task by a periodic check; if terminal work really is still going here, its
# very next hook repaints the panel within seconds.
#
# Only the transition acts. A machine where the app is simply never open does
# nothing at all, rather than rewriting "off" every two seconds.
#
# Started by install-watchdog.ps1. Safe to run by hand; a second instance exits
# immediately.

param(
    [int]$PollSeconds = 2,        # how fast an app close is noticed
    [int]$IdleCheckSeconds = 20   # how often the full dark check runs
)

$ErrorActionPreference = 'Continue'

$Script = Join-Path $PSScriptRoot 'status-light.ps1'
if (-not (Test-Path -LiteralPath $Script)) { throw "status-light.ps1 not found next to this script ($Script)" }

$AppPathMatch = '\\WindowsApps\\Claude'
$TraceFile = Join-Path $env:TEMP 'claude-status-light-trace.log'

function Write-Trace {
    param([string]$Msg)
    try { [System.IO.File]::AppendAllText($TraceFile, ((Get-Date).ToString('HH:mm:ss.fff') + "  pid=$PID  watch-app: " + $Msg + "`n")) }
    catch { }
}

function Test-AppRunning {
    # Path match, not name: the Claude Code CLI is also claude.exe and must not
    # count, or closing the desktop app while a terminal session runs would look
    # like nothing changed. .Path throws for other users' processes, which just
    # means it is not ours.
    foreach ($p in @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -match $AppPathMatch) { return $true } } catch { }
    }
    return $false
}

function Invoke-StatusLight {
    param([string]$Verb)
    # Run detached-ish and never let a failure kill the loop: this process has to
    # outlive anything that goes wrong inside a single check.
    try {
        & powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden `
            -ExecutionPolicy Bypass -File $Script $Verb 2>&1 | Out-Null
    }
    catch { Write-Trace ("invoke $Verb failed: " + $_.Exception.Message) }
}

# Single instance. The Scheduled Task already guards this with IgnoreNew, but a
# manual run should not end up with two loops fighting over the panel.
$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeStatusLightWatchApp')
$held = $false
try { $held = $mutex.WaitOne(0) } catch { $held = $false }
if (-not $held) { Write-Trace 'another instance already running, exiting'; exit 0 }

Write-Trace "started (poll ${PollSeconds}s, idle check ${IdleCheckSeconds}s)"

try {
    $wasRunning = Test-AppRunning
    $lastIdleCheck = Get-Date

    while ($true) {
        Start-Sleep -Seconds $PollSeconds

        $isRunning = Test-AppRunning

        if ($wasRunning -and -not $isRunning) {
            # The transition we exist for. `off` with no stdin is the manual
            # path, which pushes the light without touching the session slots,
            # so a session that survives the app closing keeps its place.
            Write-Trace 'desktop app EXITED -> darkening now'
            Invoke-StatusLight -Verb 'off'
        }
        elseif (-not $wasRunning -and $isRunning) {
            # Reopened. Do not paint anything: there is nothing to show until a
            # session actually starts, and its SessionStart hook will do it.
            Write-Trace 'desktop app started'
        }

        $wasRunning = $isRunning

        # The periodic dark check still runs here so the idle timeout is caught
        # within seconds rather than waiting on the Scheduled Task tick. The
        # watchdog no-ops when nothing changed, so this is nearly free.
        if (((Get-Date) - $lastIdleCheck).TotalSeconds -ge $IdleCheckSeconds) {
            $lastIdleCheck = Get-Date
            Invoke-StatusLight -Verb 'watchdog'
        }
    }
}
finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Write-Trace 'exiting'
}
