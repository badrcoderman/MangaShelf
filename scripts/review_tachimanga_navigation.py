#!/usr/bin/env python3
"""Review static tap-layout geometry and callback selection; never run AOT code."""
import argparse
import json
from pathlib import Path
import re

from review_tachimanga_reader import inspect

METHODS = {
    0x394690: "invertTap preference default",
    0x3C40C8: "normal navigation preference default",
    0x3C4564: "webtoon navigation preference fallback",
    0x3E1B0C: "outer reader gesture and navigation overlay composition",
    0x3F81D8: "Edge layout widget tree",
    0x3F8618: "Kindlish layout widget tree",
    0x3F89AC: "L-shaped layout widget tree",
    0x3F8E54: "RightAndLeft layout widget tree",
    0x506D7C: "callback swapping, temporary suppression and layout selection",
    0x56DB98: "invert tap settings and shared provider",
}
ANCHORS = [
    (0x3C4104, "bl", 0x3C4178, "normal preference initialized with disabled default"),
    (0x3C45D4, "b.ne", 0x3C45E4, "webtoon inherits available normal setting"),
    (0x3C4600, "bl", 0x3C4178, "webtoon has separate persisted key"),
    (0x3946C0, "bl", 0x391BB4, "invertTap boolean preference initialization"),
    (0x3E1B70, "bl", 0x2E4650, "outer GestureDetector"),
    (0x3E1B98, "bl", 0x3E1D0C, "navigation widget allocation"),
    (0x50702C, "b.ne", 0x507038, "test continuousHorizontalRTL"),
    (0x507074, "tbz", 0x507080, "RightAndLeft chooses mode branch"),
    (0x50707C, "tbz", 0x507088, "other layouts use invertTap"),
    (0x507080, "tbnz", 0x5071C0, "non RightAndLeft normal ordering"),
    (0x507084, "tbnz", 0x5071C0, "RightAndLeft LTR normal ordering"),
    (0x50733C, "bl", 0x1E9D44, "watch temporary tap-zone suppression"),
    (0x507340, "tbnz", 0x507360, "continue only while suppression is false"),
    (0x50737C, "b.le", 0x507650, "zero or negative index returns empty overlay"),
    (0x50739C, "bl", 0x5076A8, "index one allocates LShapedLayout"),
    (0x507514, "bl", 0x50769C, "index two allocates RightAndLeftLayout"),
    (0x507588, "bl", 0x507690, "index three allocates EdgeLayout"),
    (0x507608, "bl", 0x507684, "index four allocates KindlishLayout"),
    (0x3F827C, "bl", 0x2E4650, "Edge first outer callback zone"),
    (0x3F83BC, "bl", 0x2E4650, "Edge center lower callback zone"),
    (0x3F8530, "bl", 0x2E4650, "Edge last outer callback zone"),
    (0x3F873C, "bl", 0x2E4650, "Kindlish lower first callback zone"),
    (0x3F87FC, "bl", 0x2E4650, "Kindlish lower second callback zone"),
    (0x3F8A24, "bl", 0x2E4650, "LShaped upper zone"),
    (0x3F8AD4, "bl", 0x2E4650, "LShaped middle first zone"),
    (0x3F8C14, "bl", 0x2E4650, "LShaped middle last zone"),
    (0x3F8D6C, "bl", 0x2E4650, "LShaped lower zone"),
    (0x3F8EF8, "bl", 0x2E4650, "RightAndLeft first zone"),
    (0x3F9038, "bl", 0x2E4650, "RightAndLeft last zone"),
]
# Actual ARM64 operands (Capstone register names). These pin the callback
# sources and unequal flex weights used by the analyst-derived widget trees.
OPERANDS = [
    (0x3946B4, "add", "x3, x22, #0x30", "invertTap defaults to Dart false"),
    (0x3F81F4, "ldur", "x0, [x1, #0x17]", "Edge outer callback B"),
    (0x3F8310, "mov", "x0, #2", "Edge center upper gap flex two"),
    (0x3F8334, "ldur", "x3, [x2, #0xf]", "Edge center lower callback A"),
    (0x3F83D0, "mov", "x0, #1", "Edge center lower flex one"),
    (0x3F8634, "ldur", "x0, [x1, #0x3f]", "Kindlish upper gap label"),
    (0x3F8690, "mov", "x0, #1", "Kindlish upper gap flex one"),
    (0x3F86B4, "ldur", "x4, [x3, #0xf]", "Kindlish lower first callback A"),
    (0x3F8774, "ldur", "x3, [x2, #0x17]", "Kindlish lower second callback B"),
    (0x3F8810, "mov", "x0, #2", "Kindlish lower B width flex two"),
    (0x3F88E0, "mov", "x0, #2", "Kindlish lower row height flex two"),
    (0x3F89C8, "ldur", "x0, [x1, #0xf]", "LShaped upper callback A"),
    (0x3F8A38, "mov", "x0, #1", "LShaped upper height flex one"),
    (0x3F8A5C, "ldur", "x4, [x3, #0x2f]", "LShaped middle first label A"),
    (0x3F8B8C, "ldur", "x4, [x3, #0x17]", "LShaped middle last callback B"),
    (0x3F8D80, "mov", "x0, #1", "LShaped lower height flex one"),
    (0x3F8E70, "ldur", "x0, [x1, #0xf]", "RightAndLeft first callback A"),
    (0x3F8F8C, "mov", "x0, #1", "RightAndLeft gap width flex one"),
    (0x3F8FB0, "ldur", "x4, [x3, #0x17]", "RightAndLeft last callback B"),
    (0x506F28, "ldr", "x0, [x26, #0x60]", "read shared static field table"),
    (0x506F2C, "ldr", "x0, [x0, #0x3580]", "read invertTap shared provider"),
    (0x56DCCC, "ldr", "x0, [x0, #0x3580]", "settings read identical invertTap provider"),
    (0x507088, "ldur", "x3, [x1, #0x27]", "swapped first callback uses original second"),
    (0x5071C0, "ldur", "x0, [x1, #0x1f]", "normal first callback uses original first"),
]


