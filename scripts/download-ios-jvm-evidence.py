#!/usr/bin/env python3
"""Download an explicitly selected successful source-build artifact with provenance."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile


def gh_json(endpoint):
    result = subprocess.run(["gh", "api", endpoint], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def select_artifact(run, artifacts, repository, run_id):
    if (run.get("id") != run_id or run.get("repository", {}).get("full_name") != repository
            or run.get("head_repository", {}).get("full_name") != repository
            or run.get("path") != ".github/workflows/ios-jvm.yml"
            or run.get("event") != "workflow_dispatch"
            or run.get("status") != "completed" or run.get("conclusion") != "success"
            or not re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", ""))):
        raise ValueError("Select a completed successful ios-jvm.yml run from this repository")
    matches = [a for a in artifacts if a.get("name") == "ios-jvm-build"]
    if len(matches) != 1:
        raise ValueError("The selected run must have exactly one ios-jvm-build artifact")
    artifact = matches[0]
    workflow = artifact.get("workflow_run", {})
    if (artifact.get("expired") is not False or workflow.get("id") != run_id
            or workflow.get("head_sha") != run["head_sha"]
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", ""))):
        raise ValueError("The runtime artifact is expired or has inconsistent provenance")
    return artifact


def unpack_archive(archive, destination):
    # Workflow artifacts are generated data. Extract only bounded ordinary files.
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if len(entries) > 50000 or sum(i.file_size for i in entries) > 2 * 1024**3:
            raise ValueError("Runtime artifact exceeds extraction limits")
        for item in entries:
            path = PurePosixPath(item.filename)
            if (path.is_absolute() or ".." in path.parts or "\\" in item.filename
                    or (item.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError("Runtime artifact contains an unsafe path or symlink")
        bundle.extractall(destination)


def verify_build_manifest(runtime, run):
    path = runtime / "build-provenance.json"
    if not path.is_file():
        return False  # Historical static-only artifacts have workflow provenance only.
    manifest = json.loads(path.read_text())
    expected = {
        "format": 1, "target": "arm64-apple-ios26.0", "vm_variant": "zero",
        "openjdk_commit": "c1ed06aaef34c8dccf71e236d1ffa20918a77cfb",
        "libffi_commit": "12ffd1f9dc56fcea79d2f742f424301ae668d663",
        "cups_ref": "2e5573560cfa2da65002f86b41bd1770c9853c4d",
        "cups_commit": "7d535f73e407a72dfb5c5e83549a5ba27219dfcd",
        "head_sha": run["head_sha"], "run_id": str(run["id"]),
        "repository": run["repository"]["full_name"],
        "zero_wx_source_fix": True, "java_modules_present": True,
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("Runtime build manifest disagrees with the selected source build")
    hashes = manifest.get("sha256", {})
    required = {"static-libs/lib/zero/libjvm.a", "ffi/lib/libffi.a", "jre/lib/modules"}
    if not required <= hashes.keys():
        raise ValueError("Runtime build manifest omits required archive or module hashes")
    for name, digest in hashes.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or "\\" in name:
            raise ValueError("Runtime build manifest contains an unsafe path")
        item = runtime / name
        if not item.is_file() or hashlib.sha256(item.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Runtime build output does not match its manifest: {name}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    args = parser.parse_args()
    if args.run_id <= 0 or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("A repository and positive numeric run ID are required")
    run = gh_json(f"repos/{args.repository}/actions/runs/{args.run_id}")
    artifacts = gh_json(f"repos/{args.repository}/actions/runs/{args.run_id}/artifacts?per_page=100")
    artifact = select_artifact(run, artifacts.get("artifacts", []), args.repository, args.run_id)
    args.provenance.mkdir(parents=True, exist_ok=True)
    (args.provenance / "runtime-run.json").write_text(json.dumps(run, indent=2) + "\n")
    (args.provenance / "runtime-artifact.json").write_text(json.dumps(artifact, indent=2) + "\n")
    if args.destination.exists() and any(args.destination.iterdir()):
        raise ValueError("Download destination must be empty to prevent mixing runtime builds")
    args.destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="msl-ios-jvm-") as temporary:
        archive = Path(temporary) / "runtime.zip"
        with archive.open("wb") as output:
            subprocess.run(["gh", "api", f"repos/{args.repository}/actions/artifacts/{artifact['id']}/zip"],
                           check=True, stdout=output)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if f"sha256:{digest}" != artifact["digest"]:
            raise ValueError("Downloaded runtime artifact does not match GitHub's SHA-256 digest")
        unpack_archive(archive, args.destination)
    runtime = args.destination / "build/ios-jvm"
    for name in ("static-libs/lib/zero/libjvm.a", "ffi/lib/libffi.a", "LICENSE"):
        if not (runtime / name).is_file():
            raise ValueError(f"Runtime artifact is missing {name}")
    manifest_verified = verify_build_manifest(runtime, run)
    selection = {
        "repository": args.repository, "run_id": args.run_id, "head_sha": run["head_sha"],
        "workflow": run["path"], "run_url": run["html_url"], "conclusion": run["conclusion"],
        "artifact_id": artifact["id"], "artifact_sha256": digest,
        "java_modules_present": (runtime / "jre/lib/modules").is_file(),
        "build_manifest_verified": manifest_verified,
        "execution_proven": False,
    }
    (args.provenance / "runtime-selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    print(json.dumps(selection, indent=2))


if __name__ == "__main__":
    main()
