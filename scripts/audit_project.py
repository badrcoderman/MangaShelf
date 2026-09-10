#!/usr/bin/env python3
"""Bounded provenance checks, not antivirus or a replacement for an iOS build."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET
import zipfile

ROOT=Path(__file__).resolve().parents[1]
ignored={".git",".build","build","__pycache__","validation"}
forbidden_suffixes={".ipa",".dylib",".so",".a",".class",".jar",".apk",".framework"}
magic={b"\xcf\xfa\xed\xfe",b"\xfe\xed\xfa\xcf",b"\xca\xfe\xba\xbe",b"\x7fELF"}
hashes=[];failures=[]
for path in sorted(ROOT.rglob("*")):
    relative=path.relative_to(ROOT)
    if any(part in ignored for part in relative.parts):continue
    if path.is_symlink():failures.append(f"symlink: {relative}");continue
    if not path.is_file():continue
    if path.suffix in forbidden_suffixes:failures.append(f"prebuilt executable: {relative}")
    data=path.read_bytes()
    if data[:4] in magic:failures.append(f"binary executable signature: {relative}")
    if path.name in {"res.zip","modules","Tachimanga"}:failures.append(f"specimen payload: {relative}")
    if path.suffix in {".swift",".c",".h",".pbxproj"}:
        text=data.decode()
        for term in ["dlopen(","Firebase", "blatantsPatch", "MobileSubstrate", "NSAllowsArbitraryLoads"]:
            if term in text:failures.append(f"unexpected implementation dependency {term}: {relative}")
    hashes.append({"path":str(relative),"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
for name in ["Info.plist","PrivacyInfo.xcprivacy"]:
    plistlib.loads((ROOT/"iOS/MangaShelf"/name).read_bytes())
info=plistlib.loads((ROOT/"iOS/MangaShelf/Info.plist").read_bytes())
if info.get("NSAppTransportSecurity",{}).get("NSAllowsArbitraryLoads"):failures.append("ATS arbitrary loads enabled")
project=(ROOT/"iOS/MangaShelf.xcodeproj/project.pbxproj").read_text()
declared=set(re.findall(r'"([A-F0-9]{24})" = \{',project))
references=set(re.findall(r'"([A-F0-9]{24})"',project))
if not references.issubset(declared):failures.append("unresolved Xcode project object references")
for path in (ROOT/"iOS/MangaShelf").glob("*.swift"):
    if 'MangaShelf/'+path.name not in project:failures.append(f"Swift app file omitted from Xcode project: {path.name}")
scheme=ET.parse(ROOT/"iOS/MangaShelf.xcodeproj/xcshareddata/xcschemes/MangaShelf.xcscheme")
for ref in scheme.iter("BuildableReference"):
    if ref.attrib["BlueprintIdentifier"] not in declared:failures.append("scheme target is absent")
with zipfile.ZipFile(ROOT/"Tests/ReaderCoreTests/Fixtures/TestComic.cbz") as archive:
    if archive.testzip() is not None:failures.append("invalid test comic")
    if any(not name.endswith(".png") for name in archive.namelist()):failures.append("unexpected sample comic payload")
destination=ROOT/"validation";destination.mkdir(exist_ok=True)
report={"scope":"provenance/build-structure only, not malware detection or Swift compilation",
        "prebuilt_app_payloads":0 if not failures else "see failures","files":len(hashes),"failures":failures,
        "swift_compilation":"NOT RUN","ios_runtime":"NOT RUN","live_repository":"NOT TESTED"}
(destination/"project-audit.json").write_text(json.dumps(report,indent=2)+"\n")
(destination/"source-manifest.json").write_text(json.dumps(hashes,indent=2)+"\n")
print(json.dumps(report,indent=2));raise SystemExit(bool(failures))
