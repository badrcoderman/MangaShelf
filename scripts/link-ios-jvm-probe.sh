#!/bin/bash
# Link only: this executable is not an IPA and is never executed on the CI host.
set -euo pipefail
root="$(pwd)"
evidence="$root/build/ios-jvm-evidence/build/ios-jvm"
headers="$root/runtime-src/mobile/src/java.base"
out="$root/build/ios-jvm-link"
mkdir -p "$out"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
common=(-target arm64-apple-ios26.0 -isysroot "$sdk")
for name in MSJavaRuntime host_probe; do
  xcrun --sdk iphoneos clang "${common[@]}" -Wall -Wextra -Werror \
    -I"$headers/share/native/include" -I"$headers/unix/native/include" \
    -c "runtime-native/$name.c" -o "$out/$name.o"
done
xcrun --sdk iphoneos clang++ "${common[@]}" -Wall -Wextra -Werror \
  -c "runtime-native/ios_jvm_compat.cpp" -o "$out/ios_jvm_compat.o"
libraries=()
for name in java net nio zip jimage verify; do
  archive="$evidence/static-libs/lib/lib$name.a"
  test -s "$archive"
  python3 scripts/verify_ios_archive.py "$archive" > "$out/$name-platform.json"
  libraries+=(-Xlinker -force_load -Xlinker "$archive")
done
for archive in "$evidence/static-libs/lib/zero/libjvm.a" "$evidence/ffi/lib/libffi.a"; do
  test -s "$archive"
  libraries+=(-Xlinker -force_load -Xlinker "$archive")
done
xcrun --sdk iphoneos clang++ "${common[@]}" "$out/MSJavaRuntime.o" "$out/host_probe.o" "$out/ios_jvm_compat.o" \
  "${libraries[@]}" -lz -liconv -framework Foundation -framework Security \
  -framework SystemConfiguration -framework CoreFoundation \
  -o "$out/MangaShelfRuntimeLinkProbe" 2>&1 | tee "$out/link.log"
xcrun --sdk iphoneos otool -l "$out/MangaShelfRuntimeLinkProbe" > "$out/load-commands.txt"
xcrun --sdk iphoneos nm -u "$out/MangaShelfRuntimeLinkProbe" > "$out/dynamic-imports.txt"
echo 'Link succeeded. No iOS execution, Java modules, or extension compatibility is proven.'
