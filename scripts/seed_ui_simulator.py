#!/usr/bin/env python3
"""Seed original, synthetic library data in an explicitly booted test simulator.

Never bundled in the app. The normal empty-store capture runs first. These files
exercise the production persistence and views without a live source or artwork.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import uuid
import zipfile
import zlib


def identifier(group, index):
    return str(uuid.UUID(f"{group:08d}-0000-4000-8000-{index:012d}")).upper()


def png(index, page=0):
    width, height = 240, 320
    palettes = ((42, 115, 136), (112, 62, 133), (78, 116, 70), (57, 78, 145), (138, 82, 54))
    base = palettes[index % len(palettes)]
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            band = 20 if (x // 32 + y // 40 + page) % 3 == 0 else 0
            inset = 18 < x < width - 18 and 26 < y < height - 26
            pixels.extend(min(255, c + y // 5 + band) if inset else max(0, c - 24) for c in base)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def seed(container, now):
    root = container / "Library/Application Support/MangaShelf"
    for file, keys in ((root / "library.json", ("books", "repositories")),
                       (root / "Online/online.json", ("series", "downloads"))):
        if file.exists() and any(json.loads(file.read_text()).get(key) for key in keys):
            raise ValueError("Refusing to overwrite an existing populated store: " + str(file))
    categories = [{"id": identifier(300, 1), "name": "Favorites"},
                  {"id": identifier(300, 2), "name": "Reading"}]
    books = []
    for index, title in enumerate(("River trail", "Night city", "Garden notes")):
        book_id = identifier(100, index + 1)
        book = dict(id=book_id, title=title, pageCount=3, currentPage=1 if index == 0 else 0,
                    completed=False, bookmarks=[1] if index == 0 else [],
                    categories=[categories[index % 2]["id"]], addedAt=now - 86400 * (index + 1),
                    totalReadingTime=245 if index == 0 else 0, isDeleted=False)
        if index == 0:
            book["lastReadAt"] = now - 120
        books.append(book)
        archive_path = root / "Books" / (book_id + ".cbz")
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for page in range(3):
                info = zipfile.ZipInfo(f"page{page + 1}.png", (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, png(index, page))
    # Metadata only: no JAR, no invented trust record, and no executable fixture.
    repository = dict(id=identifier(400, 1), url="https://example.invalid/index.min.json", fetchedAt=now,
                      index=dict(name="UI test repository", extensions=[
                          dict(name="UI test Arabic", packageName="test.ui.arabic", versionName="1.0.0", versionCode=1,
                               sources=[dict(id="900000001", name="UI test source", language="ar",
                                             homeURL="https://example.invalid")]),
                          dict(name="UI test English", packageName="test.ui.english", versionName="1.0.0", versionCode=1,
                               sources=[dict(id="900000002", name="UI test English", language="en",
                                             homeURL="https://example.invalid")]),
                      ], hasEmbeddedList=True))
    write_json(root / "library.json", dict(schemaVersion=1, books=books, categories=categories,
                                          repositories=[repository],
                                          defaultDisplayOptions=dict(sortOption="added", sortAscending=False,
                                                                     displayMode="gridComfortable", columnCount=2)))
    series = []
    downloads = []
    for index, title in enumerate(("Mountain route", "Star atlas")):
        series_id = identifier(200, index + 1)
        chapters = [dict(id=identifier(210 + index, number), seriesID=series_id,
                         title=f"Route {number}", number=str(number), language="ar", group="UI test group",
                         publishedAt=now - 86400 * number) for number in (3, 2, 1)]
        progress = {chapters[2]["id"]: dict(page=2, pageCount=3, read=True, bookmarks=[1], lastReadAt=now - 600)}
        if index == 0:
            progress[chapters[1]["id"]] = dict(page=1, pageCount=3, read=False, bookmarks=[], lastReadAt=now - 60)
        series.append(dict(series=dict(id=series_id, title=title,
                                       synopsis="Original synthetic metadata used only by simulator UI tests.",
                                       authors=["UI test author"], tags=["Adventure", "Travel"], status="ongoing",
                                       sourceID="mangadex", sourceLanguage="ar"),
                           inLibrary=True, categories=[categories[0]["id"]], chapters=chapters,
                           progress=progress, addedAt=now - 3600 * (index + 1), checkedAt=now, newChapterIDs=[]))
        for chapter in chapters:
            directory = root / "Online/Pages" / chapter["id"]
            write_json(directory / "pages.json", dict(chapterID=chapter["id"], urls=[
                f"https://example.invalid/page-{page}.png" for page in range(3)]))
            for page in range(3):
                (directory / f"{page}.image").write_bytes(png(index + 3, page))
        if index == 0:
            downloads.append(dict(chapter=chapters[2], phase="complete", finishedPages=3, totalPages=3, addedAt=now))
    write_json(root / "Online/online.json", dict(version=1, series=series, downloads=downloads))
    files = [{"path": str(path.relative_to(root)), "bytes": path.stat().st_size,
              "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
             for path in sorted(root.rglob("*")) if path.is_file() and (
                 path.name in {"library.json", "online.json", "pages.json"} or path.suffix in {".image", ".cbz"})]
    return dict(local_books=len(books), saved_series=len(series), chapters=sum(len(s["chapters"]) for s in series),
                categories=len(categories), repositories=1, downloaded_chapters=len(downloads), files=files,
                scope="synthetic data in test simulator only; no real source, extension trust, or reference artwork")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-udid", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
    matches = [d for values in devices["devices"].values() for d in values if d["udid"] == args.simulator_udid]
    if len(matches) != 1 or matches[0].get("state") != "Booted" or not matches[0].get("isAvailable"):
        raise SystemExit("An explicitly booted, available simulator is required.")
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator_udid,
                                             "app.mangashelf.reader", "data"], text=True).strip()).resolve(strict=True)
    if "CoreSimulator" not in container.parts or "Application" not in container.parts:
        raise SystemExit("The data container is not a CoreSimulator application container.")
    now = datetime.now(timezone.utc).timestamp() - datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
    report = seed(container, now)
    report.update(simulator_udid=args.simulator_udid, created_at=datetime.now(timezone.utc).isoformat())
    write_json(args.report, report)
    print(json.dumps({k: v for k, v in report.items() if k != "files"}))


if __name__ == "__main__":
    main()
