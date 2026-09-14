#!/usr/bin/env python3
"""Reject static archives containing non-iOS or non-arm64 Mach-O objects."""
import argparse
import json
import struct
from pathlib import Path


def verify(data):
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('Not an ar archive')
    cursor, count = 8, 0
    while cursor < len(data):
        header = data[cursor:cursor + 60]
        if len(header) != 60 or header[58:] != b'`\n':
            raise ValueError('Truncated or invalid ar header')
        size = int(header[48:58])
        if size < 0 or cursor + 60 + size > len(data):
            raise ValueError('Invalid member size')
        name = header[:16].decode('ascii').strip().rstrip('/')
        body = data[cursor + 60:cursor + 60 + size]
        cursor += 60 + size + size % 2
        if name.startswith('#1/'):
            length = int(name[3:])
            if length > len(body):
                raise ValueError('Invalid extended member name')
            name = body[:length].rstrip(b'\0').decode('utf-8')
            body = body[length:]
        if name.startswith('__.SYMDEF') or name in ('', '/'):
            continue
        if len(body) < 32 or body[:4] != b'\xcf\xfa\xed\xfe':
            raise ValueError(f'{name}: not a 64-bit little-endian Mach-O object')
        _, cpu, _, kind, commands, command_bytes, _, _ = struct.unpack_from('<8I', body)
        if cpu != 0x0100000C or kind != 1:
            raise ValueError(f'{name}: expected arm64 MH_OBJECT')
        end = 32 + command_bytes
        if end > len(body):
            raise ValueError(f'{name}: truncated load commands')
        offset, platforms = 32, []
        for _ in range(commands):
            if offset + 8 > end:
                raise ValueError(f'{name}: truncated load command')
            cmd, length = struct.unpack_from('<II', body, offset)
            if length < 8 or offset + length > end:
                raise ValueError(f'{name}: invalid load command length')
            if cmd == 0x32:
                if length < 24:
                    raise ValueError(f'{name}: truncated build version')
                platforms.append(struct.unpack_from('<I', body, offset + 8)[0])
            elif cmd == 0x25:
                if length < 16:
                    raise ValueError(f'{name}: truncated iOS version')
                platforms.append(2)
            elif cmd in (0x24, 0x2F, 0x30):
                raise ValueError(f'{name}: other Apple platform version command')
            offset += length
        if offset != end or platforms != [2]:
            raise ValueError(f'{name}: expected exactly one iOS device platform declaration, got {platforms}')
        count += 1
    if cursor != len(data) or not count:
        raise ValueError('Empty or malformed archive')
    return {'objects': count, 'architecture': 'arm64', 'platform': 'iOS device',
            'scope': 'Object format validation only; not linking or execution'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.archive.read_bytes()), indent=2))
