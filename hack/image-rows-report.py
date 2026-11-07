#!/usr/bin/env python3
"""Say, from the harness's own evidence, whether the text after an inline picture cleared the picture.

    python3 hack/image-rows-report.py /tmp/image-cases/shots/tmux-rows-baseline.json ...

Three sources are compared, and the point of the exercise is that none of them is the relay's own opinion:

  - the browser: which pixel box the picture was drawn into, and the pixel box the viewport was laid out in;
  - the pane: its own cell count (tmux answers from outside, a bare pane writes its size out from inside), and,
    for a tmux pane, every row of text currently in the grid via capture-pane;
  - the relay's arithmetic: how many rows it decided an image covers, recomputed here from the very payload the
    case fed it, using the relay's own function.

A picture's pixel box divided by the viewport's cell metrics gives the rows it covers; the grid gives the rows
the text occupies. The relay is right when the text starts below the picture, and wrong when it does not.
"""
import glob
import importlib.util
import json
import math
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.environ.get("IMAGE_CASES_WORK", "/tmp/image-cases")
SHOTS = os.environ.get("IMAGE_CASES_SHOTS", f"{WORK}/shots")
TEST_IMAGE = os.environ.get("TEST_IMAGE", "/tmp/image-test/flag.png")

spec = importlib.util.spec_from_file_location("osc_wrap", os.path.join(REPO, "tools", "tmux-osc-wrap.py"))
osc_wrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(osc_wrap)


def value_of(json_path):
    with open(json_path) as f:
        raw = f.read()
    try:
        return json.loads(raw)["value"]
    except (json.JSONDecodeError, KeyError):
        start = raw.find('"canvases"')
        return json.loads(raw[start - 1:])


def payload_for_test_image():
    """The exact bytes the case wrote to /tmp/pi-seq.bin, regenerated the way the harness made it."""
    out = subprocess.run(["node", os.path.join(REPO, "hack", "pi-image-bytes.mjs"), TEST_IMAGE],
                         capture_output=True)
    if out.returncode != 0:
        return None
    return out.stdout


def case_name(json_path):
    base = os.path.basename(json_path)[: -len(".json")]
    variant, _, name = base.partition("-")
    return variant, name


def analyse(json_path):
    variant, name = case_name(json_path)
    d = value_of(json_path)
    a = {"case": name, "variant": variant, "json": json_path,
         "screen": d.get("screen"), "markers": {}}

    size_path = f"{WORK}/grid-{variant}-{name}.size"
    if os.path.exists(size_path):
        lines = [ln.strip() for ln in open(size_path) if ln.strip()]
        for ln in lines:
            m = re.search(r"(\d+)x(\d+)", ln)
            if m:
                # tmux's answer is the last one in the file when both are present, and it is the one the pane
                # was actually running under.
                a["pane"] = (int(m.group(1)), int(m.group(2)))
                a["paneSource"] = ln
    grid_path = f"{WORK}/grid-{variant}-{name}.txt"
    a["grid"] = [ln.rstrip() for ln in open(grid_path)] if os.path.exists(grid_path) else None

    painted = [c for c in d.get("canvases", []) if c.get("paintedPixels")]
    a["canvas"] = max(painted, key=lambda c: c["paintedPixels"]) if painted else None

    if a.get("pane") and a.get("screen"):
        cols, rows = a["pane"]
        if rows > 0 and cols > 0:
            a["cell"] = {
                "rowPx": a["screen"]["h"] / rows,
                "colPx": a["screen"]["w"] / cols,
                "ratio": (a["screen"]["w"] / cols) / (a["screen"]["h"] / rows),
            }
    if a.get("canvas") and a.get("cell"):
        box = a["canvas"]["box"]
        rh = a["cell"]["rowPx"]
        # The drawn height is what the addon chose; its top is where the cursor was when the image arrived.
        a["drawn"] = {"topRow": box["top"] / rh, "bottomRow": (box["bottom"] + 1) / rh,
                      "rows": (box["bottom"] - box["top"] + 1) / rh, "box": box}

    if a["grid"] is not None and a["grid"]:
        for marker in ("CASE-SIZE", "CASE-BEFORE-MARKER", "CASE-AFTER-MARKER", "CASE-RAN-MARKER"):
            for i, ln in enumerate(a["grid"]):
                if marker in ln:
                    a["markers"][marker] = {"row": i, "text": ln.strip()}
                    break

    seq = payload_for_test_image()
    if seq and a.get("pane"):
        cols, rows = a["pane"]
        a["reserved"] = osc_wrap.reserve_rows(seq, cols, rows)
        a["inherent"] = osc_wrap.image_dimensions(seq)
        a["header"] = osc_wrap.header_fields(seq)
    return a


