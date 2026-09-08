<#
.SYNOPSIS
Clear a session that is stuck on the ClydeCube status light.

.DESCRIPTION
Two independent things can pin a block on the panel, and a fix has to handle
both or it only works half the time.

1. A SLOT FILE. %TEMP%\claude-status-light\<session>.state holds the colour a
   session last asked for. Yellow and red slots are deliberately exempt from the
   30 minute sweep and get 4 hours instead, because a session waiting on a
   prompt fires one hook and then goes silent, and silence is exactly what red
   looks like from outside. That is correct for a live prompt and wrong for a
   session you stopped, which is why this script exists.

2. A GHOST TASK. Get-RunningTasks in status-light.ps1 treats a .output file it
   cannot open exclusively as a running background task. A stale file still held
   by something therefore reads as a live busy session for a full 24 hours, with
   no slot file anywhere to delete. Observed on 2026-09-08: session 648a8e13
   showed a permanent yellow block from two files last written at 09:56 and
   12:59, long after that session had stopped.

Slots are cleared unconditionally, because a live session re-earns its block on
its next hook. That is the existing design rather than a workaround: a session
earns its block on the first hook meaning something is HAPPENING.

Ghost task files are only moved aside when they are older than -MinAgeMinutes,
because renaming the output of a genuinely running task would take it away from
the harness reading it. The rename succeeds even while a holder has the file
open, which is what makes this work without changing status-light.ps1 at all.

.EXAMPLE
clear-light.ps1
Report what is on the panel and why, changing nothing.

.EXAMPLE
clear-light.ps1 -All
Clear every slot and every stale ghost, then repaint.

.EXAMPLE
clear-light.ps1 -Session 648a8e13
Clear one session by id prefix, slot and ghosts together.
#>
[CmdletBinding()]
param(
    [switch]$All,
    [string]$Session,
    [switch]$Ghosts,
    [int]$MinAgeMinutes = 10,
    [switch]$Force
)

$StateDir  = Join-Path $env:TEMP 'claude-status-light'
$TaskRoot  = Join-Path $env:TEMP 'claude'
$CacheFile = Join-Path $env:TEMP 'claude-status-light.state'
$Light     = Join-Path $PSScriptRoot 'status-light.ps1'
$ScanHours = 24     # matches $TaskScanMaxAgeHours in status-light.ps1

function Short {
    param([string]$Id)
    if ($Id.Length -ge 8) { return $Id.Substring(0, 8) }
    return $Id
}

function Get-Slots {
    Get-ChildItem -LiteralPath $StateDir -Filter '*.state' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Session = $_.BaseName
                State   = (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue).Trim()
                Age     = [int]((Get-Date) - $_.LastWriteTime).TotalMinutes
                Path    = $_.FullName
            }
        }
}

function Test-FileLocked {
    # The same question status-light.ps1's Get-RunningTasks asks: can this file
    # be opened exclusively? If not, something holds it, and a held task output
    # file IS a running task.
    #
    # WRITTEN AS A HELPER WITH ONE BARE CATCH ON PURPOSE. The obvious inline
    # form, with empty typed clauses for FileNotFoundException and
    # DirectoryNotFoundException ahead of a general catch, MEASURABLY FAILS here:
    # across the same 155 files it reported 0 locked while this helper found 2,
    # including one proved locked by a direct single-file test moments earlier.
    # The typed clauses appear to swallow the IOException that a held file
    # raises, and I could not reconcile that with how PowerShell documents catch
    # matching. So this uses the form that was measured to work rather than the
    # form that reads correctly, and a missing file is answered by asking
    # whether it exists instead of by catching its absence.
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    }
    catch {
        return $true
    }
}

function Get-GhostTasks {
    # The same test status-light.ps1 makes, so this reports what the panel is
    # actually seeing rather than a second opinion about it.
    $cut = (Get-Date).AddHours(-$ScanHours)
    if (-not (Test-Path -LiteralPath $TaskRoot)) { return @() }

    foreach ($proj in @(Get-ChildItem -LiteralPath $TaskRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($sess in @(Get-ChildItem -LiteralPath $proj.FullName -Directory -ErrorAction SilentlyContinue)) {
            $tasks = Join-Path $sess.FullName 'tasks'
            if (-not (Test-Path -LiteralPath $tasks)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $tasks -Filter '*.output' -File -ErrorAction SilentlyContinue)) {
                $newest = if ($f.LastWriteTime -gt $f.CreationTime) { $f.LastWriteTime } else { $f.CreationTime }
                if ($newest -lt $cut) { continue }

                if (-not (Test-FileLocked $f.FullName)) { continue }

                [pscustomobject]@{
                    Session = $sess.Name
                    Project = $proj.Name
                    File    = $f.Name
                    Age     = [int]((Get-Date) - $newest).TotalMinutes
                    Path    = $f.FullName
                }
            }
        }
    }
}

