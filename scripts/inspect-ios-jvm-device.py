#!/usr/bin/env python3
"""Inspect our unsigned Engine Check IPA as data; never execute its contents.

The supplied runtime root must be the separately downloaded and verified source
build. This compares its complete included Java image, not just the few image
paths present in the source build manifest. GitHub artifact download/digest
verification remains the caller's responsibility; this script verifies the
selected files and their internal provenance without making network requests.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import sys
import zipfile


APP = "Payload/MangaShelfEngineCheck.app/"
NATIVE_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
                b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca", b"\x7fELF"}
JAR_CLASSES = {
    "probe/main.jar": {
        "mangashelf/probe/RuntimeProbe.class", "mangashelf/probe/RuntimeProbe$BoundaryBuffer.class",
        "mangashelf/probe/RuntimeProbe$BoundaryMissingRead.class", "mangashelf/probe/RuntimeProbe$MockOkioBuffer.class",
    },
    "probe/plugin.jar": {"probe/SourceProbe.class"},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def object_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    result = json.loads(data, object_pairs_hook=unique)
    require(isinstance(result, dict), "Expected a JSON object")
    return result


def relative_name(name, directory=False):
    require(isinstance(name, str) and name and len(name.encode("utf-8")) <= 4096, "Invalid archive path")
    require(not any(ord(char) < 32 or ord(char) == 127 for char in name), "Control character in archive path")
    require("\\" not in name and ":" not in name, f"Unsafe archive path: {name}")
    path = PurePosixPath(name)
    require(not path.is_absolute() and all(part not in {"", ".", ".."} for part in name.rstrip("/").split("/")),
            f"Unsafe archive path: {name}")
    require(name == path.as_posix() + ("/" if directory else ""), f"Noncanonical archive path: {name}")
    return path


def archive_entries(bundle, limit, total_limit, member_limit):
    entries = bundle.infolist()
    require(0 < len(entries) <= limit, "Archive entry count exceeds bounds")
    require(sum(item.file_size for item in entries) <= total_limit, "Archive decompressed size exceeds bounds")
    seen = set()
    files = {}
    for item in entries:
        require(item.orig_filename == item.filename, "Truncated archive name")
        relative_name(item.filename, item.is_dir())
        canonical = item.filename.rstrip("/").casefold()
        require(canonical not in seen, f"Duplicate or case-aliased archive entry: {item.filename}")
        seen.add(canonical)
        mode = item.external_attr >> 16
        kind = stat.S_IFMT(mode)
        require(kind in {0, stat.S_IFREG, stat.S_IFDIR} and not stat.S_ISLNK(mode), "Archive has a link or special file")
        require(kind != stat.S_IFDIR or item.is_dir(), "Archive directory mode disagrees with its name")
        require(not item.flag_bits & 1, "Encrypted archive entries are unsupported")
        require(item.compress_type in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}, "Unsupported archive compression")
        require(item.file_size <= member_limit, f"Archive member exceeds bounds: {item.filename}")
        if item.is_dir():
            require(item.file_size == 0 and item.CRC == 0, "Nonempty or invalid archive directory")
        else:
            files[item.filename] = item
    for name in files:
        require(not any(parent.as_posix() in files for parent in PurePosixPath(name).parents),
                f"Archive file shadows a parent directory: {name}")
    return entries, files


def hash_archive(bundle, files):
    result = {}
    for name, item in sorted(files.items()):
        digest, count = hashlib.sha256(), 0
        with bundle.open(item) as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                count += len(block)
                require(count <= item.file_size, f"Archive size mismatch: {name}")
                digest.update(block)
        require(count == item.file_size, f"Archive size mismatch: {name}")
        # Reading each entry through EOF also checks its ZIP CRC.
        result[name] = {"path": name, "bytes": count, "sha256": digest.hexdigest()}
    return result


def safe_runtime_file(root, name):
    relative_name(name)
    path = root / name
    require(path.resolve(strict=True).is_relative_to(root), f"Runtime file escapes its root: {name}")
    require(path.is_file(), f"Missing ordinary runtime file: {name}")
    return path


def inspect_runtime(args, selection, manifest):
    run_id = args.runtime_run_id
    repository = args.repository
    require(type(run_id) is int and run_id > 0, "A positive runtime run ID is required")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
    expected = {
        "repository": repository, "run_id": run_id, "workflow": ".github/workflows/ios-jvm.yml",
        "run_url": f"https://github.com/{repository}/actions/runs/{run_id}", "conclusion": "success",
        "java_modules_present": True, "build_manifest_verified": True, "execution_proven": False,
    }
    require(all(selection.get(key) == value for key, value in expected.items()), "Runtime selection provenance disagrees")
    require(type(selection.get("artifact_id")) is int and selection["artifact_id"] > 0, "Missing runtime artifact ID")
    require(re.fullmatch(r"[0-9a-f]{40}", selection.get("head_sha", "")), "Invalid runtime source commit")
    require(re.fullmatch(r"[0-9a-f]{64}", selection.get("artifact_sha256", "")), "Invalid runtime artifact SHA-256")
    expected = {
        "format": 1, "target": "arm64-apple-ios26.0", "vm_variant": "zero",
        "openjdk_commit": "c1ed06aaef34c8dccf71e236d1ffa20918a77cfb",
        "libffi_commit": "12ffd1f9dc56fcea79d2f742f424301ae668d663",
        "cups_ref": "2e5573560cfa2da65002f86b41bd1770c9853c4d",
        "cups_commit": "7d535f73e407a72dfb5c5e83549a5ba27219dfcd",
        "head_sha": selection["head_sha"], "run_id": str(run_id), "repository": repository,
        "zero_wx_source_fix": True, "java_modules_present": True, "ios_filetype_source_fix": True,
    }
    require(all(manifest.get(key) == value for key, value in expected.items()), "Source runtime manifest disagrees")
    if not args.legacy_runtime_without_utf8_fix:
        require(manifest.get("ios_utf8_encoding_fix") is True, "Runtime does not contain the iOS UTF-8 fix")
    hashes = manifest.get("sha256")
    require(isinstance(hashes, dict), "Missing source build hashes")
    required = {"static-libs/lib/zero/libjvm.a", "static-libs/lib/libjava.a", "ffi/lib/libffi.a",
                "jre/lib/modules", "jre/release"}
    require(required <= hashes.keys(), "Source runtime manifest omits required outputs")
    if manifest.get("ios_utf8_encoding_fix") is True:
        require(hashes.get("logs/java_props_md.c") == "dcd072f3c2f8e75327bee027a4b509842a6dd156f586712ed65ff7a0c9129c92",
                "UTF-8 source hash differs from the reviewed patch")
    root = args.runtime_root.resolve(strict=True)
    require((root / "build-provenance.json").resolve(strict=True) == args.runtime_manifest.resolve(strict=True),
            "Choose the manifest inside the supplied runtime root")
    for name, digest in hashes.items():
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid source output digest")
        require(sha256_file(safe_runtime_file(root, name)) == digest, f"Source runtime hash mismatch: {name}")
    jre = (root / "jre").resolve(strict=True)
    expected_files, omitted = {}, []
    for name in ("lib", "conf", "legal", "release"):
        source = jre / name
        require(source.exists(), f"Source Java image is missing {name}")
        candidates = [source] if source.is_file() else sorted(source.rglob("*"))
        for path in candidates:
            require(path.resolve(strict=True).is_relative_to(jre), "Java image link escapes its root")
            if path.is_dir():
                continue
            require(path.is_file(), "Java image has a special file")
            relative = path.relative_to(jre).as_posix()
            relative_name(relative)
            with path.open("rb") as handle:
                prefix = handle.read(8)
            if prefix[:4] in NATIVE_MAGIC or prefix == b"!<arch>\n" or path.suffix in {".dylib", ".so", ".a"}:
                omitted.append(relative)
            else:
                expected_files[relative] = {"path": relative, "bytes": path.stat().st_size, "sha256": sha256_file(path)}
    require({"lib/modules", "lib/tzdb.dat", "conf/security/java.security", "release"} <= expected_files.keys(),
            "Source Java image lacks required boot/configuration data")
    return root, expected_files, sorted(omitted), len(hashes)


def version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def inspect_macho(data):
    require(len(data) >= 32, "Missing Mach-O executable")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    require((magic, cpu, kind) == (0xFEEDFACF, 0x0100000C, 2), "Expected a thin ARM64 Mach-O executable")
    require(0 < count <= 4096 and size <= len(data) - 32, "Invalid Mach-O load-command bounds")
    cursor, end = 32, 32 + size
    builds, libraries, rpaths, signature_count = [], [], [], 0
    for _ in range(count):
        require(cursor + 8 <= end, "Truncated Mach-O load command")
        command, length = struct.unpack_from("<2I", data, cursor)
        require(length >= 8 and length % 8 == 0 and length <= end - cursor, "Invalid Mach-O load-command size")
        if command == 0x32:  # LC_BUILD_VERSION / PLATFORM_IOS = 2.
            require(length >= 24, "Truncated Mach-O build metadata")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", data, cursor + 8)
            require(length == 24 + 8 * tools, "Invalid Mach-O build-tool bounds")
            builds.append({"platform": platform, "minimum": version(minimum), "sdk": version(sdk)})
        elif command == 0x1D:  # LC_CODE_SIGNATURE.
            signature_count += 1
        elif command in {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20, 0x8000001C, 0xE}:
            # Dylib, rpath, and dynamic-loader commands carry an offset to a C string.
            minimum = 24 if command in {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20} else 12
            require(length >= minimum, "Truncated Mach-O path command")
            offset = struct.unpack_from("<I", data, cursor + 8)[0]
            require(minimum <= offset < length, "Invalid Mach-O path offset")
            raw = data[cursor + offset:cursor + length]
            require(b"\0" in raw, "Unterminated Mach-O library path")
            name = raw.split(b"\0", 1)[0].decode("utf-8", "strict")
            require(not any(ord(char) < 32 or ord(char) == 127 for char in name), "Invalid Mach-O library path")
            require(name.startswith(("/usr/lib/", "/System/Library/Frameworks/")) and ".." not in name.split("/"),
                    f"Executable loads a non-system dependency: {name}")
            if command == 0x8000001C:
                rpaths.append(name)
            elif command != 0xE:
                libraries.append(name)
        elif command in {0x21, 0x2C}:  # LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64.
            require(length >= 20 and struct.unpack_from("<I", data, cursor + 16)[0] == 0,
                    "Executable has encrypted content")
        cursor += length
    require(cursor == end, "Mach-O load-command size mismatch")
    require(len(builds) == 1 and builds[0]["platform"] == 2 and builds[0]["minimum"] == "26.0.0",
            "Executable is not built for iOS 26.0 devices")
    require(int(builds[0]["sdk"].split(".")[0]) >= 26, "Executable SDK predates iOS 26")
    require(signature_count == 0, "Expected an unsigned executable")
    require(libraries, "Executable has no system library metadata")
    return {"architecture": "arm64", "build_commands": builds, "code_signature_load_commands": signature_count,
            "linked_libraries": libraries, "runtime_search_paths": rpaths}


def inspect_own_jar(data, name):
    with zipfile.ZipFile(io.BytesIO(data)) as jar:
        _, files = archive_entries(jar, 64, 8 * 1024**2, 4 * 1024**2)
        class_names = {name for name in files if name.endswith(".class")}
        require(class_names == JAR_CLASSES[name], f"Unexpected project JAR class list: {name}")
        require(set(files) == class_names | {"META-INF/MANIFEST.MF"}, f"Unexpected project JAR payload: {name}")
        members = hash_archive(jar, files)
        for entry in class_names:
            header = jar.read(entry)[:8]
            require(len(header) == 8 and header[:4] == b"\xca\xfe\xba\xbe", "Malformed class header")
            minor, major = struct.unpack_from(">2H", header, 4)
            require((minor, major) == (0, 61), f"Project fixture is not Java 17 bytecode: {entry}")
        return {"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "classes": sorted(class_names), "major": 61, "members": list(members.values()), "execution": False}


def inspect(args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.expected_device_commit), "Pin the full device build commit")
    selection = object_json(args.runtime_selection.read_bytes())
    manifest = object_json(args.runtime_manifest.read_bytes())
    device = object_json(args.device_build.read_bytes())
    root, image, omitted, source_hashes = inspect_runtime(args, selection, manifest)
    require(device.get("commit") == args.expected_device_commit, "Device build source commit disagrees")
    require(device.get("runtime") == selection, "Device build runtime differs from the supplied selection")
    require(device.get("java_home_relative") == "lib" and device.get("boot_image_relative") == "lib/lib/modules",
            "Device build does not use the required early Java home layout")
    included = device.get("included_java_data")
    require(isinstance(included, list), "Missing device image file inventory")
    actual_image = {}
    for entry in included:
        require(isinstance(entry, dict) and set(entry) == {"path", "bytes", "sha256"}, "Invalid device image file entry")
        relative_name(entry["path"])
        require(entry["path"] not in actual_image, "Duplicate device image file entry")
        actual_image[entry["path"]] = entry
    require(actual_image == image, "Device Java image inventory differs from the selected source runtime")
    require(sorted(device.get("omitted_native_libraries", [])) == omitted, "Device native omissions differ from the source image")
    require(args.ipa.stat().st_size <= 256 * 1024**2, "IPA exceeds compressed input limit")
    with zipfile.ZipFile(args.ipa) as bundle:
        entries, files = archive_entries(bundle, 2048, 512 * 1024**2, 256 * 1024**2)
        require(all(name.startswith(APP) for name in files), "Unexpected app or payload outside Engine Check")
        require(not any(part in {"_CodeSignature", "embedded.mobileprovision"}
                        for name in files for part in PurePosixPath(name).parts), "IPA contains signing files")
        allowed = {APP + "lib/" + name for name in image}
        allowed |= {APP + name for name in ("Info.plist", "MangaShelfEngineCheck", "runtime-provenance.json",
                    "LICENSE", "ADDITIONAL_LICENSE_INFO", "ASSEMBLY_EXCEPTION", "libffi-LICENSE",
                    "en.lproj/Localizable.strings", "ar.lproj/Localizable.strings", *JAR_CLASSES)}
        require(set(files) == allowed, "IPA files differ from the complete Engine Check allowlist")
        members = hash_archive(bundle, files)
        info = plistlib.loads(bundle.read(APP + "Info.plist"))
        expected = {"CFBundleIdentifier": "app.mangashelf.enginecheck", "CFBundleExecutable": "MangaShelfEngineCheck",
                    "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"],
                    "CFBundleShortVersionString": args.expected_version, "CFBundleVersion": args.expected_build,
                    "MinimumOSVersion": "26.0", "MSBuildCommit": args.expected_device_commit,
                    "MSRuntimeRunID": str(args.runtime_run_id)}
        require(all(info.get(key) == value for key, value in expected.items()), "Info.plist differs from the chosen build")
        require(object_json(bundle.read(APP + "runtime-provenance.json")) == selection, "Bundled runtime provenance disagrees")
        for name, entry in image.items():
            actual = members[APP + "lib/" + name]
            require((actual["bytes"], actual["sha256"]) == (entry["bytes"], entry["sha256"]),
                    f"Bundled Java image differs from its source runtime: {name}")
        for name in ("LICENSE", "ADDITIONAL_LICENSE_INFO", "ASSEMBLY_EXCEPTION", "libffi-LICENSE"):
            source_name = "ffi/LICENSE" if name == "libffi-LICENSE" else name
            require(members[APP + name]["sha256"] == sha256_file(safe_runtime_file(root, source_name)),
                    f"Bundled license differs from source runtime: {name}")
        jars = [inspect_own_jar(bundle.read(APP + name), name) for name in JAR_CLASSES]
        source_jars = []
        for name in files:
            relative = name[len(APP):]
            if relative != "MangaShelfEngineCheck":
                with bundle.open(files[name]) as handle:
                    prefix = handle.read(8)
                require(prefix[:4] not in NATIVE_MAGIC and prefix != b"!<arch>\n",
                        f"Native executable/archive data outside the main executable: {relative}")
            if relative.endswith(".jar") and relative not in JAR_CLASSES:
                require(relative == "lib/lib/jrt-fs.jar" and "lib/jrt-fs.jar" in image,
                        "Unexpected JAR outside own fixtures and source-built jrt-fs.jar")
                source_jars.append({"path": relative, "sha256": members[name]["sha256"], "execution": False})
            require(not relative.endswith((".class", ".dex", ".apk", ".dylib", ".so", ".a")),
                    f"Unexpected executable/archive payload: {relative}")
        require(len(source_jars) == 1, "Missing source-built jrt-fs.jar")
        binary = bundle.read(APP + "MangaShelfEngineCheck")
        executable_mode = files[APP + "MangaShelfEngineCheck"].external_attr >> 16
        require(executable_mode & 0o111, "Main executable has no executable permission bits")
        macho = inspect_macho(binary)
    return {
        "file": str(args.ipa), "bytes": args.ipa.stat().st_size, "sha256": sha256_file(args.ipa),
        "source_commit": args.expected_device_commit, "runtime": selection,
        "runtime_manifest": str(args.runtime_manifest), "runtime_manifest_sha256": sha256_file(args.runtime_manifest),
        "inspection_inputs": [{"file": str(path), "sha256": sha256_file(path)}
                              for path in (args.device_build, args.runtime_selection, args.runtime_manifest)],
        "source_manifest_output_hashes_verified": source_hashes, "ios_utf8_encoding_fix": manifest.get("ios_utf8_encoding_fix") is True,
        "explicit_expectations": {"version": args.expected_version, "build": args.expected_build,
                                  "legacy_runtime_without_utf8_fix": args.legacy_runtime_without_utf8_fix},
        "bundle_identifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"], "minimum_ios": info["MinimumOSVersion"], **macho,
        "unsigned": True, "crc_verified": True, "member_count": len(entries), "file_count": len(files),
        "java_home_relative": "lib", "boot_image_relative": "lib/lib/modules",
        "java_image_file_hashes_verified": len(image), "required_image_bytes_match_source_built_runtime": True,
        "project_owned_jars": jars, "source_built_jre_jars": source_jars, "omitted_native_libraries": omitted,
        "device_execution": False, "vm_start_on_iphone_verified": False, "real_extension_execution": False,
        "scope": "Read-only static inspection of our separate unsigned VM/project-owned JAR harness. No code executed; physical iPhone test required.",
        "members": list(members.values()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ipa", "device-build", "runtime-selection", "runtime-root", "runtime-manifest"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--expected-device-commit", required=True)
    parser.add_argument("--runtime-run-id", required=True, type=int)
    parser.add_argument("--repository", default="badrcoderman/MangaShelf")
    parser.add_argument("--expected-version", default="0.1.1")
    parser.add_argument("--expected-build", default="2")
    parser.add_argument("--legacy-runtime-without-utf8-fix", action="store_true",
                        help="Historical artifact inspection only; records that the UTF-8 fix was not required")
    args = parser.parse_args()
    try:
        result = inspect(args)
    except (OSError, ValueError, KeyError, TypeError, struct.error, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(2, f"IPA inspection failed: {error}\n")
    print(json.dumps(result, indent=2) + "\n", end="")


if __name__ == "__main__":
    main()
