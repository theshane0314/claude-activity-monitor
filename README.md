# Claude Activity Monitor

Live dashboard showing everything Claude Code is doing across ALL sessions — event feed, per-session console views, token usage, and detached script tracking.

## Tabs

- **activity** — event feed: every tool call (start/finish/fail with output snippet), prompts, permission asks, session lifecycle, subagents, detached spawns/exits. Filter box + category dropdown. NOW RUNNING chips show in-flight tools.
- **one tab per live session** (named by 8-char session id) — a console view tailing that session's transcript: your prompts (blue), Claude's replies (white), thinking (dim), every tool call as it's issued (amber) and the full output it returns (green), scrolling live like a terminal.
- **detached** — every Claude-launched detached process (survives session end), detected by command-line scan every 3s; pick any recent `.log` file to live-tail it. Spawns/exits are also written into the activity feed as history.

## Tokens bar

Always visible under the header: today and rolling-7-day totals (in / out / cache), rebuilt from session transcripts every 5s. Hover for per-day breakdown + top sessions. Dedupes by message id + request id so streamed/repeated entries don't double-count.

## How it works

- `hook-logger.ps1` — registered in `~/.claude/settings.json` under 14 hook events, fires async on every event, appends JSONL to `%LOCALAPPDATA%\ClaudeActivityMonitor\activity.jsonl` (named mutex, 10 MB rotation). PostToolUse includes an output snippet.
- `ClaudeActivityMonitor.ps1` — WPF app; UI thread tails the activity log + open transcripts every 400 ms; two background runspaces handle token scanning (transcripts under `~/.claude/projects`) and detached-process watching (WMI Win32_Process command-line match on `Temp\claude` / `ClaudeProjects` / `scratchpad`, min age 10s).
- `status-light.ps1` — drives a physical status light from the same hook events. See below.

## Launch

Double-click `Claude Activity Monitor.bat`, or:

```
Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<repo path>\ClaudeActivityMonitor.ps1"'
```

## Status light

`status-light.ps1` turns a smart light into a traffic light for Claude Code:

| Colour | Meaning | Hook events |
|---|---|---|
| 🔴 red | waiting for confirmation | `PermissionRequest`, `Notification` |
| 🟡 yellow | running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| 🟢 green | finished, ready for a new task | `Stop`, `SessionStart`, `SessionEnd` |

Usage: `status-light.ps1 <red|yellow|green|off|status>`

**Multiple sessions.** On the cube backend every live session gets its own block of
the panel, side by side, so nothing is hidden behind an aggregate. The cube is a 20x5
matrix: one session fills all 20 columns, two take 10 and 9, three take 6/6/6, each
separated by a dark column so the blocks can be counted at a glance. Separators are
dropped wholesale once they stop fitting (past 10 sessions), and past 20 the columns
run out and blocks are allocated per pixel instead, so all 100 LEDs can carry 100
sessions at once.

A worst-wins aggregate is still computed (red beats yellow beats green) and is what
the single-colour kasa backend shows, and what the cube shows when nothing is running.
One session hitting `Stop` while another is mid-tool leaves the aggregate yellow, and
so does a fresh `SessionStart` landing next to a session that is working. Green means
nothing is running anywhere. Each session gets a slot file under `%TEMP%\claude-status-light\`
keyed by its session id, written from the `session_id` on the hook's stdin JSON;
`SessionEnd` deletes the slot. A session that dies without firing `SessionEnd` (window
closed, crash, reboot) would pin the light yellow forever, so a slot untouched for
`$StaleMinutes` (30) is swept. Keep that above the longest gap between two hook events
in a working session: a foreground `Bash` call can hold for ten minutes, with model
thinking either side of it. If the light is ever stuck, run `status` (below), and
delete that directory if you need a hard reset.

**Backgrounded commands count as working.** Hooks only fire around tool calls, so a
session that launches a test suite with `run_in_background` and then ends its turn
fires `Stop` while the suite is still running. Slots alone would call that green. So
on the way to green (and only then, since the answer is only ever needed there) the
script asks whether any backgrounded command is still alive.

The signal is a lock, not a guess. Claude Code gives every backgrounded command a task
id and streams its output to
`%TEMP%\claude\<project>\<session>\tasks\<id>.output`, holding that file open for as
long as the command runs, so an output file that is still locked for writing **is** a
running task. Nothing else available answers it: a backgrounded command is orphaned as
soon as its launching shell exits, so its parent chain no longer reaches the session,
and picking real work out of the idle session shell, the MCP servers and the hook
processes would take a name-and-age guess that goes stale the first time any of them
changes. Every session's task directory is scanned, not just the ones holding a slot,
because a task outlives both the turn that started it and the slot's staleness sweep.
It costs about 200 ms over a few hundred files.

When the command finishes the lock clears, and the next hook from any session pushes
green. Normally that is immediate, since finishing a background task wakes its session.
If nothing wakes it the light stays yellow until something does, which is the right way
round to be wrong.

**`status-light.ps1 status`** explains the current colour and needs no session: every
session and what it last asked for (flagging stale slots), every running task, the
combined answer, the cached colour, and what the bulb itself reports it is showing.
That last line is the one that catches a silent failure, since the cache is only a
belief about a device that can be offline or have handed its address to something else.

```
sessions:
  8efcd7c6  yellow   last hook 0.0 min ago
  cfb43f8d  green    last hook 12.1 min ago
running tasks:
  (none)
aggregate : yellow
cache     : yellow
cube      : reachable at 192.168.0.228:55443
            (write-only firmware: cannot read back what it is showing)
