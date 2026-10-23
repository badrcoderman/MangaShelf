#!/usr/bin/env python3
"""Check the single vetted public source rebuild through the verified host loader."""
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
PIN = '23321c50804ace0b0327117d4a453728b10a65e9383eaa4b962d83aac4afa070'


def main(candidate, live=False, reuse=False):
    archive = candidate/'tachiyomi-all.mangadex-v1.6.0.jar'
    if build.digest(archive) != PIN: raise ValueError('Not the explicitly reviewed public source rebuild')
    tests = sorted((ROOT/'runtime-host/src/test/mangadex').rglob('*.kt'))
    inputs = [Path(__file__), ROOT/'scripts/build-runtime-host.py', ROOT/'runtime-host/dependencies.lock.json',
              *build.source_dependency_inputs(), *tests, ROOT/'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java',
              *sorted((ROOT/'runtime-host/src/main').rglob('*.kt')), *sorted((ROOT/'runtime-host/src/main').rglob('*.java'))]
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(), 'passed': False,
              'scope': 'Pinned vetted public MangaDex source rebuild, debug certificate and host JVM only; no IPA specimen, publisher trust bootstrap or iOS execution.',
              'source_rebuild_sha256': PIN, 'source_rebuild_executed': False, 'ios_execution': False,
              'live_api_requested': live, 'reuse_host_build': reuse,
              'inputs_sha256': {str(p.relative_to(ROOT)): build.digest(p) for p in inputs}, 'commands': []}

    def run(command, timeout=150):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode: raise RuntimeError(result.stderr[-8000:])
        return result

    try:
        if reuse:
            prior = json.loads((ROOT/'validation/mangadex-source-host.json').read_text())
            built = json.loads((ROOT/'validation/runtime-host-build.json').read_text())
            if prior.get('build_jar') != built['jar'] or prior['inputs_sha256']['scripts/build-runtime-host.py'] != build.digest(ROOT/'scripts/build-runtime-host.py'):
                raise RuntimeError('No previous matching source check build')
            if not built['passed'] or built['dependency_lock_sha256'] != build.digest(build.LOCK):
                raise RuntimeError('Cached host dependency inputs changed')
            for name, expected in built['sources'].items():
                if build.digest(ROOT/name) != expected: raise RuntimeError('Cached host source changed: '+name)
            if build.digest(ROOT/built['jar']['path']) != built['jar']['sha256']: raise RuntimeError('Cached host JAR changed')
            resolved = build.dependencies()
        else: resolved, built = build.build()
        report['build_jar'] = built['jar']
        with tempfile.TemporaryDirectory(prefix='mangadex-check-', dir=build.OUT) as directory:
            temp = Path(directory); classes = temp/'classes'; data = temp/'data'; data.mkdir()
            run(build.compiler_command(resolved, tests, classes, str(ROOT/built['jar']['path'])))
            cp = os.pathsep.join([str(classes), str(ROOT/built['jar']['path']), build.classpath(resolved, 'runtime')])
            report['source_rebuild_executed'] = True
            network = []
            if live:
                proxy = os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy')
                if proxy:
                    parsed = urlsplit(proxy)
                    if parsed.username or parsed.password: raise RuntimeError('Managed proxy authentication requires JVM client configuration')
                    if not parsed.hostname: raise RuntimeError('Invalid configured proxy')
                    for scheme in ['http', 'https']:
                        network += [f'-D{scheme}.proxyHost={parsed.hostname}', f'-D{scheme}.proxyPort={parsed.port or 80}']
            result = run(['java', '--enable-native-access=ALL-UNNAMED', '-Xint', '-Xcheck:jni', *network,
                          '-Djava.library.path='+str(ROOT/'build/zstd-native/host'), '-cp', cp, 'mangashelf.host.MangaDexCheck', candidate, data, *(['live'] if live else [])], timeout=300)
            report['test_result'] = json.loads(result.stdout)
            if report['test_result'].get('passed') is not True: raise RuntimeError('Source rebuild checks did not pass')
        for name, expected in report['inputs_sha256'].items():
            if build.digest(ROOT/name) != expected: raise RuntimeError('Source check input changed: '+name)
        report['passed'] = True
    except Exception as error: report['failure'] = str(error)
    path = ROOT/('validation/mangadex-source-live-host.json' if live else 'validation/mangadex-source-host.json')
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
