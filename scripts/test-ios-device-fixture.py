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
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
public final class DeviceFixtureCheck {
    private static void checkDiagnostics(String text) {
        if (!text.startsWith("JVM/file diagnostics\\n") || text.length() > 4096)
            throw new AssertionError("Diagnostics header or bound differs");
        for (String key : new String[]{"sun.jnu.encoding", "native.encoding", "file.encoding",
                "stdout.encoding", "stderr.encoding", "Charset.defaultCharset", "java.version",
                "java.runtime.version", "java.vm.name", "java.vm.version", "os.name", "os.arch", "os.version"}) {
            if (!text.contains("\\n" + key + "=")) throw new AssertionError("Missing diagnostic " + key);
        }
        for (int index = 0; index < text.length(); index++) {
            char value = text.charAt(index);
            if ((value < 32 && value != '\\n') || value > 126)
                throw new AssertionError("Diagnostics must be ASCII with escaped controls");
        }
    }
    private static List<String> entries(Path root) throws Exception {
        try (var paths = Files.list(root)) {
            return paths.map(path -> path.getFileName().toString()).sorted().toList();
        }
    }
    public static void main(String[] args) throws Exception {
        checkDiagnostics(RuntimeProbe.diagnostics("ignored", "ignored"));
        String original = System.getProperty("java.vm.name");
        try {
            System.setProperty("java.vm.name", "Synthetic\\n📚" + "x".repeat(1000));
            String bounded = RuntimeProbe.diagnostics(null, null);
            checkDiagnostics(bounded);
            if (!bounded.contains("<truncated>") || !bounded.contains("\\\\u000A\\\\uD83D\\\\uDCDA"))
                throw new AssertionError("Diagnostic escaping or truncation failed");
        } finally {
            if (original == null) System.clearProperty("java.vm.name");
            else System.setProperty("java.vm.name", original);
        }
        List<String> before = entries(Path.of(args[1]));
        String result = RuntimeProbe.runWithDiagnostics(args[0], args[1]);
        if (!result.startsWith("PASS:") || !result.contains("Unicode filesystem")) throw new AssertionError(result);
        if (!"مانغا 📚".equals(RuntimeProbe.echo("مانغا ", "📚")))
            throw new AssertionError("Unicode echo differs");
        boolean failed = false;
        System.err.println("EXPECTED_FAILURE_BEGIN");
        try { RuntimeProbe.runWithDiagnostics(args[0] + ".missing", args[1]); }
        catch (IllegalStateException expected) { failed = true; }
        System.err.println("EXPECTED_FAILURE_END");
        if (!failed) throw new AssertionError("Missing JAR must fail");
        if (!before.equals(entries(Path.of(args[1])))) throw new AssertionError("Fixture files were not cleaned up");
        System.out.println(result);
        System.out.println("PASS: Unicode echo and expected failure propagation");
        System.out.println("PASS: bounded ASCII diagnostics and Unicode filesystem cleanup");
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
    mime_checked = 'file MIME types' in run.stdout
    unicode_paths_checked = 'Unicode filesystem' in run.stdout
    diagnostics_checked = 'bounded ASCII diagnostics' in run.stdout
    cleanup_checked = 'Unicode filesystem cleanup' in run.stdout
    failure_output = run.stderr.partition('EXPECTED_FAILURE_BEGIN\n')[2].partition('EXPECTED_FAILURE_END')[0]
    diagnostics_before_failure = (failure_output.startswith('JVM/file diagnostics\n')
                                  and 'sun.jnu.encoding=' in failure_output
                                  and 'Charset.defaultCharset=' in failure_output
                                  and failure_output.find('Charset.defaultCharset=') < failure_output.find('Probe JAR missing'))
    result = {'exit_code': run.returncode,
              'host_fixture_passed': run.returncode == 0 and logged and mime_checked and unicode_paths_checked
                                     and diagnostics_checked and cleanup_checked and diagnostics_before_failure,
              'host_file_mime_probes_passed': mime_checked,
              'host_unicode_path_roundtrip_passed': unicode_paths_checked,
              'host_encoding_diagnostics_passed': diagnostics_checked,
              'host_fixture_cleanup_passed': cleanup_checked,
              'diagnostics_before_expected_java_failure': diagnostics_before_failure,
              'expected_java_failure_logged': logged, 'stdout': run.stdout, 'stderr': run.stderr,
              'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              'java_version': subprocess.run(['java', '-version'], capture_output=True, text=True, check=True).stderr.strip(),
              'scope': 'Host Java fixture only; no native JNI or iOS execution, and no real extension.',
              'ios_execution': False}
    (root / 'validation/ios-device-fixture-host.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['host_fixture_passed']:
        raise SystemExit('Device Java fixture methods failed on host')
