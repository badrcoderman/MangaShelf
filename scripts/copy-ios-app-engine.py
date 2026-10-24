#!/usr/bin/env python3
"""Copy the exact prepared engine resources into a fresh unsigned app bundle."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil


def verify_inputs(inputs):
    manifest = json.loads(inputs.read_text())
    if manifest.get('format') != 1 or not manifest.get('passed'): raise ValueError('Prepared engine inputs are required')
    for entry in manifest['native_libraries']:
        name=PurePosixPath(entry['path'])
        if name.is_absolute() or '..' in name.parts or '\\' in str(name): raise ValueError('Unsafe native path')
        source=inputs.parent/str(name)
        if source.is_symlink() or not source.resolve().is_relative_to(inputs.parent.resolve()) or not source.is_file(): raise ValueError('Invalid native input')
        if source.stat().st_size != entry['bytes'] or hashlib.sha256(source.read_bytes()).hexdigest() != entry['sha256']: raise ValueError('Native input changed')
    if hashlib.sha256((inputs.parent/'Engine.xcconfig').read_bytes()).hexdigest() != manifest['xcconfig_sha256']: raise ValueError('Engine build settings changed')
    return manifest


def copy_engine(inputs, app):
    if app.suffix != '.app' or app.is_symlink() or not app.is_dir(): raise ValueError('A fresh built app is required')
    if (app/'_CodeSignature').exists() or (app/'embedded.mobileprovision').exists(): raise ValueError('Engine resources must be copied before signing')
    manifest = verify_inputs(inputs)
    base = inputs.parent/'bundle'; files = manifest['bundle_files']
    if len(files) != len({entry['path'] for entry in files}) or len(files) > 2000: raise ValueError('Invalid bundle file set')
    # Validate every source and destination before writing any app resources.
    checked = []
    for entry in files:
        name = PurePosixPath(entry['path'])
        if name.is_absolute() or '..' in name.parts or '\\' in str(name): raise ValueError('Unsafe engine path')
        source = base/str(name); destination = app/str(name)
        if source.is_symlink() or not source.resolve().is_relative_to(base.resolve()) or not source.is_file(): raise ValueError('Invalid engine source')
        if destination.exists(): raise ValueError('Engine resource collides with app file: '+str(name))
        if source.stat().st_size != entry['bytes'] or hashlib.sha256(source.read_bytes()).hexdigest() != entry['sha256']: raise ValueError('Engine resource changed: '+str(name))
        checked.append((source,destination))
    for source,destination in checked:
        destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,destination)
    return len(checked)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',type=Path,required=True);parser.add_argument('--app',type=Path);parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    if args.check: verify_inputs(args.inputs.resolve());print(json.dumps({'verified_engine_inputs':True}))
    elif args.app: print(json.dumps({'copied_engine_resources':copy_engine(args.inputs.resolve(),args.app.resolve())}))
    else: parser.error('--app or --check is required')