# NOT $ghosts: PowerShell variables are case insensitive, so that name IS the
# [switch]$Ghosts parameter above, and assigning a list to it coerces to a
# switch and silently produces nonsense.
$slots  = @(Get-Slots)
$ghostList = @(Get-GhostTasks)

Write-Host ''
Write-Host 'WHAT IS ON THE PANEL' -ForegroundColor Cyan
if ($slots.Count -eq 0 -and $ghostList.Count -eq 0) {
    Write-Host '  nothing, the panel is showing no sessions'
}
foreach ($s in $slots) {
    Write-Host ('  slot   {0}  {1,-7} last hook {2} min ago' -f (Short $s.Session), $s.State, $s.Age)
}
foreach ($g in @($ghostList | Group-Object Session)) {
    $oldest = ($g.Group | Measure-Object Age -Maximum).Maximum
    Write-Host ('  ghost  {0}  busy from {1} locked task file(s), oldest {2} min' -f `
            (Short $g.Name), $g.Count, $oldest) -ForegroundColor Yellow
}

if (-not ($All -or $Session -or $Ghosts)) {
    Write-Host ''
    Write-Host 'Nothing changed. To clear:' -ForegroundColor DarkGray
    Write-Host '  clear-light.cmd all               every slot and every stale ghost'
    Write-Host '  clear-light.cmd <session-prefix>  just that one'
    Write-Host ''
    return
}

if ($Session) {
    $targetSlots  = @($slots  | Where-Object { $_.Session -like "$Session*" })
    $targetGhosts = @($ghostList | Where-Object { $_.Session -like "$Session*" })
    if ($targetSlots.Count -eq 0 -and $targetGhosts.Count -eq 0) {
        Write-Host ''
        Write-Host ("No session on the panel starts with '$Session'. Nothing to do.") -ForegroundColor Yellow
        Write-Host ''
        return
    }
}
elseif ($Ghosts) {
    $targetSlots  = @()
    $targetGhosts = $ghostList
}
else {
    $targetSlots  = $slots
    $targetGhosts = $ghostList
}

Write-Host ''
Write-Host 'CLEARING' -ForegroundColor Cyan
$did = 0

foreach ($s in $targetSlots) {
    try {
        Remove-Item -LiteralPath $s.Path -Force -ErrorAction Stop
        Write-Host ('  removed slot {0} ({1})' -f (Short $s.Session), $s.State)
        $did++
    }
    catch {
        Write-Host ('  FAILED to remove slot {0}: {1}' -f (Short $s.Session), $_.Exception.Message) -ForegroundColor Red
    }
}

foreach ($g in $targetGhosts) {
    if ($g.Age -lt $MinAgeMinutes -and -not $Force) {
        Write-Host ('  skipped {0} ({1} min old, under -MinAgeMinutes {2}), it may still be running' -f `
                $g.File, $g.Age, $MinAgeMinutes) -ForegroundColor DarkGray
        continue
    }
    try {
        # Renamed, not deleted: the output of a task somebody may still want back
        # is not this script's to destroy, and .cleared is enough to drop it out
        # of the *.output glob the scan uses.
        Rename-Item -LiteralPath $g.Path -NewName ($g.File + '.cleared') -ErrorAction Stop
        Write-Host ('  moved aside {0}\{1} ({2} min old)' -f (Short $g.Session), $g.File, $g.Age)
        $did++
    }
    catch {
        Write-Host ('  FAILED to move {0}: {1}' -f $g.File, $_.Exception.Message) -ForegroundColor Red
    }
}

if ($did -eq 0) { Write-Host '  nothing needed clearing' }

Write-Host ''
Write-Host 'REPAINTING' -ForegroundColor Cyan
# The cache is only ever a belief about a panel that cannot be read back, so it
# has to go first or the repaint can decide nothing changed and skip itself.
Remove-Item -LiteralPath $CacheFile -Force -ErrorAction SilentlyContinue
& powershell -NoProfile -ExecutionPolicy Bypass -File $Light watchdog | Out-Null
Write-Host '  done'
Write-Host ''
