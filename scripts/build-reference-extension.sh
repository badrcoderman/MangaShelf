#!/bin/bash
# Build the public source candidate; never invoke an extension entry point.
set -euo pipefail
root="$(pwd)"
source_root="$root/extension-src/keiyoushi"
out="$root/build/reference-extension"
mkdir -p "$out"
test "$(git -C "$source_root" rev-parse HEAD)" = 1d3d7c4b3e876fb0c26ae3ade8113fb329af15fa
git -C "$source_root" diff --exit-code
python3 - "$source_root" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
pins = {
    'settings.gradle.kts': 'af858989bd885332e6b12f0efbc8d182c36b3d3f0dba7ec566c3050aa409e211',
    'gradle/wrapper/gradle-wrapper.properties': '3cbe35d0020d8393c73f4cc2572838d1db338dd27885dd4d88c46b4d28f762e0',
}
inputs = {name: (root / name).read_bytes() for name in pins}
if any(hashlib.sha256(inputs[name]).hexdigest() != digest for name, digest in pins.items()):
    raise ValueError('Changed upstream build configuration')
settings = inputs['settings.gradle.kts']
before = b'\nloadAllIndividualExtensions()\n'
if settings.count(before) != 1:
    raise ValueError('Expected one source selection statement')
(root / 'settings.gradle.kts').write_bytes(settings.replace(before, b'\nloadIndividualExtension("all", "mangadex")\n'))
# Published at services.gradle.org/distributions/gradle-9.8.1-bin.zip.sha256.
wrapper = root / 'gradle/wrapper/gradle-wrapper.properties'
wrapper.write_bytes(inputs['gradle/wrapper/gradle-wrapper.properties'] +
    b'\ndistributionSha256Sum=dce76f55f8e251a3a1f130eb120f30b3d271de2b76c9b0729d316b5a1b6dc01f\n')
PY
git -C "$source_root" diff -- settings.gradle.kts gradle/wrapper/gradle-wrapper.properties > "$out/build-selection.diff"
java -version 2> "$out/java-version.txt"
(
  cd "$source_root"
  ./gradlew :src:all:mangadex:assembleRelease --no-daemon --console=plain --stacktrace \
    --max-workers=2 -Dorg.gradle.jvmargs=-Xmx4g -Pkotlin.compiler.execution.strategy=in-process
) 2>&1 | tee "$out/compile.log"
python3 scripts/inspect-reference-extension.py "$source_root" "$out"
