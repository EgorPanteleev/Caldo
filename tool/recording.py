#!/usr/bin/env python3
"""Reads a recording sent from Settings › Debug: the video and its log.

    tool/recording.py caldo-20261118-163000.log.jsonl
    tool/recording.py caldo-….log.jsonl --frames 12.4 13 15.25 --out shots/
    tool/recording.py caldo-….log.jsonl --slow 5 --out shots/
    tool/recording.py caldo-….log.jsonl --between 12 14

Prints the phone and build, then what happened in time order — taps
(down and up, with how far the finger went), marks, routes, the
keyboard, errors, prints — then the slowest frames and the seconds' CPU.
--frames pulls stills from the video (beside the log, same stem, .mp4)
at those seconds; --slow N pulls the N slowest frames' moments.
--between shows every line, frames included, between two seconds.
Needs ffmpeg for stills only.
"""

import argparse
import json
import math
import os
import subprocess
import sys


def load(path):
    lines = []
    with open(path) as f:
        for raw in f:
            raw = raw.strip()
            if raw:
                try:
                    lines.append(json.loads(raw))
                except json.JSONDecodeError:
                    pass
    lines.sort(key=lambda e: e.get("t", 0))
    return lines


def clock(ms):
    s = ms / 1000
    return f"{int(s // 60)}:{s % 60:06.3f}"


def describe(e):
    k = e["k"]
    rest = {key: v for key, v in e.items() if key not in ("t", "k")}
    if k == "route":
        return "route " + " ".join(f"{a}={b}" for a, b in rest.items())
    if k == "insets":
        return f"insets keys={e.get('keys')} bottom={e.get('bottom')} {e.get('w')}x{e.get('h')}"
    if k == "reach":
        return f"reach keys={e.get('keys')}" + (" sliding" + (f" ({e['how']})" if e.get("how") else "") if e.get("sliding") else "")
    if k == "life":
        return f"app {e.get('state')}"
    if k == "error":
        return "ERROR " + str(e.get("what")) + "\n" + "\n".join(
            "        " + l for l in str(e.get("stack") or "").splitlines()[:8]
        )
    if k == "print":
        return "print " + str(e.get("text"))
    if k == "mark":
        return "*** MARK ***"
    return f"{k} {json.dumps(rest)}"


