#!/bin/bash
# Capture the production app through native XCUITest on a fresh iOS 26 simulator.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode 26 on macOS is required; no simulator screenshots were captured." >&2
  exit 2
fi
artifact_dir="$project_root/build/ui-snapshots"
if [ -e "$artifact_dir" ]; then
  echo "Use a fresh build/ui-snapshots directory to avoid mixing capture evidence." >&2
  exit 2
fi
mkdir -p "$artifact_dir"
exec > >(tee "$artifact_dir/capture.log") 2>&1
simulator_udid=""
result_bundle="$artifact_dir/Tabs.xcresult"

finish() {
  command_status=$?
  trap - EXIT
  set +e
  capture_status=1
  for suite in Tabs Stage23-English Stage23-Arabic; do
    bundle="$artifact_dir/$suite.xcresult"
    if [ -d "$bundle" ]; then
      xcrun xcresulttool get test-results summary --path "$bundle" \
        > "$artifact_dir/$suite-summary.json" 2> "$artifact_dir/$suite-summary-errors.log"
      xcrun xcresulttool export attachments --path "$bundle" \
        --output-path "$artifact_dir/attachments-$suite" > "$artifact_dir/export-$suite.log" 2>&1
    fi
  done
  python3 - "$artifact_dir" <<'PY'
import json, shutil, sys
from pathlib import Path
root = Path(sys.argv[1]); output = root / 'attachments'; output.mkdir(exist_ok=True)
combined = []
for suite in ('Tabs', 'Stage23-English', 'Stage23-Arabic'):
    source = root / ('attachments-' + suite)
    if not (source / 'manifest.json').exists(): continue
    manifest = json.loads((source / 'manifest.json').read_text())
    if not isinstance(manifest, list): raise ValueError('Attachment manifest must be a list')
    combined.extend(manifest)
    for item in source.iterdir():
        if item.name == 'manifest.json': continue
        if not item.is_file() or item.is_symlink(): raise ValueError('Unexpected attachment path')
        target = output / item.name
        if target.exists() and target.read_bytes() != item.read_bytes(): raise ValueError('Attachment filename collision')
        shutil.copyfile(item, target)
(output / 'manifest.json').write_text(json.dumps(combined))
PY
  if [ "$?" -eq 0 ]; then
    python3 scripts/collect_ui_snapshots.py "$artifact_dir/attachments" \
      "$artifact_dir/screenshots" --provenance "$artifact_dir/provenance.json" --stage23
    capture_status=$?
  fi
  python3 - "$artifact_dir" "$command_status" "$capture_status" <<'PY'
import json
from pathlib import Path
import sys
output, command_status, capture_status = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
(output / "run-status.json").write_text(json.dumps({
    "command_exit_code": command_status, "capture_exit_code": capture_status,
    "capture_gate": "passed" if command_status == capture_status == 0 else "failed",
    "visual_parity": "NOT REVIEWED",
}, indent=2) + "\n")
PY
  if [ -n "$simulator_udid" ]; then
    xcrun simctl shutdown "$simulator_udid"
    xcrun simctl delete "$simulator_udid"
  fi
  if [ "$command_status" -ne 0 ]; then exit "$command_status"; fi
  exit "$capture_status"
}
trap finish EXIT

selected=$(python3 - <<'PY'
import os
from pathlib import Path
import subprocess
candidates = []
for app in Path("/Applications").glob("Xcode*.app"):
    developer = str(app / "Contents/Developer")
    result = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
                            env={**os.environ, "DEVELOPER_DIR": developer}, capture_output=True, text=True)
    if result.returncode != 0:
        continue
    version = tuple(int(part) for part in result.stdout.strip().split("."))
    if version[0] == 26:
        candidates.append((version, developer))
if not candidates:
    raise SystemExit("No installed Xcode has the iOS 26 simulator SDK.")
print(max(candidates)[1])
PY
)
export DEVELOPER_DIR="$selected"
xcodebuild -version
xcrun simctl list --json > "$artifact_dir/simulators-before.json"
python3 - "$artifact_dir" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys

output = Path(sys.argv[1])
available = json.loads((output / "simulators-before.json").read_text())
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
sdk_version = tuple(int(part) for part in sdk.split("."))
runtimes = [runtime for runtime in available["runtimes"]
            if runtime.get("isAvailable") and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-26-")
            and tuple(int(part) for part in runtime["version"].split(".")[:2]) <= sdk_version[:2]]
