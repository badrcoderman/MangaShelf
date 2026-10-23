#!/usr/bin/env python3
"""Exercise the native/JNI adapter using only project-owned Java fixture code."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java-home", type=Path)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    java_home = args.java_home
    if java_home is None:
        executable = shutil.which("java")
        if not executable:
            parser.error("Java is required; no test was run")
        java_home = Path(executable).resolve().parents[1]
    java_home = java_home.resolve()
    java = java_home / "bin/java"
    system = "darwin" if platform.system() == "Darwin" else "linux"
    for path in (java, java_home / "include/jni.h", java_home / "include" / system / "jni_md.h"):
        if not path.is_file():
            parser.error("Missing explicit JDK input: " + str(path))
    inputs = [ROOT / "runtime-native/MSJavaRuntime.c", ROOT / "runtime-native/MSJavaRuntime.h",
              ROOT / "runtime-native/MSJavaBridge.c", ROOT / "runtime-native/MSJavaBridge.h",
              ROOT / "Sources/CSafeArchive/MSJNIBridge.c", ROOT / "Sources/CSafeArchive/include/MSJNIBridge.h",
              ROOT / "runtime-native/tests/BridgeFixture.java", ROOT / "runtime-native/tests/java_bridge_test.c"]
    report = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "Host JVM and project-owned fixture only; actual ms_bridge_dispatch to JNI adapter. No real extension or iOS adapter execution.",
              "checks": ["requires explicit successful VM start and backend resolution",
                         "actual callback bridge reaches linked JNI VM",
                         "native-owned large UTF-8 response with one Java execution",
                         "fixed-buffer overflow and size query execute once without replay",
                         "native output bounds and oversized inputs reject with empty ownership",
                         "embedded NUL preserved by generic API and rejected by C-string adapter",
                         "Java exception and lookup failure recovery, including repeated failed initialization",
                         "already-attached caller remains attached and its preexisting exception survives",
                         "four concurrent workers detach their own JNI attachment",
                         "disable blocks new work while captured Java invocation completes",
                         "uninstall does not destroy or restart the process VM"],
              "inputs_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}}
    try:
        with tempfile.TemporaryDirectory(prefix="mangashelf-java-bridge-") as temporary:
            directory = Path(temporary)
            classes = directory / "classes"
            classes.mkdir()
            subprocess.run([str(java), "-m", "jdk.compiler/com.sun.tools.javac.Main", "--release", "17",
                            "-encoding", "UTF-8", "-d", str(classes), str(inputs[-2])], check=True, timeout=60)
            library = java_home / "lib/server"
            executable = directory / "java-bridge-test"
            command = [args.cc, "-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Werror", "-Wpedantic", "-pthread",
                       "-I" + str(java_home / "include"), "-I" + str(java_home / "include" / system),
                       "-I" + str(ROOT / "runtime-native"), "-I" + str(ROOT / "Sources/CSafeArchive/include"),
                       *[str(inputs[index]) for index in (0, 2, 4, 7)], "-L" + str(library),
                       "-Wl,-rpath," + str(library), "-ljvm", "-o", str(executable)]
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
            result = subprocess.run([str(executable), str(classes), str(java_home)], capture_output=True, text=True, timeout=60)
            report.update(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr,
                          passed=result.returncode == 0)
        version = subprocess.run([str(java), "-version"], capture_output=True, text=True, timeout=15)
        report["host_java"] = version.stderr.strip()
    except (subprocess.SubprocessError, OSError) as error:
        report.update(passed=False, error=str(error))
        if isinstance(error, subprocess.CalledProcessError):
            report.update(stdout=error.stdout, stderr=error.stderr)
    destination = ROOT / "validation/java-bridge-host.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