def gestures(lines):
    """Pairs each down with its up: a tap, a drag, or a long press."""
    open_ = {}
    out = []
    for e in lines:
        if e["k"] != "touch":
            continue
        pid = e["id"]
        if e["e"] == "down":
            open_[pid] = {"t": e["t"], "x": e["x"], "y": e["y"], "moves": 0, "far": 0.0}
        elif pid in open_:
            g = open_[pid]
            d = math.hypot(e["x"] - g["x"], e["y"] - g["y"])
            g["far"] = max(g["far"], d)
            if e["e"] == "move":
                g["moves"] += 1
            else:
                g.update(end=e["t"], ex=e["x"], ey=e["y"], how=e["e"])
                out.append(g)
                del open_[pid]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--frames", nargs="*", type=float, default=[])
    ap.add_argument("--slow", type=int, default=0)
    ap.add_argument("--between", nargs=2, type=float)
    ap.add_argument("--out", default="recording-shots")
    args = ap.parse_args()

    lines = load(args.log)
    if not lines:
        sys.exit("empty log")
    video = args.log.replace(".log.jsonl", ".mp4")

    start = next((e for e in lines if e["k"] == "start"), {})
    print("phone   ", start.get("maker"), start.get("model"), "Android", start.get("android"),
          f"(sdk {start.get('sdk')}, {start.get('abi')})")
    print("app     ", start.get("app"), start.get("build"), "· locale", start.get("locale"),
          "· system", start.get("brightness"))
    print("screen  ", start.get("screen"), " video", start.get("video"))
    print("started ", start.get("wall"))

    if args.between:
        a, b = (x * 1000 for x in args.between)
        for e in lines:
            if a <= e["t"] <= b:
                print(f"{clock(e['t'])}  {describe(e) if e['k'] != 'frame' else 'frame ' + json.dumps({k: v for k, v in e.items() if k not in ('t', 'k')})}")
        return

    frames = [e for e in lines if e["k"] == "frame"]
    hz = (start.get("screen") or {}).get("hz") or 60
    budget = 1000 / hz
    print()
    print("— what happened —")
    taps = {round(g["t"], 1): g for g in gestures(lines)}
    for e in lines:
        k = e["k"]
        if k in ("frame", "perf", "start"):
            continue
        if k == "touch":
            if e["e"] != "down":
                continue
            g = taps.get(round(e["t"], 1))
            if g is None:
                print(f"{clock(e['t'])}  touch down at {e['x']},{e['y']} (no up)")
                continue
            held = g["end"] - g["t"]
            kind = ("tap" if g["far"] < 18 and held < 400 else
                    "long press" if g["far"] < 18 else "drag")
            line = f"{clock(e['t'])}  {kind} at {g['x']},{g['y']}  held {held:.0f}ms"
            if kind == "drag" or g["far"] >= 18:
                line += f"  to {g['ex']},{g['ey']} ({g['far']:.0f}pt, {g['moves']} moves)"
            if g["how"] == "cancel":
                line += "  CANCELLED"
            # Frames over budget while the finger was down or just after.
            slow = [f for f in frames if g["t"] <= f["t"] <= g["end"] + 500 and
                    max(f["build"], f["raster"]) > budget]
            if slow:
                line += f"  [{len(slow)} slow frames, worst {max(max(f['build'], f['raster']) for f in slow):.1f}ms]"
            print(line)
            continue
        if k in ("insets", "reach"):
            continue
        print(f"{clock(e['t'])}  {describe(e)}")
    # The keyboard, as its moves rather than every step.
    keys = [e for e in lines if e["k"] == "insets"]
    moves = []
    for e in keys:
        if not moves or (moves[-1]["keys"] > 0) != (e["keys"] > 0):
            moves.append(e)
    if len(moves) > 1:
        print()
        print("— keyboard —")
        for e in moves:
            print(f"{clock(e['t'])}  {'up' if e['keys'] > 0 else 'down'}  ({e['keys']}pt)")

    print()
    if frames:
        over = [f for f in frames if max(f["build"], f["raster"]) > budget]
        print(f"— frames — {len(frames)} drawn, {len(over)} over {budget:.1f}ms "
              f"({100 * len(over) / len(frames):.1f}%)")
        worst = sorted(frames, key=lambda f: -max(f["build"], f["raster"]))[:12]
        for f in sorted(worst, key=lambda f: f["t"]):
            print(f"{clock(f['t'])}  #{f['n']}  build {f['build']:5.1f}  raster {f['raster']:5.1f}  total {f['total']:5.1f}")
    perf = [e for e in lines if e["k"] == "perf"]
    if perf:
        print()
        print("— each second —   fps  tickers  slow  cpu    ui     raster  mem")
        for e in perf:
            print(f"{clock(e['t'])}         {e.get('fps', 0):3}  {e.get('tickers', 0):7}  {e.get('slow', 0):4}  "
                  f"{e.get('cpu') or 0:5.0f}  {e.get('ui') or 0:5.0f}  {e.get('raster') or 0:6.0f}  {e.get('rssMb')}M")

    shots = list(args.frames)
    if args.slow and frames:
        worst = sorted(frames, key=lambda f: -max(f["build"], f["raster"]))[: args.slow]
        shots += [f["t"] / 1000 for f in worst]
    if shots:
        if not os.path.exists(video):
            sys.exit(f"no video at {video}")
        os.makedirs(args.out, exist_ok=True)
        for s in sorted(shots):
            name = os.path.join(args.out, f"at-{s:08.3f}.png")
            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{s:.3f}", "-i", video,
                 "-frames:v", "1", name],
                check=False,
            )
            print("still", name)


if __name__ == "__main__":
    main()
