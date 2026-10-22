#!/usr/bin/env python3
"""Download immutable public index data for the optional Swift integration probe."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

REPOSITORY = 'keiyoushi/extensions'
COMMIT = '229fddf8eeb9b44940fa10a77db3897c4783045d'
FILES = {
    'index.pb': (109697, 'c0ef5ec28b646dbce0064210c05004a4cdbbce01f5f4711999da4463543eea68'),
    'index.json': (1476319, '567c190d85020531f9a71a2cf3148a8e23face92dacb5787f3081ab8d788c722'),
}


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', '-H', 'Accept: application/vnd.github+json',
                                               f'repos/{REPOSITORY}/{path}'], timeout=90))


def download(destination):
    tree = api(f'git/trees/{COMMIT}')
    if tree.get('truncated'):
        raise ValueError('Incomplete repository tree')
    destination.mkdir(parents=True, exist_ok=True)
    for name, (size, digest) in FILES.items():
        entry = next(e for e in tree['tree'] if e['path'] == name)
        if entry['type'] != 'blob' or entry['size'] != size:
            raise ValueError('Unexpected pinned index blob')
        # JSON/base64 avoids treating the gzip protobuf payload as HTTP content encoding.
        blob = api('git/blobs/' + entry['sha'])
        if blob.get('encoding') != 'base64':
            raise ValueError('Unexpected blob encoding')
        data = base64.b64decode(''.join(blob['content'].split()), validate=True)
        git_digest = hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
        if (len(data) != size or hashlib.sha256(data).hexdigest() != digest
                or git_digest != entry['sha'] or blob['sha'] != entry['sha']):
            raise ValueError('Pinned index digest mismatch')
        (destination / name).write_bytes(data)
        print(name + ': SHA-256 verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    download(parser.parse_args().destination)
