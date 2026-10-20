#!/usr/bin/env python3
"""Read a JIMAGE v1 index without loading any of its Java classes.

Format reference: OpenJDK jdk17u imageFile.hpp and ImageLocation.java. This is
an independent metadata reader; compressed class payloads are left opaque.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


def inspect(path, output):
    if path.stat().st_size > 512 * 1024**2:
        raise ValueError('Image exceeds inspection limit')
    data = path.read_bytes()
    order = '<' if data[:4] == b'\xda\xda\xfe\xca' else '>'
    magic, version, flags, resource_count, table_count, locations_size, strings_size = struct.unpack_from(order + '7I', data)
    if magic != 0xcafedada or version != 0x10000 or table_count > 1_000_000:
        raise ValueError('Expected a bounded JIMAGE v1.0 index')
    location_start = 28 + table_count * 8
    strings_start = location_start + locations_size
    content_start = strings_start + strings_size
    if content_start > len(data):
        raise ValueError('JIMAGE index exceeds file')

    def string(offset):
        if offset >= strings_size:
            raise ValueError('String offset exceeds table')
        start = strings_start + offset
        end = data.find(b'\0', start, content_start)
        if end < 0:
            raise ValueError('Unterminated image string')
        return data[start:end].decode('utf8', 'strict')

    resources, seen, modules, class_versions, compressed_classes = [], set(), Counter(), Counter(), 0
    for slot in range(table_count):
        location = struct.unpack_from(order + 'I', data, 28 + table_count * 4 + slot * 4)[0]
        if not location:
            continue
        if location >= locations_size:
            raise ValueError('Location offset exceeds table')
        values, cursor = [0] * 8, location_start + location
        for _ in range(9):
            if cursor >= strings_start:
                raise ValueError('Truncated image attributes')
            header = data[cursor]
            cursor += 1
            if header <= 7:
                break
            kind, size = header >> 3, (header & 7) + 1
            if kind >= 8 or cursor + size > strings_start:
                raise ValueError('Invalid image attribute')
            values[kind] = int.from_bytes(data[cursor:cursor + size], 'big')
            cursor += size
        else:
            raise ValueError('Image attributes did not terminate')
        module, parent, base, extension = (string(values[i]) for i in range(1, 5))
        name = '/' + '/'.join(v for v in [module, parent, base] if v) + ('.' + extension if extension else '')
        if name in seen:
            raise ValueError('Duplicate resource name')
        seen.add(name)
        offset, compressed, uncompressed = values[5:]
        stored = compressed or uncompressed
        start = content_start + offset
        if stored > 128 * 1024**2 or start + stored > len(data):
            raise ValueError('Resource exceeds image bounds')
        payload = memoryview(data)[start:start + stored]
        entry = {'path': name, 'module': module, 'file_offset': start, 'stored_bytes': stored,
                 'uncompressed_bytes': uncompressed, 'compressed': bool(compressed),
                 'sha256': hashlib.sha256(payload).hexdigest()}
        if extension == 'class':
            if compressed:
                compressed_classes += 1
            elif len(payload) >= 8 and payload[:4] == b'\xca\xfe\xba\xbe':
                minor, major = struct.unpack_from('>2H', payload, 4)
                entry['class_version'] = [major, minor]
                class_versions[major] += 1
            else:
                raise ValueError('Invalid uncompressed class header')
        modules[module] += 1
        resources.append(entry)
    if len(resources) != resource_count:
        raise ValueError('Decoded resource count differs from header')
    output.mkdir(parents=True, exist_ok=True)
    index = output / 'jimage-resources.json'
    index.write_text(json.dumps(resources, indent=2) + '\n')
    module_resources = {k: v for k, v in sorted(modules.items()) if k not in {'', 'modules', 'packages'}}
    summary = {'input': {'path': str(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()},
               'format': 'JIMAGE 1.0', 'byte_order': 'little' if order == '<' else 'big',
               'resource_count': resource_count, 'resources_decoded': len(resources), 'index_bytes': content_start,
               'module_count': len(module_resources), 'modules': module_resources,
               'index_metadata_resources': sum(v for k, v in modules.items() if k not in module_resources),
               'class_versions': dict(sorted(class_versions.items())), 'compressed_class_payloads': compressed_classes,
               'index_sha256': hashlib.sha256(index.read_bytes()).hexdigest(),
               'scope': 'All indexed resource names, locations, sizes and hashes. Uncompressed class headers only; no classes executed.',
               'limits': ['Compressed class payloads, if any, are not decoded.',
                          'Class-file versions establish contained bytecode versions, not a live JavaVM version.'],
               'format_reference': 'https://github.com/openjdk/jdk17u/blob/master/src/java.base/share/native/libjimage/imageFile.hpp'}
    (output / 'jimage-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    inspect(args.image, args.output)
