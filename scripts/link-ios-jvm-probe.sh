#!/bin/bash
# Link only: this executable is not an IPA and is never executed on the CI host.
set -euo pipefail
root="$(pwd)"
evidence="$root/build/ios-jvm-evidence/build/ios-jvm"
headers="$root/runtime-src/mobile/src/java.base"
out="$root/build/ios-jvm-link"
mkdir -p "$out"
[ "$(git -C "$root/runtime-src/mobile" rev-parse HEAD)" = c1ed06aaef34c8dccf71e236d1ffa20918a77cfb ]
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
common=(-target arm64-apple-ios26.0 -isysroot "$sdk")
for name in MSJavaRuntime host_probe; do
  xcrun --sdk iphoneos clang "${common[@]}" -Wall -Wextra -Werror \
    -I"$headers/share/native/include" -I"$headers/unix/native/include" \
    -c "runtime-native/$name.c" -o "$out/$name.o"
done
# New source builds define these in bsd_zero using the actual upstream headers.
# Old static-only evidence needs the standalone ABI shim. Never mix both.
xcrun --sdk iphoneos nm -gU "$evidence/static-libs/lib/zero/libjvm.a" > "$out/jvm-defined-symbols.txt"
compat_mode="$(python3 - "$out/jvm-defined-symbols.txt" <<'PY'
from pathlib import Path
import sys
symbols = {line.split()[-1] for line in Path(sys.argv[1]).read_text().splitlines() if line.split()}
needed = {'_DefaultWXWriteMode', '__ZN2os17_jit_exec_enabledE', '__ZN2os27thread_wx_enable_write_implEv'}
present = needed & symbols
if present and present != needed:
    raise SystemExit('Refusing a runtime with only some Zero W^X definitions')
print('source' if present else 'legacy-shim')
PY
)"
if [ "$compat_mode" = source ]; then
  xcrun --sdk iphoneos clang++ "${common[@]}" -x c++ -c /dev/null -o "$out/ios_jvm_compat.o"
else
  xcrun --sdk iphoneos clang++ "${common[@]}" -DMSL_OPENJDK_ZERO=1 -Wall -Wextra -Werror \
    -c "runtime-native/ios_jvm_compat.cpp" -o "$out/ios_jvm_compat.o"
fi
libraries=()
for name in java net nio zip jimage verify; do
  archive="$evidence/static-libs/lib/lib$name.a"
  test -s "$archive"
  python3 scripts/verify_ios_archive.py "$archive" > "$out/$name-platform.json"
  libraries+=(-Xlinker -force_load -Xlinker "$archive")
done
for archive in "$evidence/static-libs/lib/zero/libjvm.a" "$evidence/ffi/lib/libffi.a"; do
  test -s "$archive"
  python3 scripts/verify_ios_archive.py "$archive" > "$out/$(basename "$archive")-platform.json"
  libraries+=(-Xlinker -force_load -Xlinker "$archive")
done
python3 - "$out" "$evidence" "$sdk" "$compat_mode" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
out, evidence = map(Path, sys.argv[1:3])
archives = [evidence / f'static-libs/lib/lib{name}.a' for name in ['java', 'net', 'nio', 'zip', 'jimage', 'verify']]
archives += [evidence / 'static-libs/lib/zero/libjvm.a', evidence / 'ffi/lib/libffi.a']
data = {
    'target': 'arm64-apple-ios26.0', 'sdk_path': sys.argv[3], 'compat_mode': sys.argv[4],
    'vm_objects': [str(out / name) for name in ['MSJavaRuntime.o', 'ios_jvm_compat.o']],
    'library_paths': list(map(str, archives)),
    'system_link_flags': ['-lz', '-liconv', '-framework', 'Foundation', '-framework', 'Security',
                          '-framework', 'SystemConfiguration', '-framework', 'CoreFoundation'],
    'archive_sha256': {str(p.relative_to(evidence)): hashlib.sha256(p.read_bytes()).hexdigest() for p in archives},
    'java_modules_present': (evidence / 'jre/lib/modules').is_file(), 'execution_proven': False,
}
(out / 'link-inputs.json').write_text(json.dumps(data, indent=2) + '\n')
PY
xcrun --sdk iphoneos clang++ "${common[@]}" "$out/MSJavaRuntime.o" "$out/host_probe.o" "$out/ios_jvm_compat.o" \
  "${libraries[@]}" -lz -liconv -framework Foundation -framework Security \
  -framework SystemConfiguration -framework CoreFoundation \
  -o "$out/MangaShelfRuntimeLinkProbe" 2>&1 | tee "$out/link.log"
xcrun --sdk iphoneos otool -l "$out/MangaShelfRuntimeLinkProbe" > "$out/load-commands.txt"
xcrun --sdk iphoneos nm -u "$out/MangaShelfRuntimeLinkProbe" > "$out/dynamic-imports.txt"
python3 - "$out/MangaShelfRuntimeLinkProbe" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = {'link_succeeded': True, 'target': 'arm64-apple-ios26.0',
        'executable_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'execution_proven': False}
(path.parent / 'link-result.json').write_text(json.dumps(data, indent=2) + '\n')
PY
echo 'Link succeeded. No iOS execution, Java modules, or extension compatibility is proven.'
