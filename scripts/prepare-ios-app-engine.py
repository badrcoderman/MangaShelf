#!/usr/bin/env python3
"""Prepare verified source-built JVM/codec and host resources for the iOS app."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT/path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

build = module('app_host_build', 'scripts/build-runtime-host.py')
evidence_check = module('app_runtime_evidence', 'scripts/download-ios-jvm-evidence.py')
platform_check = module('app_ios_archive', 'scripts/verify_ios_archive.py')
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()


def verify_host(report):
    if not report.get('passed') or report['dependency_lock_sha256'] != sha(build.LOCK):
        raise ValueError('A current verified runtime host build is required')
    current = {str(p.relative_to(ROOT)) for suffix in ['*.kt', '*.java'] for p in (ROOT/'runtime-host/src/main').rglob(suffix)}
    if not current <= report['sources'].keys(): raise ValueError('Host build omits current source files')
    for name, digest in report['sources'].items():
        if sha(ROOT/name) != digest: raise ValueError('Host source changed: '+name)
    jar = ROOT/report['jar']['path']
    if sha(jar) != report['jar']['sha256'] or jar.stat().st_size != report['jar']['bytes']:
        raise ValueError('Host JAR changed')
    with zipfile.ZipFile(jar) as archive:
        if archive.testzip() is not None: raise ValueError('Host JAR CRC mismatch')
        names = archive.namelist()
        for name in ['mangashelf/host/SourceRuntime.class', 'mangashelf/host/SourceCommands.class']:
            if name not in names: raise ValueError('Host entrypoint missing')
        if any(name.startswith('fixture/') or 'TestHooks' in name for name in names): raise ValueError('Test code in host JAR')
    return jar


def checked_legal(item, cache):
    path = cache/item['filename']
    def valid():
        return path.is_file() and path.stat().st_size == item['bytes'] and sha(path) == item['sha256'] and hashlib.sha512(path.read_bytes()).hexdigest() == item['sha512']
    if path.exists():
        if not valid(): raise ValueError('Legal input changed: '+path.name)
    else:
        if not item['url'].startswith('https://repo.maven.apache.org/maven2/') or not (0 < item['bytes'] <= 16*1024*1024): raise ValueError('Invalid legal input')
        with urllib.request.urlopen(item['url'], timeout=45) as response:
            if not response.url.startswith('https://'): raise ValueError('Insecure legal input redirect')
            data = response.read(item['bytes']+1)
        path.write_bytes(data)
        if not valid(): raise ValueError('Legal input digest mismatch: '+path.name)
    return path


def prepare(runtime, selection_path, codec, output, rebuild=False, codec_report_path=None):
    if output.exists() and any(output.iterdir()): raise ValueError('Engine output must be empty')
    output.mkdir(parents=True, exist_ok=True)
    selection = json.loads(selection_path.read_text())
    if not selection.get('build_manifest_verified') or selection.get('repository') != 'badrcoderman/MangaShelf': raise ValueError('Verified runtime provenance required')
    run = {'head_sha': selection['head_sha'], 'id': selection['run_id'], 'repository': {'full_name': selection['repository']}}
    if not evidence_check.verify_build_manifest(runtime, run): raise ValueError('Runtime build manifest missing')
    provenance = json.loads((runtime/'build-provenance.json').read_text())
    if not all(provenance.get(key) is True for key in ['zero_wx_source_fix','ios_filetype_source_fix','ios_utf8_encoding_fix']):
        raise ValueError('Runtime lacks required source fixes')
    if rebuild:
        resolved, built = build.build()
        subprocess.run(['python3', str(ROOT/'scripts/build-zstd-native.py'), '--target', 'ios'], cwd=ROOT, check=True)
    else:
        resolved = build.dependencies(); built = json.loads((ROOT/'validation/runtime-host-build.json').read_text())
    host = verify_host(built)
    codec_report_path = codec_report_path or ROOT/'validation/zstd-native-ios.json'
    codec_report = json.loads(codec_report_path.read_text())
    if not codec_report.get('passed') or not codec_report.get('test_hooks_absent'): raise ValueError('Verified production iOS codec required')
    for name, digest in codec_report['sources'].items():
        if sha(ROOT/name) != digest: raise ValueError('Codec input changed: '+name)
    codec_archive = codec/'libmslzstd.a'
    recorded = next(item for item in codec_report['artifacts'] if item['path'].endswith('/libmslzstd.a'))
    if sha(codec_archive) != recorded['sha256']: raise ValueError('Codec archive changed')

    bundle = output/'bundle'; native = output/'native'; bundle.mkdir(); native.mkdir()
    records = []; native_records = []
    def copy(source, relative):
        destination = bundle/relative
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(source, destination)
        records.append({'path': str(relative), 'bytes': destination.stat().st_size, 'sha256': sha(destination)})
    # Exactly the VM/native libraries already exercised by the source-built iPhone
    # fixture, plus the production codec. No launcher, debugger or specimen code.
    archives = [runtime/f'static-libs/lib/lib{name}.a' for name in ['java','net','nio','zip','jimage','verify']]
    archives += [runtime/'static-libs/lib/zero/libjvm.a', runtime/'ffi/lib/libffi.a', codec_archive]
    for archive in archives:
        check = platform_check.verify(archive.read_bytes())
        target = native/archive.name; shutil.copyfile(archive, target)
        native_records.append({'path': str(target.relative_to(output)), 'bytes': target.stat().st_size, 'sha256': sha(target), 'platform_check': check})

    image = (runtime/'jre').resolve()
    native_magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf', b'\x7fELF'}
    omitted = []
    for name in ['lib','conf','legal','release']:
        source = image/name
        if not source.exists(): raise ValueError('Java image missing '+name)
        for file in ([source] if source.is_file() else sorted(source.rglob('*'))):
            if not file.resolve(strict=True).is_relative_to(image): raise ValueError('Java image link escapes root')
            if file.is_dir(): continue
            if not file.is_file(): raise ValueError('Special file in Java image')
            with file.open('rb') as stream: magic = stream.read(8)
            relative = file.relative_to(image)
            if magic[:4] in native_magic or magic == b'!<arch>\n' or file.suffix in {'.a','.dylib','.so'}:
                omitted.append(str(relative)); continue
            copy(file, Path('lib')/relative)
    for required in ['lib/lib/modules','lib/lib/tzdb.dat','lib/conf/security/java.security']:
        if not (bundle/required).is_file(): raise ValueError('Incomplete Java image: '+required)
    for name in ['LICENSE','ADDITIONAL_LICENSE_INFO','ASSEMBLY_EXCEPTION']:
        copy(runtime/name, Path('engine-legal/openjdk')/name)
    copy(runtime/'ffi/LICENSE', Path('engine-legal/libffi-LICENSE'))
    for file in sorted((codec/'notices').glob('*')):
        if file.is_file(): copy(file, Path('engine-legal/codec')/file.name)
    copy(host, Path('engine/runtime-host.jar')); classpath = ['engine/runtime-host.jar']
    runtime_items = [(item,path) for item,path in resolved if 'runtime' in item['roles']]
    for item, path in runtime_items:
        relative = 'engine/jars/'+item['filename']; copy(path,Path(relative)); classpath.append(relative)
    legal = json.loads((ROOT/'runtime-host/notices.lock.json').read_text())
    notice = ROOT/legal['notices']['path']
    if sha(notice) != legal['notices']['sha256']: raise ValueError('Notices changed')
    if {a['runtime_filename'] for a in legal['artifacts']} != {item['filename'] for item,_ in runtime_items}: raise ValueError('Legal/runtime dependency sets differ')
    copy(notice, Path('engine-legal/Runtime-ThirdPartyNotices.txt'))
    cache = ROOT/'build/runtime-notices-review'; cache.mkdir(parents=True,exist_ok=True)
    inputs = [a[key] for a in legal['artifacts'] for key in ['source','pom']]
    with ThreadPoolExecutor(max_workers=4) as workers:
        files = list(workers.map(lambda value: checked_legal(value,cache), inputs))
    for file in files: copy(file,Path('engine-legal/dependency-sources')/file.name)
    app_manifest = {'format':1,'backend_class':'mangashelf/host/SourceRuntime','backend_method':'dispatch','java_home':'lib',
                    'classpath':classpath,'runtime':selection,'host_jar_sha256':sha(host),'files':records,
                    'source_repository':'https://github.com/badrcoderman/MangaShelf','source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                    'scope':'Source-built embedded runtime and app-owned host. No bundled extension or specimen executable.'}
    manifest_file = output/'app-manifest.json'; manifest_file.write_text(json.dumps(app_manifest,indent=2)+'\n')
    copy(manifest_file,Path('engine/manifest.json'))
    # Device-only flags keep simulator builds independent of arm64 iOS archives.
    for path in [output.resolve(), ROOT.resolve()]:
        if any(char in str(path) for char in ['\n','\r','$','"','\\']): raise ValueError('Unsupported build path characters')
    flags = ['$(inherited)']
    for item in native_records: flags += ['-Xlinker','-force_load','-Xlinker',json.dumps(str((output/item['path']).resolve()))]
    flags += ['-lz','-liconv','-lobjc','-lc++','-framework','UniformTypeIdentifiers','-framework','Foundation','-framework','Security','-framework','SystemConfiguration','-framework','CoreFoundation','-Wl,-export_dynamic']
    (output/'Engine.xcconfig').write_text('GCC_PREPROCESSOR_DEFINITIONS[sdk=iphoneos*] = $(inherited) MSL_APP_ENGINE_ENABLED=1\nOTHER_LDFLAGS[sdk=iphoneos*] = '+' '.join(flags)+'\nDEAD_CODE_STRIPPING[sdk=iphoneos*] = NO\n')
    result = {'format':1,'passed':True,'runtime':selection,'host_build':built['jar'],'codec_source_sha256':codec_report['sources'],
              'native_libraries':native_records,'bundle_files':records,'omitted_java_native_files':omitted,'classpath':classpath,
              'xcconfig_sha256':sha(output/'Engine.xcconfig'),
              'scope':'Prepared inputs only; no app compilation or iPhone execution.'}
    (output/'EngineInputs.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-evidence', type=Path, required=True)
    parser.add_argument('--runtime-selection', type=Path, required=True)
    parser.add_argument('--codec-directory', type=Path, default=ROOT/'build/zstd-native/ios')
    parser.add_argument('--codec-report', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'build/ios-app-engine')
    parser.add_argument('--build', action='store_true')
    args=parser.parse_args()
    result=prepare(args.runtime_evidence.resolve(),args.runtime_selection.resolve(),args.codec_directory.resolve(),args.output.resolve(),args.build,args.codec_report)
    print(json.dumps({'passed':True,'native_libraries':len(result['native_libraries']),'bundle_files':len(result['bundle_files']),'classpath_jars':len(result['classpath'])},indent=2))
