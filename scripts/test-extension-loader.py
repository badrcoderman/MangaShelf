#!/usr/bin/env python3
"""Load only authored signed SourceFactory fixtures through the verified archive host."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_build', ROOT/'scripts/build-runtime-host.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
REPORT = ROOT/'validation/extension-loader-host.json'
PASSWORD = 'mangashelf-authored-loader-test-key'


def main():
    sources = [ROOT/'scripts/build-runtime-host.py', Path(__file__),
               ROOT/'runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java']
    sources += sorted((ROOT/'runtime-host/src').rglob('*.kt'))
    sources += sorted((ROOT/'runtime-host/src').rglob('*.java'))
    report = {'recorded_at': datetime.now(timezone.utc).isoformat(),
              'scope': 'Host JVM, project-authored signed executable fixtures only. No published extension, production activation, networking, publisher trust bootstrap or iOS execution.',
              'published_extension_executed': False, 'ios_execution': False, 'passed': False,
              'inputs_sha256': {str(p.relative_to(ROOT)): build.digest(p) for p in sources},
              'documentation': [
                  'https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/util/jar/JarFile.html',
                  'https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/security/SecureClassLoader.html',
                  'https://docs.oracle.com/en/java/javase/25/docs/api/java.xml/javax/xml/parsers/SAXParserFactory.html'],
              'commands': []}

    def run(command, timeout=120):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                                text=True, timeout=timeout)
        report['commands'].append({'command': list(map(str, command)), 'exit_code': result.returncode,
                                    'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode:
            raise RuntimeError(f'Command failed: {command[0]}: {result.stderr[-4000:]}')
        return result

    try:
        if not all(shutil.which(name) for name in ['java', 'javac', 'keytool', 'jarsigner']):
            raise RuntimeError('JDK tools including keytool and jarsigner are required')
        resolved, built = build.build()
        report['build_jar'] = built['jar']
        host = ROOT/built['jar']['path']
        with tempfile.TemporaryDirectory(prefix='loader-check-', dir=build.OUT) as directory:
            temporary = Path(directory)
            fixture_classes = temporary/'fixture-classes'
            fixture_classes.mkdir()
            fixtures_root = ROOT/'runtime-host/src/test/fixtures'
            run(['javac', '--release', '17', '-Xlint:all', '-Werror', '-d', fixture_classes,
                 fixtures_root/'java/fixture/extension/Versioned.java'])
            run(build.compiler_command(resolved, sorted((fixtures_root/'kotlin').rglob('*.kt')), fixture_classes,
                                       os.pathsep.join([str(host), str(fixture_classes)])))
            versioned, shadow = temporary/'versioned-classes', temporary/'shadow-classes'
            for path in [versioned, shadow]: path.mkdir()
            run(['javac', '--release', '21', '-Xlint:all', '-Werror', '-d', versioned,
                 fixtures_root/'versioned/fixture/extension/Versioned.java'])
            run(['javac', '--release', '17', '-Xlint:all', '-Werror', '-d', shadow,
                 fixtures_root/'shadow/kotlin/Shadow.java'])
            keystore = temporary/'authored-test-key.p12'
            run(['keytool', '-genkeypair', '-alias', 'authored', '-keystore', keystore, '-storetype', 'PKCS12',
                 '-storepass', PASSWORD, '-keypass', PASSWORD, '-keyalg', 'RSA', '-keysize', '2048',
                 '-sigalg', 'SHA256withRSA', '-validity', '365',
                 '-dname', 'CN=MangaShelf Authored Loader Fixture,O=MangaShelf Tests,C=ZZ', '-noprompt'])
            certificate = temporary/'fixture.der'
            run(['keytool', '-exportcert', '-alias', 'authored', '-keystore', keystore,
                 '-storepass', PASSWORD, '-file', certificate])
            pin = build.digest(certificate)
            report['generated_fixture_certificate_sha256'] = pin
            manifest = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
 package="fixture.extension" android:versionCode="106000" android:versionName="1.6.0">
 <uses-feature android:name="tachiyomi.extension"/>
 <application>
  <meta-data android:name="tachiyomi.extension.class" android:value="fixture.extension.Generated"/>
  <meta-data android:name="tachiyomix.extensionLib" android:value="1.6"/>
 </application>
</manifest>
'''
            (temporary/'manifest.xml').write_text(manifest)
            packaged = {p.relative_to(fixture_classes).as_posix(): p.read_bytes()
                        for p in sorted(fixture_classes.rglob('*')) if p.is_file()}
            packaged['assets/العربية 📚 #%.txt'] = 'verified resource العربية 📚\n'.encode()
            variants = {
                'valid': {}, 'single': {'main': 'Single', 'relative': True},
                'not_source': {'main': 'NotSource'}, 'private': {'main': 'PrivateEntry'},
                'abstract': {'main': 'AbstractEntry'}, 'throws': {'main': 'ThrowingEntry'},
                'blocking': {'main': 'BlockingEntry'}, 'parent': {'main': 'mangashelf.host.SourceRegistry'},
                'no_android': {}, 'entity': {}, 'old_api': {}, 'shadow': {},
                'versioned_shadow': {}, 'classpath': {}, 'multi': {},
            }
            records = {}
            for label, options in variants.items():
                main = options.get('main', 'Generated')
                if '.' not in main: main = 'fixture.extension.'+main
                android = manifest.replace('fixture.extension.Generated', '.'+main.rsplit('.', 1)[1]
                                           if options.get('relative') else main)
                if label == 'old_api': android = android.replace('android:value="1.6"', 'android:value="1.5"')
                if label == 'entity': android = android.replace('<manifest ', '<!DOCTYPE manifest [<!ENTITY x SYSTEM "file:///never/open/fixture">]><manifest ', 1)
                entries = dict(packaged)
                entries['AndroidManifest.xml'] = android.encode()
                if label == 'no_android': entries.pop('AndroidManifest.xml')
                if label in ['shadow', 'versioned_shadow']:
                    target = 'kotlin/Shadow.class'
                    if label == 'versioned_shadow': target = 'META-INF/versions/21/'+target
                    entries[target] = (shadow/'kotlin/Shadow.class').read_bytes()
                header = 'Manifest-Version: 1.0\r\n'
                if label == 'classpath': header += 'Class-Path: https://example.invalid/untrusted.jar\r\n'
                if label == 'multi':
                    header += 'Multi-Release: true\r\nSealed: true\r\nImplementation-Version: authored-v1\r\n'
                    entries['META-INF/versions/21/fixture/extension/Versioned.class'] = (versioned/'fixture/extension/Versioned.class').read_bytes()
                archive = temporary/(label+'.jar')
                with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as jar:
                    jar.writestr('META-INF/MANIFEST.MF', (header+'\r\n').encode())
                    for name, data in entries.items(): jar.writestr(name, data)
                run(['jarsigner', '-keystore', keystore, '-storetype', 'PKCS12', '-storepass', PASSWORD,
                     '-keypass', PASSWORD, '-sigalg', 'SHA256withRSA', '-digestalg', 'SHA-256', archive, 'authored'])
                records[label] = {'file': archive.name, 'sha256': build.digest(archive), 'pin': pin,
                                  'mainClass': main, 'bytes': archive.stat().st_size}
            (temporary/'fixtures.json').write_text(json.dumps(records, indent=2)+'\n')
            report['authored_fixtures'] = records
            test_classes = temporary/'test-classes'
            tests = sorted((ROOT/'runtime-host/src/test/loader').rglob('*.kt'))
            run(build.compiler_command(resolved, tests, test_classes, str(host)))
            # Executable extension fixture JARs/classes are deliberately absent from parent CP.
            cp = os.pathsep.join([str(test_classes), str(host), build.classpath(resolved, 'runtime')])
            report['parent_classpath_excludes_fixtures'] = all(str(path) not in cp for path in
                                                              [fixture_classes, *[temporary/v['file'] for v in records.values()]])
            result = run(['java', '-Xint', '-cp', cp, 'mangashelf.host.LoaderCheck', temporary], timeout=90)
            report['test_result'] = json.loads(result.stdout)
            if report['test_result'].get('passed') is not True or not report['parent_classpath_excludes_fixtures']:
                raise RuntimeError('Authored loader checks did not report a pass')
        for name, expected in report['inputs_sha256'].items():
            if build.digest(ROOT/name) != expected: raise RuntimeError('Test/build source changed during execution')
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
    REPORT.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': report['passed'], 'checks': len(report.get('test_result', {}).get('checks', {})),
                      'failure': report.get('failure'), 'report': str(REPORT.relative_to(ROOT))}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
