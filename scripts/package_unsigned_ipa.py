#!/usr/bin/env python3
"""Package an existing Xcode device build; never compile or fabricate an app.

Structural checks reject simulator/non-arm64/non-executable Mach-O files.
They do not replace dyld validation, code signing or a device launch test.
"""
import argparse
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import zipfile


def validate_executable(data: bytes) -> None:
    if len(data) < 32:
        raise ValueError("Missing or truncated Mach-O executable")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, 2):
        raise ValueError("Expected a thin ARM64 Mach-O executable")
    if count > 4096 or size > len(data) - 32:
        raise ValueError("Invalid Mach-O load-command bounds")
    cursor, end, ios = 32, 32 + size, False
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, length = struct.unpack_from("<2I", data, cursor)
        if length < 8 or length % 8 or length > end - cursor:
            raise ValueError("Invalid Mach-O load-command size")
        if command == 0x32:  # LC_BUILD_VERSION; PLATFORM_IOS is 2, SIMULATOR is 7.
            if length < 24 or struct.unpack_from("<I", data, cursor + 8)[0] != 2:
                raise ValueError("Executable is not built for an iOS device")
            ios = True
        cursor += length
    if cursor != end or not ios:
        raise ValueError("Missing iOS device build metadata")


def package(app: Path, output: Path) -> None:
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ValueError("Provide a real .app produced by Xcode")
    app = app.resolve()
    output = output.absolute()
    if output.suffix != ".ipa" or output.resolve().is_relative_to(app):
        raise ValueError("Output must be an .ipa outside the app bundle")
    members = sorted(app.rglob("*"))
    for member in members:
        if member.is_symlink() or not (member.is_dir() or member.is_file()):
            raise ValueError("Unexpected link or special file in the app bundle")
        if member.name in {"_CodeSignature", "embedded.mobileprovision"}:
            raise ValueError("Use a fresh unsigned build without stale signing files")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise ValueError("Invalid CFBundleExecutable")
    if executable in {".", ".."} or "\\" in executable:
        raise ValueError("Invalid executable path")
    if info.get("CFBundlePackageType") != "APPL" or info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("Bundle is not an iPhoneOS application")
    binary = app / executable
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("App executable is missing or lacks executable permissions")
    if binary.stat().st_size > 512 * 1024 * 1024:
        raise ValueError("Executable exceeds this project's packaging limit")
    validate_executable(binary.read_bytes())
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".ipa-", suffix=".tmp", dir=output.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for member in members:
                if member.is_file():
                    name = Path("Payload") / app.name / member.relative_to(app)
                    archive.write(member, name.as_posix())
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA archive CRC verification failed")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        package(args.app, args.output)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(2, f"No IPA produced: {error}\n")
    print(f"Created {args.output}. Unsigned: signing is required before installation.")
