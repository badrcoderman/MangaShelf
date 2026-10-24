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
  if [ -d "$result_bundle" ]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" \
      > "$artifact_dir/test-summary.json" 2> "$artifact_dir/test-summary-errors.log"
    xcrun xcresulttool export attachments --path "$result_bundle" \
      --output-path "$artifact_dir/attachments" > "$artifact_dir/export.log" 2>&1
    if [ "$?" -eq 0 ]; then
      python3 scripts/collect_ui_snapshots.py "$artifact_dir/attachments" \
        "$artifact_dir/screenshots" --provenance "$artifact_dir/provenance.json"
      capture_status=$?
    fi
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
    "store": "new simulator; production empty store; no injected manga content",
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
}, indent=2) + "\n")
PY
xcrun simctl install "$simulator_udid" "$app_path"
xcodebuild -project iOS/MangaShelfUI.xcodeproj -scheme MangaShelfUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath build/UISnapshotDerivedData -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:MangaShelfUISnapshots/TabSnapshots CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test-without-building \
  2>&1 | tee "$artifact_dir/test.log"
