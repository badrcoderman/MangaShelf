#!/usr/bin/env python3
"""Check actual stored effects of StageTwoThreeSnapshots in its test simulator."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess


def verify(root, seed):
    library = json.loads((root / "library.json").read_text())
    online = json.loads((root / "Online/online.json").read_text())
    first = "00000200-0000-4000-8000-000000000001"
    second = "00000200-0000-4000-8000-000000000002"
    local = "00000100-0000-4000-8000-000000000001"
    other_local = "00000100-0000-4000-8000-000000000002"
    favorites = "00000300-0000-4000-8000-000000000001"
    reading = "00000300-0000-4000-8000-000000000002"
    chapter = "00000210-0000-4000-8000-000000000001"
    books = {b["id"]: b for b in library["books"]}
    series = {s["series"]["id"]: s for s in online["series"]}
    checks = {
        "all_titles_preserved": len(books) == 3 and len(series) == 2 and all(s["inLibrary"] for s in series.values()),
        "unchanged_mixed_category_save_preserved_each_membership": books[local]["categories"] == [favorites] and books[other_local]["categories"] == [reading],
        "local_progress_and_bookmarks_preserved": books[local]["currentPage"] == 1 and books[local]["bookmarks"] == [1],
        "only_target_title_history_removed": all(p.get("lastReadAt") is None for p in series[first]["progress"].values()) and any(p.get("lastReadAt") is not None for p in series[second]["progress"].values()),
        "source_bookmark_and_read_status_preserved": series[first]["progress"][chapter]["bookmarks"] == [1] and series[first]["progress"][chapter]["read"],
        "completed_download_preserved": len(online["downloads"]) == 1 and online["downloads"][0]["phase"] == "complete",
        "source_chapters_preserved": all(len(s["chapters"]) == 3 for s in series.values()),
    }
    files = [item for item in seed["files"] if item["path"].endswith((".image", ".cbz", "pages.json"))]
    checks["cached_pages_and_archives_byte_identical"] = all(
        (root / item["path"]).is_file() and hashlib.sha256((root / item["path"]).read_bytes()).hexdigest() == item["sha256"]
        for item in files)
    if not all(checks.values()):
        raise ValueError("Stored UI flow checks failed: " + repr({k: v for k, v in checks.items() if not v}))
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-udid", required=True)
    parser.add_argument("--seed", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    seed = json.loads(args.seed.read_text())
    if seed["simulator_udid"] != args.simulator_udid: raise ValueError("Seed belongs to a different simulator")
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator_udid,
                                             "app.mangashelf.reader", "data"], text=True).strip()).resolve(strict=True)
    if "CoreSimulator" not in container.parts or "Application" not in container.parts:
        raise ValueError("An application container in the test simulator is required")
    checks = verify(container / "Library/Application Support/MangaShelf", seed)
    report = dict(passed=True, checked_at=datetime.now(timezone.utc).isoformat(), checks=checks,
                  scope="Synthetic test simulator persistence after real UI actions, not an iPhone or real extension test")
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
