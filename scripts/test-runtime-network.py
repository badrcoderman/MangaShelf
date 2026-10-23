#!/usr/bin/env python3
"""Run authored Source 1.6 HTTP and cancellation checks with local HTTP/TLS servers."""
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_build', ROOT/'scripts/build-runtime-host.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
PASSWORD = 'mangashelf-authored-network-test'


def main():
    tests = sorted((ROOT/'runtime-host/src/test/network').rglob('*.kt'))
    sources = [ROOT/'scripts/build-runtime-host.py', ROOT/'runtime-host/dependencies.lock.json', Path(__file__), *tests]
    sources += sorted((ROOT/'runtime-host/src/main').rglob('*.kt'))
    sources += sorted((ROOT/'runtime-host/src/main').rglob('*.java'))
    sources.append(ROOT/'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java')
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(),
              'scope': 'Authored HTTP source/call fixtures and actual loopback HTTP/HTTPS on host JVM only. No NativeNet/URLSession, published extension, Android UI or iOS execution.',
              'passed': False, 'inputs_sha256': {str(p.relative_to(ROOT)): build.digest(p) for p in sources},
              'documentation': [
                  'https://raw.githubusercontent.com/square/okhttp/parent-5.4.0/okhttp/src/commonJvmAndroid/kotlin/okhttp3/Interceptor.kt',
                  'https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/suspend-cancellable-coroutine.html',
                  'https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/'],
              'commands': []}

    def run(command, timeout=120):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode,
                                    'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode: raise RuntimeError(result.stderr[-5000:])
        return result

    try:
        resolved, built = build.build()
        report['build_jar'] = built['jar']
        report['host_java'] = built['build_jdk']
        with tempfile.TemporaryDirectory(prefix='network-check-', dir=build.OUT) as directory:
            temporary = Path(directory); classes = temporary/'test-classes'; data = temporary/'data'; data.mkdir()
            # This generated key is a public test fixture. JKS avoids spending the
            # interpreted run's request budget on PKCS12 password stretching.
            keystore = temporary/'fixture.jks'
            run(['keytool', '-genkeypair', '-alias', 'fixture', '-keystore', keystore, '-storetype', 'JKS',
                 '-storepass', PASSWORD, '-keypass', PASSWORD, '-keyalg', 'RSA', '-keysize', '2048',
                 '-sigalg', 'SHA256withRSA', '-validity', '365', '-ext', 'san=dns:localhost',
                 '-dname', 'CN=localhost,O=MangaShelf Authored Network Tests,C=ZZ', '-noprompt'])
            run(build.compiler_command(resolved, tests, classes, str(ROOT/built['jar']['path'])))
            cp = os.pathsep.join([str(classes), str(ROOT/built['jar']['path']), build.classpath(resolved, 'runtime')])
            result = run(['java', '-Xint', '-cp', cp, 'mangashelf.host.NetworkCheck', data, keystore], timeout=90)
            report['test_result'] = json.loads(result.stdout)
            if report['test_result'].get('passed') is not True: raise RuntimeError('HTTP checks did not report a pass')
        for name, expected in report['inputs_sha256'].items():
            if build.digest(ROOT/name) != expected: raise RuntimeError('HTTP input changed during checks')
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
    output = ROOT/'validation/runtime-network-host.json'
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'checks': len(report.get('test_result', {}).get('checks', {})),
                      'failure': report.get('failure'), 'report': str(output.relative_to(ROOT))}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