if not runtimes:
    raise SystemExit("No available iOS 26 simulator runtime is installed.")
runtime = max(runtimes, key=lambda item: tuple(int(part) for part in item["version"].split(".")))
device_types = {item["name"]: item for item in available["devicetypes"]}
preferred = ("iPhone 11 Pro Max", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16", "iPhone 16e")
device_type = next((device_types[name] for name in preferred if name in device_types), None)
if device_type is None:
    raise SystemExit("No supported iPhone simulator device type is installed.")
name = "MangaShelf UI " + os.environ.get("GITHUB_RUN_ID", datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
udid = subprocess.check_output(["xcrun", "simctl", "create", name, device_type["identifier"], runtime["identifier"]], text=True).strip()
provenance = {
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "dirty_files": subprocess.check_output(["git", "status", "--porcelain"], text=True).splitlines(),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "simulator_sdk": sdk,
    "developer_directory": os.environ["DEVELOPER_DIR"],
    "simulator": {"udid": udid, "device_type": device_type, "runtime": runtime},
    "github_run_id": os.environ.get("GITHUB_RUN_ID"),
    "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    "appearance": "dark", "languages": ["en", "ar"],
    "additional_cases": {"light": "selected through the real saved App theme control",
                         "dynamic_type": "accessibility XXXL launch preference; verified by tab geometry"},
    "store": "new simulator: empty production store for Tabs; then original synthetic persistent library data for Stage23; seed manifest records each file; no fixtures in the app",
    "visual_parity": "NOT REVIEWED",
}
(output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
(output / "simulator-udid.txt").write_text(udid + "\n")
PY
simulator_udid=$(cat "$artifact_dir/simulator-udid.txt")
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl ui "$simulator_udid" appearance dark
xcrun simctl status_bar "$simulator_udid" override --time '9:41' \
  --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100

python3 scripts/check_ui_resources.py
python3 scripts/generate_xcode_project.py --ui-tests
xcodebuild -project iOS/MangaShelfUI.xcodeproj -scheme MangaShelfUI \
  -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath build/UISnapshotDerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build-for-testing \
  2>&1 | tee "$artifact_dir/build.log"
app_path="$project_root/build/UISnapshotDerivedData/Build/Products/Debug-iphonesimulator/MangaShelf.app"
python3 - "$app_path" "$artifact_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import plistlib
import sys
app, output = Path(sys.argv[1]), Path(sys.argv[2])
info = plistlib.loads((app / "Info.plist").read_bytes())
binary = app / info["CFBundleExecutable"]
(output / "built-app.json").write_text(json.dumps({
    "bundle_identifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"], "executable_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "debug_dylib_sha256": hashlib.sha256((app / 'MangaShelf.debug.dylib').read_bytes()).hexdigest() if (app / 'MangaShelf.debug.dylib').is_file() else None,
}, indent=2) + "\n")
PY
xcrun simctl install "$simulator_udid" "$app_path"
xcodebuild -project iOS/MangaShelfUI.xcodeproj -scheme MangaShelfUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath build/UISnapshotDerivedData -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:MangaShelfUISnapshots/TabSnapshots CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test-without-building \
  2>&1 | tee "$artifact_dir/test.log"
for language in English Arabic; do
  # Each locale gets a fresh installed container. No production launch flag or
  # fixture resource is introduced, and no personal library is touched.
  xcrun simctl uninstall "$simulator_udid" app.mangashelf.reader
  xcrun simctl install "$simulator_udid" "$app_path"
  python3 scripts/seed_ui_simulator.py --simulator-udid "$simulator_udid" --report "$artifact_dir/seed-$language.json"
  xcodebuild -project iOS/MangaShelfUI.xcodeproj -scheme MangaShelfUI \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" \
    -derivedDataPath build/UISnapshotDerivedData -resultBundlePath "$artifact_dir/Stage23-$language.xcresult" \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:MangaShelfUISnapshots/StageTwoThreeSnapshots/test${language}SavedFlows CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test-without-building \
    2>&1 | tee "$artifact_dir/test-stage23-$language.log"
  python3 scripts/verify_ui_simulator.py --simulator-udid "$simulator_udid" --seed "$artifact_dir/seed-$language.json" --report "$artifact_dir/persistence-$language.json"
done
