#!/usr/bin/env python3
"""clyde-server.py - pixel editor and API for the ClydeCube status panel.

WHY THIS RUNS ON THE PC. status-light.ps1 must stay the only thing that writes
to the cube: it repaints on every hook and re-asserts every couple of minutes,
so anything else painting independently is simply overwritten. That script runs
here, because this is where the Claude hooks fire and where session state lives.
So a drawing has to be handed to it rather than sent to the light.

This server therefore does not talk to the cube at all. It writes an override
file, which status-light.ps1 reads when it paints, and then asks it to repaint.

The layout is not reimplemented here either. `status-light.ps1 layout` reports
the cell size a drawing would get, so the editor draws at exactly the right
size and the two cannot drift apart.

    GET    /                     the editor
    GET    /api/layout           panel, sessions, canvas size per mode
    POST   /api/override         {mode, w, h, pixels[]}  -> show it
    DELETE /api/override         clear it
    GET    /api/frames           list saved frames
    GET    /api/frames/<name>    one frame
    POST   /api/frames           {name, w, h, pixels[]}  -> save
    DELETE /api/frames/<name>    delete
    GET    /api/health           liveness, and when the light last painted

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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATUS_LIGHT = os.path.join(HERE, "status-light.ps1")
EDITOR_HTML = os.path.join(HERE, "editor.html")
FRAMES_DIR = os.path.join(HERE, "frames")
OVERRIDE_FILE = os.path.join(os.environ.get("TEMP", "."), "claude-status-light.override")
HEARTBEAT_FILE = os.path.join(os.environ.get("TEMP", "."), "claude-status-light.state")

PORT = int(os.environ.get("CLYDE_PORT", "8787"))
LOG_FILE = os.path.join(os.environ.get("TEMP", "."), "clyde-server.log")
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# status-light.ps1 layout costs a PowerShell start (~300ms). The editor polls,
# so it is cached briefly; short enough that adding a session still feels live.
LAYOUT_TTL = 2.0

_layout_lock = threading.Lock()
_layout_cache = {"at": 0.0, "value": None}

SAFE_NAME = re.compile(r"^[A-Za-z0-9 _.-]{1,64}$")


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
        )
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
            out.append({"name": d.get("name", fn[:-5]), "w": d.get("w"), "h": d.get("h"),
                        "saved": d.get("saved")})
        except Exception:
            continue
    return out


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
        path = self.path.split("?")[0].rstrip("/") or "/"

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
            return self.send_json(get_layout(force="force" in self.path))

        if path == "/api/health":
            hb = None
            try:
                hb = round(time.time() - os.path.getmtime(HEARTBEAT_FILE), 1)
            except OSError:
                pass
            return self.send_json({
                "ok": True,
                "painted_seconds_ago": hb,
                "override": os.path.exists(OVERRIDE_FILE),
            })

        if path == "/api/frames":
            return self.send_json({"frames": list_frames()})

        if path.startswith("/api/frames/"):
            name = path[len("/api/frames/"):]
            try:
                with open(frame_path(name), encoding="utf-8") as fh:
                    return self.send_json(json.load(fh))
            except ValueError as e:
                return self.send_json({"error": str(e)}, 400)
            except OSError:
                return self.send_json({"error": "no such frame"}, 404)

        return self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        try:
            body = self.read_json()
        except Exception as e:
            return self.send_json({"error": f"bad JSON: {e}"}, 400)

        if path == "/api/override":
            return self.set_override(body)

        if path == "/api/frames":
            try:
                name = body["name"]
                p = frame_path(name)
                w, h = int(body["w"]), int(body["h"])
                pixels = body["pixels"]
                if len(pixels) != w * h:
                    raise ValueError(f"expected {w*h} pixels, got {len(pixels)}")
            except (KeyError, ValueError) as e:
                return self.send_json({"error": str(e)}, 400)
            os.makedirs(FRAMES_DIR, exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                json.dump({"name": name, "w": w, "h": h, "pixels": pixels,
                           "saved": time.strftime("%Y-%m-%d %H:%M:%S")}, fh)
            return self.send_json({"ok": True, "name": name})

        return self.send_json({"error": "not found"}, 404)

    def do_DELETE(self):
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path == "/api/override":
            try:
                os.remove(OVERRIDE_FILE)
            except OSError:
                pass
            run_status_light("watchdog")
            return self.send_json({"ok": True, "cleared": True})

        if path.startswith("/api/frames/"):
            try:
                os.remove(frame_path(path[len("/api/frames/"):]))
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
        """
        mode = body.get("mode")
        if mode not in ("takeover", "session"):
            return self.send_json({"error": "mode must be takeover or session"}, 400)

        layout = get_layout(force=True)
        if "error" in layout:
            return self.send_json(layout, 502)

        states = [s["state"] for s in layout.get("sessions", [])]
        want = layout["canvas"]["takeover" if mode == "takeover" else "session"]

        try:
            w, h = int(body["w"]), int(body["h"])
            pixels = body["pixels"]
            b64 = pixels_to_b64(pixels, w, h)
        except (KeyError, ValueError, TypeError) as e:
            return self.send_json({"error": f"bad pixels: {e}"}, 400)

        if (w, h) != (int(want["w"]), int(want["h"])):
            # Refused rather than scaled: the canvas is meant to be exactly the
            # cell, and silently resizing would show something other than what
            # was drawn.
            return self.send_json({
                "error": "canvas is the wrong size for the current layout",
                "drawn": {"w": w, "h": h},
                "expected": {"w": int(want["w"]), "h": int(want["h"])},
                "hint": "sessions changed while you were drawing; reload the layout",
            }, 409)

        payload = {
            "mode": mode,
            "w": w, "h": h,
            "pixels": b64,
            "stamp": str(int(time.time() * 1000)),
            "sessions": len(states),
            "signature": ",".join(states),
        }
        tmp = OVERRIDE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, OVERRIDE_FILE)   # atomic, so a paint never sees half a file

        ok, out, err = run_status_light("watchdog")
        return self.send_json({"ok": True, "mode": mode, "w": w, "h": h,
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
