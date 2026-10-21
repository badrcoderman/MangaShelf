#!/usr/bin/env python3
"""Verify selected pointer/timer/speed evidence without running specimen code."""
import argparse
import json
from pathlib import Path
import re

from review_tachimanga_reader import inspect

METHODS = {
    0x26FB0C: "Listener callback transfer to render object",
    0x38375C: "render pointer event dispatch",
    0x510B10: "FocusWrapper pointer state and Listener setup",
    0x51111C: "pointer up/cancel adapter",
    0x511174: "tracked pointer movement and speed update",
    0x511418: "speed level with hysteresis",
    0x511520: "pointer down adapter",
    0x511578: "effect returning timer cleanup",
    0x5115A0: "timer cancellation on effect cleanup",
    0x5115E8: "pointer release and selective state cleanup",
    0x511A68: "pointer count, waiting timer and second-pointer cancellation",
    0x511F84: "timer firing, long press origin and initial level",
}
ANCHORS = [
    (0x5111D8, "bl", 0x796850, "compare event pointer id with tracked id"),
    (0x5111DC, "tbz", 0x5111F0, "only matching pointer reaches movement update"),
    (0x5112A0, "b.ne", 0x5112AC, "non-longPressing movement returns"),
    (0x511300, "bl", 0x511418, "derive new speed level from delta and old level"),
    (0x51132C, "bl", 0x796850, "compare new level with old level"),
    (0x511330, "tbnz", 0x511344, "only changed level reaches speed callback"),
    (0x5113CC, "bl", 0x2CA4D0, "selection haptic when speed level changes"),
    (0x51143C, "bl", 0x7D134, "clamp old speed level"),
    (0x51149C, "b.lt", 0x5114A8, "leave decrement loop above lower hysteresis boundary"),
    (0x5114A4, "b", 0x511460, "repeat decrement for multiple crossed levels"),
    (0x5114E0, "b.lt", 0x5114F0, "leave increment loop below upper hysteresis boundary"),
    (0x5114EC, "b", 0x5114A8, "repeat increment for multiple crossed levels"),
    (0x5115CC, "bl", 0x148FC, "effect cleanup cancels existing timer"),
    (0x511794, "bl", 0x796850, "release matches tracked pointer id"),
    (0x5117C4, "b.ne", 0x5118A0, "release distinguishes waiting from active long press"),
    (0x511830, "bl", 0x148FC, "release while waiting cancels timer"),
    (0x511898, "blr", None, "waiting release invokes short action"),
    (0x5118C0, "tbz", 0x5118D0, "matching pointer ends active long press"),
    (0x5118CC, "cbnz", 0x51193C, "unmatched release ends only at zero pointer count"),
    (0x511938, "blr", None, "active release invokes end action"),
    (0x511940, "tbnz", 0x511A48, "unmatched release skips tracked-position cleanup"),
    (0x511BAC, "b.ne", 0x511CC4, "already tracked pointer is not replaced"),
    (0x511CE0, "b.ne", 0x511E5C, "only init state creates a new timer"),
    (0x511D34, "bl", 0x2D808, "record down timestamp from current micros"),
    (0x511DF8, "bl", 0x1022C, "create one-shot 500ms timer"),
    (0x511EA0, "tbnz", 0x511F6C, "second-pointer path requires count greater than one"),
    (0x511F04, "b.ge", 0x511F6C, "second-pointer cancellation only before 500ms"),
    (0x511F20, "bl", 0x148FC, "second-pointer path cancels timer"),
    (0x5120B8, "b.ne", 0x5120C0, "medium haptic only with absent pointerEvent"),
    (0x5120BC, "bl", 0x2ECC88, "medium-impact haptic on non-pointer path"),
    (0x5120EC, "blr", None, "timer invokes long-press start callback"),
]
OPERANDS = [
    (0x26FBCC, "ldur", "x0, [x1, #0x37]", "Listener fourth callback source"),
    (0x26FBD0, "stur", "x0, [x2, #0xcf]", "fourth callback stored in render object"),
    (0x38398C, "cmp", "x3, #0xee6", "PointerCancelEvent class-id check"),
    (0x3839B4, "ldur", "x0, [x3, #0xcf]", "cancel dispatch selects same callback slot"),
    (0x5112E8, "fsub", "d2, d0, d1", "vertical displacement relative to long-press origin"),
    (0x5113A8, "mov", "x0, #8", "speed array has eight indexed slots"),
    (0x5113D8, "ldur", "x0, [x1, #0x27]", "speed-factor callback slot"),
    (0x511438, "mov", "x3, #0xe", "upper clamp is tagged Smi seven"),
    (0x51145C, "fmov", "d1, #12.00000000", "hysteresis margin is twelve logical units"),
    (0x511494, "fsub", "d3, d2, d1", "lower boundary is threshold minus hysteresis"),
    (0x5114D8, "fadd", "d3, d2, d1", "upper boundary is threshold plus hysteresis"),
    (0x51186C, "stur", "x22, [x0, #0xf]", "waiting-release timer reference cleared"),
    (0x511918, "ldur", "x2, [x0, #0x2f]", "end callback slot"),
    (0x511980, "stur", "x22, [x0, #0xf]", "matched release clears tracked pointer id"),
    (0x5119C0, "stur", "x22, [x0, #0xf]", "matched release clears latest position"),
    (0x511A00, "stur", "x22, [x0, #0xf]", "matched release clears long-press origin"),
    (0x511A40, "mov", "x2, #8", "matched release restores tagged Smi level four"),
    (0x511F00, "cmp", "x1, #0x1f4", "second-pointer elapsed threshold is 500 milliseconds"),
    (0x5120A4, "mov", "x1, #8", "timer sets tagged Smi initial level four"),
    (0x5120CC, "ldur", "x1, [x2, #0x1f]", "long-press start callback slot"),
]


