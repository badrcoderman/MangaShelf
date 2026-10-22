#!/usr/bin/env python3
"""Check source preparation against a pristine pinned checkout; never run a VM."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import subprocess


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
    base = 'make/modules/java.base/Lib.gmk'
    native_flags = 'make/common/native/Flags.gmk'
    baseline = {
        os: verify.library_link_flags(originals[core].decode(), originals[native_flags].decode(), os, 'BUILD_LIBJAVA')
        for os in ['ios', 'macosx', 'linux']
    }
    assert baseline['ios'] == '', baseline
    baseline_jli = {os: verify.libjli_exclusions(originals[core].decode(), os)
                    for os in ['ios', 'macosx', 'linux']}
    assert baseline_jli == {'ios': [], 'macosx': ['java_md.c'], 'linux': []}
    baseline_nio = {
        os: verify.library_link_flags(originals[base].decode(), originals[native_flags].decode(), os, 'BUILD_LIBNIO')
        for os in ['ios', 'macosx', 'linux']
    }
    baseline_net = {
        os: verify.library_link_flags(originals[base].decode(), originals[native_flags].decode(), os, 'BUILD_LIBNET')
        for os in ['ios', 'macosx', 'linux']
    }
    assert baseline_nio['ios'] == ''
    extra_libraries = {
        'libprefs': ('make/modules/java.prefs/Lib.gmk', 'BUILD_LIBPREFS',
                     b'    LIBS_ios := -framework CoreFoundation -framework Foundation, \\\n'),
        'libinstrument': ('make/modules/java.instrument/Lib.gmk', 'BUILD_LIBINSTRUMENT',
                          b'    LIBS_ios := -liconv, \\\n'),
    }
    extra_baseline = {
        label: {os: verify.library_link_flags(originals[path].decode(), originals[native_flags].decode(), os, library)
                for os in ['ios', 'macosx', 'linux']}
        for label, (path, library, _) in extra_libraries.items()
    }
    assert all(flags['ios'] == '' for flags in extra_baseline.values())
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
        uti = 'src/java.base/macosx/native/libnio/fs/UTIFileTypeDetector.c'
        helper = root / Path(uti).with_name('msl_ios_filetype.m')
        assert helper.read_bytes() == (project / 'runtime-native/ios_filetype.m').read_bytes()
        assert not subprocess.check_output(['cc', '-E', '-P', '-x', 'c', str(helper)], text=True, timeout=15).strip()
        # Preprocess the actual pinned C source with empty framework headers:
        # this checks branch selection only, not Apple types or execution.
        includes = root / 'probe-includes'
        for name in ['jni.h', 'jni_util.h', 'CoreFoundation/CoreFoundation.h', 'CoreServices/CoreServices.h']:
            header = includes / name
            header.parent.mkdir(parents=True, exist_ok=True)
            header.write_text('')
        selected_bodies = {}
        for os, defines in [('ios', ['-D__IOS__']), ('macosx', [])]:
            output = subprocess.check_output(['cc', '-E', '-P', '-x', 'c', *defines,
                                             '-I', str(includes), str(root / uti)], text=True, timeout=15)
            selected_bodies[os] = output[output.index('Java_sun_nio_fs_UTIFileTypeDetector_probe0('):]
        assert 'return msl_ios_filetype_probe(env, ext);' in selected_bodies['ios']
        assert 'toCFString(' not in selected_bodies['ios']
        assert 'toCFString(env, ext)' in selected_bodies['macosx']
        assert 'CFRelease(extension)' in selected_bodies['macosx']
        assert 'msl_ios_filetype_probe' not in selected_bodies['macosx']
        by_os = {case['platform']: case['libjava_platform_libraries'] for case in result['cases']}
        assert by_os['ios'] == '-framework CoreFoundation'
        assert all(by_os[os] == baseline[os] for os in ['macosx', 'linux'])
        assert all(case['libnet_platform_libraries'] == baseline_net[case['platform']] for case in result['cases'])
        assert all(case['libnio_platform_libraries'] == baseline_nio[case['platform']]
                   for case in result['cases'] if case['platform'] != 'ios')
        extra_patched = {}
        for label, (path, _, addition) in extra_libraries.items():
            patched = (root / path).read_bytes()
            assert patched.count(addition) == 1
            assert patched.replace(addition, b'') == originals[path]
            extra_patched[path] = patched
            assert all(case[label + '_platform_libraries'] == extra_baseline[label][case['platform']]
                       for case in result['cases'] if case['platform'] != 'ios')
        addition = b'    LIBS_ios := -framework CoreFoundation, \\\n'
        patched_core = (root / core).read_bytes()
        assert patched_core.count(addition) == 1
        old_jli = b'ifeq ($(call isTargetOs, macosx), true)\n  LIBJLI_EXCLUDE_FILES += java_md.c'
        new_jli = b'ifeq ($(call isTargetOs, macosx ios), true)\n  LIBJLI_EXCLUDE_FILES += java_md.c'
        assert patched_core.count(new_jli) == 1
        assert patched_core.replace(addition, b'').replace(new_jli, old_jli) == originals[core]
        patched_base = (root / base).read_bytes()
        nio_addition = b'    LIBS_ios := -lobjc -framework CoreFoundation -framework Foundation -framework UniformTypeIdentifiers, \\\n'
        arc_addition = b'    msl_ios_filetype.m_CFLAGS := -fobjc-arc -fobjc-arc-exceptions, \\\n'
        assert patched_base.count(nio_addition) == patched_base.count(arc_addition) == 1
        assert patched_base.replace(nio_addition, b'').replace(arc_addition, b'') == originals[base]
        assert all(verify.libjli_exclusions(patched_core.decode(), os) == baseline_jli[os]
                   for os in ['macosx', 'linux'])
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
        (root / core).write_bytes(patched_core.replace(new_jli, old_jli))
        try:
            verify.verify(root)
        except AssertionError as error:
            assert error.args == (('ios', []),), error.args
        else:
            raise AssertionError('Duplicate-producing iOS libjli source selection accepted')
        (root / core).write_bytes(patched_core)
        (root / base).write_bytes(originals[base])
        try:
            verify.verify(root)
        except AssertionError as error:
            assert error.args == (('ios', ''),), error.args
        else:
            raise AssertionError('Missing iOS libnio CoreFoundation accepted')
        (root / base).write_bytes(patched_base.replace(arc_addition, b''))
        try:
            verify.verify(root)
        except AssertionError as error:
            assert error.args == (('ios', ''),), error.args
        else:
            raise AssertionError('Missing file type ARC setting accepted')
        (root / base).write_bytes(patched_base)
        for label, (path, _, addition) in extra_libraries.items():
            (root / path).write_bytes(extra_patched[path].replace(addition, b''))
            try:
                verify.verify(root)
            except AssertionError as error:
                assert error.args == (('ios', ''),), error.args
            else:
                raise AssertionError(f'Missing iOS {label} libraries accepted')
            (root / path).write_bytes(extra_patched[path])
    result.update({
        'changed_input_rejected_before_writes': len(rejected) == len(prepare.PINNED_FILES),
        'rejected_changed_inputs': rejected,
        'repeat_patch_rejected': True,
        'missing_ios_corefoundation_rejected': True,
        'libjava_non_ios_branches_unchanged': True,
        'missing_ios_libjli_exclusion_rejected': True,
        'libjli_non_ios_branches_unchanged': True,
        'missing_ios_libnio_corefoundation_rejected': True,
        'libnio_non_ios_branches_unchanged': True,
        'libnet_platform_branches_unchanged': True,
        'filetype_ios_bridge_selected': True,
        'filetype_macos_legacy_branch_preserved': True,
        'filetype_helper_copy_verified': True,
        'filetype_non_ios_helper_empty': True,
        'missing_filetype_arc_setting_rejected': True,
        'filetype_helper_sha256': hashlib.sha256((project / 'runtime-native/ios_filetype.m').read_bytes()).hexdigest(),
        'baseline_libjava_platform_libraries': baseline,
        'baseline_libjli_exclusions': baseline_jli,
        'baseline_libnio_platform_libraries': baseline_nio,
        'baseline_libnet_platform_libraries': baseline_net,
        'baseline_libprefs_platform_libraries': extra_baseline['libprefs'],
        'baseline_libinstrument_platform_libraries': extra_baseline['libinstrument'],
        'missing_ios_libprefs_frameworks_rejected': True,
        'missing_ios_libinstrument_iconv_rejected': True,
        'libprefs_non_ios_branches_unchanged': True,
        'libinstrument_non_ios_branches_unchanged': True,
        'openjdk_commit': 'c1ed06aaef34c8dccf71e236d1ffa20918a77cfb',
        'input_sha256': {name: hashlib.sha256(data).hexdigest() for name, data in originals.items()},
    })
    return result


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: test_ios_jvm_source.py PRISTINE_PINNED_OPENJDK_ROOT')
    print(json.dumps(check(Path(sys.argv[1])), indent=2))
