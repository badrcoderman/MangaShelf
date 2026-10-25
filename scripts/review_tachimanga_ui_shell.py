#!/usr/bin/env python3
"""Verify selected UI AOT exports against the supplied Mach-O as static data.

REA's artifact evidence establishes the input identity; the existing bounded
Capstone reader verifies the Flutter export without loading reference code.
"""
import argparse
import hashlib
import json
from pathlib import Path

from review_tachimanga_reader import inspect, APP_SHA256

METHODS = {
    0x542670: "More screen composition",
    0x5D5300: "General settings composition",
    0x53AE08: "Custom tab configuration screen",
    0x5D4500: "Custom tab configuration row",
    0x5D46E0: "iOS 26 custom tab preview",
    0x5D4B9C: "Fallback custom tab preview",
    0x5D4FBC: "Tab labels switch",
    0x5CE9C0: "Content padding above the floating tab bar",
    0x5CEB7C: "Selection toolbar and native root tab visibility",
    0x5CED1C: "Bottom sheet padding above the tab bar",
    0x5CEE60: "Positioned action bar",
}

ANCHORS = [
    (0x53AE48, "bl", 0x4149F0, "tab configuration reads native glass toolbar policy"),
    (0x53AFD8, "bl", 0x53B7F8, "tab configuration obtains navigation item data"),
    (0x53B4BC, "bl", 0x4147A4, "tab configuration builds native page header"),
    (0x542BFC, "bl", 0x4149F0, "More reads native glass toolbar policy"),
    (0x542DD8, "bl", 0x4475A8, "More obtains the shared primary scroll controller"),
    (0x5CE9F8, "bl", 0x5E7CC, "padding reads MediaQuery when available"),
    (0x5CEA54, "bl", 0x1E9D44, "padding watches the glass-enabled provider"),
    (0x5CEA60, "bl", 0x331268, "padding reads keyboard view insets"),
    (0x5CEA7C, "bl", 0x5CEB7C, "padding consults bottom bar visibility"),
    (0x5CEAFC, "bl", 0x5AB60, "padding copies insets with an explicit bottom value"),
    (0x5CEB10, "bl", 0x2F7038, "padding wraps copied MediaQuery data"),
    (0x5CEBD0, "bl", 0x1E9D44, "visibility watches selection toolbar state"),
    (0x5CEBDC, "bl", 0x43B4D0, "visibility looks up native root tabs"),
    (0x5D4758, "bl", 0x53B7F8, "iOS 26 preview obtains navigation item data"),
    (0x5D4C14, "bl", 0x53B7F8, "fallback preview uses the same navigation data"),
    (0x5D5354, "bl", 0x4149F0, "General reads native glass toolbar policy"),
    (0x5D5584, "bl", 0x4147A4, "General builds native page header"),
]


def review(root: Path, rea_evidence: Path) -> dict:
    rea = json.loads(rea_evidence.read_text())
    if (rea.get("operation") != "inspect_artifact"
            or rea["subject"]["digest"]["sha256"] != APP_SHA256
            or rea["subject"]["format"] != "mach-o"):
        raise ValueError("REA evidence does not identify the reviewed Flutter image")
    result = inspect(root, methods=METHODS, selected_anchors=ANCHORS,
        filenames=("more_screen_lite.dart", "general_screen.dart",
                   "custom_tabs_config_screen.dart", "liquid_glass_tab_bar_padding.dart"),
        pool_markers={})
    functions = json.loads((root / "flutter-full/app-functions.json").read_text())
    names = {}
    for row in functions:
        label = ".".join(filter(None, (row["class_name"], row["method"])))
        names.setdefault(row["address"], set()).add(label)
    for method in result["methods"]:
        for call in method["direct_calls"]:
            call["exported_target_names"] = sorted(names.get(call["target"], ()))
    result["scope"] = "Static UI shell, tab configuration and padding; no reference code executed"
    result["rea_artifact"] = {"evidence_id": rea["evidence_id"],
        "sha256": hashlib.sha256(rea_evidence.read_bytes()).hexdigest(),
        "provider": rea["provider"],
        "scope": "Input identity only; artifact inspection does not decompile Flutter"}
    result["limits"] = ["Not original Dart/Flutter source recovery",
        "No UI or runtime equivalence test", "Indirect callbacks are not resolved by this review",
        "AOT method names do not establish exact rendered fonts, colors or gestures",
        "Screenshots show v5.0(511); reviewed AOT sample is modified 5.1(520)"]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis_root", type=Path)
    parser.add_argument("rea_evidence", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = review(args.analysis_root, args.rea_evidence)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["totals"]))
