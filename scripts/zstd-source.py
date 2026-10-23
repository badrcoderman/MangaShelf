#!/usr/bin/env python3
"""Verify pinned codec source/header sets and prepare the recorded JVM loader edit."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT/'runtime-host/zstd-source.lock.json'
PATCH = ROOT/'runtime-host/zstd-compat.patch.json'
PINS = {
    'kotlin': ('square/okio-zstd', '4fbdf35df030888d2a0cce4a84329d107438134f', 'runtime-host/third_party/zstd-kmp', 12),
    'native': ('facebook/zstd', '1dbc2e09084e843f6c0dcc2d0791610015c50979', 'runtime-native/third_party/zstd', 65),
    'jni': ('openjdk/mobile', 'c1ed06aaef34c8dccf71e236d1ffa20918a77cfb', 'runtime-native/third_party/openjdk-jni', 5),
}


def verify():
    lock = json.loads(LOCK.read_text())
    if lock.get('format') != 1 or set(lock) != {'format', *PINS}:
        raise ValueError('Unsupported Zstd source lock')
    paths = []
    for key, (repository, commit, source_root, count) in PINS.items():
        component = lock[key]
        if (component['repository'] != 'https://github.com/'+repository or component['commit'] != commit
                or component['source_root'] != source_root or len(component['files']) != count):
            raise ValueError('Changed Zstd source pin: '+key)
        root = ROOT/source_root
        selected = []
        for item in component['files']:
            name = Path(item['path'])
            if name.is_absolute() or '..' in name.parts or '\\' in str(name):
                raise ValueError('Invalid codec source path')
            path = root/name
            if path.is_symlink(): raise ValueError('Symlink in codec source set')
            data = path.read_bytes()
            if not (len(data) == item['bytes'] <= 512 * 1024
                    and hashlib.sha256(data).hexdigest() == item['sha256']
                    and hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest() == item['git_blob']):
                raise ValueError('Changed pinned codec input: '+str(path.relative_to(ROOT)))
            selected.append(path)
        if len(set(selected)) != count or set(selected) != {p for p in root.rglob('*') if p.is_file()}:
            raise ValueError('Changed codec source set: '+key)
        paths.extend(selected)
    return lock, paths


def inputs():
    _, paths = verify()
    return [Path(__file__), LOCK, PATCH, *paths]


def prepare_kotlin(lock, directory):
    patch = json.loads(PATCH.read_text())
    if patch['format'] != 1 or patch['file'] != 'zstd-kmp/src/jvmMain/kotlin/com/squareup/zstd/JvmZstd.kt':
        raise ValueError('Unsupported codec compatibility edit')
    root = ROOT/lock['kotlin']['source_root']
    groups = {'common': [], 'platform': [], 'okio': []}
    for item in lock['kotlin']['files']:
        name = item['path']
        if not name.endswith('.kt'): continue
        data = (root/name).read_bytes()
        if name == patch['file']:
            if hashlib.sha256(data).hexdigest() != patch['original_sha256']:
                raise ValueError('Changed original JVM codec loader')
            text = data.decode()
            for replacement in patch['replacements']:
                if text.count(replacement['old']) != replacement['count']:
                    raise ValueError('Changed codec patch anchor')
                text = text.replace(replacement['old'], replacement['new'])
            data = text.encode()
            if hashlib.sha256(data).hexdigest() != patch['patched_sha256']:
                raise ValueError('Changed patched JVM codec loader')
        out = directory/name; out.parent.mkdir(parents=True, exist_ok=True); out.write_bytes(data)
        group = 'okio' if name.startswith('zstd-kmp-okio/') else 'common' if '/commonMain/' in name else 'platform'
        groups[group].append(out)
    if {key: len(value) for key, value in groups.items()} != {'common': 3, 'platform': 5, 'okio': 3}:
        raise ValueError('Changed Kotlin codec source layout')
    return groups
