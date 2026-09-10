#!/usr/bin/env python3
"""In-memory header checks and failure paths; no fake IPA fixture is created."""
import struct
import json
import tempfile
from pathlib import Path
import unittest
from package_unsigned_ipa import package, validate_executable


def header(platform=2, cpu=0x0100000C, kind=2, length=24):
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, kind, 1, 24, 0, 0) + struct.pack("<6I", 0x32, length, platform, 0x110000, 0x110000, 0)


class PackagingTests(unittest.TestCase):
    def test_device_header(self):
        validate_executable(header())

    def test_rejects_simulator(self):
        for cpu in [0x0100000C, 0x01000007]:
            with self.assertRaises(ValueError):
                validate_executable(header(platform=7, cpu=cpu))

    def test_rejects_non_application(self):
        with self.assertRaises(ValueError):
            validate_executable(header(kind=6))

    def test_rejects_truncated(self):
        for length in range(56):
            with self.assertRaises(ValueError):
                validate_executable(header()[:length])

    def test_rejects_command_bounds(self):
        for length in [0, 7, 16, 32, 0xFFFFFFF8]:
            with self.assertRaises(ValueError):
                validate_executable(header(length=length))

    def test_missing_bundle_does_not_create_ipa(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                package(root / "Missing.app", root / "result.ipa")
            self.assertFalse((root / "result.ipa").exists())

    def test_rejects_symlink_before_reading_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Test.app"
            app.mkdir()
            (app / "link").symlink_to(root)
            with self.assertRaises(ValueError):
                package(app, root / "result.ipa")
            self.assertFalse((root / "result.ipa").exists())


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False).result
    destination = Path(__file__).resolve().parents[1] / "validation"
    destination.mkdir(exist_ok=True)
    (destination / "packaging-test-results.json").write_text(json.dumps({
        "scope": "in-memory Mach-O headers and packaging rejection paths only",
        "tests": result.testsRun, "failures": len(result.failures),
        "errors": len(result.errors), "success": result.wasSuccessful(),
        "real_ios_bundle_packaged": False, "ipa_created": False
    }, indent=2) + "\n")
    raise SystemExit(not result.wasSuccessful())
