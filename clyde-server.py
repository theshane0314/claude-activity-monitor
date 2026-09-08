#!/usr/bin/env python3
"""clyde-server.py - pixel editor and API for the ClydeCube status panel.

WHY THIS RUNS ON THE PC. status-light.ps1 must stay the only thing that writes
to the cube: it repaints on every hook and re-asserts every couple of minutes,
so anything else painting independently is simply overwritten. That script runs
here, because this is where the Claude hooks fire and where session state lives.
So a drawing has to be handed to it rather than sent to the light.

This server therefore does not talk to the cube at all. It writes an override
file, which status-light.ps1 reads when it paints, and then asks it to repaint.
That holds for the SCROLLING frames too: a first attempt pushed frames straight
at the cube and looked broken, because every Claude hook repainted over it. A
scrolling drawing is still just an override file, with a `scroll` block on it,
and status-light.ps1's `animate` verb is what walks the window across it.

The layout is not reimplemented here either. `status-light.ps1 layout` reports
the cell size a drawing would get, so the editor draws at exactly the right
size and the two cannot drift apart. The same goes for the scroll limits: they
are reported by /api/layout so the editor never has to invent a maximum width.

    GET    /                     the editor
    GET    /api/layout           panel, sessions, canvas size per mode, scroll limits
    POST   /api/override         {mode, w, h, pixels[], scroll?}  -> show it
    DELETE /api/override         clear it
    GET    /api/frames           list saved frames
    GET    /api/frames/<name>    one frame
    POST   /api/frames           {name, w, h, pixels[], scroll?}  -> save
    DELETE /api/frames/<name>    delete
    GET    /api/health           liveness, when the light last painted, animator

Serves on 0.0.0.0 so Home Assistant and phones on the LAN can reach it.
"""

import base64
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATUS_LIGHT = os.path.join(HERE, "status-light.ps1")
CLEAR_LIGHT = os.path.join(HERE, "clear-light.ps1")
EDITOR_HTML = os.path.join(HERE, "editor.html")
FRAMES_DIR = os.path.join(HERE, "frames")
OVERRIDE_FILE = os.path.join(os.environ.get("TEMP", "."), "claude-status-light.override")

# clyde-nas on the NAS shows this when the PC stops driving the cube. It is a
# FULL PANEL frame: the NAS has no sessions to share the panel with.
NAS_URL = os.environ.get("CLYDE_NAS_URL", "http://192.168.0.3:8788")
HEARTBEAT_FILE = os.path.join(os.environ.get("TEMP", "."), "claude-status-light.state")

# Touched every tick by `status-light.ps1 animate` while it is scrolling. Its
# FRESHNESS is the only signal that matters: a stale file is a process that
# died, and treating that as a lock would wedge the light off for good.
ANIMATE_FILE = os.path.join(os.environ.get("TEMP", "."), "claude-status-light.animating")
ANIMATOR_FRESH = 3.0     # same window status-light.ps1 uses to defer hook paints
ANIMATOR_GRACE = 6.0     # a start takes a PowerShell launch, so wait before re-judging

PORT = int(os.environ.get("CLYDE_PORT", "8787"))
LOG_FILE = os.path.join(os.environ.get("TEMP", "."), "clyde-server.log")
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# status-light.ps1 layout costs a PowerShell start (~300ms). The editor polls,
# so it is cached briefly; short enough that adding a session still feels live.
LAYOUT_TTL = 6.0

# pythonw has no console of its own, so without this flag every PowerShell child
# creates ONE, and a console window flashes on screen for each call. The editor
# polls, so that was several visible flashes a minute.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
# The animator outlives the request that started it, and must not die with this
# server or hold its stdio open.
DETACHED = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)

# How wide a scrolling canvas may be. The panel is 20 columns, so this is a bit
# over twelve panel-widths, which is a long ticker message and still a small
# JSON body. A cap has to live somewhere, and here is the only place that also
# tells the editor about it (see /api/layout), so the editor cannot pick a
# different one.
MAX_SCROLL_W = 256

