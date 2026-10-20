#!/usr/bin/env python3
"""Apply the reviewed Zero W^X fix to exactly the pinned OpenJDK source."""
import hashlib
from pathlib import Path
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare-ios-jvm-source.py OPENJDK_ROOT")
    root = Path(__file__).resolve().parent.parent
    source = Path(sys.argv[1]) / "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
    original = source.read_bytes()
    expected = "8451f0f8bea69dbb16e6f26c1dbd4c7b3e96e39850206e5a0e91940bf030da08"
    if hashlib.sha256(original).hexdigest() != expected:
        raise SystemExit("Refusing to patch a changed or already patched bsd_zero source")
    compat = (root / "runtime-native/ios_jvm_compat.cpp").read_bytes()
    (source.parent / "msl_ios_zero_compat.hpp").write_bytes(compat)
    source.write_bytes(original + b"""
// MangaShelf: definitions absent from this pinned interpreter-only iOS port.
#if defined(__IOS__) && defined(MACOS_AARCH64)
#define MSL_OPENJDK_ZERO 1
#define MSL_OPENJDK_ZERO_SOURCE 1
#include "msl_ios_zero_compat.hpp"
#endif
""")
    print("Applied source fix using the full upstream os.hpp declaration")


if __name__ == "__main__":
    main()
