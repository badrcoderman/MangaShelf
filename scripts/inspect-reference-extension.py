#!/usr/bin/env python3
"""Inspect a newly source-built candidate as ZIP/class metadata, without loading it."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile


def inspect(source, out):
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != '1d3d7c4b3e876fb0c26ae3ade8113fb329af15fa':
        raise ValueError('Unexpected public source revision')
    module = source / 'src/all/mangadex/build'
    jars = list((module / 'outputs/jar/release').glob('*.jar'))
    if len(jars) != 1 or not 0 < jars[0].stat().st_size <= 64 * 1024**2:
        raise ValueError('Expected one bounded source-built JAR')
    metadata = json.loads((module / 'keiyoushi-source-info.json').read_text())
    expected_package = 'eu.kanade.tachiyomi.extension.all.mangadex'
    if metadata['packageName'] != expected_package or metadata['extensionLib'] != '1.6':
        raise ValueError('Unexpected source build metadata')
    sources = metadata['sources']
    if len(sources) < 2 or len({s['id'] for s in sources}) != len(sources):
        raise ValueError('Missing or duplicate factory source IDs')
    if not {'ar', 'en'} <= {s['lang'] for s in sources}:
        raise ValueError('Missing expected source languages')
    records, classes = [], []
    with zipfile.ZipFile(jars[0]) as archive:
        entries = archive.infolist()
        if len(entries) > 20_000 or sum(e.file_size for e in entries) > 256 * 1024**2:
            raise ValueError('JAR exceeds inspection limits')
        names = [e.filename for e in entries]
        if len(set(names)) != len(names):
            raise ValueError('Duplicate JAR entries')
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in entry.filename
                    or entry.file_size > 16 * 1024**2 or entry.file_size > max(1, entry.compress_size) * 500):
                raise ValueError('Unsafe JAR entry')
            data = archive.read(entry)  # also verifies CRC
            records.append({'path': entry.filename, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            if entry.filename.endswith('.dex'):
                raise ValueError('Expected JVM classes, not an APK/Dex package')
            if entry.filename.endswith('.class'):
                if len(data) < 10 or data[:4] != b'\xca\xfe\xba\xbe':
                    raise ValueError('Invalid class header')
                classes.append({'path': entry.filename, 'major': struct.unpack_from('>H', data, 6)[0]})
        manifest = archive.read('AndroidManifest.xml')
        if len(manifest) > 256 * 1024 or b'<!DOCTYPE' in manifest or b'<!ENTITY' in manifest:
            raise ValueError('Unsupported extension manifest')
        root = ET.fromstring(manifest.decode('utf-8'))
        android = '{http://schemas.android.com/apk/res/android}'
        application = root.find('application')
        if root.tag != 'manifest' or root.get('package') != expected_package or application is None:
            raise ValueError('Unexpected extension manifest identity')
        main = [e.get(android + 'value') for e in application.findall('meta-data')
                if e.get(android + 'name') == 'tachiyomi.extension.class']
        if main != ['keiyoushi.source.Generated'] or main[0].replace('.', '/') + '.class' not in names:
            raise ValueError('Missing generated source entry point')
        if int(root.get(android + 'versionCode')) != metadata['versionCode']:
            raise ValueError('Manifest and metadata versions differ')
    if not classes:
        raise ValueError('No JVM classes')
    out.mkdir(parents=True, exist_ok=True)
    target = out / jars[0].name
    shutil.copyfile(jars[0], target)
    shutil.copyfile(module / 'keiyoushi-source-info.json', out / 'source-info.json')
    shutil.copyfile(source / 'LICENSE', out / 'UPSTREAM-LICENSE')
    report = {'repository': 'https://github.com/keiyoushi/extensions-source', 'commit': revision,
              'package': expected_package, 'version_name': metadata['versionName'],
              'version_code': metadata['versionCode'], 'main_class': main[0],
              'file': target.name, 'bytes': target.stat().st_size,
              'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
              'class_count': len(classes), 'maximum_class_major': max(c['major'] for c in classes),
              'sources': [{**s, 'id': str(s['id'])} for s in sources], 'members': records,
              'signature_entries': [n for n in names if n.startswith('META-INF/') and n.endswith(('.SF', '.RSA', '.DSA', '.EC'))],
              'publisher_signature_verified': False, 'source_executed': False, 'device_executed': False,
              'scope': 'Fresh public source build candidate. Not the publisher release; not bundled or enabled in MangaShelf.'}
    (out / 'source-build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in {'members', 'sources'}}, indent=2))


if __name__ == '__main__':
    inspect(Path(sys.argv[1]), Path(sys.argv[2]))
