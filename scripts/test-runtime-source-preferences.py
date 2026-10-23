#!/usr/bin/env python3
"""Check authored source settings, validation and source-lease lifecycle on the host JVM."""
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


def main():
    tests = sorted((ROOT/'runtime-host/src/test/source-preferences').rglob('*.kt'))
    sources = [ROOT/'scripts/build-runtime-host.py', ROOT/'runtime-host/dependencies.lock.json', Path(__file__),
               *build.source_dependency_inputs(), *tests]
    sources += sorted((ROOT/'runtime-host/src/main').rglob('*.kt'))
    sources += sorted((ROOT/'runtime-host/src/main').rglob('*.java'))
    sources.append(ROOT/'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java')
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(),
              'scope': 'Authored ConfigurableSource settings, validation, persistence and source-lease lifecycle on host JVM; no published extension, Android rendering, Swift UI or iOS execution.',
              'passed': False, 'inputs_sha256': {str(p.relative_to(ROOT)): build.digest(p) for p in sources},
              'commands': []}

    def run(command):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=120)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode,
                                    'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode: raise RuntimeError(result.stderr[-5000:])
        return result

    try:
        resolved, built = build.build()
        report['build_jar'] = built['jar']
        report['host_java'] = built['build_jdk']
        with tempfile.TemporaryDirectory(prefix='source-preferences-check-', dir=build.OUT) as directory:
            temp = Path(directory); classes = temp/'test-classes'; data = temp/'data'; data.mkdir()
            run(build.compiler_command(resolved, tests, classes, str(ROOT/built['jar']['path'])))
            cp = os.pathsep.join([str(classes), str(ROOT/built['jar']['path']), build.classpath(resolved, 'runtime')])
            result = run(['java', '-Xint', '-cp', cp, 'mangashelf.host.SourcePreferencesCheck', data])
            report['test_result'] = json.loads(result.stdout)
            if report['test_result'].get('passed') is not True: raise RuntimeError('Source preference checks did not report a pass')
        for name, expected in report['inputs_sha256'].items():
            if build.digest(ROOT/name) != expected: raise RuntimeError('Source preference input changed during checks')
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
    output = ROOT/'validation/runtime-source-preferences-host.json'
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'checks': len(report.get('test_result', {}).get('checks', {})),
                      'failure': report.get('failure'), 'report': str(output.relative_to(ROOT))}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
