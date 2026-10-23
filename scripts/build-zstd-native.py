#!/usr/bin/env python3
"""Build pinned Zstd C and MSL JNI without invoking an upstream build script."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('msl_zstd_source', ROOT/'scripts/zstd-source.py')
source = importlib.util.module_from_spec(spec); spec.loader.exec_module(source)
EXPORTS = {
    'JNI_OnLoad_mslzstd', 'JNI_OnUnload_mslzstd',
    *('Java_com_squareup_zstd_'+suffix for suffix in [
        'JniZstdKt_createJniZstd', 'JniZstdKt_jniGetErrorName', 'JniZstdKt_createZstdCompressor',
        'JniZstdKt_createZstdDecompressor', 'JniZstdCompressor_setParameter',
        'JniZstdCompressor_compressStream2', 'JniZstdCompressor_close',
        'JniZstdDecompressor_decompressStream', 'JniZstdDecompressor_close'])}


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def build(target='host'):
    lock, vendor = source.verify()
    out = ROOT/'build/zstd-native'/target; out.mkdir(parents=True, exist_ok=True)
    inputs = [Path(__file__), *source.inputs(), ROOT/'runtime-native/MSZstdJNI.c', ROOT/'runtime-native/MSZstdJNI.h']
    if target == 'ios': inputs.append(ROOT/'scripts/verify_ios_archive.py')
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(), 'passed': False,
              'scope': 'Pinned source-built native codec and authored JNI adapter. iOS target is compile/link inspection only, never device execution.',
              'target': target, 'ios_execution': False, 'sources': {str(p.relative_to(ROOT)): digest(p) for p in inputs}, 'commands': []}

    def run(command):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=180)
        entry = {'command': list(map(str, command)), 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
        return result, entry

    def checked(command):
        result, entry = run(command); report['commands'].append(entry)
        if result.returncode: raise RuntimeError('Native build command failed: '+result.stderr[-4000:])
        return result

    try:
        if target not in ['host', 'ios'] or platform.system() not in ['Linux', 'Darwin']:
            raise RuntimeError('Supported native targets are Linux/macOS host or iOS device on macOS')
        if target == 'ios' and (platform.system() != 'Darwin' or not shutil.which('xcrun')):
            raise RuntimeError('iOS compilation requires macOS/Xcode; no host fallback')
        compiler = ['xcrun', '--sdk', 'iphoneos', 'clang'] if target == 'ios' else [shutil.which('clang') or 'cc']
        report['compiler'] = checked([*compiler, '--version']).stdout
        common = ['-std=c11', '-O2', '-fvisibility=hidden', '-DZSTD_DISABLE_ASM=1',
                  '-DZSTDLIB_VISIBLE=__attribute__((visibility("hidden")))']
        if target == 'ios':
            sdk = checked(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']).stdout.strip()
            report['sdk'] = sdk
            report['sdk_version'] = checked(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version']).stdout.strip()
            if int(report['sdk_version'].split('.')[0]) < 26: raise RuntimeError('Xcode SDK 26 or later required')
            common += ['-target', 'arm64-apple-ios26.0', '-isysroot', sdk]
        else: common += ['-fPIC']
        zstd = ROOT/lock['native']['source_root']
        jni = ROOT/lock['jni']['source_root']
        includes = ['-I'+str(zstd/'lib'), '-I'+str(jni/'src/java.base/share/native/include'), '-I'+str(jni/'src/java.base/unix/native/include')]
        c_sources = [p for p in vendor if p.is_relative_to(zstd) and p.suffix == '.c']
        if len(c_sources) != 26: raise RuntimeError('Unexpected Zstd C source set')
        objects = []
        commands = []
        for path in c_sources:
            output = out/(path.relative_to(zstd).as_posix().replace('/', '_')+'.o'); objects.append(output)
            commands.append([*compiler, *common, *includes, '-c', path, '-o', output])
        with ThreadPoolExecutor(max_workers=4) as pool: results = list(pool.map(run, commands))
        report['commands'].extend(entry for _, entry in results)
        failed = [entry for result, entry in results if result.returncode]
        if failed: raise RuntimeError('Zstd C compilation failed: '+failed[0]['stderr'][-4000:])

        def adapter(label, defines):
            output = out/('MSZstdJNI-'+label+'.o')
            checked([*compiler, *common, *includes, '-Wall', '-Wextra', '-Werror', *defines,
                     '-c', ROOT/'runtime-native/MSZstdJNI.c', '-o', output])
            return output

        def archive(label, extra):
            output = out/label; output.unlink(missing_ok=True)
            if target == 'ios': checked(['xcrun', '--sdk', 'iphoneos', 'ar', 'rcs', output, *objects, extra])
            else: checked(['ar', 'rcs', output, *objects, extra])
            return output

        production = archive('libmslzstd.a', adapter('static', ['-DMSL_ZSTD_STATIC=1']))
        artifacts = [production]
        if target == 'host':
            test_static = archive('libmslzstd-test.a', adapter('test-static', ['-DMSL_ZSTD_STATIC=1', '-DMSL_ZSTD_TESTING=1']))
            dynamic_adapter = adapter('test-dynamic', ['-DMSL_ZSTD_TESTING=1'])
            shared = out/('libmslzstd.dylib' if platform.system() == 'Darwin' else 'libmslzstd.so')
            checked([*compiler, '-dynamiclib' if platform.system() == 'Darwin' else '-shared', *objects, dynamic_adapter, '-pthread', '-o', shared])
            artifacts += [test_static, shared]
        else:
            platform_result = checked(['python3', ROOT/'scripts/verify_ios_archive.py', production])
            report['archive_platform'] = json.loads(platform_result.stdout)
            link_source = out/'link.c'
            link_source.write_text('#include "MSZstdJNI.h"\nint main(void) { return JNI_OnLoad_mslzstd(0, 0) != JNI_VERSION_1_8; }\n')
            executable = out/'MSLZstdLinkProbe'
            checked([*compiler, *common, *includes, '-I'+str(ROOT/'runtime-native'), link_source,
                     '-Xlinker', '-force_load', '-Xlinker', production, '-Wl,-export_dynamic', '-o', executable])
            symbols = checked(['xcrun', 'nm', '-gU', executable]).stdout
            names = {row.split()[-1].removeprefix('_') for row in symbols.splitlines() if row.split()}
            if not EXPORTS <= names or any(name.startswith('Java_mangashelf_host_ZstdNativeTestHooks') for name in names):
                raise RuntimeError('Missing production JNI exports or unexpected test hooks in iOS executable')
            report['verified_jni_exports'] = sorted(EXPORTS)
            report['test_hooks_absent'] = True
            report['link_load_commands'] = checked(['xcrun', 'otool', '-l', executable]).stdout
            artifacts += [executable]
        notices = out/'notices'; notices.mkdir(exist_ok=True)
        for component, names in [('native', ['LICENSE', 'COPYING']), ('jni', ['LICENSE', 'ADDITIONAL_LICENSE_INFO', 'ASSEMBLY_EXCEPTION'])]:
            for name in names:
                output = notices/(component+'-'+name+'.txt')
                shutil.copyfile(ROOT/lock[component]['source_root']/name, output); artifacts.append(output)
        for name, expected in report['sources'].items():
            if digest(ROOT/name) != expected: raise RuntimeError('Native build input changed: '+name)
        report['artifacts'] = [{'path': str(p.relative_to(ROOT)), 'bytes': p.stat().st_size, 'sha256': digest(p)} for p in artifacts]
        report['passed'] = True
    except Exception as error: report['failure'] = str(error)
    path = ROOT/('validation/zstd-native-'+target+'.json'); path.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'target': target, 'failure': report.get('failure'), 'report': str(path.relative_to(ROOT))}))
    if not report['passed']: raise RuntimeError(report.get('failure', 'Native codec build failed'))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--target', choices=['host', 'ios'], default='host')
    build(parser.parse_args().target)
