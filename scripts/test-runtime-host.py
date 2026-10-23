#!/usr/bin/env python3
"""Check authored API bytecode against pinned descriptors and run own models only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_build', ROOT / 'scripts/build-runtime-host.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
API_HASH = '28685652e15c6ea010212db5cd94e8d7019c5227f260442cbb985ec0f51cb324'


def class_members(data):
    cursor = 0
    def read(count):
        nonlocal cursor
        result = data[cursor:cursor+count]
        if len(result) != count:
            raise ValueError('Truncated authored class')
        cursor += count
        return result
    def u2(): return struct.unpack('>H', read(2))[0]
    def u4(): return struct.unpack('>I', read(4))[0]
    if u4() != 0xCAFEBABE:
        raise ValueError('Invalid class magic')
    minor, major = u2(), u2()
    if (minor, major) != (0, 61):
        raise ValueError('Own API classes must target Java 17')
    pool = [None] * u2()
    index = 1
    while index < len(pool):
        tag = read(1)[0]
        if tag == 1: pool[index] = read(u2()).decode('utf-8', 'replace')
        elif tag in (7,8,16,19,20): pool[index] = u2()
        elif tag in (3,4,9,10,11,12,17,18): read(4)
        elif tag in (5,6): read(8); index += 1
        elif tag == 15: read(3)
        else: raise ValueError(f'Unsupported class constant tag {tag}')
        index += 1
    access, own, parent = u2(), u2(), u2()
    interfaces = [pool[pool[u2()]] for _ in range(u2())]
    def attributes():
        for _ in range(u2()):
            u2(); read(u4())
    def members():
        result, flags_by_member = set(), {}
        for _ in range(u2()):
            flags, name, descriptor = u2(), u2(), u2()
            if flags & 1:
                result.add((pool[name], pool[descriptor]))
                flags_by_member[(pool[name], pool[descriptor])] = flags
            attributes()
        return result, flags_by_member
    (fields, field_flags), (methods, method_flags) = members(), members()
    attributes()
    if cursor != len(data): raise ValueError('Unexpected authored class tail')
    return {'name':pool[pool[own]], 'parent':pool[pool[parent]] if parent else None,
            'interfaces':interfaces, 'fields':fields, 'methods':methods, 'access':access,
            'fields_flags':field_flags, 'methods_flags':method_flags}


def expected_api(path):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != API_HASH:
        raise ValueError('Public API file does not match the pinned revision')
    expected, current = {}, None
    names = {'eu/kanade/tachiyomi/source/'+name for name in
             ('Source','Source$DefaultImpls','SourceFactory','CatalogueSource','CatalogueSource$DefaultImpls')}
    for line in data.decode().splitlines():
        match = re.match(r'public .*?class ([^ :{]+).*\{', line)
        if match:
            name = match.group(1)
            current = name if name in names or name.startswith('eu/kanade/tachiyomi/source/model/') else None
            if current:
                parents = line.split(' : ', 1)[1].removesuffix(' {').split(', ') if ' : ' in line else []
                expected[current] = {'methods':set(), 'fields':set(), 'static':set(),
                                     'interface':' interface ' in line, 'parents':parents}
        elif line == '}': current = None
        elif current:
            match = re.search(r'\b(fun|field) (\S+) (\S+)', line)
            if match:
                kind, name, descriptor = match.groups()
                expected[current]['methods' if kind=='fun' else 'fields'].add((name, descriptor))
                if ' static ' in line:
                    expected[current]['static'].add((kind, name, descriptor))
    if len(expected) < 20: raise ValueError('Pinned API selection unexpectedly small')
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-api', type=Path, default=ROOT/'runtime-host/reference/library.api')
    args = parser.parse_args()
    report = {'scope':'Authored Source1.6 API/model subset descriptors and functional synthetic sources on host. No HttpSource/Android host bootstrap, real extension class loading, source registry, network or iOS proof.',
              'reference_commit':'42255ee5fa96d9425697b7c143587483207308d1', 'reference_api_sha256':API_HASH,
              'extension_code_executed':False, 'passed':False,
              'script_sha256':build.digest(Path(__file__)),
              'build_script_sha256':build.digest(ROOT/'scripts/build-runtime-host.py')}
    try:
        expected = expected_api(args.reference_api)
        resolved, build_report = build.build()
        report['build_jar'] = build_report['jar']
        with zipfile.ZipFile(ROOT / build_report['jar']['path']) as jar:
            actual = {name[:-6]:class_members(jar.read(name)) for name in jar.namelist() if name.endswith('.class')}
        missing = []
        for name, members in expected.items():
            if name not in actual:
                missing.append({'class':name}); continue
            if bool(actual[name]['access'] & 0x0200) != members['interface']:
                missing.append({'class':name, 'kind':'interface/class mismatch'})
            for parent in members['parents']:
                if parent not in [actual[name]['parent'], *actual[name]['interfaces']]:
                    missing.append({'class':name, 'kind':'inheritance', 'parent':parent})
            for kind in ('fields','methods'):
                for member in sorted(members[kind] - actual[name][kind]):
                    missing.append({'class':name, 'kind':kind, 'name':member[0], 'descriptor':member[1]})
                for member in members[kind] & actual[name][kind]:
                    expected_static = ('fun' if kind=='methods' else 'field', *member) in members['static']
                    if bool(actual[name][kind+'_flags'][member] & 8) != expected_static:
                        missing.append({'class':name,'kind':'static/instance mismatch','member':member})
        report['abi'] = {'classes_checked':len(expected), 'members_checked':sum(len(v['fields'])+len(v['methods']) for v in expected.values()), 'missing':missing}
        if missing: raise ValueError('Authored API is missing pinned public descriptors')
        tests = sorted((ROOT / 'runtime-host/src/test/kotlin').rglob('*.kt'))
        if not tests: raise ValueError('Missing authored functional tests')
        report['test_source_sha256'] = {str(p.relative_to(ROOT)):build.digest(p) for p in tests}
        with tempfile.TemporaryDirectory(prefix='tests-', dir=build.OUT) as directory:
            classes = Path(directory)
            command = build.compiler_command(resolved, tests, classes, str(ROOT / build_report['jar']['path']))
            compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
            report['test_compile'] = {'command':command,'exit_code':compiled.returncode,'stdout':compiled.stdout,'stderr':compiled.stderr}
            if compiled.returncode: raise ValueError('Functional tests did not compile')
            cp = os.pathsep.join([str(classes), str(ROOT / build_report['jar']['path']), build.classpath(resolved,'runtime')])
            command = ['java','-Xint','-cp',cp,'mangashelf.host.ModelApiCheck']
            ran = subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=45)
            report['functional_run'] = {'command':command,'exit_code':ran.returncode,'stdout':ran.stdout,'stderr':ran.stderr}
            if ran.returncode: raise ValueError('Authored functional API tests failed')
            result = json.loads(ran.stdout)
            if result.get('passed') is not True: raise ValueError('Functional API tests did not report a pass')
            report['functional_checks'] = result
        for name, value in report['test_source_sha256'].items():
            if build.digest(ROOT/name) != value:
                raise ValueError('Functional test input changed during compilation/execution')
        if build.digest(Path(__file__)) != report['script_sha256']:
            raise ValueError('Test helper changed during execution')
        if build.digest(ROOT/'scripts/build-runtime-host.py') != report['build_script_sha256']:
            raise ValueError('Build helper changed during execution')
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
    (ROOT/'validation/runtime-host-tests.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed':report['passed'],'abi':report.get('abi'),'failure':report.get('failure')},indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
