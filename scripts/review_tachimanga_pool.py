#!/usr/bin/env python3
"""Verify the external read-only pool query and independently decode Double bits."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess

from review_tachimanga_reader import APP_SHA256
from prepare_tachimanga_pool_tool import COMMIT, FILES


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def signed_bits(data):
    """Dart signed stream, terminal contribution b-0xc0; bounded to 64 bits."""
    if not 1 <= len(data) <= 10:
        raise ValueError("Invalid numeric byte length")
    value = 0
    for index, byte in enumerate(data):
        if byte & 0x80:
            if index != len(data) - 1:
                raise ValueError("Bytes remain after numeric terminator")
            value |= (byte - 0xC0) << (index * 7)
            return value & ((1 << 64) - 1)
        value |= byte << (index * 7)
    raise ValueError("Missing numeric terminator")


def review(root):
    tool = root / "flutter-full/tooling"
    source = tool / "dae-source"
    own = Path(__file__).parent
    app_path = root / "FlutterApp"
    if sha(app_path) != APP_SHA256:
        raise ValueError("Wrong reference App")
    app = app_path.read_bytes()
    query_path = root / "flutter-full/pool-followup/pool-values.json"
    if query_path.stat().st_size > 1024 * 1024:
        raise ValueError("Query output exceeds bounds")
    query = json.loads(query_path.read_text())
    if query["target_executed"] is not False or query["warnings"]:
        raise ValueError("Unexpected query execution flag or warnings")
    if (query["snapshot_hash"], query["iso_function_count"], query["pool_entries"],
            query["double_values_captured"]) != ("f956f595844a2f845a55707faaaa51e4", 58419, 71800, 490):
        raise ValueError("Unexpected snapshot identity/counts")
    baseline = json.loads((own.parent / "validation/rea/tachimanga-5.1-flutter-deep.json").read_text())
    # The full export's original pool cardinality must match the new query.
    if query["pool_entries"] != baseline["export"]["object_pool_entries"]:
        raise ValueError("Pool cardinality changed from full export")
    functions = (root / "flutter-full/dae-export-single-cpu/text/functions.txt").read_text()
    known_entries = set(re.findall(r'^(0x[0-9a-f]+)\t', functions, re.M))
    checked_doubles = {}

    def verify(value):
        if "double_bits" in value:
            begin, end = value["serialized_range"]
            if not 0 <= begin < end <= len(app):
                raise ValueError("Numeric range outside App")
            raw = app[begin:end]
            bits = signed_bits(raw)
            number = struct.unpack("<d", bits.to_bytes(8, "little"))[0]
            if raw.hex() != value["serialized_hex"] or hex(bits) != value["double_bits"]:
                raise ValueError("Independent numeric decoding disagrees")
            if math.isfinite(number):
                if number != value["double"]:
                    raise ValueError("Floating point value disagrees")
            elif not math.isinf(number) or value["double"] != str(number):
                raise ValueError("Unexpected nonfinite value")
            checked_doubles[value["reference"]] = {"bits": value["double_bits"],
                "value": value["double"], "serialized_range": [begin, end]}
        if "entry" in value and value["entry"] not in known_entries:
            raise ValueError("Function entry absent from original index")
        if "elements" in value:
            if value["length"] != len(value["elements"]):
                raise ValueError("Array count disagrees")
            for child in value["elements"]:
                verify(child)

    entries = {entry["offset"]: entry["value"] for entry in query["entries"]}
    if len(entries) != len(query["entries"]):
        raise ValueError("Duplicate requested offsets")
    for value in entries.values():
        verify(value)
    factors = [v["double"] for v in entries["0x38f88"]["elements"]]
    thresholds = [v["double"] for v in entries["0x38f98"]["elements"]]
    if factors != [3.0, 2.0, 1.5, 1.25, 1.0, 0.75, 0.5, 0.25]:
        raise ValueError("Speed factor array changed")
    if thresholds != [-180.0, -120.0, -60.0, -30.0, 60.0, 120.0, 180.0]:
        raise ValueError("Speed threshold array changed")
    expected_functions = {
        "0x39088": "0x511f84", "0x38f28": "0x511578", "0x38fa0": "0x5115a0",
        "0x38f30": "0x511520", "0x38f38": "0x511174", "0x38f40": "0x51111c",
        "0x38f48": "0x51111c", "0x2f870": "0x50ca70", "0x2f878": "0x50c950",
        "0x2f860": "0x50cd88", "0x2f868": "0x50cb90",
    }
    for offset, entry in expected_functions.items():
        if entries[offset].get("entry") != entry:
            raise ValueError("Callback binding changed: " + offset)
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() != COMMIT:
        raise ValueError("Wrong upstream source")
    for name, expected in FILES.items():
        original = subprocess.check_output(["git", "show", "HEAD:" + name], cwd=source)
        if hashlib.sha256(original).hexdigest() != expected:
            raise ValueError("Wrong original source hash")
    if (own / "tachimanga_pool_audit.rs").read_bytes() != (source / "src/bin/pool_audit.rs").read_bytes():
        raise ValueError("Helper differs from recorded build input")
    inputs = ["Cargo.lock", "src/engine/snapshot.rs", "src/engine/fill.rs",
              "src/bin/pool_audit.rs", "profiles/sdk/dart-3.6.1-w64-no-compressed.json",
              "profiles/platform/macho-arm64.json"]
    return {"format": 1, "target_executed": False, "image_sha256": APP_SHA256,
        "scope": "Read-only parsed pool metadata with independent numeric-byte check",
        "query_sha256": sha(query_path), "query_counts": {k: query[k] for k in
            ["iso_function_count", "pool_entries", "double_values_captured"]},
        "query_offsets": [entry["offset"] for entry in query["entries"]],
        "query_limits": {"address_space_bytes": 3 * 1024**3, "cpu_seconds": 60,
                         "wall_seconds": 90, "cpus": 1},
        "speed_factors": factors, "vertical_thresholds": thresholds,
        "verified_doubles": checked_doubles,
        "functions": {k: v for k, v in entries.items() if v.get("kind") == "Function"},
        "fields": {k: v for k, v in entries.items() if v.get("kind") == "Field"},
        "argument_descriptors": {k: [v.get("integer", v.get("string")) for v in entries[k]["elements"]]
            for k in ["0x160a8", "0x26f98", "0x390e8", "0x38f58"]},
        "provenance": {"upstream": "https://github.com/ejfkdev/dae", "tag": "v0.1.13",
            "commit": COMMIT, "license": "MIT", "build_profile": "release",
            "rust_version": "1.90.0 (1159e78c4 2025-09-14)",
            "cargo_arguments": ["build", "--release", "--locked", "--no-default-features", "--bin", "pool_audit"],
            "upstream_original_sha256": FILES,
            "build_inputs_sha256": {p: sha(source / p) for p in inputs},
            "binary_sha256": sha(tool / "dae-target/release/pool_audit"),
            "build_log_sha256": sha(tool / "pool-audit-release-build.log"),
            "rust_components_sha256": sha(tool / "rust-components.json"),
            "own_scripts_sha256": {p: sha(own / p) for p in
                ["prepare_tachimanga_pool_tool.py", "tachimanga_pool_audit.rs", "review_tachimanga_pool.py"]}},
        "limits": ["Array membership and function metadata come from the reviewed parser",
            "Only numeric byte decoding is independently implemented here",
            "Stock debug build panicked in upstream instance bitmap shift; release query succeeded",
            "No runtime, original-source recovery or physical iPhone equivalence claim"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = review(args.analysis_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"numeric_objects_verified": len(result["verified_doubles"]),
                      "speed_factors": result["speed_factors"], "vertical_thresholds": result["vertical_thresholds"]}))
