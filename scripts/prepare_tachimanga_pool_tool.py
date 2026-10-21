#!/usr/bin/env python3
"""Add a bounded read-only pool query to pinned external dae source.

The helper exposes parsed arrays/functions plus Double bits that the stock text
formatter omits. Its side reader does not change the original fill cursor.
"""
import hashlib
from pathlib import Path
import subprocess
import sys

COMMIT = "9f65eeaef92b9709b169c2a9a503a89bbdd14b72"
FILES = {
    "src/engine/snapshot.rs": "ebe1625eb890fe511ce4ac551b2cc90938791da331ad3a536f67dd2be97b87d0",
    "src/engine/fill.rs": "4b762d15170a0f787af6513750cef496d5a59c99c2598f69cc36d32169bdb40a",
}


def prepare(root, helper):
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() != COMMIT:
        raise ValueError("Wrong dae source commit")
    original = {}
    for name, expected in FILES.items():
        data = (root / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Changed or already patched source: " + name)
        original[name] = data.decode()
    destination = root / "src/bin/pool_audit.rs"
    if destination.exists():
        raise ValueError("Helper destination already exists")
    helper_data = helper.read_bytes()
    snapshot = original["src/engine/snapshot.rs"]
    field = "    pub mint_values: HashMap<u64, i64>,"
    init = "            mint_values: HashMap::new(),"
    if snapshot.count(field) != 1 or snapshot.count(init) != 2:
        raise ValueError("Snapshot layout drift")
    snapshot = snapshot.replace(field, field + "\n    /// Analysis-only: original IEEE-754 Double bits and serialized positions.\n    pub double_bits: HashMap<u64, (u64, usize, usize)>,")
    snapshot = snapshot.replace(init, init + "\n            double_bits: HashMap::new(),")
    fill = original["src/engine/fill.rs"]
    before = "        for k in 0..count {\n            for v in ctx.iter_mut() {"
    capture = '''        // Read-only side capture; the original fill reader still consumes
        // exactly the original DSL. Restricted to the reviewed Double layout.
        if profile.class_id_names.get(&cid.to_string()).map(String::as_str) == Some("Double") {
            let mut capture = Reader::new(snap.data);
            capture.pos = r.pos;
            for k in 0..count {
                let begin = capture.pos;
                let bits = capture.read_signed().map_err(|e| format!("double capture: {e:?}"))? as u64;
                snap.double_bits.insert(start_ref + k, (bits, begin, capture.pos));
            }
        }
'''
    if fill.count(before) != 1:
        raise ValueError("Fill layout drift")
    # All prerequisites and replacements are validated before the first write.
    (root / "src/engine/snapshot.rs").write_text(snapshot)
    (root / "src/engine/fill.rs").write_text(fill.replace(before, capture + before))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(helper_data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare_tachimanga_pool_tool.py DAE_SOURCE")
    prepare(Path(sys.argv[1]), Path(__file__).with_name("tachimanga_pool_audit.rs"))
    print("Prepared read-only pool query; build the helper without default features")