```

Run by hand with no stdin there is no session to attribute the colour to, so the
argument is forced onto the bulb directly; `off` also forgets every session, so the
next hook event rebuilds the picture from scratch.

**Trace.** Every invocation appends its decision (colour asked for, session, hook, the
slots it saw, the aggregate it chose, and any exception it swallowed) to
`%TEMP%\claude-status-light-trace.log`, rotated at 1 MB. Set `$TraceFile = ''` to turn
it off. It is worth its keep: the light showing the wrong colour is otherwise
unfalsifiable after the fact, because nothing else records what the sessions looked
like at the time. Keep it in `%TEMP%` — **hook processes cannot write under
`%LOCALAPPDATA%`**, which is also why `activity.jsonl` stops updating (see Notes).

**Backend.** Set `$Backend` to pick one. Both are dependency-free socket writes: no
Python, no library, no cloud, no credentials. Typical call is 15-150 ms, which matters
because these hooks fire on every tool use. A DHCP reservation is recommended for
either, since the script fails silently if the address moves.

`cube` (default) drives a Yeelight Cube Smart Lamp Lite (YLFWD-0062, reported model
`CubeLite`) over Yeelight LAN Control on TCP 55443. It is a 20x5 RGB matrix and is the
only backend that can show per-session blocks. LAN Control must be enabled for the
device in the Yeelight Station app or the port stays shut.

The matrix methods are **undocumented and absent from the SSDP `support:` header**,
which is empty on this device, so that header cannot be used to decide what is
available. Driving it is `activate_fx_mode {"mode":"direct"}` followed by `update_leds`
with a base64 RGB frame, **both on the same connection** — arming on one connection and
pushing on another is refused with `illegal request`. `update_leds` never replies, so
only the arming step can be checked. A pushed frame survives the connection closing,
which is what lets short-lived hook processes drive it without a daemon.

Geometry is 20 wide, 5 tall, row 0 at the top, pixel index running right to left, and
not serpentine, so `index = row*20 + (19-x)` with x from the left. On this firmware
`get_prop` never answers and the SSDP reply is a hardcoded stub that does not change
when the light does, so `status` cannot read back what the panel is showing and says so
rather than guessing.

`kasa` drives a TP-Link Kasa bulb (tested on a KL125) over the legacy autokey-XOR
protocol on TCP 9999, and shows the aggregate colour only. Set `$BulbIp`. Note this is
the LEGACY protocol; newer Kasa/Tapo devices speak KLAP over port 80 and need cloud
credentials.

To drive different hardware (a USB tower light, an addressable LED strip, a Home
Assistant entity), replace `Set-Light`. Nothing else in the file changes.

**Flashing (optional, off by default).** Set `$FlashCount` above 0 and the bulb pulses
the new colour that many times on a state *change*, which helps if the bulb shares a
fixture with a brighter room light. It is off because it gets annoying fast once the
status light has a bulb to itself. Off, a change costs ~60ms; at 3 pulses, ~1s. Either
way a repeat of the current state costs 4ms and touches nothing.

**Design notes.** It caches the last state and skips the network entirely when the
colour is unchanged, because `PreToolUse` and `PostToolUse` fire constantly. It gives
up quietly after a 1s connect timeout and never throws, so an offline bulb can't break
a hook. Set `green` to `@{ hue = 0; sat = 0 }` if you would rather idle be warm white
and keep the bulb usable as a room light.

Two things that are easy to get wrong and are worth keeping:

- **The whole sequence runs over one connection, reading each reply before sending
  the next command.** Closing the socket straight after a write races the device, and
  the last command gets silently dropped — the bulb ends up on the previous colour
  while the script reports success.
- **The cache is claimed before the flash, not after.** `PreToolUse` and `PostToolUse`
  both ask for yellow milliseconds apart; claiming afterwards lets the second call see
  a stale cache and flash on top of the first. If the bulb turns out to be unreachable
  the claim is rolled back, so the next hook retries.
- **Recording the session, combining the sessions and pushing the bulb are one
  critical section**, held under a named mutex. Sessions fire hooks concurrently, so
  two interleaved runs can otherwise read each other's half-written state and leave
  the bulb showing the loser.

**Wiring.** Register it in `~/.claude/settings.json` alongside the other hooks, passing
the colour as the final argument:

```json
{
  "type": "command",
  "command": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
           "-File", "<repo path>\\status-light.ps1", "yellow"],
  "timeout": 5,
  "async": true
}
```

Hook config is picked up live; no restart needed.

## Notes

- Session tabs appear automatically for any transcript active in the last 30 min.
- Colors: amber = running/tool call, green = done/output, red = fail/denied, blue = your prompts, purple = alerts/permission asks, cyan = agents, orange = detached, gray = lifecycle.
- pause = stops autoscroll everywhere; clear = wipes the feed list (log file untouched).
- To disable logging: remove the `hooks` block from `~/.claude/settings.json`.

## Known issue: the event feed is not being written

**`hook-logger.ps1` is failing silently and `activity.jsonl` has not been written since
2026-09-01 18:00**, so the activity tab and the session tabs show nothing newer than
that. Sessions have run since; the hooks fire (the status light reacts to them), but
the append does not land.

What is established: a hook-spawned PowerShell process cannot write under
`%LOCALAPPDATA%\ClaudeActivityMonitor\`, while the identical call from an interactive
shell writes there fine. That was found by pointing the status light's own trace file
at that directory (nothing appeared, across many invocations) and then moving it to
`%TEMP%` (every invocation appeared immediately). `hook-logger.ps1` writes only to
`%LOCALAPPDATA%`, and it swallows every error via `trap { exit 0 }`, so it has been
failing invisibly.

Not yet established: why. Candidates are the sandbox Claude Code spawns hooks inside,
an ACL on the directory, or controlled-folder-access blocking writes by an unrecognised
process. The fix is likely to be moving the log under `%TEMP%` like the trace, but the
cause should be pinned first, since the monitor app reads that path too.