# THE SPEED CEILING IS THE HARDWARE, NOT A PREFERENCE. DO NOT RAISE IT.
# Measured 2026-09-08 against the real cube: a held connection is refused after
# about 25 to 30 commands ("client quota exceeded"), and above that sits a
# client-level cap that refills at about 68 commands a MINUTE. `update_leds`
# never replies, so going over budget is SILENT: the socket keeps accepting
# frames and the panel just freezes on the last one it managed to render. That
# is why the first build looked like it worked and died about 5 seconds in.
# So a speed above 1.0 does not scroll faster, it freezes the panel.
# 0.7 updates a second is about 42 commands a minute, which deliberately leaves
# headroom: the status light still needs commands for its ordinary hook paints,
# and a hook paint refused on quota leaves a ticker on screen that has already
# been taken down.
# `step` is what buys the motion back: columns moved per update. At one update a
# second, step 4 advances exactly one character (3 columns wide plus 1 of
# spacing), so the message walks across a character at a time. It is a
# flip-board rather than a glide, and it is the most this device can sustain.
SCROLL_DEFAULTS = {"speed": 0.7, "step": 4, "dir": "left", "gap": 8, "loop": True}
SCROLL_LIMITS = {"speed": [0.05, 1.0], "step": [1, 8], "gap": [0, 64],
                 "dir": ["left", "right"]}
# Carried into the clamp note so whoever reads it learns WHY, not just what.
# Without this, the obvious "fix" for a clamped speed is to raise the limit,
# which is exactly the change that kills the panel.
SPEED_REASON = ("the cube refuses commands past about 68 a minute and never says "
                "so, so a higher speed does not scroll faster, it freezes the "
                "panel; raise scroll.step instead to move more columns per update")

_layout_lock = threading.Lock()
_layout_cache = {"at": 0.0, "value": None}

_animator_lock = threading.Lock()
# proc is kept only so a start that failed can be REPORTED. It is never used as
# the liveness test, because the animator may equally have been started by hand.
_animator = {"proc": None, "started_at": 0.0, "last_exit": None}

SAFE_NAME = re.compile(r"^[A-Za-z0-9 _.-]{1,64}$")

# Cloudflare Tunnel routes ha.plaincandle.dev/clyde/* here and does NOT strip the
# prefix, so every path arrives with it attached. Stripping it here means the
# editor works identically at http://<pc>:8787/ and at https://ha.../clyde/.
URL_PREFIX = os.environ.get("CLYDE_PREFIX", "/clyde")


def strip_prefix(path):
    if URL_PREFIX and (path == URL_PREFIX or path.startswith(URL_PREFIX + "/")):
        path = path[len(URL_PREFIX):] or "/"
    return path


def log(msg):
    """Never write to stderr.

    The supervisor launches this with pythonw.exe so no console window flashes
    on every restart, and under pythonw sys.stderr is not a usable stream. A
    single write to it at startup killed the process before it could bind,
    which looked exactly like a port conflict: four copies spawned, none
    serving. Everything goes to a file instead.
    """
    line = "%s  %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def run_status_light(verb, timeout=25):
    """Returns (ok, stdout, stderr)."""
    try:
        p = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", STATUS_LIGHT, verb],
            capture_output=True, text=True, timeout=timeout,
            creationflags=NO_WINDOW,
        )
        return p.returncode == 0, p.stdout, p.stderr
    except Exception as e:
        return False, "", str(e)


def run_clear_light(session=None, timeout=60):
    """Clear a stuck session, via the same script the CLI uses.

    Two different things can pin a block on the panel and both have to go: the
    slot file, and a "ghost" background task whose .output file is still held so
    the scan reads it as a running task. clear-light.ps1 owns that logic, and
    calling it here rather than reimplementing it is what stops the button and
    the command line drifting apart.

    Returns (ok, stdout, stderr).
    """
    args = [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", CLEAR_LIGHT]
    args += ["-Session", session] if session else ["-All"]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           creationflags=NO_WINDOW)
        return p.returncode == 0, p.stdout, p.stderr
    except Exception as e:
        return False, "", str(e)


