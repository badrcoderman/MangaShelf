#!/usr/bin/env python3
"""Execute only the pinned reviewed Team X source rebuild, never a specimen JAR."""
from datetime import datetime, timezone
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_build', ROOT/'scripts/build-runtime-host.py')
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)
PIN = '9b8908c39e874bbebb09698e1b535f0b8260938992a4687ffbd82f8fbe388a4d'


def main(candidate, live, reuse):
    archive = candidate/'tachiyomi-ar.teamx-v1.6.33.jar'
    if build.digest(archive) != PIN:
        raise ValueError('Not the explicitly reviewed source rebuild from run 40094882189')
    tests = sorted((ROOT/'runtime-host/src/test/teamx').rglob('*.kt'))
    inputs = [Path(__file__), ROOT/'scripts/build-runtime-host.py', build.LOCK, *build.source_dependency_inputs(), *tests,
              ROOT/'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java',
              *sorted((ROOT/'runtime-host/src/main').rglob('*.kt')), *sorted((ROOT/'runtime-host/src/main').rglob('*.java'))]
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(), 'passed': False,
              'scope': 'Reviewed public Team X source rebuild with debug certificate on host JVM only; no original IPA code, publisher trust bootstrap or iPhone execution.',
              'source_rebuild_sha256': PIN, 'source_rebuild_executed': False, 'live_requested': live, 'ios_execution': False,
              'inputs_sha256': {str(p.relative_to(ROOT)): build.digest(p) for p in inputs}, 'commands': []}

    def run(command, timeout=180):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode,
                                   'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode:
            raise RuntimeError(result.stderr[-8000:])
        return result

    try:
        if reuse:
            built = json.loads((ROOT/'validation/runtime-host-build.json').read_text())
            if built.get('passed') is not True or built['dependency_lock_sha256'] != build.digest(build.LOCK):
                raise ValueError('No matching successful host build')
            expected_main = {str(p.relative_to(ROOT)) for p in inputs if p.is_relative_to(ROOT/'runtime-host/src/main')}
            built_main = {p for p in built['sources'] if p.startswith('runtime-host/src/main/')}
            if expected_main != built_main:
                raise ValueError('Cached host main source set differs')
            for name, expected in built['sources'].items():
                if build.digest(ROOT/name) != expected:
                    raise ValueError('Cached host source changed: '+name)
            if build.digest(ROOT/built['jar']['path']) != built['jar']['sha256']:
                raise ValueError('Cached host JAR changed')
            resolved = build.dependencies()
        else:
            resolved, built = build.build()
        report['build_jar'] = built['jar']
        with tempfile.TemporaryDirectory(prefix='teamx-check-', dir=build.OUT) as directory:
            temp = Path(directory); classes = temp/'classes'; data = temp/'data'; data.mkdir()
            run(build.compiler_command(resolved, tests, classes, str(ROOT/built['jar']['path'])))
            cp = os.pathsep.join([str(classes), str(ROOT/built['jar']['path']), build.classpath(resolved, 'runtime')])
            network = []
            if live:
                proxy = os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy')
                if proxy:
                    parsed = urlsplit(proxy)
                    if parsed.username or parsed.password or not parsed.hostname:
                        raise ValueError('Proxy requires explicit supported JVM configuration')
                    for scheme in ['http', 'https']:
                        network += [f'-D{scheme}.proxyHost={parsed.hostname}', f'-D{scheme}.proxyPort={parsed.port or 80}']
            report['source_rebuild_executed'] = True
            result = run(['java', '--enable-native-access=ALL-UNNAMED', '-Xint', '-Xcheck:jni', *network,
                          '-Djava.library.path='+str(ROOT/'build/zstd-native/host'), '-cp', cp,
                          'mangashelf.host.TeamXCheck', candidate, data, *(['live'] if live else [])], timeout=400)
            report['test_result'] = json.loads(result.stdout)
            if report['test_result'].get('passed') is not True:
                raise RuntimeError('Source check did not pass')
        for name, expected in report['inputs_sha256'].items():
            if build.digest(ROOT/name) != expected:
                raise RuntimeError('Source check input changed: '+name)
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
    path = ROOT/('validation/teamx-source-live-host.json' if live else 'validation/teamx-source-host.json')
    path.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'failure': report.get('failure'), 'report': str(path.relative_to(ROOT))}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate-directory', type=Path, required=True)
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--reuse-host-build', action='store_true')
    arguments = parser.parse_args()
    raise SystemExit(main(arguments.candidate_directory.resolve(), arguments.live, arguments.reuse_host_build))
