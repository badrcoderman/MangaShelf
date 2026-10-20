#!/usr/bin/env python3
"""Build/run only project-owned Java fixture methods on the host, never the IPA."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parent.parent
sources = [root / 'runtime-probe/src/mangashelf/probe/RuntimeProbe.java',
           root / 'runtime-probe/plugin/probe/SourceProbe.java']
driver = '''import mangashelf.probe.RuntimeProbe;
public final class DeviceFixtureCheck {
    public static void main(String[] args) throws Exception {
        String result = RuntimeProbe.runWithDiagnostics(args[0], args[1]);
        if (!result.startsWith("PASS:")) throw new AssertionError(result);
        if (!"مانغا 📚".equals(RuntimeProbe.echo("مانغا ", "📚")))
            throw new AssertionError("Unicode echo differs");
        boolean failed = false;
        try { RuntimeProbe.runWithDiagnostics(args[0] + ".missing", args[1]); }
        catch (IllegalStateException expected) { failed = true; }
        if (!failed) throw new AssertionError("Missing JAR must fail");
        System.out.println(result);
        System.out.println("PASS: Unicode echo and expected failure propagation");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='msl-device-fixture-') as temporary:
    work = Path(temporary)
    for name, source in zip(['main', 'plugin'], sources):
        classes = work / name
        classes.mkdir()
        subprocess.run(['javac', '--release', '17', '-encoding', 'UTF-8', '-d', str(classes), str(source)],
                       check=True, timeout=60)
    plugin = work / 'plugin.jar'
    with zipfile.ZipFile(plugin, 'w', zipfile.ZIP_DEFLATED) as archive:
        for p in (work / 'plugin').rglob('*.class'):
            archive.write(p, p.relative_to(work / 'plugin'))
    source = work / 'DeviceFixtureCheck.java'
    source.write_text(driver, encoding='utf-8')
    subprocess.run(['javac', '--release', '17', '-encoding', 'UTF-8', '-cp', str(work / 'main'),
                    '-d', str(work), str(source)], check=True, timeout=60)
    run = subprocess.run(['java', '-Xint', '-cp', str(work) + os.pathsep + str(work / 'main'),
                          'DeviceFixtureCheck', str(plugin), str(work)],
                         capture_output=True, text=True, encoding='utf-8', timeout=60)
    logged = 'Probe JAR missing' in run.stderr
    result = {'exit_code': run.returncode, 'host_fixture_passed': run.returncode == 0 and logged,
              'expected_java_failure_logged': logged, 'stdout': run.stdout,
              'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              'java_version': subprocess.run(['java', '-version'], capture_output=True, text=True, check=True).stderr.strip(),
              'scope': 'Host Java fixture only; no native JNI or iOS execution, and no real extension.',
              'ios_execution': False}
    (root / 'validation/ios-device-fixture-host.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['host_fixture_passed']:
        raise SystemExit('Device Java fixture methods failed on host')