def verdict(a):
    drawn = a.get("drawn")
    reserved = a.get("reserved")
    notes = []
    if drawn and reserved is not None:
        # This line is a prediction, not a description of the case: a case run with --no-reserve reserves no
        # rows whatever the arithmetic says. The description is the grid evidence below it.
        notes.append(
            f"prediction: the shipped defaults (ratio {osc_wrap.CELL_RATIO}, cell {osc_wrap.CELL_HEIGHT_PX}px) "
            f"reserve {reserved} rows where the renderer covered {drawn['rows']:.1f}"
        )
    before = (a["markers"].get("CASE-BEFORE-MARKER") or {}).get("row")
    after = (a["markers"].get("CASE-AFTER-MARKER") or {}).get("row")
    if before is not None and after is not None:
        step = after - before
        notes.append(f"grid: BEFORE row {before}, AFTER row {after} ({step} rows apart)")
        if drawn:
            advance = after - drawn["topRow"]
            notes.append(
                f"observed: the pane moved {advance:.0f} rows from the top of the picture "
                + (f"while the arithmetic predicted {reserved}" if reserved is not None else "")
            )
            inside = before < drawn["bottomRow"] and after <= drawn["bottomRow"]
            notes.append(
                "text OVERLAPS the picture rows "
                f"{drawn['topRow']:.1f}..{drawn['bottomRow']:.1f}" if inside else
                f"text clears the picture rows {drawn['topRow']:.1f}..{drawn['bottomRow']:.1f}"
            )
    if a["grid"] is None:
        notes.append("no grid for a bare pane (capture-pane needs tmux); the picture geometry and the "
                     "screenshot are the evidence there")
    return notes


def main(argv):
    paths = argv or sorted(glob.glob(f"{SHOTS}/*rows-*.json"))
    if not paths:
        print(f"no case reports under {SHOTS}; run hack/image-cases.sh first", file=sys.stderr)
        return 2
    results = []
    for path in paths:
        a = analyse(path)
        print(f"== {a['case']} through {a['variant']}")
        print(f"   pane {a.get('pane', ('?', '?'))} ({a.get('paneSource', 'size not reported')})"
              f"  viewport {a.get('screen')}")
        if a.get("cell"):
            c = a["cell"]
            print(f"   cell metrics measured: {c['colPx']:.2f}px wide x {c['rowPx']:.2f}px tall"
                  f"  ratio {c['ratio']:.3f}  (the relay's default is {osc_wrap.CELL_RATIO})")
        if a.get("inherent"):
            print(f"   payload: {len(payload_for_test_image())} bytes, header {a['header']},"
                  f" inherent {a['inherent'][0]}x{a['inherent'][1]},"
                  f" relay arithmetic would reserve {a['reserved']} rows")
        if a.get("drawn"):
            d = a["drawn"]
            print(f"   picture drawn: canvas {a['canvas']['className']} painted={a['canvas']['paintedPixels']}"
                  f" box={d['box']}  rows {d['topRow']:.1f}..{d['bottomRow']:.1f}")
        for marker, m in a["markers"].items():
            print(f"   grid row {m['row']:3}: {m['text'][:60]}")
        for note in verdict(a):
            print(f"   -> {note}")
        results.append(a)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
