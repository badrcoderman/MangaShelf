#!/usr/bin/env python3
"""Inventory attribution and build metadata without executing specimen code."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile
import zlib


def digest(data):
    return hashlib.sha256(data).hexdigest()


def properties(text):
    result = {}
    for line in text.splitlines():
        if line and not line.startswith(("#", "!")) and "=" in line:
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def inventory(app):
    archive_path = app / "MCHome.bundle/res.zip"
    notices_path = app / "Frameworks/App.framework/flutter_assets/NOTICES.Z"
    packed = notices_path.read_bytes()
    if len(packed) > 8 * 1024 * 1024:
        raise ValueError("ملف الإشعارات يتجاوز حد القراءة")
    decoder = zlib.decompressobj(47)
    raw = decoder.decompress(packed, 8 * 1024 * 1024 + 1)
    if len(raw) > 8 * 1024 * 1024 or not decoder.eof or decoder.unused_data:
        raise ValueError("ملف إشعارات غير صالح أو يتجاوز حد فك الضغط")
    notices = []
    for block in re.split(r"(?m)^-{80}\r?$", raw.decode("utf-8")):
        header, separator, body = block.strip().partition("\n\n")
        if separator and body.strip():
            notices.append({"names": header.splitlines(), "notice_sha256": digest(body.encode())})
    artifacts = []
    prefixes = ("suwayomi/", "mihon/", "eu/kanade/tachiyomi/", "org/tachiyomi/", "app/tachimanga/", "xyz/nulldev/androidcompat/")
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        if len(entries) > 100000:
            raise ValueError("عدد ملفات الأرشيف يتجاوز حد الجرد")
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("الأرشيف يحتوي أسماء ملفات مكررة")
        def read_metadata(name):
            entry = archive.getinfo(name)
            if entry.file_size > 256 * 1024:
                raise ValueError("ملف بيانات وصفية أكبر من الحد: " + name)
            return archive.read(entry)
        manifest = read_metadata("META-INF/MANIFEST.MF")
        for name in sorted(names):
            if name.startswith("META-INF/maven/") and name.endswith("/pom.properties"):
                content = read_metadata(name)
                artifacts.append({"path": name, "sha256": digest(content), "declared": properties(content.decode("utf-8"))})
        counts = {prefix: sum(name.startswith(prefix) and name.endswith(".class") for name in names) for prefix in prefixes}
    return {
        "schema_version": 1,
        "scope_ar": "جرد بيانات وإشعارات من العينة فقط؛ لا يثبت سلامتها أو تطابقها مع سورس منشور أو ترخيص كل مكون",
        "executes_specimen": False,
        "copies_payload_to_app": False,
        "backend_manifest": manifest.decode("utf-8"),
        "backend_manifest_sha256": digest(manifest),
        "class_prefix_counts": counts,
        "maven_artifacts": artifacts,
        "flutter_notices_sha256": digest(raw),
        "flutter_notice_groups": notices,
        "limits_ar": "نسخ المكونات الفعلية يتطلب تثبيت مراجعة سورس وفحص ترخيصها وتبعياتها؛ إشعارات الحزمة ليست إذنًا لنسخ التطبيق كاملًا",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.resolve().is_relative_to(args.app.resolve()):
        parser.error("ملف التقرير يجب أن يكون خارج مجلد العينة")
    try:
        report = inventory(args.app)
        with args.output.open("x", encoding="utf-8") as output:
            json.dump(report, output, ensure_ascii=False, indent=2)
            output.write("\n")
        print(json.dumps({"maven_artifacts": len(report["maven_artifacts"]), "flutter_notice_groups": len(report["flutter_notice_groups"]), "class_prefix_counts": report["class_prefix_counts"]}, ensure_ascii=False))
    except (OSError, ValueError, KeyError, UnicodeError, zipfile.BadZipFile, zlib.error) as error:
        print("تعذر إكمال الجرد: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
