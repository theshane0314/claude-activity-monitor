# install-watchdog.ps1 - register the Scheduled Task that darkens the status light.
#
# The light goes off when the Claude desktop app is closed, or when no hook has
# fired in an hour. NEITHER can be noticed by a hook, because both conditions
# ARE the absence of hook events: if nothing is running, nothing fires, and the
# light would sit there showing the last thing it was told forever.
#
# So a Scheduled Task polls `status-light.ps1 watchdog` every couple of minutes.
# It is cheap: the watchdog skips the network write entirely unless the picture
# has actually changed, so a quiet machine costs one process spawn and a couple
# of file reads per tick.
#
# Run with -Remove to unregister.

param([switch]$Remove)

$TaskName = 'ClaudeStatusLightWatchdog'
$Script = Join-Path $PSScriptRoot 'status-light.ps1'
$IntervalMinutes = 2

if (-not (Test-Path -LiteralPath $Script)) { throw "status-light.ps1 not found next to this script ($Script)" }

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
if ($Remove) { "unregistered $TaskName"; exit 0 }

$ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" watchdog' -f $Script

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
$interval = New-TimeSpan -Minutes $IntervalMinutes

$now = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) `
    -RepetitionInterval $interval -RepetitionDuration $dur

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logon.Repetition = $now.Repetition

$trigger = @($now, $logon)

# Interactive logon type: the watchdog has to see the user's %TEMP% (where the
# session slots live) and the user's processes (to spot the desktop app). A
# service-account run would see neither and would darken the light constantly.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -Hidden `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Darkens the Claude status light when the desktop app is closed or nothing has run for an hour.' -ErrorAction Stop | Out-Null

Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Start-Sleep -Seconds 4

# Verify rather than assume: a registration that half-succeeded would otherwise
# report success and leave the light stuck on whatever it last showed.
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$i = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
"task    : $($t.TaskName)  state=$($t.State)"
"last run: $($i.LastRunTime)  result=0x$('{0:X}' -f $i.LastTaskResult)"
"next run: $($i.NextRunTime)"
if ($i.LastTaskResult -ne 0) { throw "watchdog ran but exited 0x$('{0:X}' -f $i.LastTaskResult)" }
"registered OK: every $IntervalMinutes min. Remove with: install-watchdog.ps1 -Remove"
