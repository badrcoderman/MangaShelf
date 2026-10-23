#!/usr/bin/env python3
"""Build the authored source host with pinned Kotlin tools, never an extension JAR."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/runtime-host'
LOCK = ROOT / 'runtime-host/dependencies.lock.json'


def digest(path, algorithm='sha256'):
    value = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def dependencies():
    lock = json.loads(LOCK.read_text())
    if lock['format'] != 1 or lock['repository'] != 'https://repo.maven.apache.org/maven2/':
        raise ValueError('Unsupported dependency lock')
    target = OUT / 'dependencies'
    target.mkdir(parents=True, exist_ok=True)
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    resolved, seen = [], set()
    for item in lock['artifacts']:
        group, artifact, version = (item[key] for key in ('group', 'artifact', 'version'))
        if not all(re.fullmatch(r'[A-Za-z0-9_.-]+', part) and '..' not in part for part in (group, artifact, version)):
            raise ValueError('Invalid dependency coordinates')
        name = f'{artifact}-{version}.jar'
        url = f'https://repo.maven.apache.org/maven2/{group.replace(".", "/")}/{artifact}/{version}/{name}'
        if item['filename'] != name or item['url'] != url or name in seen:
            raise ValueError('Invalid or duplicate dependency URL/name')
        seen.add(name)
        if not (0 < item['bytes'] <= 128 * 1024**2 and re.fullmatch('[a-f0-9]{64}', item['sha256'])
                and re.fullmatch('[a-f0-9]{128}', item['sha512'])
                and item['roles'] and set(item['roles']) <= {'compiler', 'runtime'}):
            raise ValueError('Invalid dependency bounds or fingerprints')
        path = target / name
        valid = lambda candidate: (candidate.is_file() and candidate.stat().st_size == item['bytes']
                                    and digest(candidate) == item['sha256']
                                    and digest(candidate, 'sha512') == item['sha512'])
        if path.exists():
            if not valid(path):
                raise ValueError(f'Dependency output was modified: {name}')
        else:
            candidates = list((cache / group / artifact / version).glob('*/' + name))
            cached = next((candidate for candidate in candidates if valid(candidate)), None)
            if cached:
                shutil.copyfile(cached, path)
            else:
                with tempfile.NamedTemporaryFile(dir=target, delete=False) as temporary:
                    pending = Path(temporary.name)
                    try:
                        with urllib.request.urlopen(url, timeout=45) as response:
                            if not response.url.startswith('https://'):
                                raise ValueError('Dependency download redirected away from HTTPS')
                            count = 0
                            for block in iter(lambda: response.read(1024 * 1024), b''):
                                count += len(block)
                                if count > item['bytes']:
                                    raise ValueError('Dependency download exceeds pinned size')
                                temporary.write(block)
                        temporary.flush()
                        if not valid(pending):
                            raise ValueError(f'Dependency fingerprint mismatch: {name}')
                        pending.replace(path)
                    finally:
                        pending.unlink(missing_ok=True)
        resolved.append((item, path))
    if not resolved or not any('compiler' in item['roles'] for item, _ in resolved):
        raise ValueError('No pinned compiler dependencies')
    return resolved


def classpath(resolved, role):
    return os.pathsep.join(str(path) for item, path in resolved if role in item['roles'])


def compiler_command(resolved, sources, destination, extra_classpath=''):
    runtime = classpath(resolved, 'runtime')
    if extra_classpath:
        runtime += os.pathsep + extra_classpath
    return ['java', '-Xmx768m', '-cp', classpath(resolved, 'compiler'),
            'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
            '-jvm-target=17', '-jvm-default=enable', '-Werror', '-classpath', runtime,
            '-d', str(destination), *map(str, sources)]


def build():
    resolved = dependencies()  # Every tool/runtime artifact is verified before Java runs.
    java = subprocess.run(['java', '-version'], capture_output=True, text=True, check=True)
    java_version = java.stdout + java.stderr
    match = re.search(r'version "(\d+)', java_version)
    if not match or int(match.group(1)) < 21:
        raise ValueError('JDK 21 or later is required for the pinned List ABI; bytecode targets 17')
    sources = sorted((ROOT / 'runtime-host/src/main/kotlin').rglob('*.kt'))
    java_sources = sorted((ROOT / 'runtime-host/src/main/java').rglob('*.java'))
    java_sources.append(ROOT / 'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java')
    if not sources or len(java_sources) < 2:
        raise ValueError('No authored runtime host sources')
    OUT.mkdir(parents=True, exist_ok=True)
    report = {'scope': 'Compile independently authored source host, verifier and loader only; no archive execution during build or iOS execution.',
              'dependency_lock_sha256': digest(LOCK),
              'dependencies': [{'filename': item['filename'], 'sha256': digest(path), 'roles': item['roles']} for item, path in resolved],
              'sources': {str(path.relative_to(ROOT)): digest(path) for path in [*sources, *java_sources]},
              'build_jdk': java_version,
              'platform_api': 'JDK21+ List compatibility bridges; Java17 bytecode, not a Java17 platform API guarantee',
              'extension_code_executed': False, 'ios_execution': False}
    with tempfile.TemporaryDirectory(prefix='classes-', dir=OUT) as directory:
        classes = Path(directory)
        java_command = ['javac', '--release', '17', '-encoding', 'UTF-8', '-Xlint:all', '-Werror',
                        '-d', str(classes), *map(str, java_sources)]
        java_result = subprocess.run(java_command, cwd=ROOT, capture_output=True, text=True, timeout=60)
        report['java_compile'] = {'command': java_command, 'exit_code': java_result.returncode,
                                  'stdout': java_result.stdout, 'stderr': java_result.stderr}
        command = compiler_command(resolved, sources, classes, str(classes))
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        report['compile'] = {'command': command, 'exit_code': result.returncode,
                             'stdout': result.stdout, 'stderr': result.stderr}
        report['passed'] = result.returncode == 0 and java_result.returncode == 0
        if report['passed'] and any(digest(ROOT / name) != value for name, value in report['sources'].items()):
            report['passed'] = False
            report['compile']['stderr'] += '\nAuthored source changed during compilation.\n'
        if report['passed']:
            jar_path = OUT / 'runtime-host.jar'
            with zipfile.ZipFile(jar_path, 'w', zipfile.ZIP_DEFLATED) as jar:
                for path in sorted(classes.rglob('*')):
                    if path.is_file():
                        entry = zipfile.ZipInfo(path.relative_to(classes).as_posix(), (1980, 1, 1, 0, 0, 0))
                        entry.compress_type = zipfile.ZIP_DEFLATED
                        jar.writestr(entry, path.read_bytes())
            report['jar'] = {'path': str(jar_path.relative_to(ROOT)), 'bytes': jar_path.stat().st_size, 'sha256': digest(jar_path)}
    (ROOT / 'validation/runtime-host-build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'sources': len(sources), 'report': 'validation/runtime-host-build.json'}))
    if not report['passed']:
        print(report['java_compile']['stderr'])
        print(report['compile']['stderr'])
        raise SystemExit(1)
    return resolved, report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    build()
