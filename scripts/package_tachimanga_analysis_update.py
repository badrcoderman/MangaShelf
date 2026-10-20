#!/usr/bin/env python3
"""Make an immutable review archive from verified static evidence and Git index.

Never reads the IPA or executes reference code. Raw analysis remains external
to the production repository. Requires the previously verified complete bundle.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import zipfile

BASE_SHA256 = "0183cdeafcc4bc53609c871213508bac88fbd783a566e9290bc6308730f7909d"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def build(base, output, repo):
    if output.exists():
        raise ValueError("Review archives are immutable; choose a new output filename")
    if digest(base.read_bytes()) != BASE_SHA256:
        raise ValueError("Wrong base analysis archive")
    entries = {}
    with zipfile.ZipFile(base) as source:
        manifest = json.loads(source.read("MANIFEST.json"))
        recorded = {r["path"]: r for r in manifest["files"]}
        if len(recorded) != len(manifest["files"]) or set(source.namelist()) != set(recorded) | {"MANIFEST.json"}:
            raise ValueError("Base member list mismatch")
        for name, record in recorded.items():
            data = source.read(name)  # Verifies each ZIP CRC as well.
            if len(data) != record["bytes"] or digest(data) != record["sha256"]:
                raise ValueError("Base manifest mismatch: " + name)
            entries[name] = data
    previous_provenance = json.loads(entries["PROVENANCE.json"])
    reports = subprocess.check_output(
        ["git", "ls-files", "docs/TACHIMANGA-5.1-*.md"], cwd=repo, text=True).splitlines()
    names = reports + ["TODO.md", "CHANGELOG.md", "scripts/review_tachimanga_reader.py",
                       "scripts/package_tachimanga_analysis_update.py",
                       "validation/rea/tachimanga-5.1-reader-pairing.json"]
    for name in names:
        entries[name] = subprocess.check_output(["git", "show", ":" + name], cwd=repo)
    entries["PROVENANCE.json"] = (json.dumps({
        "base_archive": {"name": base.name, "sha256": BASE_SHA256, "manifest_verified": True},
        "base_provenance": previous_provenance,
        "repository_base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "updated_files_from_git_index": names, "target_executed": False,
        "scope": "Adds scoped reader pairing analysis and current reports; not complete semantic recovery or runtime proof",
    }, indent=2) + "\n").encode()
    entries["README.md"] += b"""

## Reader pairing follow-up

Start with docs/TACHIMANGA-5.1-READER-PAIRING-AR.md for the latest addition.
13 selected methods, 1,901 instructions and 38 anchors were cross-checked
against the supplied App image using independent Capstone decoding.
The script and metadata are included. All original coverage limits above
still apply. See PROVENANCE.json for the verified input archive and updates.
"""
    manifest = []
    for name, data in sorted(entries.items()):
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name:
            raise ValueError("Unsafe member path")
        if path.suffix.lower() in {".class", ".jar", ".dylib", ".ipa", ".exe", ".so", ".a", ".o"}:
            raise ValueError("Executable carrier: " + name)
        if data[:4] in [bytes.fromhex(h) for h in ("cafebabe", "feedfacf", "cffaedfe", "feedface", "cefaedfe")]:
            raise ValueError("Executable carrier magic: " + name)
        manifest.append({"path": name, "bytes": len(data), "sha256": digest(data)})
    with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for record in manifest:
            archive.writestr(record["path"], entries[record["path"]])
        archive.writestr("MANIFEST.json", json.dumps({"target_executed": False, "files": manifest}, indent=2))
    with zipfile.ZipFile(output) as archive:
        if set(archive.namelist()) != {r["path"] for r in manifest} | {"MANIFEST.json"}:
            raise ValueError("Output member list mismatch")
        for record in manifest:
            data = archive.read(record["path"])
            if len(data) != record["bytes"] or digest(data) != record["sha256"]:
                raise ValueError("Output manifest mismatch")
    return {"path": str(output), "bytes": output.stat().st_size, "sha256": digest(output.read_bytes()),
            "members": len(manifest) + 1, "crc_and_manifest_members_verified": len(manifest),
            "target_executed": False, "original_executable_carriers_included": False,
            "scope": "Static investigation with scoped reader follow-up; not runtime or visual parity proof"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_archive", type=Path)
    parser.add_argument("output_archive", type=Path)
    parser.add_argument("summary", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    summary = build(args.base_archive, args.output_archive, repo)
    args.summary.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
