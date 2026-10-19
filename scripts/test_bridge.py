#!/usr/bin/env python3
"""Test the production C callback bridge without Swift, JNI, or a JVM."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VALIDATION = ROOT / "validation"
COMPILER = shlex.split(os.environ.get("CC", "cc"))
FLAGS = ["-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Werror", "-Wpedantic", "-pthread"]
SOURCES = [ROOT / "Sources/CSafeArchive/MSJNIBridge.c", ROOT / "scripts/bridge_regression.c"]


def run(command, *, env=None):
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=30, env=env)
        return {"command": [str(part) for part in command], "exit_code": completed.returncode,
                "stdout": completed.stdout, "stderr": completed.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"command": [str(part) for part in command], "exit_code": None, "error": str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-leak-check", action="store_true",
                        help="disable LeakSanitizer when sandbox /proc enumeration is unavailable")
    args = parser.parse_args()
    VALIDATION.mkdir(exist_ok=True)
    report = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "production MSJNIBridge.c with synthetic native callbacks; no Swift/JNI/iOS build",
              "tests_per_run": 9, "runs": [], "leak_detection": not args.no_leak_check,
              "concurrency_limit": "disabling/unregistering blocks subsequent snapshots; captured calls may complete"}
    with tempfile.TemporaryDirectory(prefix="mangashelf-bridge-") as temporary:
        for name, extra in [("strict", ["-O2"]),
                            ("asan-ubsan", ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"])]:
            binary = Path(temporary) / name
            command = COMPILER + FLAGS + extra + ["-I", str(ROOT / "Sources/CSafeArchive/include")]
            command += [str(path) for path in SOURCES] + ["-o", str(binary)]
            result = {"mode": name, "compile": run(command)}
            if result["compile"]["exit_code"] == 0:
                environment = os.environ.copy()
                environment["ASAN_OPTIONS"] = f"detect_leaks={0 if args.no_leak_check else 1}:halt_on_error=1"
                environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
                result["execute"] = run([str(binary)], env=environment)
                result["passed"] = result["execute"]["exit_code"] == 0
            else:
                result["passed"] = False
            report["runs"].append(result)
    report["passed"] = all(result["passed"] for result in report["runs"])
    destination = VALIDATION / "bridge-test-results.json"
    destination.write_text(json.dumps(report, indent=2) + "\n")
    for result in report["runs"]:
        print(f"{result['mode']}: {'PASS' if result['passed'] else 'FAIL'}")
        for phase in ("compile", "execute"):
            details = result.get(phase, {})
            for key in ("stdout", "stderr", "error"):
                if details.get(key): print(details[key], end="" if details[key].endswith("\n") else "\n")
    print(f"Report: {destination}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
