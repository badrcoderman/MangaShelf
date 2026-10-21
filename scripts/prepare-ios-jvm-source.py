#!/usr/bin/env python3
"""Apply reviewed Zero and Darwin link fixes to the pinned OpenJDK source."""
import hashlib
from pathlib import Path
import sys

PINNED_FILES = {
    "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp": "8451f0f8bea69dbb16e6f26c1dbd4c7b3e96e39850206e5a0e91940bf030da08",
    "make/autoconf/toolchain.m4": "699cc380f9d7a4ba5706f5110873be142fb0832a06f7343549f3b1dead05288a",
    "make/autoconf/flags-cflags.m4": "1411da4d9dc6def3d2e9e97ff28a3aaa0e4d4b0915b0d3315a2a8afc5dd38cbc",
    "make/common/native/Link.gmk": "0c6a92cf88b5d951435775faf360b66e94722bb79433bbcc3ed6df31cfe07896",
    "make/common/JdkNativeCompilation.gmk": "6d85c79bb814444d2a032a14aacab63081685390bf104e87090d64230bf1a164",
    "make/autoconf/flags-ldflags.m4": "42d0721eeeee7c303e85599c44fa0ab6c702e26196c4ea2309b4d2a10904c0dc",
    "make/modules/java.base/lib/CoreLibraries.gmk": "be4e69e243695695dfbaef04620a51ebf25e5c1e06989e84e9c74bc34264b7fe",
}

def prepare(source_root, project_root):
    # Validate every input before writing any file. A partially changed checkout
    # must not receive just some of the fixes.
    originals = {}
    for name, expected in PINNED_FILES.items():
        original = (source_root / name).read_bytes()
        if hashlib.sha256(original).hexdigest() != expected:
            raise ValueError(f"Refusing to patch changed or already patched source: {name}")
        originals[name] = original
    compat = (project_root / "runtime-native/ios_jvm_compat.cpp").read_bytes()
    results = dict(originals)
    zero = "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
    results[zero] += b"""
// MangaShelf: definitions absent from this pinned interpreter-only iOS port.
#if defined(__IOS__) && defined(MACOS_AARCH64)
#define MSL_OPENJDK_ZERO 1
#define MSL_OPENJDK_ZERO_SOURCE 1
#include "msl_ios_zero_compat.hpp"
#endif
"""
    replacements = {
        "make/autoconf/toolchain.m4": (
            b'if test "x$OPENJDK_TARGET_OS" = xmacosx; then\n      SHARED_LIBRARY_SUFFIX',
            b'if test "x$OPENJDK_TARGET_OS" = xmacosx || test "x$OPENJDK_TARGET_OS" = xios; then\n      SHARED_LIBRARY_SUFFIX',
        ),
        "make/autoconf/flags-cflags.m4": (
            b'if test "x$OPENJDK_TARGET_OS" = xmacosx; then\n      # Linking is different on MacOSX',
            b'if test "x$OPENJDK_TARGET_OS" = xmacosx || test "x$OPENJDK_TARGET_OS" = xios; then\n      # Apple platforms use Darwin dynamic-library flags.',
        ),
        "make/common/native/Link.gmk": (
            b'ifeq ($(call isTargetOs, macosx), true)\n    SetSharedLibraryName',
            b'ifeq ($(call isTargetOs, macosx ios), true)\n    SetSharedLibraryName',
        ),
        "make/common/JdkNativeCompilation.gmk": (
            b'ifeq ($(call isTargetOs, macosx), true)\n    SetExecutableOrigin',
            b'ifeq ($(call isTargetOs, macosx ios), true)\n    SetExecutableOrigin',
        ),
        "make/autoconf/flags-ldflags.m4": (
            b'&& test "x$OPENJDK_TARGET_OS" != xaix; then\n    if test -n "$HAS_NOEXECSTACK"; then',
            b'&& test "x$OPENJDK_TARGET_OS" != xaix \\\n      && test "x$OPENJDK_TARGET_OS" != xmacosx \\\n      && test "x$OPENJDK_TARGET_OS" != xios; then\n    if test -n "$HAS_NOEXECSTACK"; then',
        ),
        "make/modules/java.base/lib/CoreLibraries.gmk": (
            b'    LIBS_aix := $(LIBDL) $(LIBM), \\\n    LIBS_macosx :=',
            b'    LIBS_aix := $(LIBDL) $(LIBM), \\\n    LIBS_ios := -framework CoreFoundation, \\\n    LIBS_macosx :=',
        ),
    }
    for name, (before, after) in replacements.items():
        if results[name].count(before) != 1:
            raise ValueError(f"Expected one reviewed replacement in {name}")
        results[name] = results[name].replace(before, after)
    for name, result in results.items():
        (source_root / name).write_bytes(result)
    (source_root / zero).with_name("msl_ios_zero_compat.hpp").write_bytes(compat)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare-ios-jvm-source.py OPENJDK_ROOT")
    try:
        prepare(Path(sys.argv[1]), Path(__file__).resolve().parent.parent)
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
    print("Applied pinned Zero definitions, Darwin link flags and iOS libjava CoreFoundation")


if __name__ == "__main__":
    main()
