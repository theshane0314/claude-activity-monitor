# install-watchdog.ps1 - register the Scheduled Task that keeps the status light
# honest about nothing happening.
#
# The light goes off when the Claude desktop app is closed, when no session is
# live, or when no hook has fired in $DarkAfterMinutes. NONE of that can be
# noticed by a hook, because those conditions ARE the absence of hook events: if
# nothing is running, nothing fires, and the panel would sit showing the last
# thing it was told forever.
#
# The task launches watch-app.ps1, which sits resident: it polls for the desktop
# app every couple of seconds so a close is instant, and runs the full dark check
# every 20 seconds. An earlier version had the task call `status-light.ps1
# watchdog` directly on a timer instead, but a Scheduled Task cannot repeat more
# often than once a minute, and closing the app measurably left the panel lit for
# about four minutes.
#
# The task repeats anyway, as a SUPERVISOR: the resident watcher runs forever, so
# MultipleInstances=IgnoreNew means each tick is skipped harmlessly while it is
# alive, and the first tick after it dies restarts it. That is the whole recovery
# story, and it needs no extra moving parts.
#
# Run with -Remove to unregister and stop the watcher.

param([switch]$Remove)

$TaskName = 'ClaudeStatusLightWatchdog'
$Watcher = Join-Path $PSScriptRoot 'watch-app.ps1'
$SuperviseMinutes = 5

if (-not (Test-Path -LiteralPath $Watcher)) { throw "watch-app.ps1 not found next to this script ($Watcher)" }

function Stop-Watcher {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*watch-app.ps1*' } |
        ForEach-Object {
            "stopping watcher pid $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Stop-Watcher
if ($Remove) { "unregistered $TaskName"; exit 0 }

$ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Watcher
$action = New-ScheduledTaskAction -Execute $ps -Argument $arg

# TWO triggers, and both are needed.
#
# The -Once trigger starts the repetition immediately, which matters because a
# repetition attached only to -AtLogOn does not begin until the NEXT logon: you
# would register the task, see it succeed, and it would never tick again this
# session. The -AtLogOn trigger then restarts the cycle on future sign-ins.
#
# [TimeSpan]::MaxValue serialises to P99999999DT23H59M59S, which Task Scheduler
# rejects outright, so the duration is long-but-finite.
$dur = [TimeSpan]::FromDays(3650)
$interval = New-TimeSpan -Minutes $SuperviseMinutes

$now = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) `
    -RepetitionInterval $interval -RepetitionDuration $dur

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logon.Repetition = $now.Repetition

$trigger = @($now, $logon)

# Interactive logon type: the watcher has to see the user's %TEMP% (where the
# session slots live) and the user's processes (to spot the desktop app). A
# service-account run would see neither and would darken the light constantly.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# ExecutionTimeLimit MUST be unlimited. The watcher is a resident loop, and the
# default limit would kill it a few minutes in, leaving the light stale until the
# next supervisor tick restarted it.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Keeps the Claude status light dark when the desktop app is closed, no session is live, or nothing has run recently.' `
    -ErrorAction Stop | Out-Null

Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Start-Sleep -Seconds 5

# Verify rather than assume. A registration that half-succeeded, or a watcher
# killed by an execution time limit, would otherwise report success and leave the
# light stuck on whatever it last showed.
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$i = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
"task     : $($t.TaskName)  state=$($t.State)"
"last run : $($i.LastRunTime)  result=0x$('{0:X}' -f $i.LastTaskResult)"
"next run : $($i.NextRunTime)"

$proc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*watch-app.ps1*' })
if ($proc.Count -eq 0) { throw 'watcher process is NOT running after start' }
"watcher  : running, pid $($proc[0].ProcessId)"
"registered OK. Supervisor ticks every $SuperviseMinutes min. Remove with: install-watchdog.ps1 -Remove"