def review(root):
    result = inspect(root, methods=METHODS, selected_anchors=ANCHORS, operand_anchors=OPERANDS,
        filenames=("reader_navigation_layout.dart", "reader_wrapper.dart", "layouts_edge_layout.dart",
                   "layouts_kindlish_layout.dart", "layouts_l_shaped_layout.dart", "layouts_right_and_left_layout.dart",
                   "reader_navigation_layout_tile.dart", "reader_invert_tap_tile.dart"),
        pool_markers={"0x38cf8": "readerNavigationLayout", "0x38d20": "readerNavigationLayoutWebtoon",
                      "0x38de8": "invertTap", "0x46410": "Tap zone temporarily disabled"})
    pool = (root / "flutter-full/dae-export-single-cpu/text/pp.txt").read_text()
    enum_markers = {}
    for offset, expected in {"0x15cd0": (2, "rightAndLeft"), "0x15cb8": (5, "disabled"),
                             "0x25c48": (0, "defaultNavigation"),
                             "0x18d18": (3, "singleHorizontalRTL"), "0x18d28": (5, "continuousHorizontalRTL"),
                             "0xb580": (2, "translucent")}.items():
        prefix = re.escape(f"[pp+{offset}]")
        block = re.search(prefix + r'[^\n]*\n(.*?)(?=\n\[pp\+|\Z)', pool, re.S)
        match = re.search(r'off_8: int\((0x[0-9a-f]+)\),\s*off_10: "([^"\n]+)"', block[1]) if block else None
        if not match or (int(match[1], 16), match[2]) != expected:
            raise ValueError("Enum marker mismatch: " + offset)
        enum_markers[offset] = {"index": expected[0], "name": expected[1]}
    result["scope"] = "Static tap layout and callback selection; no reference code executed"
    result["verified_enum_markers"] = enum_markers
    result["analyst_derived_layouts"] = {
        "1_LShaped": [["A", "A", "A"], ["A", "G", "B"], ["B", "B", "B"]],
        "2_RightAndLeft": [["A", "G", "B"], ["A", "G", "B"], ["A", "G", "B"]],
        "3_Edge": [["B", "G", "B"], ["B", "G", "B"], ["B", "A", "B"]],
        "4_Kindlish": [["G", "G", "G"], ["A", "B", "B"], ["A", "B", "B"]],
    }
    result["grid_legend"] = {
        "A": "first callback field after selection", "B": "second callback field after selection",
        "G": "gap without layout-specific GestureDetector; final parent tap action not established",
        "columns": "Row child order, not verified physical left-to-right screen coordinates",
        "rows": "Column child order; equal thirds shown where applicable",
    }
    result["analyst_derived_swap_table"] = [
        {"layout_index": index, "rtl_mode": rtl, "invertTap": invert,
         "callbacks_swapped": rtl if index == 2 else invert}
        for index in range(1, 5) for rtl in (False, True) for invert in (False, True)
    ]
    result["limits"] = ["Not a runtime, gesture-arena or UI geometry test", "Not original source recovery",
                        "Outer callback semantic names and inherited physical Directionality remain open",
                        "Does not trace all pointer, double-tap, long-press or zoom behavior",
                        "No production reader changes"]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = review(args.analysis_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["totals"]))
