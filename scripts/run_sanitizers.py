#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="mangashelf-sanitizers-") as temporary:
    executable = Path(temporary)/"fuzz-native"
    subprocess.run(["cc", "-std=c11", "-g", "-O1", "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
                    "-Wall", "-Wextra", "-Werror", "-I", str(ROOT/"Sources/CSafeArchive/include"),
                    str(ROOT/"Sources/CSafeArchive/archive.c"), str(ROOT/"scripts/fuzz_native.c"), "-lz", "-o", str(executable)],check=True)
    environment = dict(os.environ)
    # LeakSanitizer needs /proc task access unavailable in this runtime. Disable
    # that separate check; ASan bounds/UAF and UBSan remain active.
    environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
    environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    result=subprocess.run([str(executable),str(ROOT/"Tests/ReaderCoreTests/Fixtures/TestComic.cbz")],capture_output=True,text=True,timeout=60,env=environment)
    report={"exit_code":result.returncode,"stdout":result.stdout,"stderr":result.stderr,
            "instrumentation":["AddressSanitizer","UndefinedBehaviorSanitizer"],
            "leak_detection":"disabled: runtime denies /proc task access",
            "random_inputs":30000,"seeded_mutations":30000,
            "scope":"C ZIP/GZIP/Protobuf only; not Swift, image codecs or JVM"}
    destination=ROOT/"validation";destination.mkdir(exist_ok=True)
    (destination/"sanitizer-results.json").write_text(json.dumps(report,indent=2)+"\n")
    print(result.stdout,end="");print(result.stderr,end="")
    raise SystemExit(result.returncode)
