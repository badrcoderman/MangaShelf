#!/usr/bin/env python3
"""Build a standalone review HTML from supplied photos and real native captures.

The output contains user reference images and belongs in build/, never the app.
"""
import argparse
import base64
import html
import json
from pathlib import Path
import struct


def image(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (1242, 2688):
        raise ValueError("Expected a matching 1242x2688 PNG: " + str(path))
    return "data:image/png;base64," + base64.b64encode(data).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference_directory", type=Path)
    parser.add_argument("capture_directory", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    capture = args.capture_directory
    report = json.loads((capture.parent / "capture-report.json").read_text())
    status = json.loads((capture.parent / "run-status.json").read_text())
    app = json.loads((capture.parent / "built-app.json").read_text())
    version = f"MSL {app['version']} ({app['build']})"
    commit = report["collected_from_commit"]
    pairs = []
    for title, ref, native in [
        ("More / المزيد", "IMG_5304.png", "msl-ar-dark-05-more.png"),
        ("About / حول", "IMG_5336.png", "msl-ar-dark-settings-about.png"),
        ("Library menu / قائمة المكتبة", "IMG_5327.png", "msl-ar-dark-library-options.png"),
    ]:
        pairs.append(dict(title=title, reference=image(args.reference_directory / ref), native=image(capture / native)))
    markup = '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width"><title>Shared UI comparison</title>
<style>
body{background:#18181a;color:#e8ebf2;font:16px system-ui;margin:24px}
header{max-width:1000px}button,input{accent-color:#aec6ff;font:inherit}
main{display:flex;gap:24px;align-items:start;flex-wrap:wrap}.panel{position:relative;width:min(414px,90vw);aspect-ratio:414/896}
.panel img{position:absolute;inset:0;width:100%;height:100%}label{display:block;margin:16px 0}
#screens{display:flex;gap:12px;flex-wrap:wrap}h2{font-size:18px}.note{color:#c4c7ce}
</style><header><h1>VERSION</h1><p>Commit COMMIT · capture/test gate: GATE</p>
<p class="note">Supplied Tachimanga photos vs real MSL iOS captures, 414 × 896 points.
This is a review tool; full visual parity remains incomplete. Status bars and project identity differ.
The Library menu actions belong to stage 2. The reference library contains manga; MSL uses its real empty store.</p>
<div id="screens"></div><label>MSL opacity over reference
<input id="opacity" type="range" min="0" max="100" value="50"><output id="value">50%</output></label></header>
<main><section><h2>Reference</h2><div class="panel"><img id="ref" alt="Supplied reference screenshot"></div></section>
<section><h2>Reference + MSL overlay</h2><div class="panel"><img id="under" alt="Reference underlay">
<img id="over" alt="Real native MSL screenshot" style="opacity:.5"></div></section></main>
<script>const pairs=PAIRS;
function select(i){for(const id of ['ref','under'])document.getElementById(id).src=pairs[i].reference;
document.getElementById('over').src=pairs[i].native;}
for(let i=0;i<pairs.length;i++){const b=document.createElement('button');b.textContent=pairs[i].title;
b.onclick=()=>select(i);document.getElementById('screens').append(b);}
document.getElementById('opacity').oninput=e=>{document.getElementById('over').style.opacity=e.target.value/100;
document.getElementById('value').textContent=e.target.value+'%';};select(0);</script></html>'''
    markup = markup.replace("VERSION", html.escape(version)).replace("COMMIT", html.escape(commit))
    markup = markup.replace("GATE", html.escape(status["capture_gate"]))
    markup = markup.replace("PAIRS", json.dumps(pairs).replace("<", "\\u003c"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(markup)
    print(json.dumps(dict(output=str(args.output), pairs=len(pairs), capture_gate=status["capture_gate"], full_visual_parity=False)))


if __name__ == "__main__":
    main()
