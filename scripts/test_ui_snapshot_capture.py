#!/usr/bin/env python3
"""Synthetic export cases for the native screenshot completeness gate."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location("collect_ui_snapshots", Path(__file__).with_name("collect_ui_snapshots.py"))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def png(index: int) -> bytes:
    def chunk(name: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", zlib.crc32(name + payload))
    row = b"\0" + bytes([index, 0, 0]) * 640
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 640, 1000, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * 1000)) + chunk(b"IEND", b""))


class SnapshotCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.attachments = self.root / "attachments"
        self.attachments.mkdir()
        self.manifest = [{"testName": "TabSnapshots", "attachments": [
            {"exportedFileName": f"{index}.png", "suggestedHumanReadableName": name + "_0_0123.png"}
            for index, name in enumerate(capture.EXPECTED)
        ]}]
        for index in range(len(capture.EXPECTED)):
            (self.attachments / f"{index}.png").write_bytes(png(index))

    def run_collect(self):
        (self.attachments / "manifest.json").write_text(json.dumps(self.manifest))
        return capture.collect(self.attachments, self.root / "screenshots")

    def test_full_export_preserves_native_bytes_and_leaves_parity_unreviewed(self):
        report = self.run_collect()
        self.assertEqual(report["captured_screenshots"], 24)
        self.assertEqual(report["visual_parity"], "NOT REVIEWED")
        for index, name in enumerate(capture.EXPECTED):
            self.assertEqual((self.root / "screenshots" / (name + ".png")).read_bytes(), png(index))

    def test_missing_capture_fails(self):
        self.manifest[0]["attachments"].pop()
        with self.assertRaisesRegex(ValueError, "missing native screenshots"):
            self.run_collect()

    def test_duplicate_capture_fails(self):
        self.manifest[0]["attachments"].append(self.manifest[0]["attachments"][0].copy())
        with self.assertRaisesRegex(ValueError, "duplicate named screenshot"):
            self.run_collect()

    def test_repeated_image_fails(self):
        (self.attachments / "1.png").write_bytes((self.attachments / "0.png").read_bytes())
        with self.assertRaisesRegex(ValueError, "identical screenshot bytes"):
            self.run_collect()

    def test_invalid_png_fails(self):
        (self.attachments / "0.png").write_bytes(b"not a screenshot")
        with self.assertRaisesRegex(ValueError, "invalid native PNG"):
            self.run_collect()

    def test_manifest_path_traversal_fails(self):
        self.manifest[0]["attachments"][0]["exportedFileName"] = "../0.png"
        with self.assertRaisesRegex(ValueError, "must not contain a path"):
            self.run_collect()


if __name__ == "__main__":
    unittest.main()
