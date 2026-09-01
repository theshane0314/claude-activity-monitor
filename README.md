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

`status-light.ps1` turns a smart bulb into a traffic light for Claude Code:

| Colour | Meaning | Hook events |
|---|---|---|
| 🔴 red | waiting for confirmation | `PermissionRequest`, `Notification` |
| 🟡 yellow | running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| 🟢 green | finished, ready for a new task | `Stop`, `SessionStart`, `SessionEnd` |

Usage: `status-light.ps1 <red|yellow|green|off>`

**Backend.** Ships with a TP-Link Kasa driver (tested on a KL125) speaking the legacy
autokey-XOR protocol directly over TCP 9999. No Python, no library, no cloud, no
credentials, no dependencies at all — just a socket write. Typical call is 15-150 ms,
which matters because these hooks fire on every tool use. Set `$BulbIp` to your bulb's
address; a DHCP reservation is recommended, since the script fails silently if the
address moves.

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