def run_clear_light_report(timeout=60):
    """clear-light.ps1 with no switches reports and changes nothing."""
    try:
        p = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", CLEAR_LIGHT],
            capture_output=True, text=True, timeout=timeout, creationflags=NO_WINDOW)
        return p.returncode == 0, p.stdout, p.stderr
    except Exception as e:
        return False, "", str(e)


def get_layout(force=False):
    with _layout_lock:
        now = time.time()
        if not force and _layout_cache["value"] and (now - _layout_cache["at"]) < LAYOUT_TTL:
            return _layout_cache["value"]
        ok, out, err = run_status_light("layout")
        if not ok or not out.strip():
            return {"error": "layout failed", "detail": (err or out).strip()[:400]}
        try:
            value = json.loads(out)
        except json.JSONDecodeError as e:
            return {"error": "layout was not JSON", "detail": f"{e}: {out.strip()[:200]}"}
        _layout_cache["at"] = now
        _layout_cache["value"] = value
        return value


class ScrollError(ValueError):
    """A scroll block that cannot be repaired by clamping.

    Kept distinct from ValueError so a bad scroll says WHICH key was wrong,
    instead of arriving as a generic "bad request" and sending the editor
    hunting through the pixels.
    """


def parse_scroll(raw):
    """Validate a `scroll` block. Returns (scroll|None, [notes]).

    None means "not a scrolling drawing", and the caller must then write an
    override with no scroll key at all, so an old-style drawing stays byte for
    byte what it was before this feature existed.

    Out-of-range NUMBERS are clamped, because a speed of 300 has an obvious
    intent and refusing it would only make the editor clamp instead. The speed
    clamp is the hardware, not a preference (see SCROLL_LIMITS), so its note
    carries the reason: past about 68 commands a minute the panel freezes
    rather than scrolling faster. Wrong
    TYPES and unknown keys are refused, because those have no obvious intent:
    a typo like `spede` would otherwise silently take the default and the
    drawing would scroll at a speed nobody asked for.
    """
    if raw is None or raw is False:
        return None, []
    if not isinstance(raw, dict):
        raise ScrollError("scroll must be an object like "
                          '{"speed":0.7,"step":4,"dir":"left","gap":8}')

    unknown = [k for k in raw if k not in SCROLL_DEFAULTS]
    if unknown:
        raise ScrollError("unknown scroll key(s) %s; allowed: %s"
                          % (", ".join(sorted(unknown)), ", ".join(sorted(SCROLL_DEFAULTS))))

    notes = []

    def number(key):
        v = raw.get(key, SCROLL_DEFAULTS[key])
        # bool is an int in Python, and `"speed": true` is nonsense, not 1.
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise ScrollError(f"scroll.{key} must be a number, got {v!r}")
        lo, hi = SCROLL_LIMITS[key]
        if v < lo or v > hi:
            # The speed clamp gets its reason attached, because it is the one
            # limit a reader would otherwise assume was somebody's taste.
            why = ("; " + SPEED_REASON) if key == "speed" else ""
            notes.append(f"scroll.{key} {v} clamped to {lo}..{hi}{why}")
            v = max(lo, min(hi, v))
        return v

    # speed is a FLOAT at every value, never normalised back to an int. Old
    # clients and frames saved before the measurement still send `"speed": 12`,
    # and that has to land on 1.0 with a note rather than being honoured.
    speed = round(float(number("speed")), 3)
    step = number("step")
    if not float(step).is_integer():
        notes.append(f"scroll.step {step} rounded to whole columns")
    step = int(round(step))
    gap = number("gap")
    if not float(gap).is_integer():
        notes.append(f"scroll.gap {gap} rounded to whole columns")
    gap = int(round(gap))

    direction = raw.get("dir", SCROLL_DEFAULTS["dir"])
    if not isinstance(direction, str) or direction.strip().lower() not in SCROLL_LIMITS["dir"]:
        raise ScrollError('scroll.dir must be "left" or "right", got %r' % (direction,))
    direction = direction.strip().lower()

    loop = raw.get("loop", True)
    if not isinstance(loop, bool):
        raise ScrollError(f"scroll.loop must be true or false, got {loop!r}")
    if not loop:
        # Reserved by the contract: a ticker is continuous by definition, and a
        # one-shot pass would need an end-of-run behaviour nothing has defined.
        notes.append("scroll.loop is reserved and always true for now")

    return {"speed": speed, "step": step, "dir": direction,
            "gap": gap, "loop": True}, notes


