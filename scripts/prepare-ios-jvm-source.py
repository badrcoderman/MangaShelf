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
    "make/modules/java.base/Lib.gmk": "f85b5faeecf778c704c8fa5ea5371494622a2e9167e94cf36986ad70ed0cf48c",
    "src/java.base/macosx/native/libnio/fs/UTIFileTypeDetector.c": "7706136f78495d9c33ac4e153a44089b871a7e02d6c926152f1c689e492b3b62",
    "make/modules/java.prefs/Lib.gmk": "b69c8f19d49de73318e3032f2855e054b513788094271b1d4776d73b6c716dad",
    "make/modules/java.instrument/Lib.gmk": "a8665634a69b13563f95b406d333da504efe927465c97773aa187d1d8771b57c",
    "make/autoconf/libraries.m4": "bf75cabbaccfa7650e878c7ada059dcd9f0823d434e55c0feae167365eb27383",
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
    filetype = (project_root / "runtime-native/ios_filetype.m").read_bytes()
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
        "make/modules/java.base/Lib.gmk": (
            b'    LIBS_linux := $(LIBDL) $(LIBPTHREAD), \\\n    LIBS_aix := $(LIBDL), \\\n    LIBS_macosx :=',
            b'    LIBS_linux := $(LIBDL) $(LIBPTHREAD), \\\n    LIBS_aix := $(LIBDL), \\\n    LIBS_ios := -lobjc -framework CoreFoundation -framework Foundation -framework UniformTypeIdentifiers, \\\n    LIBS_macosx :=',
        ),
        "make/autoconf/libraries.m4": (
            b'if test "x$OPENJDK_TARGET_OS" == "xaix" || test "x$OPENJDK_TARGET_OS" == "xmacosx"; then\n    ICONV_CFLAGS=',
            b'if test "x$OPENJDK_TARGET_OS" == "xaix" || test "x$OPENJDK_TARGET_OS" == "xmacosx" \\\n      || test "x$OPENJDK_TARGET_OS" == "xios"; then\n    ICONV_CFLAGS=',
        ),
        "src/java.base/macosx/native/libnio/fs/UTIFileTypeDetector.c": (
            b'    jstring result = NULL;\n\n    CFStringRef extension = toCFString(env, ext);',
            b'#ifdef __IOS__\n    extern jstring msl_ios_filetype_probe(JNIEnv *, jstring);\n    return msl_ios_filetype_probe(env, ext);\n#else\n    jstring result = NULL;\n\n    CFStringRef extension = toCFString(env, ext);',
        ),
    }
    for name, (before, after) in replacements.items():
        if results[name].count(before) != 1:
            raise ValueError(f"Expected one reviewed replacement in {name}")
        results[name] = results[name].replace(before, after)
    for name, libraries in [
        ("make/modules/java.prefs/Lib.gmk", b'-framework CoreFoundation -framework Foundation'),
    ]:
        before = b'    LIBS_macosx := \\\n'
        if results[name].count(before) != 1:
            raise ValueError(f"Expected one reviewed Apple library setting in {name}")
        results[name] = results[name].replace(before, b'    LIBS_ios := ' + libraries + b', \\\n' + before)
    # Darwin's launcher implementation also has explicit __IOS__ branches.
    # Compiling the generic Unix java_md.c beside it defines ten symbols twice.
    core = "make/modules/java.base/lib/CoreLibraries.gmk"
    before = b'ifeq ($(call isTargetOs, macosx), true)\n  LIBJLI_EXCLUDE_FILES += java_md.c\nendif'
    after = b'ifeq ($(call isTargetOs, macosx ios), true)\n  LIBJLI_EXCLUDE_FILES += java_md.c\nendif'
    if results[core].count(before) != 1:
        raise ValueError("Expected one reviewed libjli platform exclusion")
    results[core] = results[core].replace(before, after)
    base = "make/modules/java.base/Lib.gmk"
    before = b'    NAME := nio, \\\n    OPTIMIZATION := HIGH,'
    after = b'    NAME := nio, \\\n    msl_ios_filetype.m_CFLAGS := -fobjc-arc -fobjc-arc-exceptions, \\\n    OPTIMIZATION := HIGH,'
    if results[base].count(before) != 1:
        raise ValueError("Expected one reviewed libnio ARC setting")
    results[base] = results[base].replace(before, after)
    uti = "src/java.base/macosx/native/libnio/fs/UTIFileTypeDetector.c"
    before = b'    return result;\n}\n'
    if results[uti].count(before) != 1:
        raise ValueError("Expected one reviewed UTI probe return")
    results[uti] = results[uti].replace(before, b'    return result;\n#endif\n}\n')
    for name, result in results.items():
        (source_root / name).write_bytes(result)
    (source_root / zero).with_name("msl_ios_zero_compat.hpp").write_bytes(compat)
    (source_root / uti).with_name("msl_ios_filetype.m").write_bytes(filetype)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare-ios-jvm-source.py OPENJDK_ROOT")
    try:
        prepare(Path(sys.argv[1]), Path(__file__).resolve().parent.parent)
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
    print("Applied pinned Zero/Darwin fixes, iOS NIO file types and libjli selection")


if __name__ == "__main__":
    main()
