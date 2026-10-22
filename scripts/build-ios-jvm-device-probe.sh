#!/bin/bash
# Build a separate unsigned iPhone harness from source-built runtime inputs.
# This does not add a JVM or test fixtures to the MangaShelf production app.
set -euo pipefail
root="$(pwd)"
evidence="$root/build/ios-jvm-evidence/build/ios-jvm"
out="$root/build/ios-jvm-device"
app="$out/MangaShelfEngineCheck.app"
test -s "$evidence/jre/lib/modules"
test -d "$evidence/jre/conf"
python3 - <<'PY'
import json
from pathlib import Path
selection = json.loads(Path('build/ios-jvm-link/runtime-selection.json').read_text())
if not selection.get('build_manifest_verified'):
    raise SystemExit('A verified source build manifest is required for the device harness')
manifest = json.loads(Path('build/ios-jvm-evidence/build/ios-jvm/build-provenance.json').read_text())
if manifest.get('ios_filetype_source_fix') is not True:
    raise SystemExit('The current device fixture requires the source-built iOS file type implementation')
PY
test ! -e "$app"
mkdir -p "$app/probe" "$out/java/main" "$out/java/plugin"
bash scripts/link-ios-jvm-probe.sh

# Both JARs contain only code authored in this repository. No specimen is used.
javac --release 17 -encoding UTF-8 -d "$out/java/main" runtime-probe/src/mangashelf/probe/RuntimeProbe.java
javac --release 17 -encoding UTF-8 -d "$out/java/plugin" runtime-probe/plugin/probe/SourceProbe.java
jar --create --file "$app/probe/main.jar" -C "$out/java/main" .
jar --create --file "$app/probe/plugin.jar" -C "$out/java/plugin" .

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
headers="$root/runtime-src/mobile/src/java.base"
xcrun --sdk iphoneos clang -target arm64-apple-ios26.0 -isysroot "$sdk" \
  -fobjc-arc -fmodules -Wall -Wextra -Werror \
  -I"$root/runtime-native" -I"$headers/share/native/include" -I"$headers/unix/native/include" \
  -c runtime-native/ios-probe/main.m -o "$out/main.o"

python3 - "$root" "$evidence" "$out" "$app" <<'PY'
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys

root, evidence, out, app = map(Path, sys.argv[1:])
inputs = json.loads((root / 'build/ios-jvm-link/link-inputs.json').read_text())
command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-target', inputs['target'], '-isysroot', inputs['sdk_path'],
           str(out / 'main.o'), *inputs['vm_objects']]
for archive in inputs['library_paths']:
    command += ['-Xlinker', '-force_load', '-Xlinker', archive]
command += [*inputs['system_link_flags'], '-framework', 'UIKit', '-Wl,-export_dynamic',
            '-o', str(app / 'MangaShelfEngineCheck')]
with (out / 'device-link.log').open('w') as log:
    subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)

# Include source-built Java data and legal notices, not native shared libraries.
# This statically linked probe covers java/net/nio/zip/jimage/verify only.
jre = (evidence / 'jre').resolve()
omitted, included = [], []
native_magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
                b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf', b'\x7fELF'}
for name in ['lib', 'conf', 'legal', 'release']:
    source = jre / name
    if not source.exists():
        raise ValueError(f'Source-built Java image is missing {name}')
    files = [source] if source.is_file() else sorted(source.rglob('*'))
    for file in files:
        resolved = file.resolve(strict=True)
        if not resolved.is_relative_to(jre):
            raise ValueError(f'Java image link escapes its root: {file}')
        if file.is_dir():
            continue
        if not file.is_file():
            raise ValueError(f'Java image has a special file: {file}')
        relative = file.relative_to(jre)
        with file.open('rb') as handle:
            prefix = handle.read(8)
        if prefix[:4] in native_magic or prefix == b'!<arch>\n' or file.suffix in {'.dylib', '.so', '.a'}:
            omitted.append(str(relative))
            continue
        destination = app / 'jre' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, destination)
        included.append({'path': str(relative), 'bytes': file.stat().st_size,
                         'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
for required in ['lib/modules', 'lib/tzdb.dat']:
    if not (app / 'jre' / required).is_file():
        raise ValueError(f'Java image is missing required data: {required}')
for name in ['LICENSE', 'ADDITIONAL_LICENSE_INFO', 'ASSEMBLY_EXCEPTION']:
    shutil.copyfile(evidence / name, app / name)
shutil.copyfile(evidence / 'ffi/LICENSE', app / 'libffi-LICENSE')
for language in ['en', 'ar']:
    target = app / f'{language}.lproj'
    target.mkdir()
    shutil.copyfile(root / f'iOS/MangaShelf/Resources/{language}.lproj/Localizable.strings', target / 'Localizable.strings')

selection = json.loads((root / 'build/ios-jvm-link/runtime-selection.json').read_text())
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
info = {
    'CFBundleIdentifier': 'app.mangashelf.enginecheck', 'CFBundleDisplayName': 'MSL Engine Check',
    'CFBundleExecutable': 'MangaShelfEngineCheck', 'CFBundleName': 'MangaShelfEngineCheck',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
    'CFBundleSupportedPlatforms': ['iPhoneOS'], 'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en', 'ar'], 'MinimumOSVersion': '26.0', 'LSRequiresIPhoneOS': True,
    'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft',
                                       'UIInterfaceOrientationLandscapeRight'],
    'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
    'MSBuildCommit': commit, 'MSRuntimeRunID': str(selection['run_id']),
}
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
(app / 'runtime-provenance.json').write_text(json.dumps(selection, indent=2) + '\n')
(out / 'device-build.json').write_text(json.dumps({
    'commit': commit, 'runtime': selection, 'included_java_data': included, 'omitted_native_libraries': omitted,
    'scope': 'Separate unsigned iOS VM/JAR harness. No real extension is bundled or tested.',
    'device_execution': 'pending',
}, indent=2) + '\n')
PY

python3 scripts/package_unsigned_ipa.py "$app" "$out/MangaShelfEngineCheck-unsigned.ipa"
xcrun --sdk iphoneos otool -l "$app/MangaShelfEngineCheck" > "$out/device-load-commands.txt"
xcrun --sdk iphoneos nm -u "$app/MangaShelfEngineCheck" > "$out/device-dynamic-imports.txt"
python3 - "$out/MangaShelfEngineCheck-unsigned.ipa" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
result = {'file': path.name, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
          'unsigned': True, 'minimum_ios': '26.0', 'device_execution': 'pending'}
(path.parent / 'ipa-result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
PY
