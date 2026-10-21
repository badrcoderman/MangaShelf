#!/usr/bin/env python3
"""Check source preparation against a pristine pinned checkout; never run a VM."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(pristine):
    prepare = load('prepare-ios-jvm-source')
    verify = load('verify-ios-jvm-source')
    names = list(prepare.PINNED_FILES) + ['make/common/native/Flags.gmk']
    originals = {name: (pristine / name).read_bytes() for name in names}
    for name, expected in prepare.PINNED_FILES.items():
        if hashlib.sha256(originals[name]).hexdigest() != expected:
            raise ValueError(f'Not pristine pinned source: {name}')
    core = 'make/modules/java.base/lib/CoreLibraries.gmk'
    native_flags = 'make/common/native/Flags.gmk'
    baseline = {
        os: verify.libjava_link_flags(originals[core].decode(), originals[native_flags].decode(), os)
        for os in ['ios', 'macosx', 'linux']
    }
    assert baseline['ios'] == '', baseline
    with tempfile.TemporaryDirectory(prefix='msl-jvm-source-') as directory:
        root = Path(directory)

        def restore():
            for name, data in originals.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)

        def snapshot():
            return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}

        project = Path(__file__).resolve().parent.parent
        rejected = []
        for name in prepare.PINNED_FILES:
            restore()
            (root / name).write_bytes(originals[name] + b'\n// changed input\n')
            before = snapshot()
            try:
                prepare.prepare(root, project)
            except ValueError:
                assert snapshot() == before, name
                rejected.append(name)
            else:
                raise AssertionError(f'Changed input accepted: {name}')
        restore()
        prepare.prepare(root, project)
        result = verify.verify(root)
        by_os = {case['platform']: case['libjava_platform_libraries'] for case in result['cases']}
        assert by_os['ios'] == '-framework CoreFoundation'
        assert all(by_os[os] == baseline[os] for os in ['macosx', 'linux'])
        addition = b'    LIBS_ios := -framework CoreFoundation, \\\n'
        patched_core = (root / core).read_bytes()
        assert patched_core.count(addition) == 1
        assert patched_core.replace(addition, b'') == originals[core]
        before = snapshot()
        try:
            prepare.prepare(root, project)
        except ValueError:
            assert snapshot() == before
        else:
            raise AssertionError('Repeated patch accepted')
        # A missing framework must fail the actual branch verifier even when
        # all earlier Darwin fixes are present.
        (root / core).write_bytes(originals[core])
        try:
            verify.verify(root)
        except AssertionError as error:
            assert error.args == (('ios', ''),), error.args
        else:
            raise AssertionError('Missing iOS CoreFoundation accepted')
    result.update({
        'changed_input_rejected_before_writes': len(rejected) == len(prepare.PINNED_FILES),
        'rejected_changed_inputs': rejected,
        'repeat_patch_rejected': True,
        'missing_ios_corefoundation_rejected': True,
        'libjava_non_ios_branches_unchanged': True,
        'baseline_libjava_platform_libraries': baseline,
        'openjdk_commit': 'c1ed06aaef34c8dccf71e236d1ffa20918a77cfb',
        'input_sha256': {name: hashlib.sha256(data).hexdigest() for name, data in originals.items()},
    })
    return result


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: test_ios_jvm_source.py PRISTINE_PINNED_OPENJDK_ROOT')
    print(json.dumps(check(Path(sys.argv[1])), indent=2))
