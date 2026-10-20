#!/usr/bin/env python3
"""Cross-check selected reader AOT contracts without executing reference code.

Requires the user's analysis tree (FlutterApp and dae-export-single-cpu) and
Capstone. Emits metadata only; no proprietary instructions or executable bytes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, __version__ as capstone_version

APP_SHA256 = "4ee96f784bd111cd23842e98f66d5f8b49fd635ef6ed1bee92d22c763c255469"
METHODS = {
    0x4D8EAC: "single-page set initialization",
    0x501F9C: "chapter/page to spread index",
    0x50203C: "spread identity predicate",
    0x502648: "single or paired page presentation",
    0x504500: "spread to flat-page progress index",
    0x5046B8: "image-size callback arguments",
    0x50470C: "landscape or square image detection",
    0x504B3C: "deferred single-page set update",
    0x504BCC: "copy and publish single-page set",
    0x8617E8: "reader list dependencies",
    0x8619D4: "chapter-scoped page pairing",
    0x8634F8: "skip-first preference precedence",
    0x8636B0: "invert-pair preference precedence",
}
# Reviewed instruction anchors. Their meanings are described in the report;
# matching instructions verifies evidence locations, not runtime equivalence.
ANCHORS = [
    (0x8618A4, "bl", 0x4F1DF8, "single-page-set provider"),
    (0x8618E4, "bl", 0x50810C, "skip-first provider"),
    (0x8619B0, "bl", 0x8619D4, "pairing inputs"),
    (0x861A70, "bl", 0x16A774, "sort chapters before flattening"),
    (0x861F58, "b.ge", 0x862044, "no second page past chapter end"),
    (0x862058, "cbnz", 0x86210C, "first-page-only condition"),
    (0x862060, "tbnz", 0x862100, "skip-first boolean"),
    (0x862188, "blr", None, "current page membership"),
    (0x86218C, "tbnz", 0x862230, "current not forced single"),
    (0x862240, "b.eq", 0x862368, "missing second page"),
    (0x8622B8, "blr", None, "next page membership"),
    (0x8622BC, "tbnz", 0x86235C, "next not forced single"),
    (0x862404, "ldur", None, "pair consumes next page"),
    (0x862408, "add", None, "advance chapter page cursor"),
    (0x502024, "bl", 0x16E704, "indexWhere over spreads"),
    (0x50206C, "b.ne", 0x502098, "compare first page chapter"),
    (0x5020CC, "b.eq", 0x502108, "compare second page chapter"),
    (0x504568, "b.eq", 0x504578, "one or two pages per spread"),
    (0x504588, "b.ge", 0x50459C, "preserve old page within same spread"),
    (0x504618, "sub", None, "last flat page within chosen spread"),
    (0x50268C, "tbnz", 0x502774, "full-width single versus two slots"),
    (0x50277C, "tbnz", 0x502788, "swap pair presentation"),
    (0x5027AC, "b.eq", 0x502800, "empty first slot"),
    (0x502810, "b.eq", 0x502868, "empty second slot"),
    (0x504770, "fdiv", None, "image dimension ratio"),
    (0x504774, "fmov", None, "ratio threshold one"),
    (0x504784, "csel", None, "ratio greater than or equal"),
    (0x504788, "tbz", 0x50479C, "landscape or square continues"),
    (0x5047A8, "b.ne", 0x5047BC, "reader data availability"),
    (0x5049E0, "bl", 0x1E218, "match generated page URL suffix"),
    (0x504AC0, "bl", 0x14D2C, "chapter hash page key"),
    (0x504AF8, "bl", 0x1E93B0, "schedule microtask"),
    (0x504BB0, "bl", 0x504BCC, "publish detected single page"),
    (0x504C18, "bl", 0x6D520, "copy set"),
    (0x504C28, "bl", 0x8785E8, "add key"),
    (0x504C38, "bl", 0x124764, "publish state"),
    (0x8635FC, "b.ne", 0x863608, "title skip-first overrides global"),
    (0x8637B4, "b.ne", 0x8637C0, "title inversion overrides global"),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def inspect(root, *, methods=None, selected_anchors=None, filenames=None, pool_markers=None, operand_anchors=()):
    methods = METHODS if methods is None else methods
    selected_anchors = ANCHORS if selected_anchors is None else selected_anchors
    filenames = filenames or ("reader_controller_v2.dart", "double_page_reader_mode_v2.dart", "reader_setting_controller.dart")
    app = (root / "FlutterApp").read_bytes()
    if sha(app) != APP_SHA256:
        raise ValueError("Wrong reference App image")
    if app[:4] != bytes.fromhex("cffaedfe"):
        raise ValueError("Expected thin little-endian Mach-O 64")
    segments, cursor = [], 32
    for _ in range(struct.unpack_from("<I", app, 16)[0]):
        command, size = struct.unpack_from("<II", app, cursor)
        if size < 8 or cursor + size > len(app):
            raise ValueError("Invalid load command")
        if command == 0x19:
            _, address, _, offset, file_size = struct.unpack_from("<16sQQQQ", app, cursor + 8)
            segments.append((address, offset, file_size))
        cursor += size

    def code_at(address, size):
        for base, offset, file_size in segments:
            if base <= address and address + size <= base + file_size:
                return app[offset + address - base:offset + address - base + size]
        raise ValueError(f"Unmapped code: {address:x}")

    directory = root / "flutter-full/dae-export-single-cpu/dart"
    files = [next(directory.glob("*" + name)) for name in filenames]
    sections, hashes = {}, {}
    for file in files:
        hashes[file.name] = sha(file.read_bytes())
        # Read only the disassembly comment sections, never execute pseudocode.
        for match in re.finditer(r"^// ([A-Za-z_][A-Za-z_0-9]*)\n// raw disassembly:\n(.*?)(?=^dynamic |\Z)", file.read_text(), re.M | re.S):
            instructions = [(int(a, 16), m, o.strip()) for a, m, o in re.findall(
                r"^//  (0x[0-9a-f]+): ([a-z0-9.]+)[ \t]*(.*?)$", match[2], re.M)]
            if instructions and instructions[0][0] in methods:
                sections[instructions[0][0]] = (match[1], instructions)
    if set(sections) != set(methods):
        raise ValueError("Missing selected disassembly")
    pool_file = root / "flutter-full/dae-export-single-cpu/text/pp.txt"
    pool = pool_file.read_text()
    hashes["../text/pp.txt"] = sha(pool_file.read_bytes())
    pool_markers = pool_markers if pool_markers is not None else {"0x13e8": "#", "0x18e18": "/manga", "0x1a880": "/chapter/",
                    "0x260f8": "/page/", "0x32bd0": "[Reader2] skipFirstPage:",
                    "0x32bd8": ", singlePageSet:"}
    for offset, literal in pool_markers.items():
        expected = f"[pp+{offset}] String: {json.dumps(literal)}"
        if expected not in pool.splitlines():
            raise ValueError(f"Pool marker mismatch at {offset}")
    decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    decoded, records = {}, []
    for start, (name, exported) in sorted(sections.items()):
        size = exported[-1][0] + 4 - start
        code = code_at(start, size)
        machine = list(decoder.disasm(code, start))
        if [i.address for i in machine] != [a for a, _, _ in exported]:
            raise ValueError(f"Noncontiguous or mismatched instructions: {name}")
        direct_calls, branches = [], 0
        addresses = {i.address for i in machine}
        for ins, (address, mnemonic, operands) in zip(machine, exported):
            if ins.mnemonic != mnemonic:
                raise ValueError(f"Instruction mnemonic mismatch at {address:x}")
            decoded[address] = ins
            if mnemonic in ("b", "bl", "cbz", "cbnz", "tbz", "tbnz") or mnemonic.startswith("b."):
                machine_target = int(ins.op_str.rsplit("#", 1)[1], 0)
                exported_target = int(operands.rsplit("#", 1)[1], 0)
                if machine_target != exported_target:
                    raise ValueError(f"Branch/call mismatch at {address:x}")
                if mnemonic == "bl":
                    direct_calls.append({"at": hex(address), "target": hex(machine_target)})
                else:
                    branches += 1
                    if machine_target not in addresses:
                        raise ValueError(f"Unreviewed branch outside function at {address:x}")
        records.append({"address": hex(start), "name": name, "purpose": methods[start],
                        "bytes": size, "instructions": len(machine), "code_sha256": sha(code),
                        "internal_branches": branches, "direct_calls": direct_calls,
                        "indirect_calls": sum(i.mnemonic == "blr" for i in machine)})
    anchors = []
    for address, mnemonic, target, meaning in selected_anchors:
        ins = decoded[address]
        if ins.mnemonic != mnemonic or (target is not None and int(ins.op_str.rsplit("#", 1)[1], 0) != target):
            raise ValueError(f"Anchor mismatch at {address:x}")
        anchors.append({"at": hex(address), "meaning": meaning, "verified": True})
    for address, mnemonic, operands, meaning in operand_anchors:
        ins = decoded[address]
        if ins.mnemonic != mnemonic or ins.op_str != operands:
            raise ValueError(f"Operand anchor mismatch at {address:x}")
        anchors.append({"at": hex(address), "meaning": meaning, "verified": True})
    return {"format": 1, "specimen": "Tachimanga 5.1 build 520 (modified supplied sample)",
            "image_sha256": APP_SHA256, "export_files_sha256": hashes,
            "capstone_version": capstone_version, "verified_pool_markers": pool_markers,
            "scope": "Static reader pairing and progress contracts; no reference code executed",
            "methods": records, "anchors": anchors,
            "totals": {"methods": len(records), "instructions": sum(r["instructions"] for r in records),
                       "code_bytes": sum(r["bytes"] for r in records), "anchors": len(anchors)},
            "limits": ["No runtime or UI equivalence test", "Not original source recovery",
                       "No proof for all gestures or all indirect-call targets",
                       "No production reader changes in this analysis step"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = inspect(args.analysis_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["totals"]))
