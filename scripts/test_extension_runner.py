#!/usr/bin/env python3
"""Build and exercise the experimental Java runner with project-authored fixtures only."""
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "validation/extension-runner-host-results.json"
RUNNER = ROOT / "runtime-probe/src/mangashelf/runtime/ExtensionRunner.java"
HOST = ROOT / "runtime-probe/tests/mangashelf/runtime/RunnerHost.java"
FIXTURE = ROOT / "runtime-probe/tests/fixtures/SyntheticSources.java"


def main():
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "command": "python3 scripts/test_extension_runner.py",
        "scope": "Host Java runner, synthetic project fixtures only; no specimen execution or iOS compatibility claim.",
        "inputs": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (RUNNER, HOST, FIXTURE)},
        "commands": [], "tests": [], "passed": False,
    }

    def run(command, **kwargs):
        entry = {"argv": command}
        report["commands"].append(entry)
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30, **kwargs)
        except subprocess.TimeoutExpired as error:
            entry["timeout_seconds"] = 30
            entry["stdout"] = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or ""
            entry["stderr"] = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or ""
            raise RuntimeError("Host command timed out: " + command[0]) from error
        entry.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
        if result.returncode:
            raise RuntimeError("Host command failed: " + " ".join(command))
        return result

    try:
        javac, java = shutil.which("javac"), shutil.which("java")
        if not javac or not java:
            raise RuntimeError("A JDK with javac and java is required; no test pass can be claimed.")
        run([java, "-version"])
        with tempfile.TemporaryDirectory(prefix="mangashelf-runner-") as directory:
            temporary = Path(directory)
            classes, fixture_classes = temporary / "host", temporary / "fixture"
            classes.mkdir(); fixture_classes.mkdir()
            run([javac, "--release", "8", "-encoding", "UTF-8", "-Xlint:all,-options", "-Werror", "-d", str(classes), str(RUNNER), str(HOST)])
            run([javac, "--release", "8", "-encoding", "UTF-8", "-Xlint:all,-options", "-Werror", "-d", str(fixture_classes), str(FIXTURE)])
            archive = temporary / 'synthetic "source" \\ archive.jar'
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as jar:
                for path in sorted(fixture_classes.rglob("*.class")):
                    jar.write(path, path.relative_to(fixture_classes).as_posix())

            cases = []

            def case(name, action, payload, *, error=None, status=None, expected=None):
                encoded = json.dumps(payload, ensure_ascii=True) if isinstance(payload, dict) else payload
                cases.append((name, action, encoded, error, status, expected))

            def load(name, package, kind="Good", source_id=None, **overrides):
                payload = {"package": package, "path": str(archive),
                           "mainClass": "mangashelf.fixtures.SyntheticSources$" + kind}
                if source_id is not None:
                    payload["sourceId"] = source_id
                payload.update(overrides)
                case(name, "load", payload, status="loaded")

            case("ping", "ping", None, status="ok")
            case("null action is explicit error", None, {}, error="invalid_action")
            case("unknown action escapes correctly", 'unknown"\\\n', {}, error="unknown_action")
            for action in ("popular", "latest", "search", "details", "chapters", "pages"):
                case("missing source / " + action, action, {"sourceId": "absent", "url": "/x"}, error="source_not_loaded")
            case("load without mainClass cannot succeed", "load", {"package": "absent", "path": str(archive)}, error="invalid_request")
            case("failed load registers no source", "popular", {"sourceId": "absent"}, error="source_not_loaded")
            case("missing archive", "load", {"package": "absent", "path": str(archive) + ".missing", "mainClass": "missing"}, error="load_failed")
            case("missing class", "load", {"package": "absent", "path": str(archive), "mainClass": "missing"}, error="load_failed")
            case("constructor failure", "load", {"package": "absent", "path": str(archive), "mainClass": "mangashelf.fixtures.SyntheticSources$BrokenConstructor"}, error="load_failed")
            case("constructor failure registers no source", "popular", {"sourceId": "absent"}, error="source_not_loaded")
            load("successful retry after failed load", "absent", source_id="numeric-source-123")
            case("package is not silently a source alias", "popular", {"sourceId": "absent"}, error="source_not_loaded")
            popular = {"mangas": [{"id": "fixture-popular", "title": "Synthetic Popular", "url": "/fixture/manga", "coverURL": None}], "hasNextPage": True}
            source = "numeric-source-123"
            case("explicit source identifier works", "popular", {"sourceId": source}, expected=popular)
            case("duplicate package rejected", "load", {"package": "absent", "path": str(archive), "mainClass": "mangashelf.fixtures.SyntheticSources$Good"}, error="already_loaded")
            case("duplicate source rejected", "load", {"package": "another", "sourceId": source, "path": str(archive), "mainClass": "mangashelf.fixtures.SyntheticSources$Good"}, error="source_conflict")
            case("failed replacements preserve existing source", "popular", {"sourceId": source}, expected=popular)
            for page, code in ((2, "invocation_failed"), (3, "invalid_response"), (4, "invalid_response"),
                               (5, "invalid_response"), (6, "invalid_response"), (7, "invalid_response"),
                               (9, "invalid_response"), (10, "invalid_response"), (11, "invalid_response"),
                               (12, "invalid_response"), (13, "invocation_failed")):
                case("popular explicit failure / page " + str(page), "popular", {"sourceId": source, "page": page}, error=code)
            empty_page = {"mangas": [], "hasNextPage": False}
            case("genuine empty popular response stays empty", "popular", {"sourceId": source, "page": 8}, expected=empty_page)
            latest = {"mangas": [{"id": "fixture-latest", "title": "Synthetic Latest", "url": "/fixture/latest"}], "hasNextPage": False}
            case("latest calls its own method", "latest", {"sourceId": source, "page": 1}, expected=latest)

            titles = [{"id": 'fixture/"\\\t', "title": 'عربي 📚 "quoted" \\ newline\n', "coverURL": None, "url": '/manga/"\\'}]
            title_page = {"mangas": titles, "hasNextPage": False}
            case("escaped Unicode query reaches source intact", "search", {"sourceId": source, "page": 1, "query": json.dumps(title_page, ensure_ascii=True)}, expected=title_page)
            case("empty search response stays empty", "search", {"sourceId": source, "query": json.dumps(empty_page)}, expected=empty_page)
            for items in ([], titles, titles * 3):
                for has_next in (False, True):
                    reply = {"mangas": items, "hasNextPage": has_next}
                    case("source pagination preserved / " + str(len(items)) + " / " + str(has_next),
                         "search", {"sourceId": source, "query": json.dumps(reply)}, expected=reply)
            case("search invocation failure", "search", {"sourceId": source, "query": "throw"}, error="invocation_failed")
            for query in ("not JSON", "{}", "[{}]", "[null]", "null", "[true]", '[{"id":"a","title":"t","url":false}]',
                          '{"mangas":[]}', '{"mangas":[],"hasNextPage":null}',
                          '{"mangas":[],"hasNextPage":1}', '{"mangas":[],"hasNextPage":"false"}',
                          '{"hasNextPage":false}', '{"mangas":null,"hasNextPage":false}',
                          '{"mangas":[{"id":"a","title":"t","url":false}],"hasNextPage":false}'):
                case("invalid search reply / " + query, "search", {"sourceId": source, "query": query}, error="invalid_response")
            case("details from synthetic source", "details", {"sourceId": source, "url": "good"}, expected={
                "title": "Synthetic Details", "author": None, "artist": None, "description": "Fixture only",
                "genre": ["Test"], "status": "ongoing", "coverURL": None})
            for url in ("null", "wrong-shape", "wrong-genre", "malformed"):
                case("invalid details / " + url, "details", {"sourceId": source, "url": url}, error="invalid_response")
            chapter = [{"id": "fixture-chapter", "name": "Synthetic Chapter", "url": "/fixture/chapter", "chapterNumber": 1.5,
                        "dateUpload": 1700000000, "scanlator": None}]
            case("chapters from synthetic source", "chapters", {"sourceId": source, "url": "good"}, expected=chapter)
            case("genuine empty chapters response", "chapters", {"sourceId": source, "url": "empty"}, expected=[])
            for url in ("null", "wrong-shape", "infinite-number", "fractional-date", "overflow-date"):
                case("invalid chapters / " + url, "chapters", {"sourceId": source, "url": url}, error="invalid_response")
            case("pages from synthetic source", "pages", {"sourceId": source, "url": "good"}, expected=[{
                "index": 0, "url": "/fixture/page", "imageURL": "https://fixture.invalid/page.png"}])
            for url in ("null", "wrong-shape", "empty", "negative-index", "overflow-index"):
                case("invalid pages / " + url, "pages", {"sourceId": source, "url": url}, error="invalid_response")
            for action in ("details", "chapters", "pages"):
                case("invocation failure / " + action, action, {"sourceId": source, "url": "throw"}, error="invocation_failed")
            for page in (0, -1, 10001, 1.5, True, "1", None, 9223372036854775808):
                case("invalid page field / " + repr(page), "popular", {"sourceId": source, "page": page}, error="invalid_request")
                case("invalid latest page field / " + repr(page), "latest", {"sourceId": source, "page": page}, error="invalid_request")
            for payload in ('[]', 'null', '{} trailing', '{"sourceId":"x","sourceId":"y"}', '{"sourceId":"\\ud800"}',
                            '{"sourceId":"\\uZZZZ"}', '{"sourceId":"\\x41"}', '{"page":01}', '{"page":+1}', '{"page":NaN}',
                            '{"sourceId":"x",}', '{"sourceId":', '"unterminated', ' ' * (256 * 1024 + 1)):
                case("malformed/oversized request " + str(len(cases)), "popular", payload, error="invalid_request")
            case("depth limit", "ping", '{"x":' + '[' * 40 + 'null' + ']' * 40 + '}', error="invalid_request")
            case("value count limit", "ping", '{"x":[' + ','.join(['0'] * 100_001) + ']}', error="invalid_request")
            case("escaped field name is decoded", "popular", '{"source\\u0049d" : "numeric-source-123", "page" : 1}', expected=popular)
            case("key text inside query cannot spoof sourceId", "search", {"query": '"sourceId":"numeric-source-123"'}, error="invalid_request")
            load("load unsupported source", "no-methods", "NoMethods")
            for action in ("popular", "latest", "search", "details", "chapters", "pages"):
                case("unsupported method / " + action, action, {"sourceId": "no-methods", "url": "good"}, error="unsupported_method")
            load("load wrong-signature source", "wrong-signature", "WrongSignature")
            for action in ("popular", "search"):
                case("no loose reflection matching / " + action, action, {"sourceId": "wrong-signature"}, error="unsupported_method")
            case("classpath loader need not be URLClassLoader", "load", {"package": "classpath", "mainClass": "mangashelf.runtime.RunnerHost$ClasspathSource"}, status="loaded")
            case("classpath fixture executes", "popular", {"sourceId": "classpath"}, expected=empty_page)
            case("unload source by package", "unload", {"package": "absent"}, status="unloaded")
            case("unloaded source no longer works", "popular", {"sourceId": source}, error="source_not_loaded")
            case("unknown unload cannot claim success", "unload", {"package": "absent"}, error="not_loaded")
            load("source identifier reusable after unload", "another", source_id=source)
            case("reloaded source works", "popular", {"sourceId": source}, expected=popular)

            def encode(value):
                return "-" if value is None else base64.b64encode(value.encode("utf-8")).decode("ascii")

            requests = "".join(encode(action) + "\t" + encode(payload) + "\n" for _, action, payload, _, _, _ in cases)
            output = run([java, "-Xmx128m", "-cp", str(classes), "mangashelf.runtime.RunnerHost"], input=requests)
            replies = output.stdout.splitlines()
            if len(replies) != len(cases):
                raise AssertionError(f"Expected {len(cases)} replies, received {len(replies)}")
            for (name, _, _, code, status, expected), reply in zip(cases, replies):
                try:
                    decoded = json.loads(base64.b64decode(reply, validate=True).decode("utf-8"))
                    if code:
                        passed = isinstance(decoded, dict) and decoded.get("code") == code and bool(decoded.get("error")) and "status" not in decoded
                    elif status:
                        passed = isinstance(decoded, dict) and decoded.get("status") == status and "error" not in decoded
                        if status == "loaded": passed = passed and decoded.get("hasInstance") is True
                    else:
                        passed = decoded == expected
                    report["tests"].append({"name": name, "passed": passed, "response": decoded})
                except Exception as error:
                    report["tests"].append({"name": name, "passed": False, "failure": str(error)})
            report["passed"] = all(test["passed"] for test in report["tests"])
            report["test_count"] = len(cases)
    except Exception as error:
        report["failure"] = str(error)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "tests": len(report["tests"]), "report": str(REPORT),
                      "failure": report.get("failure"), "failed_tests": [t["name"] for t in report["tests"] if not t["passed"]]}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
