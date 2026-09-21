#!/usr/bin/env python3
"""Compile our JNI bridge against provided JDK headers and a linked host VM. No specimen code."""
import argparse,json,os,platform,subprocess
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--jni-headers', type=Path, default=None)
p.add_argument('--jni-platform-headers', type=Path, default=None)
p.add_argument('--java-home', type=Path, default=None)
p.add_argument('--cc', default='cc')
args = p.parse_args()

root = Path(__file__).resolve().parents[1]
out = root / 'build/runtime-probe'
out.mkdir(parents=True, exist_ok=True)

java_home = args.java_home
if not java_home:
    candidates = []
    if os.environ.get('JAVA_HOME'):
        candidates.append(Path(os.environ['JAVA_HOME']))
    candidates.extend([
        Path('/usr/lib/jvm/java-26-openjdk'),
        Path('/usr/lib/jvm/default'),
        Path('/usr/lib/jvm/default-runtime')
    ])
    for c in candidates:
        if c.is_dir() and (c / 'include/jni.h').is_file():
            java_home = c
            break

if not java_home or not java_home.is_dir():
    p.error("Missing or cannot auto-detect valid Java home directory. Pass --java-home.")

jni_headers = args.jni_headers or (java_home / 'include')
sys_name = 'darwin' if platform.system() == 'Darwin' else 'linux'
jni_platform_headers = args.jni_platform_headers or (java_home / 'include' / sys_name)

if not (out / 'main.jar').is_file() or not (out / 'plugin.jar').is_file():
    subprocess.run(['python3', str(root / 'scripts/run-runtime-probe.py')], check=True)

for path in [jni_headers / 'jni.h', jni_platform_headers / 'jni_md.h', out / 'main.jar', out / 'plugin.jar']:
    if not path.is_file():
        p.error('Missing required input: ' + str(path))

lib = java_home / 'lib/server'
exe = out / 'jni-host-probe'
cmd = [
    args.cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
    '-I' + str(jni_headers),
    '-I' + str(jni_platform_headers),
    str(root / 'runtime-native/MSJavaRuntime.c'),
    str(root / 'runtime-native/host_probe.c'),
    '-L' + str(lib),
    '-Wl,-rpath,' + str(lib),
    '-ljvm', '-lpthread',
    '-o', str(exe)
]
subprocess.run(cmd, check=True)

r = subprocess.run([str(exe), str(out / 'main.jar'), str(java_home), str(out / 'plugin.jar'), str(out)], capture_output=True, text=True, timeout=60)
result = {
    'platform': platform.system(),
    'exit_code': r.returncode,
    'stdout': r.stdout,
    'stderr': r.stderr,
    'checks': [
        'JNI VM creation',
        'native thread attach/detach',
        'separate JAR and reflection',
        'Java exception recovery',
        'Okio buffer extraction',
        'small buffer sizing probe',
        'NativeChannel topic and content validation',
        'missing method exception recovery',
        'concurrent multithreaded dispatch'
    ],
    'scope': 'Host JNI integration; no claim of iOS runtime or real extension support.'
}
(out / 'jni-result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
raise SystemExit(r.returncode)
