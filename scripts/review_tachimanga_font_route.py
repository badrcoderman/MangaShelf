#!/usr/bin/env python3
"""Verify root theme wiring and null global font overrides, without running AOT."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from review_tachimanga_reader import inspect

METHODS = {
    0x595AA0: "Sorayomi root theme provider and MaterialApp fields",
    0x3AE004: "theme provider light/dark pair",
    0x3C1A3C: "light wrapper calls toTheme",
    0x3AEA08: "dark wrapper calls toTheme",
    0x3AEA60: "toTheme typography and ThemeData argument construction",
    0x3BFC10: "default typography callback",
    0x3BFC8C: "Material 2018 typography with iOS platform",
    0x20BE2C: "Material 2021 typography delegation",
    0x20BCE4: "platform typography branch",
    0x207078: "ThemeData font and platform arguments",
    0x205B78: "TextTheme merge null fast return",
    0x2F45A8: "MaterialApp theme-mode resolution",
}
ANCHORS = [
    (0x595C2C, "bl", 0x1E9D44, "root watches theme scheme provider"),
    (0x3C1A68, "bl", 0x3AEA60, "light wrapper produces ThemeData"),
    (0x3AEA48, "bl", 0x3AEA60, "dark wrapper produces ThemeData"),
    (0x3BFC50, "bl", 0x20BE2C, "default Material 2021 typography path"),
    (0x3BFC68, "bl", 0x3BFC8C, "default Material 2018 typography path"),
    (0x3BFCD4, "bl", 0x20BCE4, "Material 2018 platform selector"),
    (0x20BE78, "bl", 0x20BCE4, "Material 2021 platform selector"),
    (0x3AEBE4, "bl", 0x205B78, "main text theme merges null override"),
    (0x3AEBF4, "bl", 0x205B78, "primary text theme merges null override"),
    (0x205BA4, "b.ne", 0x205BB8, "null merge returns receiver unchanged"),
    (0x3AFA3C, "bl", 0x207078, "construct ThemeData using reviewed descriptor"),
    (0x207C14, "b.ne", 0x207C40, "ThemeData recognizes fontFamily named argument"),
    (0x209BBC, "b.eq", 0x209C00, "null fontFamily skips family replacement"),
]
OPERANDS = [
    (0x595BF8, "ldr", "x0, [x0, #0x33f8]", "root reads theme scheme static field"),
    (0x595C0C, "ldr", "x2, [x2, #0x830]", "theme scheme provider initializer field"),
    (0x595F00, "ldur", "x3, [x0, #7]", "root takes light ThemeData from pair"),
    (0x595F08, "ldur", "x4, [x0, #0xf]", "root takes dark ThemeData from pair"),
    (0x595FBC, "stur", "x1, [x0, #0x5f]", "MaterialApp light theme field"),
    (0x595FC4, "stur", "x1, [x0, #0x67]", "MaterialApp dark theme field"),
    (0x2F4680, "ldur", "x3, [x1, #0x67]", "framework reads dark theme field"),
    (0x2F46B4, "ldur", "x2, [x3, #0x5f]", "framework light theme fallback field"),
    (0x3AEB24, "stur", "x1, [x3, #0x47]", "typography callback context receives iOS platform"),
    (0x3AEB20, "ldr", "x1, [x1, #0x370]", "typography context uses the reviewed iOS enum constant"),
    (0x3AF804, "ldr", "x16, [x16, #0x370]", "ThemeData platform argument uses the same iOS constant"),
    (0x3AF808, "mov", "x17, #0x238", "platform call argument stack offset"),
    (0x3AF80C, "add", "x17, x17, x15", "platform slot is relative to Dart SP x15"),
    (0x3AF810, "stp", "x16, x22, [x17]", "iOS platform and adjacent null argument"),
    (0x3AF898, "stp", "x22, x16, [x15, #0x188]", "fontFamily call argument is Dart null"),
    (0x3AF89C, "stp", "x22, x22, [x15, #0x178]", "package and fontFamilyFallback are null"),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def review(root):
    result = inspect(root, methods=METHODS, selected_anchors=ANCHORS, operand_anchors=OPERANDS,
        filenames=("tachidesk_sorayomi_src_sorayomi.dart", "appearance_controller_theme_controller.dart",
            "flex_color_scheme_src_flex_theme_data_extensions.dart", "flex_color_scheme_src_flex_color_scheme.dart",
            "flutter_src_material_typography.dart", "flutter_src_material_theme_data.dart",
            "flutter_src_material_text_theme.dart", "flutter_src_material_app.dart"),
        pool_markers={"0x5f48": "fontFamily", "0x5eb8": "fontFamilyFallback"})
    own = Path(__file__).parent.parent
    tool = root / "flutter-full/tooling"
    source = tool / "dae-source"
    previous = json.loads((own / "validation/rea/tachimanga-5.1-pool-followup.json").read_text())["provenance"]
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() != previous["commit"]:
        raise ValueError("External source commit changed")
    for name, expected in previous["build_inputs_sha256"].items():
        if sha(source / name) != expected: raise ValueError("External build input changed: " + name)
    helper = own / "scripts/tachimanga_object_details.rs"
    if helper.read_bytes() != (source / "src/bin/object_details.rs").read_bytes():
        raise ValueError("Object details helper differs from build input")
    if sha(tool / "dae-target/release/pool_audit") != previous["binary_sha256"]:
        raise ValueError("Original pool helper changed")
    directory = root / "flutter-full/font-route-followup"
    query_path = directory / "objects.json"
    callbacks_path = directory / "callbacks.json"
    query = json.loads(query_path.read_text())
    callbacks = json.loads(callbacks_path.read_text())
    for data in [query, callbacks]:
        if data["warnings"] or data["target_executed"] is not False or data["pool_entries"] != 71800 or data["iso_function_count"] != 58419:
            raise ValueError("Unexpected snapshot query")
    callback = next(v["value"] for v in callbacks["entries"] if v["offset"] == "0x39aa8")
    if callback.get("entry") != "0x3bfc10": raise ValueError("Typography callback binding changed")
    values = {v["offset"]: v["value"] for v in query["entries"]}
    if values["0xb830"]["field_name"] != "themeSchemeColorProvider" or values["0xb830"]["field_offset_or_id"] * 8 != 0x33F8:
        raise ValueError("Root theme provider mapping changed")
    descriptor = [v.get("integer", v.get("string")) for v in values["0x39af0"]["elements"]]
    if len(descriptor) != 159 or descriptor[:4] != [0, 78, 77, 1] or descriptor[-1] is not None:
        raise ValueError("ThemeData argument descriptor changed")
    positions = dict(zip(descriptor[4:-1:2], descriptor[5:-1:2]))
    if len(positions) != 77 or set(positions.values()) != set(range(1, 78)):
        raise ValueError("Invalid named argument positions")
    expected = {"fontFamily": 0x188, "fontFamilyFallback": 0x180, "package": 0x178, "platform": 0x238}
    offsets = {name: (descriptor[1] - positions[name] - 1) * 8 for name in expected}
    if offsets != expected: raise ValueError("Font/platform stack positions changed")
    # Verify no branch/call or later stack store overwrites the null font slots.
    app = (root / "FlutterApp").read_bytes();cursor=32;segments=[]
    for _ in range(struct.unpack_from('<I',app,16)[0]):
        command,size=struct.unpack_from('<II',app,cursor)
        if command==0x19:
            _,base,_,offset,length=struct.unpack_from('<16sQQQQ',app,cursor+8);segments.append((base,offset,length))
        cursor+=size
    start,end=0x3AF898,0x3AFA3C
    base,offset,_=next(v for v in segments if v[0]<=start and end<=v[0]+v[2])
    decoder=Cs(CS_ARCH_ARM64,CS_MODE_ARM);writes={}
    for ins in decoder.disasm(app[offset+start-base:offset+end-base],start):
        if ins.mnemonic.startswith('b') or ins.mnemonic in ['ret','cbz','cbnz','tbz','tbnz']:
            raise ValueError("Unexpected control transfer in final argument setup")
        if ins.mnemonic in ['mov','add','sub'] and ins.op_str.startswith('x15,'):
            raise ValueError("Stack moved in final argument setup")
        if ins.mnemonic not in ['str','stp']: continue
        match=re.fullmatch(r'(.*), \[x15(?:, #((?:0x[0-9a-f]+|\d+)))?\]',ins.op_str)
        if not match:
            if '[x15' in ins.op_str: raise ValueError("Unreviewed stack store form: " + ins.op_str)
            continue
        slot=int(match[2],0) if match[2] else 0
        for i,register in enumerate(match[1].split(', ')):
            writes[slot+8*i]={"at":hex(ins.address),"register":register}
    for name in ['fontFamily','fontFamilyFallback','package']:
        if writes[offsets[name]]["register"]!='x22': raise ValueError("Font argument overwritten")
    mapping=values['0x254e8'];elements=mapping['map_data']['elements']
    if mapping['map_used']['integer'] != len(elements) or len(elements)%2:
        raise ValueError("Scheme map shape changed")
    keys=[v['string'] for v in elements[::2]]
    if len(keys)!=62 or len(set(keys))!=62 or keys[0]!='default': raise ValueError("Scheme lookup keys changed")
    appearance=json.loads((own/'validation/rea/tachimanga-5.1-appearance.json').read_text())
    old_method=next(m for m in appearance['methods'] if m['address']=='0x20bce4')
    current_method=next(m for m in result['methods'] if m['address']=='0x20bce4')
    if appearance['image_sha256']!=result['image_sha256'] or old_method['code_sha256']!=current_method['code_sha256']:
        raise ValueError("Previous typography evidence does not match this image/method")
    families=appearance['framework_ios_typography']
    if any(v!=['CupertinoSystemDisplay','CupertinoSystemText'] for v in families.values()):
        raise ValueError("Unexpected typography families")
    result['scope']='Root theme wiring and global font arguments; not per-widget or Arabic glyph validation'
    result['theme_data_argument_descriptor']={'total_arguments':78,'named_arguments':77,'positions':positions}
    result['argument_stack_base_register']='x15 (Dart SP)'
    result['font_argument_stack_slots']={name:{'position':positions[name],'offset':hex(offsets[name]),'last_store':writes[offsets[name]]} for name in ['fontFamily','fontFamilyFallback','package']}
    result['root_theme_provider']={'pool_offset':'0xb830','static_table_offset':'0x33f8','name':'themeSchemeColorProvider'}
    result['scheme_lookup_keys']=keys
    result['framework_typography_evidence']={'file':'tachimanga-5.1-appearance.json','sha256':sha(own/'validation/rea/tachimanga-5.1-appearance.json'),'families':families}
    result['queries_sha256']={'objects.json':sha(query_path),'callbacks.json':sha(callbacks_path)}
    result['object_tool_provenance']={'upstream_commit':previous['commit'],'sdk_and_library_inputs':previous['build_inputs_sha256'],
        'helper_sha256':sha(helper),'binary_sha256':sha(tool/'dae-target/release/object_details'),
        'build_log_sha256':sha(tool/'object-details-build.log'),
        'cargo_arguments':['build','--release','--locked','--no-default-features','--bin','object_details'],
        'query_offsets':[v['offset'] for v in query['entries']],
        'limits':{'address_space_bytes':3*1024**3,'cpu_seconds':60,'wall_seconds':90,'cpus':1}}
    result['limits']=['Null global fontFamily is not proof of every descendant TextStyle',
        '62 lookup keys are not a claim that every theme option is visible or entitled',
        'No native-shell font, Arabic fallback glyph, Dynamic Type or screenshot proof',
        'No sample code executed or production app changes']
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('analysis_root',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();r=review(a.analysis_root);a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r['totals']))
