#!/usr/bin/env python3
"""Check runtime provenance rejection and bounded artifact extraction."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("runtime_evidence", Path(__file__).with_name("download-ios-jvm-evidence.py"))
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.repository = "example/MangaShelf"
        self.run = {
            "id": 42, "repository": {"full_name": self.repository},
            "head_repository": {"full_name": self.repository},
            "path": ".github/workflows/ios-jvm.yml", "event": "workflow_dispatch",
            "status": "completed", "conclusion": "success", "head_sha": "a" * 40,
        }
        self.artifact = {
            "name": "ios-jvm-build", "id": 99, "expired": False,
            "digest": "sha256:" + "b" * 64, "workflow_run": {"id": 42, "head_sha": "a" * 40},
        }

    def test_select_successful_source_run(self):
        self.assertEqual(evidence.select_artifact(self.run, [self.artifact], self.repository, 42)["id"], 99)

    def test_reject_unproven_or_unrelated_run(self):
        for key, value in [("conclusion", "failure"), ("status", "in_progress"),
                           ("path", ".github/workflows/ios.yml"), ("event", "pull_request"),
                           ("head_sha", "malformed")]:
            with self.subTest(key=key):
                run = dict(self.run, **{key: value})
                with self.assertRaises(ValueError):
                    evidence.select_artifact(run, [self.artifact], self.repository, 42)

    def test_reject_expired_missing_duplicate_or_mismatched_artifact(self):
        cases = [[], [self.artifact, self.artifact]]
        for key, value in [("expired", True), ("digest", ""),
                           ("workflow_run", {"id": 42, "head_sha": "c" * 40})]:
            artifact = copy.deepcopy(self.artifact)
            artifact[key] = value
            cases.append([artifact])
        for artifacts in cases:
            with self.subTest(artifacts=artifacts), self.assertRaises(ValueError):
                evidence.select_artifact(self.run, artifacts, self.repository, 42)

    def test_extract_ordinary_file_and_reject_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "artifact.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("build/ios-jvm/LICENSE", "project-owned fixture")
            evidence.unpack_archive(archive, root / "out")
            self.assertEqual((root / "out/build/ios-jvm/LICENSE").read_text(), "project-owned fixture")
            for name in ["../escape", "/absolute", "build\\escape"]:
                with zipfile.ZipFile(archive, "w") as bundle:
                    bundle.writestr(name, "bad")
                with self.subTest(name=name), self.assertRaises(ValueError):
                    evidence.unpack_archive(archive, root / "reject")

    def test_missing_manifest_is_explicit_legacy_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertFalse(evidence.verify_build_manifest(Path(temporary), self.run))


if __name__ == "__main__":
    unittest.main()
