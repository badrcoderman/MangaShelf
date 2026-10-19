#!/usr/bin/env python3
"""Read a supplied IPA as data and record bounded, reproducible static evidence.

No specimen code is executed or extracted into the application. This is a package,
Mach-O header and Java signature review, not a decompiler or runtime validation.
"""
import argparse
import datetime
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def member(archive, name, limit=100 * 1024 * 1024):
    info = archive.getinfo(name)
    if info.file_size > limit or info.flag_bits & 1:
        raise ValueError("Encrypted or oversized member: " + name)
    return archive.read(info)  # ZIP reader also checks CRC.


def macho(data, base=0):
    if data[base:base + 4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a thin little-endian 64-bit Mach-O")
    _, cpu, subtype, kind, count, command_bytes, flags, _ = struct.unpack_from("<8I", data, base)
    if count > 4096 or base + 32 + command_bytes > len(data):
        raise ValueError("Invalid Mach-O load commands")
    result = {"cpu_type": hex(cpu), "cpu_subtype": subtype,
              "architecture": "arm64" if cpu == 0x100000c else hex(cpu),
              "file_type": kind, "flags": hex(flags), "cryptid": None,
              "loads": [], "segments": [], "selected_symbols": []}
    pos = base + 32
    for _ in range(count):
        cmd, size = struct.unpack_from("<II", data, pos)
        if size < 8 or pos + size > base + 32 + command_bytes:
            raise ValueError("Invalid Mach-O command size")
        if cmd in (0x21, 0x2c):
            result["cryptid"] = struct.unpack_from("<I", data, pos + 16)[0]
        if cmd & 0x7fffffff in (0xc, 0x18, 0x1f, 0x23):
            offset = struct.unpack_from("<I", data, pos + 8)[0]
            if not 8 <= offset < size:
                raise ValueError("Invalid Mach-O dylib name")
            result["loads"].append(data[pos + offset:pos + size].split(b"\0")[0].decode("utf8", "replace"))
        if cmd == 0x19:
            name = data[pos + 8:pos + 24].split(b"\0")[0].decode("ascii", "replace")
            vm, vm_size, file_offset, file_size = struct.unpack_from("<4Q", data, pos + 24)
            result["segments"].append({"name": name, "vm_address": hex(vm), "vm_size": vm_size,
                                       "file_offset": file_offset, "file_size": file_size})
        if cmd == 2:
            table, symbols, strings, string_size = struct.unpack_from("<4I", data, pos + 8)
            if symbols > 1_000_000 or base + table + symbols * 16 > len(data) or base + strings + string_size > len(data):
                raise ValueError("Invalid Mach-O symbol table")
            for index in range(symbols):
                name_offset, _, _, _, address = struct.unpack_from("<IBBHQ", data, base + table + index * 16)
                if not 0 < name_offset < string_size:
                    continue
                start = base + strings + name_offset
                end = data.find(b"\0", start, min(start + 512, base + strings + string_size))
                if end < 0:
                    continue
                name = data[start:end].decode("utf8", "replace")
                if re.search(r"J9_CreateJavaVM|JNI_CreateJavaVM|JavaLauncher|NativeNet|NativeChannel|Java_org_tachiyomi", name):
                    if len(result["selected_symbols"]) < 200:
                        result["selected_symbols"].append({"name": name, "address": hex(address)})
        pos += size
    return result


def java_signatures(data):
    stream = io.BytesIO(data)

    def take(size):
        value = stream.read(size)
        if len(value) != size:
            raise ValueError("Truncated class")
        return value

    def u2():
        return struct.unpack(">H", take(2))[0]

    def attributes():
        for _ in range(u2()):
            u2()
            take(struct.unpack(">I", take(4))[0])

    if take(4) != b"\xca\xfe\xba\xbe":
        raise ValueError("Invalid class header")
    minor, major = u2(), u2()
    pool = [None] * u2()
    index = 1
    while index < len(pool):
        tag = take(1)[0]
        if tag == 1:
            pool[index] = take(u2()).decode("utf8", "replace")
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            take(4)
        elif tag in (5, 6):
            take(8)
            index += 1
        elif tag in (7, 8, 16, 19, 20):
            take(2)
        elif tag == 15:
            take(3)
        else:
            raise ValueError("Unknown constant-pool tag")
        index += 1
    take(6)
    take(u2() * 2)
    for _ in range(u2()):  # Fields.
        take(6)
        attributes()
    methods = []
    for _ in range(u2()):
        access, name, signature = u2(), u2(), u2()
        methods.append({"name": pool[name], "descriptor": pool[signature], "native": bool(access & 0x100)})
        attributes()
    return {"sha256": digest(data), "class_version": [major, minor], "methods": methods}


def review(path):
    with path.open("rb") as stream:
        hasher = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
        identity = hasher.hexdigest()
    report = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "input": {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": identity},
              "scope": "static data only; no specimen execution", "limitations": [
                  "A patched, user-supplied IPA does not establish official-distribution provenance.",
                  "Strings, symbols and class signatures establish presence, not runtime behavior.",
                  "No Flutter widget tree, original source project, or physical-device verification recovered."]}
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 4096 or sum(i.file_size for i in entries) > 512 * 1024 * 1024:
            raise ValueError("IPA inventory limits exceeded")
        for entry in entries:
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
                raise ValueError("Unsafe member path")
        roots = [i.filename[:-len("Info.plist")] for i in entries
                 if i.filename.count("/") == 2 and i.filename.endswith(".app/Info.plist")]
        if len(roots) != 1:
            raise ValueError("Expected one application root")
        root = roots[0]
        info = plistlib.loads(member(archive, root + "Info.plist", 1024 * 1024))
        keys = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
                "CFBundleVersion", "MinimumOSVersion", "DTSDKName")
        report["bundle"] = {k: info.get(k) for k in keys}
        report["inventory"] = {"entries": len(entries), "expanded_bytes": sum(i.file_size for i in entries)}
        report["native"] = {}
        for relative in [info["CFBundleExecutable"], "Frameworks/App.framework/App"]:
            data = member(archive, root + relative)
            report["native"][relative] = {"bytes": len(data), "sha256": digest(data), **macho(data)}
            if relative.endswith("/App"):
                pattern = re.compile(rb"[\x20-\x7e]{6,}")
                needles = re.compile(r"WithMangaId|tapZones|DoublePageReaderMode|Crop page borders|autoScrollInterval|ReaderTapZone", re.I)
                markers = [{"file_offset": m.start(), "text": m.group().decode("ascii")}
                           for m in pattern.finditer(data)
                           if len(m.group()) <= 240 and needles.search(m.group().decode("ascii"))]
                report["reader_markers"] = markers[:100]
                report["reader_marker_coverage"] = {"ascii_matches": len(markers), "retained": min(len(markers), 100),
                                                     "omitted": max(0, len(markers) - 100),
                                                     "scope": "selected ASCII names only; not complete Flutter strings or feature coverage"}
        raw = member(archive, root + "MCHome.bundle/res.zip", 80 * 1024 * 1024)
        with zipfile.ZipFile(io.BytesIO(raw)) as classes:
            items = classes.infolist()
            if len(items) > 50000 or sum(i.file_size for i in items) > 256 * 1024 * 1024:
                raise ValueError("Java archive limits exceeded")
            report["java_archive"] = {"sha256": digest(raw), "entries": len(items),
                                      "class_entries": sum(i.filename.endswith(".class") for i in items),
                                      "selected_contracts": {}}
            for name in ("org/tachiyomi/NativeNet.class", "org/tachiyomi/NativeChannel.class",
                         "suwayomi/tachidesk/manga/impl/util/PackageTools.class"):
                report["java_archive"]["selected_contracts"][name] = java_signatures(member(classes, name, 2 * 1024 * 1024))
        for relative in ["jre/release", "jre/lib/jvm.cfg", "jre/lib/options.default"]:
            if root + relative in archive.namelist():
                report.setdefault("java_runtime_configuration", {})[relative] = member(archive, root + relative, 64 * 1024).decode("utf8", "replace")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = review(args.ipa)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(args.output), "input": result["input"], "bundle": result["bundle"]}, indent=2))