def animator_status():
    """Is `status-light.ps1 animate` alive, judged only by heartbeat freshness."""
    age = pid = None
    try:
        age = round(time.time() - os.path.getmtime(ANIMATE_FILE), 2)
        with open(ANIMATE_FILE, encoding="utf-8") as fh:
            text = fh.read(400)
        m = re.search(r"\d+", text)
        if m:
            pid = int(m.group())
    except (OSError, ValueError):
        pass
    st = {"running": age is not None and age < ANIMATOR_FRESH, "seconds_ago": age, "pid": pid}
    if _animator["last_exit"] is not None:
        # A non-zero code here is almost always "this build of status-light.ps1
        # has no animate verb yet". Reporting it beats a silently still frame.
        st["last_exit"] = _animator["last_exit"]
    return st


def ensure_animator():
    """Start the animator if nothing is animating, and never start a second one.

    Checked from the heartbeat file rather than by asking PowerShell, because a
    PowerShell start costs ~300ms and this runs on every scrolling override.
    """
    with _animator_lock:
        proc = _animator["proc"]
        if proc is not None and proc.poll() is not None:
            _animator["last_exit"] = proc.returncode
            _animator["proc"] = None

        st = animator_status()
        if st["running"]:
            return dict(st, started=False, reason="already animating")

        # A start we made moments ago has not written its first heartbeat yet.
        # Without this window every request in a burst would launch its own.
        waiting = (time.time() - _animator["started_at"]) < ANIMATOR_GRACE
        if waiting and _animator["proc"] is not None:
            return dict(st, started=False, reason="start already in flight")

        try:
            _animator["proc"] = subprocess.Popen(
                [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-File", STATUS_LIGHT, "animate"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=NO_WINDOW | DETACHED, close_fds=True,
            )
        except Exception as e:
            log(f"animator start failed: {e}")
            return dict(st, started=False, reason=f"start failed: {e}")

        _animator["started_at"] = time.time()
        _animator["last_exit"] = None
        log(f"started animator pid {_animator['proc'].pid}")
        return dict(st, started=True, pid=_animator["proc"].pid,
                    reason="started status-light.ps1 animate")


def reap_animator_later(delay=ANIMATOR_GRACE + 4.0):
    """Safety net for an animator that should have exited and did not.

    It is meant to notice the override is gone and stop on its own, so this
    only fires when it has not: still our process, still heartbeating, and
    nothing left on disk that wants scrolling. Anything else is left alone,
    because killing an animator that is legitimately running would blank a
    drawing Shane is looking at.
    """
    def run():
        time.sleep(delay)
        with _animator_lock:
            proc = _animator["proc"]
            if proc is None or proc.poll() is not None:
                return
            ov = read_override()
            if ov is not None and ov.get("scroll"):
                return                      # something wants it again, leave it
            if not animator_status()["running"]:
                return                      # already stopped, nothing to reap
            log(f"animator pid {proc.pid} outlived its override, terminating")
            try:
                proc.terminate()
            except Exception as e:
                log(f"animator terminate failed: {e}")
            _animator["proc"] = None
        # The animator is the writer while it lives, so the panel needs one
        # ordinary paint to get back to showing the sessions.
        run_status_light("watchdog")

    threading.Thread(target=run, daemon=True).start()


def read_override():
    """The override as written, or None. Never raises: it is only ever a report."""
    try:
        with open(OVERRIDE_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def scroll_report():
    """What is scrolling right now, for /api/health and /api/layout."""
    ov = read_override()
    return (ov or {}).get("scroll") or None


def pixels_to_b64(pixels, w, h):
    """pixels is a flat list of [r,g,b] in row-major order, top-left first."""
    if len(pixels) != w * h:
        raise ValueError(f"expected {w * h} pixels, got {len(pixels)}")
    buf = bytearray()
    for px in pixels:
        r, g, b = (int(px[0]), int(px[1]), int(px[2]))
        buf += bytes((max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))))
    return base64.b64encode(bytes(buf)).decode()


