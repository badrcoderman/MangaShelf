#!/usr/bin/env python3
"""Check authored Android preference contracts and durable files on the host JDK."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
JAVA = ROOT/'runtime-host/src/main/java'
SOURCES = [JAVA/'android/content/SharedPreferences.java', JAVA/'android/content/Context.java',
           JAVA/'android/preference/PreferenceManager.java', JAVA/'mangashelf/host/PreferenceStore.java',
           ROOT/'runtime-host/src/test/java/mangashelf/host/PreferenceStoreCheck.java']


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(),
              'scope': 'Authored Android preference descriptors, application file context and bounded durable preference store on host JVM only. No Android UI, real extension, networking or iOS execution.',
              'passed': False, 'inputs_sha256': {str(p.relative_to(ROOT)): digest(p) for p in [*SOURCES, Path(__file__)]},
              'documentation': ['https://developer.android.com/reference/android/content/SharedPreferences',
                                'https://developer.android.com/reference/android/content/SharedPreferences.Editor'],
              'commands': []}

    def run(command):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=60)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode,
                                    'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode: raise RuntimeError(result.stderr[-4000:])
        return result

    try:
        with tempfile.TemporaryDirectory(prefix='msl-preference-check-') as directory:
            temp = Path(directory); classes = temp/'classes'; data = temp/'data'; data.mkdir()
            report['host_java'] = run(['java', '-version']).stderr
            run(['javac', '--release', '17', '-encoding', 'UTF-8', '-Xlint:all', '-Werror', '-d', classes, *SOURCES])
            result = run(['java', '-Xint', '-cp', classes, 'mangashelf.host.PreferenceStoreCheck', data])
            report['test_result'] = json.loads(result.stdout)
            assert report['test_result']['passed'] and all(report['test_result']['checks'].values())
        for name, expected in report['inputs_sha256'].items():
            if digest(ROOT/name) != expected: raise RuntimeError('Preference input changed during checks')
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
    output = ROOT/'validation/runtime-preferences-host.json'
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'checks': len(report.get('test_result', {}).get('checks', {})),
                      'failure': report.get('failure'), 'report': str(output.relative_to(ROOT))}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
