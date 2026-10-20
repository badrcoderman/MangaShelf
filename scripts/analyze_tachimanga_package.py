#!/usr/bin/env python3
"""Inventory every IPA member as data, including native linkage and declarations.

Writes metadata only. Never launches the application or imports its code. This
is structural coverage, not a claim to understand every function's behavior.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def version(number):
    return f"{number >> 16}.{(number >> 8) & 255}.{number & 255}"


def text(data, start, end):
    if not 0 <= start <= end <= len(data):
        raise ValueError("Invalid string bounds")
    terminator = data.find(b"\0", start, end)
    return data[start:end if terminator < 0 else terminator].decode("utf8", "replace")


def native_slice(data):
    if data[:4] != b"\xcf\xfa\xed\xfe" or len(data) < 32:
        raise ValueError("Unsupported Mach-O header")
    _, cpu, subtype, kind, count, length, flags, _ = struct.unpack_from("<8I", data)
    end = 32 + length
    if count > 4096 or end > len(data):
        raise ValueError("Invalid Mach-O commands")
    result = {"cpu": hex(cpu), "subtype": subtype, "file_type": kind, "flags": hex(flags),
              "segments": [], "dependencies": [], "symbols": [], "load_commands": [], "cryptid": None}
    position = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or size % 8 or position + size > end:
            raise ValueError("Invalid Mach-O command bounds")
        item = {"command": hex(command), "file_offset": position, "bytes": size}
        if command == 0x19:
            name = text(data, position + 8, position + 24)
            vm, vm_size, offset, file_size, max_prot, init_prot, nsects, _ = struct.unpack_from("<4Q4I", data, position + 24)
            if 72 + nsects * 80 > size or offset + file_size > len(data):
                raise ValueError("Invalid Mach-O segment")
            segment = {"name": name, "vm": hex(vm), "vm_bytes": vm_size, "offset": offset,
                       "file_bytes": file_size, "max_protection": max_prot, "initial_protection": init_prot, "sections": []}
            for index in range(nsects):
                cursor = position + 72 + index * 80
                section_name = text(data, cursor, cursor + 16)
                section_segment = text(data, cursor + 16, cursor + 32)
                address, section_size, section_offset, alignment, relocation, relocation_count, section_flags, *_ = struct.unpack_from("<2Q8I", data, cursor + 32)
                segment["sections"].append({"name": section_name, "segment": section_segment, "address": hex(address),
                                            "bytes": section_size, "offset": section_offset, "flags": hex(section_flags),
                                            "relocations": relocation_count})
            result["segments"].append(segment)
        elif command & 0x7fffffff in (0xc, 0x18, 0x1f, 0x23, 0xd):
            name_offset, timestamp, current, compatibility = struct.unpack_from("<4I", data, position + 8)
            if not 24 <= name_offset < size:
                raise ValueError("Invalid dylib command")
            dependency = {"path": text(data, position + name_offset, position + size), "command": hex(command),
                          "current_version": version(current), "compatibility_version": version(compatibility)}
            if command == 0xd:
                result["install_name"] = dependency
            else:
                result["dependencies"].append(dependency)
        elif command == 0x1b:
            result["uuid"] = data[position + 8:position + 24].hex()
        elif command == 0x32:
            platform, minimum, sdk, tools = struct.unpack_from("<4I", data, position + 8)
            result["build"] = {"platform": platform, "minimum": version(minimum), "sdk": version(sdk)}
        elif command in (0x24, 0x25, 0x2f, 0x30):
            minimum, sdk = struct.unpack_from("<2I", data, position + 8)
            result["legacy_build"] = {"command": hex(command), "minimum": version(minimum), "sdk": version(sdk)}
        elif command in (0x21, 0x2c):
            result["cryptid"] = struct.unpack_from("<I", data, position + 16)[0]
        elif command == 0x80000028:
            result["entry_file_offset"], result["initial_stack_size"] = struct.unpack_from("<2Q", data, position + 8)
        elif command == 0x8000001c:
            offset = struct.unpack_from("<I", data, position + 8)[0]
            result.setdefault("rpaths", []).append(text(data, position + offset, position + size))
        elif command == 0x2:
            table, symbols, strings, string_bytes = struct.unpack_from("<4I", data, position + 8)
            if symbols > 2_000_000 or table + symbols * 16 > len(data) or strings + string_bytes > len(data):
                raise ValueError("Invalid native symbol table")
            for index in range(symbols):
                name, kind_byte, section, description, address = struct.unpack_from("<IBBHQ", data, table + index * 16)
                if name >= string_bytes:
                    raise ValueError("Invalid native symbol name")
                result["symbols"].append({"name": text(data, strings + name, strings + string_bytes),
                                           "type": kind_byte, "section": section, "description": description,
                                           "address": hex(address), "undefined": kind_byte & 0xe == 0,
                                           "external": bool(kind_byte & 1)})
        elif command == 0x1d:
            offset, signature_bytes = struct.unpack_from("<2I", data, position + 8)
            if offset + signature_bytes > len(data):
                raise ValueError("Invalid signature bounds")
            result["code_signature"] = {"offset": offset, "bytes": signature_bytes,
                                         "sha256": sha(data[offset:offset + signature_bytes])}
            signature = data[offset:offset + signature_bytes]
            if len(signature) >= 12 and struct.unpack_from(">I", signature)[0] == 0xfade0cc0:
                magic, blob_bytes, slots = struct.unpack_from(">3I", signature)
                if slots > 1024 or 12 + slots * 8 > len(signature) or blob_bytes > len(signature):
                    raise ValueError("Invalid signature superblob")
                for index in range(slots):
                    slot, blob = struct.unpack_from(">2I", signature, 12 + index * 8)
                    if blob + 8 > len(signature):
                        raise ValueError("Invalid signature subblob")
                    blob_magic, size_bytes = struct.unpack_from(">2I", signature, blob)
                    if size_bytes < 8 or blob + size_bytes > len(signature):
                        raise ValueError("Invalid signature subblob bounds")
                    if blob_magic == 0xfade7171:
                        result["entitlements"] = plistlib.loads(signature[blob + 8:blob + size_bytes])
        result["load_commands"].append(item)
        position += size
    if position != end:
        raise ValueError("Mach-O commands did not consume declared range")
    return result


def native(data):
    if data[:4] == b"\xcf\xfa\xed\xfe":
        return [native_slice(data)]
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count = struct.unpack_from(">I", data, 4)[0]
        wide = data[3] == 0xbf
        if count > 32:
            raise ValueError("Invalid fat architecture count")
        results = []
        for index in range(count):
            cursor = 8 + index * (32 if wide else 20)
            values = struct.unpack_from(">2I2Q2I" if wide else ">5I", data, cursor)
            cpu, subtype, offset, size = values[:4]
            if offset + size > len(data):
                raise ValueError("Invalid fat slice")
            slice_result = native_slice(data[offset:offset + size])
            slice_result["container_offset"] = offset
            results.append(slice_result)
        return results
    return None


def analyze(ipa, output):
    output.mkdir(parents=True, exist_ok=True)
    hasher = hashlib.sha256()
    with ipa.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(block)
    inventory, natives, plists, privacy, errors = [], [], {}, {}, []
    paths = set()
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        if len(entries) > 10000 or sum(e.file_size for e in entries) > 1024**3:
            raise ValueError("IPA exceeds bounds")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or entry.filename in paths:
                raise ValueError("Unsafe or duplicate archive path")
            paths.add(entry.filename)
            if entry.file_size > 256 * 1024**2 or entry.flag_bits & 1:
                raise ValueError("Encrypted or oversized member")
            # Reading every member to EOF verifies its CRC. No member is executed.
            with archive.open(entry) as handle:
                data = handle.read()
            row = {"path": entry.filename, "bytes": len(data), "compressed_bytes": entry.compress_size,
                   "crc32": f"{entry.CRC:08x}", "sha256": sha(data), "zip_method": entry.compress_type,
                   "unix_mode": oct(entry.external_attr >> 16)}
            inventory.append(row)
            try:
                parsed = native(data)
                if parsed:
                    natives.append({**row, "slices": parsed})
                if entry.filename.endswith('.plist'):
                    value = plistlib.loads(data)
                    # Google client-service configuration stays outside metadata reports.
                    if entry.filename.endswith('GoogleService-Info.plist'):
                        value = {"keys": sorted(value), "values_omitted": True}
                    plists[entry.filename] = value
                if entry.filename.endswith('PrivacyInfo.xcprivacy'):
                    privacy[entry.filename] = plistlib.loads(data)
            except (ValueError, struct.error, plistlib.InvalidFileException) as error:
                errors.append({"path": entry.filename, "error": str(error)})
        root = next(p.rsplit('/', 1)[0] for p in paths if p.count('/') == 2 and p.endswith('.app/Info.plist'))
        configuration = {}
        for name in ['jre/lib/options.default', 'jre/lib/jvm.cfg', 'jre/release']:
            if root + '/' + name in paths:
                configuration[name] = archive.read(root + '/' + name).decode('utf8', 'replace')
    # Keep full native tables separate so the review summary remains readable.
    for filename, value in [('inventory.json', inventory), ('native-images.json', natives),
                            ('bundle-plists.json', plists), ('privacy-manifests.json', privacy),
                            ('jvm-configuration.json', configuration)]:
        (output / filename).write_text(json.dumps(value, indent=2, ensure_ascii=False, default=str) + '\n')
    summary = {
        "input": {"name": ipa.name, "bytes": ipa.stat().st_size, "sha256": hasher.hexdigest()},
        "scope": "Every ZIP member hashed and CRC checked; all recognized native images and plist/privacy declarations parsed. No target execution.",
        "coverage": {"zip_entries": len(inventory), "zip_entries_read": len(inventory), "crc_failures": 0,
                     "native_images": len(natives), "native_slices": sum(len(n['slices']) for n in natives),
                     "plists": len(plists), "privacy_manifests": len(privacy), "parse_errors": len(errors)},
        "extensions": dict(Counter(PurePosixPath(r['path']).suffix or '(none)' for r in inventory)),
        "native": [{"path": r['path'], "bytes": r['bytes'], "sha256": r['sha256'],
                    "slices": [{k: v for k, v in s.items() if k not in ['symbols', 'segments', 'load_commands']}
                               | {"symbols": len(s['symbols']), "undefined_symbols": sum(x['undefined'] for x in s['symbols'])}
                               for s in r['slices']]} for r in natives],
        "errors": errors,
        "outputs": {name: sha((output / name).read_bytes()) for name in
                    ['inventory.json', 'native-images.json', 'bundle-plists.json', 'privacy-manifests.json', 'jvm-configuration.json']},
        "limits": ["Static declarations do not prove use, runtime behavior, privacy compliance or authenticity.",
                   "Symbol tables are not full call graphs; stripped symbols and indirect calls need further analysis.",
                   "Signatures are located and decoded as data, not authenticated against a trust store."]}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False, default=str) + '\n')
    print(json.dumps({"output": str(output), "coverage": summary['coverage'], "errors": errors}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    analyze(arguments.ipa, arguments.output)
