#!/usr/bin/env python3
"""Measure selected shared components in real 414x896 @3x reference/capture PNGs.

ImageMagick decodes the images. Fixed regions deliberately limit this report to
the supplied Arabic dark screenshots; this is not a full visual parity gate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess


class Screenshot:
    def __init__(self, path):
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (1242, 2688):
            raise ValueError("Expected a 1242x2688 PNG: " + str(path))
        self.sha256 = hashlib.sha256(data).hexdigest()
        self.rgb = subprocess.check_output(["magick", str(path), "-depth", "8", "RGB:-"])
        if len(self.rgb) != 1242 * 2688 * 3:
            raise ValueError("Unexpected decoded image size")

    def pixel(self, x, y):
        offset = (y * 1242 + x) * 3
        return self.rgb[offset:offset + 3]

    def points(self, region, predicate):
        x, y, width, height = region
        return {(xx, yy) for yy in range(y, y + height) for xx in range(x, x + width)
                if predicate(self.pixel(xx, yy))}

    @staticmethod
    def bounds(points):
        if not points:
            return None
        xs, ys = zip(*points)
        return dict(x=min(xs), y=min(ys), width=max(xs) - min(xs) + 1, height=max(ys) - min(ys) + 1)

    def bright_bounds(self, region, threshold=420):
        return self.bounds(self.points(region, lambda rgb: sum(rgb) > threshold))

    def selected_capsule(self):
        # Select the largest connected flat selected-color region, excluding
        # unrelated antialiasing pixels in the glass perimeter.
        remaining = self.points((880, 2430, 320, 200), lambda rgb: rgb == bytes((58, 58, 60)))
        largest = set()
        while remaining:
            start = remaining.pop()
            stack, component = [start], {start}
            while stack:
                x, y = stack.pop()
                for point in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                    if point in remaining:
                        remaining.remove(point); component.add(point); stack.append(point)
            if len(component) > len(largest):
                largest = component
        return self.bounds(largest)

    def about_arrows(self):
        points = self.points((20, 750, 100, 1000), lambda rgb: sum(rgb) > 200)
        rows = sorted({y for _, y in points})
        runs = []
        for y in rows:
            if not runs or y > runs[-1][-1] + 1:
                runs.append([y])
            else:
                runs[-1].append(y)
        return [self.bounds({p for p in points if run[0] <= p[1] <= run[-1]}) for run in runs]


def measure(more, about, menu, reference):
    more, about, menu = map(Screenshot, (more, about, menu))
    regions = {"more_icon": (960, 2460, 180, 90), "more_label": (960, 2550, 180, 60),
               "library_icon": (100, 2460, 170, 90), "history_icon": (760, 2460, 150, 90)}
    return {"sha256": {"more": more.sha256, "about": about.sha256, "menu": menu.sha256},
            "tabs": {**{key: more.bright_bounds(region) for key, region in regions.items()},
                     "selected_capsule": more.selected_capsule()},
            "about": {"back": about.bright_bounds((1092, 140, 140, 130)),
                      "row_arrows": about.about_arrows()},
            "menu_refresh_icon": menu.bright_bounds((420, 210 if reference else 790, 80, 80))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference_directory", type=Path)
    parser.add_argument("capture_directory", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    ref, native = args.reference_directory, args.capture_directory
    reference = measure(ref / "IMG_5304.png", ref / "IMG_5336.png", ref / "IMG_5327.png", True)
    captured = measure(native / "msl-ar-dark-05-more.png", native / "msl-ar-dark-settings-about.png",
                       native / "msl-ar-dark-library-options.png", False)
    deltas = {}
    for key in reference["tabs"]:
        a, b = reference["tabs"][key], captured["tabs"][key]
        if a and b:
            deltas[key] = {axis: (b[axis] - a[axis]) / 3 for axis in a}
    report = {"scope": "fixed Arabic dark More, About and Library-menu regions, 414x896 @3x",
              "threshold": "glyphs: RGB sum > 420; dim row chevrons: > 200; capsule: largest flat #3A3A3C component",
              "reference": reference, "native": captured, "tab_deltas_points": deltas,
              "limitations": ["Menu actions differ; compare refresh glyph dimensions only, not row position.",
                              "Glyph bounds do not identify the font or prove full-screen parity.",
                              "Reference About is v5.0(511); static IPA is 5.1/520."],
              "full_visual_parity": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"measured": True, "output": str(args.output), "full_visual_parity": False}))


if __name__ == "__main__":
    main()
