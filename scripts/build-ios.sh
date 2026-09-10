#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode on macOS is required. No IPA has been generated." >&2
  exit 2
fi
cd "$project_root"
mode="${1:-simulator}"
case "$mode" in
  simulator)
    swift test
    xcodebuild -project iOS/MangaShelf.xcodeproj -scheme MangaShelf \
      -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  unsigned)
    # A fresh, task-owned build directory prevents stale signing files from
    # entering an archive intended for later sideload signing.
    swift test
    mkdir -p build/Export
    unsigned_build="$(mktemp -d "$project_root/build/Unsigned-XXXXXX")"
    trap 'rm -rf -- "$unsigned_build"' EXIT
    xcodebuild -project iOS/MangaShelf.xcodeproj -scheme MangaShelf \
      -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
      -derivedDataPath "$unsigned_build" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
    python3 scripts/package_unsigned_ipa.py \
      "$unsigned_build/Build/Products/Release-iphoneos/MangaShelf.app" \
      build/Export/MangaShelf-unsigned.ipa
    ;;
  archive)
    : "${MANGASHELF_TEAM_ID:?Set MANGASHELF_TEAM_ID to your Apple development team.}"
    : "${MANGASHELF_BUNDLE_ID:?Set MANGASHELF_BUNDLE_ID to a bundle ID you control.}"
    swift test
    xcodebuild -project iOS/MangaShelf.xcodeproj -scheme MangaShelf -configuration Release \
      -destination 'generic/platform=iOS' -archivePath build/MangaShelf.xcarchive \
      DEVELOPMENT_TEAM="$MANGASHELF_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$MANGASHELF_BUNDLE_ID" archive
    ;;
  export)
    : "${MANGASHELF_EXPORT_OPTIONS:?Set MANGASHELF_EXPORT_OPTIONS to your reviewed ExportOptions.plist.}"
    test -f "$MANGASHELF_EXPORT_OPTIONS"
    xcodebuild -exportArchive -archivePath build/MangaShelf.xcarchive \
      -exportPath build/Export -exportOptionsPlist "$MANGASHELF_EXPORT_OPTIONS"
    ;;
  *) echo "Usage: bash scripts/build-ios.sh [simulator|unsigned|archive|export]" >&2; exit 2 ;;
esac