def frame_path(name):
    if not SAFE_NAME.match(name or ""):
        raise ValueError("name must be 1-64 chars of letters, digits, space, dot, dash or underscore")
    return os.path.join(FRAMES_DIR, name + ".json")


def list_frames():
    os.makedirs(FRAMES_DIR, exist_ok=True)
    out = []
    for fn in sorted(os.listdir(FRAMES_DIR)):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(FRAMES_DIR, fn), encoding="utf-8") as fh:
                d = json.load(fh)
            # scroll is None for every frame saved before this existed, which is
            # exactly what "not a scrolling frame" should look like to the editor.
            out.append({"name": d.get("name", fn[:-5]), "w": d.get("w"), "h": d.get("h"),
                        "saved": d.get("saved"), "scroll": d.get("scroll")})
        except Exception:
            continue
    return out


def layout_with_scroll(force=False):
    """The PowerShell layout, plus everything the editor needs about scrolling.

    Added HERE rather than in the editor so there is one answer to "how wide may
    a ticker be", and it is the same answer this server enforces. `min_w` per
    mode is that mode's own canvas width: a scrolling canvas may be wider than
    the region it walks across, never narrower, or there would be nothing to
    scroll past.
    """
    layout = get_layout(force=force)
    if "error" in layout:
        return layout

    # Copied before touching, because the cache hands out the same dict to
    # every caller and the animation state below is live, not cacheable.
    layout = dict(layout)
    canvas = {}
    for mode, cell in (layout.get("canvas") or {}).items():
        cell = dict(cell) if isinstance(cell, dict) else cell
        if isinstance(cell, dict) and cell.get("w"):
            cell["scroll_min_w"] = int(cell["w"])
            cell["scroll_max_w"] = MAX_SCROLL_W
        canvas[mode] = cell
    layout["canvas"] = canvas

    layout["scroll"] = {
        "max_w": MAX_SCROLL_W,
        "defaults": dict(SCROLL_DEFAULTS),
        "limits": dict(SCROLL_LIMITS),
        "note": "canvas may be wider than the region it scrolls across, up to max_w",
        # The editor shows this next to the speed control. speed is UPDATES per
        # second and step is COLUMNS per update, so motion is speed * step
        # columns a second, and only step can be raised without freezing it.
        "speed_note": SPEED_REASON,
        "step_note": ("columns moved per update; at speed 1.0 a step of 4 advances "
                      "exactly one character (3 wide plus 1 of spacing)"),
    }
    layout["animation"] = dict(animator_status(), scroll=scroll_report())
    return layout


