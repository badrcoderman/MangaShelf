#!/usr/bin/env python3
"""Exercise the isolated JAR verifier with generated test keys and data-only JARs.

No JAR member is ever put on the class path or invoked. The optional reference
candidate check inspects a public source rebuild only, with an explicitly
diagnostic Android Debug certificate pin; it grants no publisher trust.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import warnings
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "runtime-probe/src/mangashelf/runtime/ExtensionArchiveVerifier.java"
REPORT = ROOT / "validation/extension-archive-verifier-host.json"
PASSWORD = "mangashelf-generated-test-key"
DOCS = [
    "https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/jar/JarFile.html",
    "https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/jar/JarEntry.html",
    "https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/jar/JarInputStream.html",
]


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            value.update(block)
    return value.hexdigest()


def main():
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "command": "python3 scripts/test-extension-archive-verifier.py",
        "scope": "Host-only JAR v1 cryptographic/data inspection; no archive class loading, iOS, real source execution, publisher/PKIX trust, expiry or revocation proof. No production activation.",
        "policy": "Expected whole-file SHA-256 and one explicitly pinned leaf certificate DER SHA-256; every physical payload must have exactly that one signer after EOF. Private snapshot is deleted; result does not authorize later loading of the original path.",
        "documentation": DOCS,
        "inputs": {str(path.relative_to(ROOT)): digest(path) for path in (SOURCE, Path(__file__))},
        "commands": [], "tests": [], "passed": False,
    }

    def run(argv, *, check=True, timeout=45):
        result = subprocess.run([str(item) for item in argv], cwd=ROOT, text=True,
                                capture_output=True, timeout=timeout)
        report["commands"].append({"argv": [str(item) for item in argv],
                                   "returncode": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr})
        if check and result.returncode:
            raise RuntimeError("Command failed: " + str(argv[0]))
        return result

    try:
        tools = {name: shutil.which(name) for name in ("java", "javac", "keytool", "jarsigner")}
        if not all(tools.values()):
            raise RuntimeError("java, javac, keytool and jarsigner are required; missing tools cannot pass.")
        run([tools["java"], "-version"])
        with tempfile.TemporaryDirectory(prefix="msl-jar-signature-tests-") as directory:
            temporary = Path(directory)
            classes, scratch = temporary / "verifier-classes", temporary / "private-scratch"
            classes.mkdir()
            scratch.mkdir(mode=0o700)
            run([tools["javac"], "--release", "17", "-encoding", "UTF-8", "-Xlint:all", "-Werror",
                 "-d", classes, SOURCE])
            keystore = temporary / "generated-fixtures.p12"
            pins = {}
            for alias in ("fixturea", "fixtureb"):
                run([tools["keytool"], "-genkeypair", "-alias", alias, "-keystore", keystore,
                     "-storetype", "PKCS12", "-storepass", PASSWORD, "-keypass", PASSWORD,
                     "-keyalg", "RSA", "-keysize", "2048", "-sigalg", "SHA256withRSA",
                     "-validity", "365", "-dname", "CN=" + alias + ",O=MangaShelf Generated Tests,C=ZZ",
                     "-noprompt"])
                certificate = temporary / (alias + ".der")
                run([tools["keytool"], "-exportcert", "-alias", alias, "-keystore", keystore,
                     "-storepass", PASSWORD, "-file", certificate])
                pins[alias] = digest(certificate)
            report["generated_fixture_certificate_sha256"] = pins

            def write_jar(path, entries):
                with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as jar:
                    with warnings.catch_warnings():
                        warnings.simplefilter("ignore", UserWarning)
                        for name, content in entries:
                            jar.writestr(name, content)
                return path

            def rewrite(path, source, transform=lambda name, data: data, extra=(), order=None):
                with zipfile.ZipFile(source) as jar:
                    entries = [(info.filename, transform(info.filename, jar.read(info))) for info in jar.infolist()]
                if order:
                    entries.sort(key=lambda item: order(item[0]))
                return write_jar(path, entries + list(extra))

            def sign(path, alias="fixturea", *, sections_only=False):
                run([tools["jarsigner"], "-keystore", keystore, "-storepass", PASSWORD,
                     "-keypass", PASSWORD, "-sigalg", "SHA256withRSA", "-digestalg", "SHA-256",
                     *(["-sectionsonly"] if sections_only else []),
                     path, alias])
                return path

            def corrupt_central(path, source, field):
                # Keep compressed payload/signatures unchanged; modify only the selected
                # central-directory field so readEntry must compare real bytes with it.
                data = bytearray(source.read_bytes())
                end = data.rfind(b"PK\x05\x06")
                offset = struct.unpack_from("<I", data, end + 16)[0]
                target = b"payload.txt"
                while data[offset:offset + 4] == b"PK\x01\x02":
                    names, extras, comments = struct.unpack_from("<HHH", data, offset + 28)
                    if data[offset + 46:offset + 46 + names] == target:
                        position = offset + {"crc": 16, "size": 24}[field]
                        original = struct.unpack_from("<I", data, position)[0]
                        declared = original ^ 1 if field == "crc" else 1
                        struct.pack_into("<I", data, position, declared)
                        with zipfile.ZipFile(source) as jar:
                            info = jar.getinfo(target.decode())
                        local_names, local_extras = struct.unpack_from("<HH", data, info.header_offset + 26)
                        start = info.header_offset + 30 + local_names + local_extras
                        actual = zlib.decompress(data[start:start + info.compress_size], -15)
                        assert actual == b"Project-authored data, never executable.\n"
                        assert declared != (zlib.crc32(actual) if field == "crc" else len(actual))
                        report.setdefault("central_directory_corruptions", []).append({
                            "field": field, "original": original, "declared": declared,
                            "actual_expanded_size": len(actual), "actual_crc32": zlib.crc32(actual),
                            "payload_bytes_preserved": actual == b"Project-authored data, never executable.\n",
                        })
                        path.write_bytes(data)
                        return path
                    offset += 46 + names + extras + comments
                raise AssertionError("Fixture central-directory payload entry not found")

            def case(name, path, *, error=None, expected_hash=None, pin=None, scratch_path=None):
                before = sorted(item.name for item in scratch.iterdir())
                result = run([tools["java"], "-Xmx128m", "-cp", classes,
                              "mangashelf.runtime.ExtensionArchiveVerifier", path,
                              expected_hash if expected_hash is not None else digest(path),
                              pin if pin is not None else pins["fixturea"],
                              scratch_path if scratch_path is not None else scratch], check=False)
                value = json.loads(result.stdout)
                passed = ((result.returncode == 0 and value.get("verified") is True)
                          if error is None else (result.returncode != 0 and value == {"verified": False, "code": error}))
                passed = passed and before == sorted(item.name for item in scratch.iterdir())
                report["tests"].append({"name": name, "passed": passed, "response": value,
                                        "scratch_cleaned": before == sorted(item.name for item in scratch.iterdir())})

            entries = [("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\n\r\n"),
                       ("payload.txt", b"Project-authored data, never executable.\n"),
                       ("META-INF/services/mangashelf.fixture.Service", b"fixture-only\n"),
                       ("META-INF/versions/17/fixture.txt", b"versioned data only\n"),
                       ("العربية-📚.txt", "UTF-8 fixture\n".encode()), ("empty.txt", b""), ("empty-directory/", b"")]
            unsigned = write_jar(temporary / "unsigned.jar", entries)
            valid = sign(rewrite(temporary / "signed.jar", unsigned))
            case("valid signed resources including META-INF, Unicode and empty entries", valid)
            case("uppercase caller hash and certificate pin", valid,
                 expected_hash=digest(valid).upper(), pin=pins["fixturea"].upper())
            case("wrong expected whole-file hash", valid, expected_hash="0" * 64, error="digest_mismatch")
            case("wrong explicit trusted leaf certificate", valid, pin=pins["fixtureb"], error="signer_mismatch")
            case("malformed expected whole-file hash", valid, expected_hash="not-a-hash", error="invalid_argument")
            case("malformed trusted certificate pin", valid, pin="", error="invalid_argument")
            case("unsigned archive cannot gain trust from a matching hash", unsigned, error="unsigned_archive")
            case("caller scratch directory must exist", valid, scratch_path=temporary / "missing", error="invalid_argument")

            changed = rewrite(temporary / "tampered.jar", valid,
                              transform=lambda name, data: b"Tampered with valid ZIP CRC\n" if name == "payload.txt" else data)
            case("signed payload tampering with recomputed ZIP CRC", changed, error="invalid_signature")
            changed = rewrite(temporary / "tampered-manifest.jar", valid,
                              transform=lambda name, data: data.replace(b"Manifest-Version: 1.0", b"Manifest-Version: 2.0")
                              if name == "META-INF/MANIFEST.MF" else data)
            case("signed manifest tampering", changed, error="invalid_signature")
            crc_corruption = corrupt_central(temporary / "central-crc.jar", valid, "crc")
            case("central-directory CRC corruption rejected against actual expanded data", crc_corruption,
                 error="invalid_archive")
            size_corruption = corrupt_central(temporary / "central-understated-size.jar", valid, "size")
            case("central-directory understated size rejected against actual decompression", size_corruption,
                 error="invalid_archive")
            for index, name in enumerate(("added.txt", "META-INF/NOTICE.txt", "META-INF/services/added.Service",
                                           "META-INF/versions/21/added.txt", "META-INF/subdirectory/FAKE.SF",
                                           "META-INF/SIG-FAKE.XYZ")):
                changed = rewrite(temporary / ("unsigned-extra-" + str(index) + ".jar"), valid,
                                  extra=[(name, b"Unsigned added data\n")])
                case("unsigned extra payload rejected / " + name, changed, error="unsigned_entry")

            dual = sign(rewrite(temporary / "dual-signed.jar", valid), "fixtureb")
            case("additional untrusted signer cannot hide behind a trusted co-signer", dual, error="multiple_signers")
            partial = sign(rewrite(temporary / "mixed-signers.jar", valid, extra=[("new-signer-only.txt", b"B only\n")]), "fixtureb")
            case("partially overlapping mixed signers fail closed", partial, error="multiple_signers")
            second_only = sign(rewrite(temporary / "second-signer.jar", unsigned), "fixtureb")
            case("uniformly signed by another key", second_only, error="signer_mismatch")

            # Each signature covers its own manifest section only. Merging those
            # sections preserves valid independent A-only and B-only signatures.
            sections, signatures, payloads = [], [], []
            main_attributes = None
            for alias, name in (("fixturea", "a-only.txt"), ("fixtureb", "b-only.txt")):
                part = sign(write_jar(temporary / (alias + "-section.jar"),
                                     [entries[0], (name, alias.encode())]), alias, sections_only=True)
                with zipfile.ZipFile(part) as jar:
                    manifest = jar.read("META-INF/MANIFEST.MF").split(b"\r\n\r\n")
                    if main_attributes is not None:
                        assert manifest[0] == main_attributes
                    main_attributes = manifest[0]
                    sections.extend(section for section in manifest[1:] if section)
                    signatures.extend((info.filename, jar.read(info)) for info in jar.infolist()
                                      if info.filename.startswith("META-INF/") and info.filename.endswith((".SF", ".RSA")))
                    payloads.append((name, jar.read(name)))
            disjoint_manifest = b"\r\n\r\n".join([main_attributes] + sections) + b"\r\n\r\n"
            disjoint = write_jar(temporary / "genuinely-disjoint-signers.jar",
                                 [("META-INF/MANIFEST.MF", disjoint_manifest)] + signatures + payloads)
            signer_probe = temporary / "DisjointSignerProbe.java"
            signer_probe.write_text('''import java.io.*; import java.nio.file.*; import java.security.*;
import java.util.*; import java.util.jar.*;
public final class DisjointSignerProbe {
 public static void main(String[] args) throws Exception {
  try (JarFile jar=new JarFile(args[0], true)) {
   for (String name: new String[]{"a-only.txt", "b-only.txt"}) {
    JarEntry entry=jar.getJarEntry(name);
    try (InputStream input=jar.getInputStream(entry)) { input.transferTo(OutputStream.nullOutputStream()); }
    CodeSigner[] signers=entry.getCodeSigners();
    if (signers==null || signers.length!=1) throw new AssertionError("Not exactly one signer");
    byte[] der=signers[0].getSignerCertPath().getCertificates().get(0).getEncoded();
    System.out.println(name+" "+HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(der)));
   }
  }
 }
}
''', encoding="utf-8")
            run([tools["javac"], "--release", "17", "-Xlint:all", "-Werror", "-d", classes, signer_probe])
            observed_signers = dict(line.split() for line in run(
                [tools["java"], "-cp", classes, "DisjointSignerProbe", disjoint]).stdout.splitlines())
            report["tests"].append({"name": "disjoint fixture has valid A-only and B-only payload signatures",
                                    "passed": observed_signers == {"a-only.txt": pins["fixturea"], "b-only.txt": pins["fixtureb"]},
                                    "response": observed_signers})
            case("genuinely disjoint signers rejected when A is pinned", disjoint, error="signer_mismatch")
            case("genuinely disjoint signers rejected when B is pinned", disjoint,
                 pin=pins["fixtureb"], error="signer_mismatch")

            reordered = rewrite(temporary / "late-signature-metadata.jar", valid,
                                order=lambda name: (name.startswith("META-INF/"), name))
            case("JarFile verifies payload preceding manifest and signature metadata", reordered)
            # The diagnostic contains only our own code and reads reordered JAR entries as data.
            stream_probe = temporary / "StreamOrderProbe.java"
            stream_probe.write_text('''import java.nio.file.*; import java.util.jar.*;
public final class StreamOrderProbe {
 public static void main(String[] args) throws Exception {
  int payloads=0, signed=0;
  try (JarInputStream input=new JarInputStream(Files.newInputStream(Path.of(args[0])), true)) {
   JarEntry entry; byte[] buffer=new byte[8192];
   while ((entry=input.getNextJarEntry())!=null) {
    while(input.read(buffer)!=-1) {}
    if (!entry.isDirectory() && !entry.getName().startsWith("META-INF/")) {
     payloads++; if(entry.getCodeSigners()!=null) signed++;
    }
   }
  }
  System.out.println("{\\\"payloadEntries\\\":"+payloads+",\\\"signedEntries\\\":"+signed+"}");
 }
}
''', encoding="utf-8")
            run([tools["javac"], "--release", "17", "-Xlint:all", "-Werror", "-d", classes, stream_probe])
            sequential = json.loads(run([tools["java"], "-cp", classes, "StreamOrderProbe", reordered]).stdout)
            report["tests"].append({"name": "sequential reader misses late manifest/signatures, regression reproduced",
                                    "passed": sequential["payloadEntries"] > 0 and sequential["signedEntries"] == 0,
                                    "response": sequential})

            duplicate = rewrite(temporary / "duplicate.jar", valid, extra=[("payload.txt", b"duplicate\n")])
            case("duplicate physical entry names rejected", duplicate, error="duplicate_entry")
            unsafe = ("../escape", "/absolute", "drive:name", "back\\slash", "dot/./name", "empty//name", "control\nname")
            for index, name in enumerate(unsafe):
                bad = rewrite(temporary / ("unsafe-" + str(index) + ".jar"), valid, extra=[(name, b"unsafe\n")])
                case("unsafe archive name rejected / " + repr(name), bad, error="unsafe_entry_name")
            ambiguous = rewrite(temporary / "ambiguous-manifest.jar", valid,
                                extra=[("meta-inf/manifest.mf", b"alias")])
            case("case alias for signing metadata rejected", ambiguous, error="ambiguous_signature_metadata")
            unpaired = rewrite(temporary / "unpaired-signature.jar", valid, extra=[("META-INF/FAKE.SF", b"unpaired")])
            case("unpaired signature marker rejected", unpaired, error="invalid_signature_metadata")
            empty = sign(write_jar(temporary / "empty-signed.jar", entries[:1]))
            case("manifest-only archive has no authenticated payload", empty, error="no_payload")

            too_large_entry = rewrite(temporary / "large-entry.jar", valid,
                                      extra=[("large.bin", b"0" * (16 * 1024 * 1024 + 1))])
            case("expanded individual entry bound", too_large_entry, error="entry_size_limit")
            large_manifest = rewrite(temporary / "large-manifest.jar", valid,
                                     transform=lambda name, data: b"0" * (1024 * 1024 + 1)
                                     if name == "META-INF/MANIFEST.MF" else data)
            case("manifest bounded before JarFile eager parsing", large_manifest, error="entry_size_limit")
            large_signature = rewrite(temporary / "large-signature.jar", valid,
                                      transform=lambda name, data: b"0" * (1024 * 1024 + 1)
                                      if name.endswith(".RSA") else data)
            case("signature block bounded before JarFile eager parsing", large_signature, error="entry_size_limit")
            many = write_jar(temporary / "too-many.jar", [(str(number), b"") for number in range(4097)])
            case("entry count bound", many, error="entry_count_limit")
            long_name = rewrite(temporary / "long-name.jar", valid, extra=[("n" * 4097, b"")])
            case("UTF-8 entry name bound", long_name, error="unsafe_entry_name")
            bomb = write_jar(temporary / "expanded-total.jar", [(str(number), b"0" * (16 * 1024 * 1024)) for number in range(9)])
            case("aggregate expanded byte bound", bomb, error="expanded_size_limit")
            file_limit = temporary / "file-limit.jar"
            with file_limit.open("wb") as stream:
                stream.truncate(64 * 1024 * 1024 + 1)
            case("whole archive byte bound", file_limit, expected_hash="0" * 64, error="archive_limit")
            no_manifest = write_jar(temporary / "no-manifest.jar", [("payload.txt", b"data")])
            case("missing manifest rejected", no_manifest, error="missing_manifest")
            symlink = temporary / "archive-symlink.jar"
            symlink.symlink_to(valid)
            case("archive symlink rejected", symlink, error="invalid_archive")

            candidate = ROOT / "build/mangadex-source-39768470880/evidence/tachiyomi-all.mangadex-v1.6.0.jar"
            if candidate.is_file():
                case("public source rebuild signature inspected with diagnostic debug certificate pin ONLY", candidate,
                     expected_hash="23321c50804ace0b0327117d4a453728b10a65e9383eaa4b962d83aac4afa070",
                     pin="a5086c0c2f8e442846a0ea6df55af9cfc70baba17382029e7903de84731bbe7a")
                report["public_candidate_inspection"] = {
                    "path": str(candidate.relative_to(ROOT)), "sha256": digest(candidate),
                    "trust": "Explicit diagnostic Android Debug leaf certificate, not publisher trust or activation.",
                }
            report["passed"] = all(test["passed"] for test in report["tests"])
            report["test_count"] = len(report["tests"])
    except Exception as error:
        report["failure"] = type(error).__name__ + ": " + str(error)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "tests": len(report["tests"]),
                      "failure": report.get("failure"),
                      "failed_tests": [test["name"] for test in report["tests"] if not test["passed"]],
                      "report": str(REPORT)}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
