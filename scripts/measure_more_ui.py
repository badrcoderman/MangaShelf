#!/usr/bin/env python3
"""Measure surface colors and the first More row in matching 414x896 @3x PNGs.

Requires ImageMagick. This is a narrow screenshot measurement, not a full
visual parity gate. Reference screenshots are never app resources.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def measure(path: Path) -> dict:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (1242, 2688):
        raise ValueError("Expected a 1242x2688 native PNG")

    def command(*args: str) -> str:
        return subprocess.check_output(["magick", str(path), *args], text=True).strip()

    def histogram(region: str) -> list:
        result = command("-crop", region, "-depth", "8", "-format", "%c", "histogram:info:-")
        colors = sorted(((int(m[1]), m[2].upper()) for m in re.finditer(
            r"^\s*(\d+):.*#([A-Fa-f0-9]{6})\b", result, re.M)), reverse=True)
        return [{"pixels": count, "rgb": "#" + color} for count, color in colors[:8]]

    def bounds(region: str) -> dict:
        result = command("-crop", region, "-colorspace", "Gray", "-threshold", "20%",
                         "-trim", "-format", "%wx%h%O", "info:")
        match = re.fullmatch(r"(\d+)x(\d+)\+(\d+)\+(\d+)", result)
        if not match:
            raise ValueError("Unexpected first-row bounds: " + result)
        width, height, x, y = map(int, match.groups())
        return {"x": x, "y": y, "width": width, "height": height}

    return {"sha256": hashlib.sha256(data).hexdigest(), "pixels": [1242, 2688],
        "colorspace": command("-format", "%[colorspace]", "info:"),
        "surfaces": command("-format", "background=%[pixel:p{0,700}] header=%[pixel:p{0,150}]", "info:"),
        "row_colors": histogram("600x850+600+300"),
        "selected_tab_colors": histogram("140x120+980+2450"),
        "first_row_arrow": bounds("150x120+0+285"),
        "first_row_icon": bounds("150x120+1092+285")}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("native", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    reference, native = measure(args.reference), measure(args.native)
    deltas = {}
    for key in ("first_row_arrow", "first_row_icon"):
        deltas[key] = {axis: (native[key][axis] - reference[key][axis]) / 3
                       for axis in ("x", "y", "width", "height")}
    report = {"scope": "More first-row geometry and flat colors only; no full visual parity claim",
        "reference": reference, "native": native, "native_minus_reference_points": deltas,
        "full_visual_parity": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(deltas))
