#!/usr/bin/env python3
"""Seed a set of frames, a few for every canvas size the editor offers.

Sizes come from the splits status-light.ps1 reports, so a frame can only be sent
if it matches the canvas exactly:

    4x5  = 1/4 of the panel        13x5 = 2/3
    6x5  = 1/3                     15x5 = 3/4
    9x5  = 1/2                     20x5 = whole panel

Art is written as character maps with a colour legend rather than raw tuples,
because a picture you cannot read in the source is a picture nobody will edit.

Re-runnable: saving over an existing name just replaces it.
"""
import json
import urllib.request

API = "http://127.0.0.1:8787"

# ---- palette ------------------------------------------------------------
P = {
    ".": (0, 0, 0),
    "r": (255, 0, 0),      "o": (255, 112, 0),    "y": (255, 200, 0),
    "g": (0, 255, 100),    "c": (0, 200, 220),    "b": (0, 90, 255),
    "p": (170, 0, 220),    "m": (255, 0, 140),    "w": (255, 255, 255),
    "d": (60, 60, 70),     "k": (120, 40, 0),     "n": (10, 40, 20),
}


def build(rows):
    """rows: list of equal-length strings of legend keys."""
    h = len(rows)
    w = len(rows[0])
    assert all(len(r) == w for r in rows), "rows must be equal length"
    return w, h, [list(P[ch]) for r in rows for ch in r]


FRAMES = {
    # ---- 4x5, one quarter -----------------------------------------------
    "04 heart": ["mm.m", "mmmm", "mmmm", ".mm.", "..m."],
    "04 arrow": ["..g.", ".ggg", "g.g.", "..g.", "..g."],
    "04 dice":  ["wwww", "w.rw", "wr.w", "w..w", "wwww"],

    # ---- 6x5, one third --------------------------------------------------
    "06 smile":  [".yyyy.", "y.yy.y", "yyyyyy", "y.yy.y", ".y..y."],
    "06 skull":  [".wwww.", "w.ww.w", "wwwwww", ".w.w.w", "..ww.."],
    "06 flame":  ["...o..", "..oy..", ".oyyo.", "oyyyyo", ".orro."],

    # ---- 9x5, one half ---------------------------------------------------
    "09 wave":   ["..c...c..", ".c.c.c.c.", "c...c...c", ".........", "bbbbbbbbb"],
    "09 bars":   ["....g....", "..g.g.g..", "g.g.g.g.g", "g.g.g.g.g", "ggggggggg"],
    "09 invader": [".p.....p.", "..p...p..", ".ppppppp.", "pp.ppp.pp", "p.p...p.p"],

    # ---- 13x5, two thirds ------------------------------------------------
    "13 pulse":  ["......r......", "..r...r...r..", "rrr.r.r.r.rrr", "....r...r....", "....r...r...."],
    "13 sunset": ["ooooooooooooo", "yyyyyyyyyyyyy", "ooooooooooooo", "rrrrrrrrrrrrr", "ppppppppppppp"],
    "13 trees":  ["......g......", ".....ggg.....", "..g.ggggg.g..", ".ggg..k..ggg.", "nnnnnnknnnnnn"],

    # ---- 15x5, three quarters --------------------------------------------
    "15 rainbow": ["rrrrrrrrrrrrrrr", "ooooooooooooooo", "yyyyyyyyyyyyyyy", "ggggggggggggggg", "bbbbbbbbbbbbbbb"],
    "15 peaks":   ["......w........", ".....www...w...", "....ggggg.www..", "..ggggggggggg..", "nnnnnnnnnnnnnnn"],

    # ---- 20x5, the whole panel -------------------------------------------
    # 3x5 letters, one dark column between: 5*3 + 4 = 19 of 20.
    "20 clyde":  ["ggg.g...g.g.gg..ggg.",
                  "g...g...g.g.g.g.g...",
                  "g...g....g..g.g.ggg.",
                  "g...g....g..g.g.g...",
                  "ggg.ggg..g..gg..ggg."],
    "20 aurora": ["ccccbbbbppppmmmmpppp",
                  "cccbbbbppppmmmmppppc",
                  "ccbbbbppppmmmmppppcc",
                  "cbbbbppppmmmmppppccc",
                  "bbbbppppmmmmppppcccc"],
    "20 night":  ["..w......w.......w..",
                  ".......w......w.....",
                  "...w.......w........",
                  "..dd...dddd....dd...",
                  "dddddddddddddddddddd"],
}


def save(name, rows):
    w, h, px = build(rows)
    body = json.dumps({"name": name, "w": w, "h": h, "pixels": px}).encode()
    req = urllib.request.Request(API + "/api/frames", body,
                                 {"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        json.load(r)
    return w, h


if __name__ == "__main__":
    by_size = {}
    for name, rows in FRAMES.items():
        w, h = save(name, rows)
        by_size.setdefault(f"{w}x{h}", []).append(name)
    for size in sorted(by_size, key=lambda s: int(s.split("x")[0])):
        print(f"  {size:>5}  " + ", ".join(by_size[size]))
    print(f"\n{len(FRAMES)} frames saved")
