#!/usr/bin/env python3
"""Static settings inventory and selected backup UI/default contracts."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from review_tachimanga_reader import inspect

PAGES = {
    0x5E2964: ("settings_settings_screen.dart", "SettingsScreen"),
    0x5D5300: ("general_general_screen.dart", "GeneralScreen"),
    0x523980: ("appearance_screen.dart", "AppearanceScreen"),
    0x5D829C: ("library_settings_screen.dart", "LibrarySettingsScreen"),
    0x5641B0: ("reader_reader_settings_screen.dart", "ReaderSettingsScreen"),
    0x564C18: ("reader_tap_zones_settings_screen.dart", "ReaderTapZonesSettingsScreen"),
    0x5DB2C4: ("reader_toolbar_settings_screen.dart", "ReaderToolbarSettingsScreen"),
    0x5DB6B4: ("reader_advanced_screen.dart", "ReaderAdvancedScreen"),
    0x53A584: ("download_setting_screen.dart", "DownloadSettingScreen"),
    0x570DCC: ("security_setting_screen.dart", "SecuritySettingScreen"),
    0x530D1C: ("browse_settings_screen.dart", "BrowseSettingsScreen"),
    0x5CBAF4: ("advanced_screen.dart", "AdvancedScreen"),
    0x5E4748: ("storage_storage_screen.dart", "StorageScreen"),
    0x57B5E0: ("tracker_settings_screen.dart", "TrackerSettingsScreen"),
    0x529644: ("backup_screen_v2.dart", "BackupScreenV2"),
    0x52A480: ("backup_screen_v2.dart", "BackupScreenV2 content builder"),
}
METHODS = {address: "inventory of " + item[1] for address, item in PAGES.items()}
METHODS.update({
    0x393DF4: "autoBackup preference default, separate from frequency",
    0x397E30: "retention default and persisted key",
    0x3974F8: "shared integer preference initialization and fallback",
    0x3C239C: "frequency preference default and persisted key",
    0x3C2470: "shared enum preference initialization",
    0x5D045C: "frequency display and fallback",
    0x5D08D0: "frequency selection options array",
    0x5D0DCC: "retention display and fallback",
    0x4B3F18: "retention selection options array",
    0x52B890: "restore confirmation and filename suffix guard",
    0x52C5E4: "file import routing between restore and proto import",
    0x52DA60: "backup file picker to restore confirmation",
    0x5D00A8: "restore confirmation content and autoBackup preference",
    0x52BE34: "confirm restore action and success dialog",
    0x52C2D4: "serialize BACKUP:RESTORE request",
    0x52D1A0: "pre-import backup and protobuf restore",
    0x52DD00: "manual backup and created dialog",
})
ANCHORS = [
    (0x393E24, "bl", 0x391BB4, "boolean autoBackup preference initialization"),
    (0x397E60, "bl", 0x3974F8, "retention uses shared integer preference initializer"),
    (0x397680, "b.ne", 0x397690, "shared integer initializer returns saved value when available"),
    (0x3C23D8, "bl", 0x3C2470, "frequency uses enum preference initializer"),
    (0x5D0540, "b.ne", 0x5D0550, "frequency display uses saved value when available"),
    (0x5D0E4C, "b.ne", 0x5D0E58, "retention display uses saved value when available"),
    (0x52B9B4, "bl", 0x1E218, "test zip suffix on restore filename"),
    (0x52B9EC, "bl", 0x1E218, "test tmb suffix after zip did not match"),
    (0x52BA50, "bl", 0x3FA18C, "show error if filename matches neither accepted suffix"),
    (0x52C76C, "bl", 0x1E218, "import picker tests zip suffix"),
    (0x52C798, "bl", 0x1E218, "import picker tests tmb suffix"),
    (0x52C7E8, "bl", 0x52B890, "matching Tachimanga filename goes to restore confirmation"),
    (0x52C83C, "bl", 0x52C850, "other filename goes to import confirmation"),
    (0x52DBBC, "bl", 0x52B890, "backup picker goes to restore confirmation"),
    (0x52BF5C, "bl", 0x52C2D4, "confirmed restore sends restore action"),
    (0x52BF88, "bl", 0x52BF9C, "restore continuation opens restored dialog"),
    (0x52D298, "bl", 0x482BDC, "import path requests pre-import backup"),
    (0x52D33C, "bl", 0x52D3F0, "import path calls ProtoBackupRepository.restoreBackup"),
    (0x52DD9C, "bl", 0x482BDC, "manual create requests backup action"),
    (0x52DE44, "bl", 0x52DE58, "create continuation opens created dialog"),
]
OPERANDS = [
    (0x393E18, "add", "x3, x22, #0x20", "autoBackup boolean default true"),
    (0x397E54, "mov", "x3, #4", "retention default tagged Smi two"),
    (0x397688, "ldur", "x2, [x1, #0x27]", "shared integer initializer fallback reads supplied default"),
    (0x5D0E50, "mov", "x3, #2", "retention display fallback integer two"),
    (0x3C23CC, "ldr", "x5, [x5, #0xd60]", "frequency default is off enum constant"),
    (0x5D097C, "ldr", "x0, [x0, #0x408]", "frequency selection reads same enum array"),
    (0x4B3FF4, "ldr", "x0, [x0, #0x3b8]", "retention selection array constant"),
    (0x52C354, "ldr", "x16, [x16, #0x638]", "autoBackup request key"),
    (0x52C3A0, "ldr", "x16, [x16, #0x5d0]", "BACKUP:RESTORE command constant"),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def review(root):
    files = tuple(dict.fromkeys([item[0] for item in PAGES.values()] + [
        "backup2_controller_backup_controller.dart", "auto_backup_controller.dart",
        "global_providers_global_providers.dart", "auto_backup_frequency_tile.dart", "auto_backup_limit_tile.dart"]))
    result = inspect(root, methods=METHODS, selected_anchors=ANCHORS,
        operand_anchors=OPERANDS, filenames=files, allowed_external_branches=(0x2F984,),
        pool_markers={"0x38b88": "autoBackupLimit", "0x38b60": "autoBackupFrequency",
                      "0x17638": "autoBackup", "0x175d0": "BACKUP:RESTORE",
                      "0x113d8": ".zip", "0x113e0": ".tmb", "0x17698": "Tachimanga"})
    export = root / "flutter-full/dae-export-single-cpu/text"
    refs_path = root / "flutter-full/app-pool-references.json"
    refs = json.loads(refs_path.read_text())
    inventory = {}
    for address, (_, page) in PAGES.items():
        controls = []
        for ref in refs:
            if ref["function"] != hex(address):
                continue
            match = re.match(r'Obj!([^@]+)@([0-9a-f]+)', ref["value"])
            if match and any(token in match[1] for token in ["Tile", "Switch", "Selector", "Slider"]):
                controls.append({"at": ref["address"], "pool_offset": ref["pool_offset"],
                                 "class": match[1], "reference": "0x" + match[2]})
        inventory[hex(address)] = {"page": page, "constant_control_references": controls}
    query_path = root / "flutter-full/settings-followup/backup-settings-pool.json"
    query = json.loads(query_path.read_text())
    if (query["warnings"] or query["target_executed"] is not False or query["pool_entries"] != 71800
            or query["snapshot_hash"] != "f956f595844a2f845a55707faaaa51e4"):
        raise ValueError("Unreviewed pool query")
    provenance = json.loads((Path(__file__).parent.parent /
        "validation/rea/tachimanga-5.1-pool-followup.json").read_text())["provenance"]
    if sha(root / "flutter-full/tooling/dae-target/release/pool_audit") != provenance["binary_sha256"]:
        raise ValueError("Pool query tool differs from reviewed binary")
    values = {item["offset"]: item["value"] for item in query["entries"]}
    objects = (export / "objs.txt").read_text()
    frequency = []
    for value in values["0x25408"]["elements"]:
        reference = value["reference"][2:]
        block = re.search(r'^Obj!FrequencyEnum@' + re.escape(reference) + r'[^\n]*\n(.*?)(?=\n\n|\Z)', objects, re.M | re.S)
        found = re.search(r'off_8: int\((0x[0-9a-f]+)\),\s*off_10: "([^"\n]+)"', block[1]) if block else None
        if not found:
            raise ValueError("Frequency enum object absent from original object index")
        frequency.append({"index": int(found[1], 16), "enum_name": found[2], "reference": value["reference"]})
    if [item["enum_name"] for item in frequency] != ["off", "update_6hour", "update_12hour",
            "update_24hour", "update_48hour", "update_weekly"]:
        raise ValueError("Frequency enum options changed")
    if values["0x10d60"]["reference"] != frequency[0]["reference"]:
        raise ValueError("Frequency default is not off")
    retention = [item["integer"] for item in values["0x253b8"]["elements"]]
    if retention != [2, 3, 4, 5]:
        raise ValueError("Retention options changed")
    result["scope"] = "Settings page constant-control inventory and selected backup UI/default contracts"
    result["page_inventory"] = inventory
    result["backup_preferences"] = {"frequency_key": "autoBackupFrequency", "frequency_default": "off",
        "frequency_options": frequency, "retention_key": "autoBackupLimit", "retention_default": 2,
        "retention_options": retention, "pre_restore_backup_key": "autoBackup", "pre_restore_backup_default": True}
    result["pool_fields"] = {offset: value["field_name"] for offset, value in values.items() if value.get("kind") == "Field"}
    result["pool_query_sha256"] = sha(query_path)
    result["pool_tool_provenance"] = "tachimanga-5.1-pool-followup.json"
    result["query_offsets"] = [item["offset"] for item in query["entries"]]
    result["export_files_sha256"].update({"../text/objs.txt": sha(export / "objs.txt"),
                                         "app-pool-references.json": sha(refs_path)})
    result["limits"] = ["Inventory lists constant object references, not every dynamic row or its visual order",
        "Presence in a branch does not prove visibility, entitlement or runtime effect",
        "Only selected backup preferences have reviewed defaults here",
        "File extension/name routing is not content validation or proof that restore succeeds",
        "External 0x2f984 branches are recorded async exits, not executed",
        "No original source recovery, production changes, or iPhone UI equivalence test"]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = review(args.analysis_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["totals"]))
