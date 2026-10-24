#!/usr/bin/env python3
"""Collect named tab and settings XCTest PNGs from an xcresulttool attachment export.

This checks capture completeness and provenance. Visual parity still requires
reviewing the real screenshots against the supplied Tachimanga references.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess


TABS = ("library", "updates", "browse", "history", "more")
EXPECTED = tuple(f"msl-{language}-dark-{index:02d}-{tab}"
                 for language in ("en", "ar") for index, tab in enumerate(TABS, 1))
SETTINGS = ("general", "appearance", "library", "reader", "backup", "privacy", "about")
EXPECTED += tuple(f"msl-{language}-dark-settings-{page}" for language in ("en", "ar") for page in SETTINGS)


def collect(attachments: Path, destination: Path) -> dict:
    manifest = json.loads((attachments / "manifest.json").read_text())
    if not isinstance(manifest, list):
        raise ValueError("xcresulttool attachment manifest must be a list")
    found = {}
    for test in manifest:
        for attachment in test.get("attachments", []):
            exported_name = attachment.get("exportedFileName", "")
            human_name = attachment.get("suggestedHumanReadableName", "")
            if not exported_name.lower().endswith(".png"):
                continue
            for name in EXPECTED:
                if not re.fullmatch(re.escape(name) + r"(?:_\d+_.+)?(?:\.png)?", human_name):
                    continue
                if name in found:
                    raise ValueError(f"duplicate named screenshot: {name}")
                if Path(exported_name).name != exported_name:
                    raise ValueError("exported screenshot filename must not contain a path")
                source = attachments / exported_name
                data = source.read_bytes()
                if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
                    raise ValueError(f"invalid native PNG: {exported_name}")
                width, height = struct.unpack(">II", data[16:24])
                if width < 640 or height < 1000 or height <= width:
                    raise ValueError(f"unexpected portrait iPhone screenshot dimensions: {width}x{height}")
                found[name] = {"source": source, "test": test.get("testName", test.get("testIdentifier")),
                               "width": width, "height": height, "bytes": len(data),
                               "sha256": hashlib.sha256(data).hexdigest()}
    missing = sorted(set(EXPECTED) - set(found))
    if missing:
        raise ValueError("missing native screenshots: " + ", ".join(missing))
    if len({item["sha256"] for item in found.values()}) != len(EXPECTED):
        raise ValueError("different tab/locale captures produced identical screenshot bytes")
    if len({(item["width"], item["height"]) for item in found.values()}) != 1:
        raise ValueError("all captures must use the same simulator viewport")
    destination.mkdir(parents=True, exist_ok=True)
    screenshots = []
    for name in EXPECTED:
        item = found[name].copy()
        source = item.pop("source")
        filename = name + ".png"
        shutil.copyfile(source, destination / filename)
        screenshots.append({"file": filename, **item})
    return {"captured_at": datetime.now(timezone.utc).isoformat(), "expected_screenshots": len(EXPECTED),
            "captured_screenshots": len(screenshots), "screenshots": screenshots,
            "capture_gate": "passed", "visual_parity": "NOT REVIEWED",
            "scope": "real production app, five tabs and seven settings pages, English/Arabic, dark, fresh empty store; first viewport per page",
            "remaining": "populated library, light, accessibility, smaller phone, reference comparison, physical iPhone"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--provenance", type=Path, required=True)
    arguments = parser.parse_args()
    report = collect(arguments.attachments, arguments.destination)
    report["provenance"] = json.loads(arguments.provenance.read_text())
    report["collected_from_commit"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True).strip()
    path = arguments.destination.parent / "capture-report.json"
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"capture_gate": report["capture_gate"], "screenshots": len(EXPECTED),
                      "visual_parity": report["visual_parity"], "report": str(path)}))


if __name__ == "__main__":
    main()