def review(root):
    result = inspect(root, methods=METHODS, selected_anchors=ANCHORS,
        operand_anchors=OPERANDS,
        filenames=("reader_wrapper.dart", "long_press_scroll_speed.dart",
                   "flutter_src_widgets_basic.dart", "flutter_src_rendering_proxy_box.dart"),
        pool_markers={"0x38fa8": "pointerEvent"})
    pool = (root / "flutter-full/dae-export-single-cpu/text/pp.txt").read_text()
    for offset, index, name in [("0x38f10", 0, "init"), ("0x38fc0", 1, "wait"),
                                ("0x38f70", 2, "longPressing")]:
        block = re.search(re.escape(f"[pp+{offset}]") + r'[^\n]*\n(.*?)(?=\n\[pp\+|\Z)', pool, re.S)
        expected = f'off_8: int({hex(index)}),\n    off_10: "{name}"'
        if not block or expected not in block[1]:
            raise ValueError("LongPressState marker mismatch: " + offset)
    duration = re.search(r'\[pp\+0x6650\][^\n]*\n(.*?)(?=\n\[pp\+|\Z)', pool, re.S)
    if not duration or "off_8: int(0x7a120)" not in duration[1]:
        raise ValueError("500,000 microsecond duration not verified")
    classes = (root / "flutter-full/dae-export-single-cpu/text/classes.txt").read_bytes()
    for cid, name in [(3814, "_TransformedPointerCancelEvent"), (4571, "PointerCancelEvent")]:
        pattern = rf'^\S+\t{cid}\t[^\n]*\t{re.escape(name)}$'.encode()
        if not re.search(pattern, classes, re.M):
            raise ValueError("Cancel event class-id mapping not verified: " + name)
    import hashlib
    result["export_files_sha256"]["../text/classes.txt"] = hashlib.sha256(classes).hexdigest()
    result["scope"] = "Static pointer/timer lifecycle and speed evidence; no specimen code executed"
    result["verified_constants"] = {"wait_milliseconds": 500, "initial_speed_level": 4,
                                    "minimum_level": 0, "maximum_level": 7, "hysteresis": 12.0}
    result["limits"] = ["No iPhone timing, gesture-arena or UI test",
        "Keyboard dispatch and all caller callback effects are outside this method set",
        "Array factors and callback identities require the separate snapshot pool review",
        "No production gesture changes"]
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
