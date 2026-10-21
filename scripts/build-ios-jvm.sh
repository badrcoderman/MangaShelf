#!/bin/bash
# Build an experimental iOS Zero runtime from reviewed source checkouts.
set -euo pipefail
: "${JAVA_HOME:?A supported macOS boot JDK is required}"
root="$(pwd)"
mobile="$root/runtime-src/mobile"
ffi="$root/runtime-src/libffi"
cups="$root/runtime-src/cups"
out="$root/build/ios-jvm"
mkdir -p "$out/logs" "$out/ffi"
[ "$(git -C "$mobile" rev-parse HEAD)" = c1ed06aaef34c8dccf71e236d1ffa20918a77cfb ]
[ "$(git -C "$ffi" rev-parse HEAD)" = 12ffd1f9dc56fcea79d2f742f424301ae668d663 ]
# The pinned CUPS object is an annotated v2.4.11 tag; HEAD is its commit.
[ "$(git -C "$cups" rev-parse HEAD)" = 7d535f73e407a72dfb5c5e83549a5ba27219dfcd ]
python3 scripts/prepare-ios-jvm-source.py "$mobile"
python3 scripts/verify-ios-jvm-source.py "$mobile" > "$out/logs/source-link-flags.json"
git -C "$mobile" diff -- src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp \
  make/autoconf/toolchain.m4 make/autoconf/flags-cflags.m4 make/common/native/Link.gmk \
  make/common/JdkNativeCompilation.gmk make/autoconf/flags-ldflags.m4 \
  make/modules/java.base/lib/CoreLibraries.gmk \
  > "$out/logs/source-patch.diff"
cp runtime-native/ios_jvm_compat.cpp "$out/logs/ios_jvm_compat.cpp"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
clang="$(xcrun --sdk iphoneos --find clang)"
(
  cd "$ffi"
  ./autogen.sh
  CC="$clang" CFLAGS="-target arm64-apple-ios26.0 -isysroot $sdk -O2" \
    LDFLAGS="-target arm64-apple-ios26.0 -isysroot $sdk" \
    ./configure --host=aarch64-apple-darwin --disable-shared --enable-static --prefix="$out/ffi"
  make -j3
  make install
) 2>&1 | tee "$out/logs/libffi.log"
python3 scripts/verify_ios_archive.py "$out/ffi/lib/libffi.a" > "$out/logs/libffi-platform.json"
# The pinned cross-build spec inherits iOS platform variables in the build JDK.
# Build the host tools natively from the same revision, using the macOS SDK.
# They are build tools only and are never copied into the device image.
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
(
  cd "$mobile"
  bash configure --with-conf-name=mangashelf-host-tools \
    --disable-warnings-as-errors --with-jvm-variants=server \
    --with-debug-level=release --with-native-debug-symbols=none \
    --with-boot-jdk="$JAVA_HOME" \
    --with-sysroot="$host_sdk" --with-cups-include="$cups" --with-jobs=3
  make CONF=mangashelf-host-tools jdk-image
) 2>&1 | tee "$out/logs/host-tools.log"
build_jdk="$mobile/build/mangashelf-host-tools/images/jdk"
test -x "$build_jdk/bin/jlink"
"$build_jdk/bin/java" -version 2>&1 | tee "$out/logs/host-java-version.txt"
(
  cd "$mobile"
  bash configure --with-conf-name=mangashelf-ios-zero \
    --disable-warnings-as-errors --openjdk-target=aarch64-macos-ios \
    --with-jvm-variants=zero --with-debug-level=release \
    --with-boot-jdk="$JAVA_HOME" --with-build-jdk="$build_jdk" --with-sysroot="$sdk" \
    --with-libffi-include="$out/ffi/include" --with-libffi-lib="$out/ffi/lib" \
    --with-cups-include="$cups" --with-jobs=3
  make CONF=mangashelf-ios-zero static-libs-image
) 2>&1 | tee "$out/logs/openjdk.log"
archive="$mobile/build/mangashelf-ios-zero/images/static-libs/lib/zero/libjvm.a"
test -s "$archive"
python3 scripts/verify_ios_archive.py "$archive" > "$out/logs/jvm-platform.json"
xcrun lipo -info "$archive" | tee "$out/logs/architecture.txt"
xcrun nm -g "$archive" > "$out/logs/symbols.txt"
# Keep source-built outputs separate from the application until execution is verified.
cp -R "$mobile/build/mangashelf-ios-zero/images/static-libs" "$out/"
cp "$mobile/LICENSE" "$mobile/ADDITIONAL_LICENSE_INFO" "$mobile/ASSEMBLY_EXCEPTION" "$out/"
cp "$ffi/LICENSE" "$out/ffi/LICENSE"
# Static libraries contain no Java classes or runtime configuration. Build the
# matching source-derived image separately; never borrow modules from an IPA.
(
  cd "$mobile"
  make CONF=mangashelf-ios-zero legacy-jre-image
) 2>&1 | tee "$out/logs/java-image.log"
image="$mobile/build/mangashelf-ios-zero/images/jre"
for required in lib/modules lib/tzdb.dat conf/security/java.security release; do
  test -s "$image/$required"
done
cp -R "$image" "$out/jre"
python3 - "$out" "$sdk" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
files = sorted(p for p in root.rglob('*') if p.is_file() and p.suffix == '.a')
files += [root / 'jre/lib/modules', root / 'jre/release', root / 'logs/ios_jvm_compat.cpp']
files += [root / 'logs/source-patch.diff', root / 'logs/source-link-flags.json', root / 'logs/host-java-version.txt']
manifest = {
    'format': 1, 'target': 'arm64-apple-ios26.0', 'vm_variant': 'zero',
    'openjdk_commit': 'c1ed06aaef34c8dccf71e236d1ffa20918a77cfb',
    'libffi_commit': '12ffd1f9dc56fcea79d2f742f424301ae668d663',
    'cups_ref': '2e5573560cfa2da65002f86b41bd1770c9853c4d',
    'cups_commit': '7d535f73e407a72dfb5c5e83549a5ba27219dfcd',
    'repository': os.environ.get('GITHUB_REPOSITORY'),
    'head_sha': os.environ.get('GITHUB_SHA'), 'run_id': os.environ.get('GITHUB_RUN_ID'),
    'sdk_path': sys.argv[2],
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'compiler': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'clang', '--version'], text=True).strip(),
    'zero_wx_source_fix': True, 'java_modules_present': True, 'execution_proven': False,
    'darwin_dynamic_library_fix': True, 'build_jdk': 'same-source native macOS host tools',
    'darwin_origin_fix': True,
    'ios_libjava_corefoundation_fix': True,
    'sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
}
(root / 'build-provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
