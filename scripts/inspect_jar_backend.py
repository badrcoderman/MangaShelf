#!/usr/bin/env python3
"""Inventory a pinned backend checkout without importing or executing its code.

This source-text inventory does not prove reachability, JNI linkage, or iOS support.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

PIN = '2e52214106ffab02d13ff61a620def78414a8a45'


def inspect(root):
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        raise ValueError(f'Expected reviewed revision {PIN}, found {revision}')
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
    native = []
    cloud = []
    binaries = []
    # Strip comments and literals before matching declarations, retaining line numbers.
    trivia = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
    declaration = re.compile(r'\bnative\s+([\w.$<>?,\[\] ]+?)\s+(\w+)\s*\(([^;{}]*)\)\s*;', re.S)
    for name in sorted(filter(None, tracked)):
        path = root / name
        if name.endswith('.jar'):
            data = path.read_bytes()
            binaries.append({'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        if not name.endswith(('.java', '.kt')):
            continue
        raw = path.read_text()
        text = trivia.sub(lambda m: ''.join('\n' if c == '\n' else ' ' for c in m.group()), raw)
        if name.endswith('.java'):
            for match in declaration.finditer(text):
                native.append({'path': name, 'line': text.count('\n', 0, match.start()) + 1,
                               'return_type': match[1].strip(), 'method': match[2],
                               'parameters': ' '.join(match[3].split())})
        imports = re.findall(r'^import\s+(app\.tachimanga\.cloud\.[\w.*]+)', text, re.M)
        if imports:
            cloud.append({'path': name, 'imports': sorted(set(imports))})
    return {'revision': revision, 'scope': 'Static declared native methods and dependencies; not execution or iOS compatibility',
            'native_methods': native, 'cloud_imports': cloud, 'tracked_jar_files': binaries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = inspect(args.checkout.resolve())
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'native_methods': len(result['native_methods']), 'cloud_consumers': len(result['cloud_imports']),
                      'jar_dependencies': len(result['tracked_jar_files'])}))


if __name__ == '__main__':
    main()
