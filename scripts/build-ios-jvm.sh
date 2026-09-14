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
(
  cd "$mobile"
  bash configure --with-conf-name=mangashelf-ios-zero \
    --disable-warnings-as-errors --openjdk-target=aarch64-macos-ios \
    --with-jvm-variants=zero --with-debug-level=release \
    --with-boot-jdk="$JAVA_HOME" --with-sysroot="$sdk" \
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
