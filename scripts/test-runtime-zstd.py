#!/usr/bin/env python3
"""Check source-built codec JNI through dynamic and genuinely builtin host loading."""
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/filename)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def main():
    build = module('host_build', 'build-runtime-host.py')
    native = module('native_build', 'build-zstd-native.py')
    tests = sorted((ROOT/'runtime-host/src/test/zstd').rglob('*.kt'))
    java_tests = sorted((ROOT/'runtime-host/src/test/zstd').rglob('*.java'))
    sources = [Path(__file__), ROOT/'scripts/build-runtime-host.py', ROOT/'scripts/build-zstd-native.py',
               ROOT/'runtime-host/dependencies.lock.json', *build.source_dependency_inputs(),
               ROOT/'runtime-native/MSZstdJNI.c', ROOT/'runtime-native/MSZstdJNI.h', ROOT/'runtime-native/zstd_host_check.c',
               ROOT/'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java', *tests, *java_tests]
    sources += sorted((ROOT/'runtime-host/src/main').rglob('*.kt'))
    sources += sorted((ROOT/'runtime-host/src/main').rglob('*.java'))
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(), 'passed': False,
              'scope': 'Source-built Zstd/Okio and authored host JNI/format/fault fixtures under -Xcheck:jni; dynamic and named builtin loading, no iOS execution or published extension.',
              'ios_execution': False, 'published_extension_executed': False,
              'inputs_sha256': {str(p.relative_to(ROOT)): build.digest(p) for p in sources}, 'commands': [], 'test_runs': {}}

    def run(command, timeout=180):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode: raise RuntimeError(result.stderr[-6000:])
        if any(text in result.stderr for text in ['WARNING in native method', 'FATAL ERROR in native method']):
            raise RuntimeError('JNI checker reported a contract violation')
        return result

    try:
        report['native_build'] = native.build('host')
        resolved, built = build.build()
        report['build_jar'] = built['jar']; report['host_java'] = built['build_jdk']
        lock, _ = build.zstd_source.verify(); jni = ROOT/lock['jni']['source_root']
        with tempfile.TemporaryDirectory(prefix='zstd-check-', dir=build.OUT) as directory:
            temp = Path(directory); classes = temp/'test-classes'; classes.mkdir()
            run(['javac', '--release', '17', '-encoding', 'UTF-8', '-Xlint:all', '-Werror', '-d', classes, *java_tests])
            extra = os.pathsep.join([str(classes), str(ROOT/built['jar']['path'])])
            run(build.compiler_command(resolved, tests, classes, extra))
            cp = os.pathsep.join([str(classes), str(ROOT/built['jar']['path']), build.classpath(resolved, 'runtime')])
            dynamic_temp = temp/'dynamic-temp'; dynamic_temp.mkdir()
            result = run(['java', '--enable-native-access=ALL-UNNAMED', '-Xint', '-Xcheck:jni',
                          '-Djava.library.path='+str(ROOT/'build/zstd-native/host'), '-Djava.io.tmpdir='+str(dynamic_temp),
                          '-cp', cp, 'mangashelf.host.ZstdCheck', 'dynamic'])
            report['test_runs']['dynamic'] = json.loads(result.stdout)
            report['test_runs']['dynamic']['no_temporary_library_extraction'] = not any(dynamic_temp.iterdir())
            settings = run(['java', '-XshowSettings:properties', '-version'])
            java_home = Path(re.search(r'^\s*java.home\s*=\s*(.+)$', settings.stderr, re.MULTILINE).group(1))
            jvm = java_home/'lib/server'
            executable = temp/'ZstdBuiltinHostCheck'
            force = ['-Xlinker', '-force_load', '-Xlinker', str(ROOT/'build/zstd-native/host/libmslzstd-test.a'), '-Wl,-export_dynamic'] if platform.system() == 'Darwin' else [
                '-Xlinker', '--whole-archive', str(ROOT/'build/zstd-native/host/libmslzstd-test.a'), '-Xlinker', '--no-whole-archive', '-Wl,--export-dynamic']
            run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                 '-I'+str(jni/'src/java.base/share/native/include'), '-I'+str(jni/'src/java.base/unix/native/include'),
                 '-I'+str(ROOT/'runtime-native'), ROOT/'runtime-native/zstd_host_check.c', *force,
                 '-L'+str(jvm), '-Wl,-rpath,'+str(jvm), '-ljvm', '-pthread', '-o', executable])
            empty_libraries = temp/'empty-libraries'; empty_libraries.mkdir()
            builtin_temp = temp/'builtin-temp'; builtin_temp.mkdir()
            result = run([executable, cp, empty_libraries, builtin_temp])
            if 'PASS embedded VM shutdown after codec cleanup' not in result.stderr:
                raise RuntimeError('Embedded VM shutdown did not report success')
            report['test_runs']['builtin'] = json.loads(result.stdout)
            report['test_runs']['builtin']['no_temporary_library_extraction'] = not any(builtin_temp.iterdir())
            report['builtin_library_path_empty'] = not any(empty_libraries.iterdir())
            report['embedded_vm_shutdown'] = True
            for mode, result in report['test_runs'].items():
                if (result.get('passed') is not True or result.get('loading') != mode
                        or not result.get('no_temporary_library_extraction')
                        or not result.get('checks') or not all(value is True for value in result['checks'].values())):
                    raise RuntimeError('Codec tests did not pass: '+mode)
        for name, expected in report['inputs_sha256'].items():
            if build.digest(ROOT/name) != expected: raise RuntimeError('Codec input changed during testing: '+name)
        report['passed'] = True
    except Exception as error: report['failure'] = str(error)
    path = ROOT/'validation/runtime-zstd-host.json'; path.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'checks_per_mode': {key: len(value.get('checks', {})) for key, value in report['test_runs'].items()},
                      'failure': report.get('failure'), 'report': str(path.relative_to(ROOT))}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