class Handler(BaseHTTPRequestHandler):
    server_version = "clyde/1.0"

    def log_message(self, fmt, *args):
        log(fmt % args)

    # ---- helpers -------------------------------------------------------
    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # The editor may be embedded in Home Assistant from another origin.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        return json.loads(self.rfile.read(n).decode())

    # ---- routes --------------------------------------------------------
    def do_OPTIONS(self):
        self.send_json({}, 204)

    def do_GET(self):
        path = strip_prefix(self.path.split("?")[0]).rstrip("/") or "/"

        if path == "/":
            try:
                with open(EDITOR_HTML, "rb") as fh:
                    body = fh.read()
            except OSError as e:
                return self.send_json({"error": f"editor.html missing: {e}"}, 500)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/api/layout":
            return self.send_json(layout_with_scroll(force="force" in self.path))

        if path == "/api/sessions":
            # A dry run of the clear: what is pinning a block, and why. The
            # script reports before it changes anything, so with no switches its
            # output IS the report.
            ok, out, err = run_clear_light_report()
            return self.send_json({"ok": ok, "report": out.strip(),
                                   "error": (err or "").strip()[:400] or None})

        if path == "/api/health":
            hb = None
            try:
                hb = round(time.time() - os.path.getmtime(HEARTBEAT_FILE), 1)
            except OSError:
                pass
            anim = animator_status()
            scroll = scroll_report()
            return self.send_json({
                "ok": True,
                "painted_seconds_ago": hb,
                "override": os.path.exists(OVERRIDE_FILE),
                # Flat keys as well as the block, so a dashboard can read
                # "animating" without walking into a nested object.
                "animating": anim["running"],
                "scroll": scroll,
                "animation": dict(anim, scroll=scroll),
            })

        if path == "/api/frames":
            return self.send_json({"frames": list_frames()})

        if path.startswith("/api/frames/"):
            # Names may contain spaces, so they arrive percent-encoded. Without
            # decoding, "20 clyde" arrives as "20%20clyde" and is rejected by the
            # name check as if it were an illegal name.
            name = urllib.parse.unquote(path[len("/api/frames/"):])
            try:
                with open(frame_path(name), encoding="utf-8") as fh:
                    return self.send_json(json.load(fh))
            except ValueError as e:
                return self.send_json({"error": str(e)}, 400)
            except OSError:
                return self.send_json({"error": "no such frame"}, 404)

        return self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = strip_prefix(self.path.split("?")[0]).rstrip("/") or "/"
        try:
            body = self.read_json()
        except Exception as e:
            return self.send_json({"error": f"bad JSON: {e}"}, 400)

        if path == "/api/clear":
            # Clearing is a POST because it changes things. A live session
            # re-earns its block on its next hook, so this is safe to press: the
            # worst case is a block missing for a few seconds.
            session = (body or {}).get("session") or None
            ok, out, err = run_clear_light(session)
            log(f"clear requested (session={session or 'all'}) ok={ok}")
            return self.send_json({"ok": ok, "report": out.strip(),
                                   "error": (err or "").strip()[:400] or None},
                                  200 if ok else 500)

        if path == "/api/override":
            return self.set_override(body)

        if path == "/api/away-frame":
            # Forwarded rather than sent from the browser: the editor may be
            # loaded over https through the tunnel, and a direct call to the
            # NAS's http endpoint would be blocked as mixed content.
            try:
                w, h = int(body["w"]), int(body["h"])
                pixels = body["pixels"]
                if (w, h) != (20, 5):
                    return self.send_json({
                        "error": "the away frame is the whole panel, so it must be 20x5",
                        "got": {"w": w, "h": h}}, 400)
                if len(pixels) != w * h:
                    raise ValueError(f"expected {w*h} pixels, got {len(pixels)}")
            except (KeyError, ValueError, TypeError) as e:
                return self.send_json({"error": str(e)}, 400)
            try:
                req = urllib.request.Request(
                    NAS_URL + "/away-frame",
                    json.dumps({"w": w, "h": h, "pixels": pixels}).encode(),
                    {"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(req, timeout=10) as r:
                    json.load(r)
                return self.send_json({"ok": True})
            except Exception as e:
                return self.send_json({"error": f"NAS did not accept it: {e}"}, 502)

        if path == "/api/frames":
            try:
                name = body["name"]
                p = frame_path(name)
                w, h = int(body["w"]), int(body["h"])
                pixels = body["pixels"]
                if len(pixels) != w * h:
                    raise ValueError(f"expected {w*h} pixels, got {len(pixels)}")
                if w > MAX_SCROLL_W:
                    raise ValueError(f"canvas may be at most {MAX_SCROLL_W} columns wide, got {w}")
                scroll, notes = parse_scroll(body.get("scroll"))
            except ScrollError as e:
                # Same shape the override path refuses with, so an editor that
                # saves a frame learns the current limits from the same place
                # it would learn them from a failed show. Without this, the two
                # surfaces disagree about what the numbers are.
                return self.send_json({"error": str(e), "limits": SCROLL_LIMITS,
                                       "defaults": SCROLL_DEFAULTS}, 400)
            except (KeyError, ValueError) as e:
                return self.send_json({"error": str(e)}, 400)
            saved = {"name": name, "w": w, "h": h, "pixels": pixels,
                     "saved": time.strftime("%Y-%m-%d %H:%M:%S")}
            # Written only when it exists, so a plain frame is the same file it
            # has always been and old frames stay loadable unchanged.
            if scroll:
                saved["scroll"] = scroll
            os.makedirs(FRAMES_DIR, exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                json.dump(saved, fh)
            return self.send_json({"ok": True, "name": name, "scroll": scroll, "notes": notes})

        return self.send_json({"error": "not found"}, 404)

    def do_DELETE(self):
        path = strip_prefix(self.path.split("?")[0]).rstrip("/") or "/"

        if path == "/api/override":
            try:
                os.remove(OVERRIDE_FILE)
            except OSError:
                pass
            # The animator watches the override and stops on its own, so it is
            # not killed here. reap_animator_later only steps in if it did not.
            reap_animator_later()
            run_status_light("watchdog")
            return self.send_json({"ok": True, "cleared": True,
                                   "animation": animator_status()})

        if path.startswith("/api/frames/"):
            try:
                os.remove(frame_path(urllib.parse.unquote(path[len("/api/frames/"):])))
            except ValueError as e:
                return self.send_json({"error": str(e)}, 400)
            except OSError:
                return self.send_json({"error": "no such frame"}, 404)
            return self.send_json({"ok": True})

        return self.send_json({"error": "not found"}, 404)

    # ---- the one that matters -----------------------------------------
    def set_override(self, body):
        """Write the override file, then make the light repaint immediately.

        The mode decides what the drawing has to carry with it, because
        status-light.ps1 expires the two on different things: a takeover dies
        when the session composition changes, a session drawing dies when the
        session COUNT changes. Both values are read from the live layout rather
        than trusted from the client, so a stale editor tab cannot pin a drawing
        against a panel that has moved on.

        A `scroll` block turns the drawing into a ticker: `w` may then be wider
        than the region, and status-light.ps1's animator walks a window across
        it. With no `scroll` key nothing about this path changes, and the file
        written is the same file it always was.
        """
        mode = body.get("mode")
        if mode not in ("takeover", "session"):
            return self.send_json({"error": "mode must be takeover or session"}, 400)

        # Checked before the layout call, because a bad scroll block is cheap to
        # spot and there is no point spending a PowerShell start to reject it.
        try:
            scroll, notes = parse_scroll(body.get("scroll"))
        except ScrollError as e:
            return self.send_json({"error": str(e), "limits": SCROLL_LIMITS,
                                   "defaults": SCROLL_DEFAULTS}, 400)

        # PIN suspends expiry. Parsed here rather than inside the scroll try
        # block: it applies to a still drawing too, and a bad value should say
        # so plainly instead of arriving as a scroll error.
        pin = body.get("pin", False)
        if not isinstance(pin, bool):
            return self.send_json(
                {"error": "pin must be true or false", "got": repr(pin),
                 "hint": "pin true keeps the drawing up until something clears it, "
                         "and session state stays off the panel while it is up"}, 400)

        layout = get_layout(force=True)
        if "error" in layout:
            return self.send_json(layout, 502)

        states = [s["state"] for s in layout.get("sessions", [])]

        share = total = None
        if mode == "takeover":
            want = layout["canvas"]["takeover"]
        else:
            # How much of the panel the drawing claims, as share/total parts.
            # Defaults to one part out of (sessions + 1), which is the old
            # "counts as one more session" behaviour.
            share = int(body.get("share", 1))
            total = int(body.get("total", len(states) + 1))
            want = next((s for s in layout.get("splits", [])
                         if s["share"] == share and s["total"] == total), None)
            if want is None:
                return self.send_json({
                    "error": f"no such split {share}/{total}",
                    "available": [f'{s["share"]}/{s["total"]}' for s in layout.get("splits", [])],
                }, 400)

        try:
            w, h = int(body["w"]), int(body["h"])
            pixels = body["pixels"]
            b64 = pixels_to_b64(pixels, w, h)
        except (KeyError, ValueError, TypeError) as e:
            return self.send_json({"error": f"bad pixels: {e}"}, 400)

        exp_w, exp_h = int(want["w"]), int(want["h"])
        # The height is the region's height either way: a ticker scrolls
        # sideways, so there is no reason for it to be the wrong shape
        # vertically. Only the WIDTH is allowed to grow, and only when scrolling.
        wrong = h != exp_h or (w != exp_w if scroll is None else not exp_w <= w <= MAX_SCROLL_W)
        if wrong:
            # Refused rather than scaled: the canvas is meant to be exactly the
            # cell, and silently resizing would show something other than what
            # was drawn.
            err = {
                "error": "canvas is the wrong size for the current layout",
                "drawn": {"w": w, "h": h},
                "expected": {"w": exp_w, "h": exp_h},
                "hint": "sessions changed while you were drawing; reload the layout",
            }
            if scroll is not None:
                err["expected"] = {"w": f"{exp_w}..{MAX_SCROLL_W}", "h": exp_h}
                err["hint"] = ("a scrolling canvas is the region's height, and at least "
                               "as wide as the region so there is something to scroll past")
            return self.send_json(err, 409)

        payload = {
            "mode": mode,
            "w": w, "h": h,
            "pixels": b64,
            "stamp": str(int(time.time() * 1000)),
            "sessions": len(states),
            "signature": ",".join(states),
            "share": share, "total": total,
        }
        # PIN suspends expiry. Without it a takeover ends the moment session
        # composition changes, which is right for "show me this instead" and
        # wrong for a ticker meant to run all day: measured 2026-09-08, a ticker
        # scrolled for 20 seconds and was then dropped by a session turning a
        # different colour, which looks exactly like the freeze it had just
        # stopped doing. Written only when true, so a normal drawing produces the
        # same file it always did.
        if pin:
            payload["pin"] = True
        # Absent, not null, when there is no scroll: status-light.ps1 decides
        # "is this a ticker" by the key being there at all, and an old build
        # reading this file has to see exactly what it saw before.
        if scroll:
            payload["scroll"] = scroll
        tmp = OVERRIDE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, OVERRIDE_FILE)   # atomic, so a paint never sees half a file

        # A scrolling override is inert until something is walking the window
        # across it, so the animator is started here rather than left for the
        # next hook. A still drawing gets the ordinary one-shot repaint, and any
        # animator still up from a previous drawing is left to notice and stop.
        if scroll:
            animation = ensure_animator()
            ok, out, err = (True, "", "")
            if not animation.get("running") and not animation.get("started"):
                # Could not animate. One ordinary paint at least puts the head
                # of the drawing on the panel instead of leaving it blank, and
                # the response says why it is not moving.
                ok, out, err = run_status_light("watchdog")
        else:
            animation = animator_status()
            if animation["running"]:
                reap_animator_later()
            ok, out, err = run_status_light("watchdog")

        return self.send_json({"ok": True, "mode": mode, "w": w, "h": h,
                               "share": share, "total": total,
                               "scroll": scroll, "notes": notes,
                               "animation": animation,
                               "repainted": ok, "detail": (err or "").strip()[:200]})


class Server(ThreadingHTTPServer):
    """Single instance, enforced by the socket.

    http.server sets allow_reuse_address = 1, and on Windows SO_REUSEADDR lets a
    second process bind a port that is ALREADY BOUND rather than failing. Every
    supervisor restart therefore quietly stole the port from the running copy,
    leaving a pile of processes all believing they were the server and the
    supervisor starting yet another whenever the wrong one answered. Turning it
    off makes a duplicate fail to bind, which is what the supervisor needs.
    """

    allow_reuse_address = False
    daemon_threads = True

    def server_bind(self):
        # On Windows, NOT setting SO_REUSEADDR is not enough. Without
        # SO_EXCLUSIVEADDRUSE a second process can still bind a port that is
        # already bound and silently take it over, which is exactly what was
        # happening: several servers each thought they were the one.
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def main():
    os.makedirs(FRAMES_DIR, exist_ok=True)
    try:
        srv = Server(("0.0.0.0", PORT), Handler)
    except OSError as e:
        # Already serving. Not an error worth a traceback: the supervisor polls
        # the port and will simply find the existing copy healthy.
        log(f"port {PORT} already in use, exiting ({e.__class__.__name__})")
        return
    log(f"listening on http://0.0.0.0:{PORT}/  (frames in {FRAMES_DIR})")
    srv.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # Under pythonw a traceback goes nowhere, so record it or a crash is
        # indistinguishable from never having started at all.
        log("FATAL: %s: %s" % (type(e).__name__, e))
        raise
