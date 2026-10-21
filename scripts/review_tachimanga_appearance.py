#!/usr/bin/env python3
"""Review theme defaults, seed colors and framework font fallback as static data."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from review_tachimanga_reader import inspect
from review_tachimanga_pool import signed_bits

METHODS = {
    0x393D80: "pure black preference default",
    0x395A9C: "theme key default",
    0x3A4204: "blend level default",
    0x3AE004: "light/dark theme composition and app bar override",
    0x3C5A34: "system/light/dark preference default",
    0x3C1A3C: "Flex light theme wrapper",
    0x3AEA08: "Flex dark theme wrapper",
    0x3C1648: "FlexSchemeColor primary field mapping",
    0x3AE400: "AppBarTheme copyWith argument handling",
    0x20BCE4: "framework platform typography selection",
    0x73BD98: "Color red channel accessor",
    0x73BDA0: "Color green channel accessor",
    0x73BC10: "Color blue channel accessor",
    0x773B00: "Color alpha channel accessor",
    0x528554: "pure black settings control",
    0x528864: "theme selector control",
    0x5CDB18: "blend level control",
}
ANCHORS = [
    (0x393DB0, "bl", 0x391BB4, "initialize saved pure-black boolean"),
    (0x395AD0, "bl", 0x3950FC, "initialize saved theme key"),
    (0x3A4238, "bl", 0x3A3A68, "initialize saved blend number"),
    (0x3C5A70, "bl", 0x3C5AE4, "initialize saved theme mode enum"),
    (0x3AE0C0, "b.ne", 0x3AE0CC, "use saved blend when available"),
    (0x3AE120, "b.ne", 0x3AE12C, "use saved pure black when available"),
    (0x3AE140, "bl", 0x7855BC, "lookup selected scheme in constant map"),
    (0x3AE148, "b.ne", 0x3AE154, "fallback scheme if key missing"),
    (0x3AE1B4, "bl", 0x3C1A3C, "compose light theme"),
    (0x3AE1D0, "tbnz", 0x3AE1DC, "normal dark mode keeps requested blend"),
    (0x3AE1FC, "tbnz", 0x3AE20C, "pure black selects explicit scaffold color"),
    (0x3AE2D4, "bl", 0x3AEA08, "compose dark theme"),
    (0x3AE300, "bl", 0x3AE400, "light theme app bar override"),
    (0x3AE340, "bl", 0x3AE400, "dark theme app bar override"),
    (0x3C1754, "b.ne", 0x3C1784, "recognize named primary parameter"),
    (0x3C18CC, "b.ne", 0x3C18D8, "missing primary override falls back to field"),
    (0x20BD04, "b.ne", 0x20BD1C, "non-iOS platform continues to other typography"),
    (0x20BD18, "b", 0x20BDC4, "iOS selects Cupertino typography pair"),
]
OPERANDS = [
    (0x393DA4, "add", "x3, x22, #0x30", "pure black defaults to false"),
    (0x3AE0C4, "fmov", "d0, #10.00000000", "blend fallback ten"),
    (0x3AE124, "add", "x3, x22, #0x30", "pure black fallback false"),
    (0x3AE160, "ldur", "x2, [x0, #0x17]", "light scheme group logical offset 0x18"),
    (0x3AE1C4, "ldur", "x2, [x0, #0x1f]", "dark scheme group logical offset 0x20"),
    (0x3AE1D4, "mov", "x1, #0", "pure black sets dark blend to zero"),
    (0x3C18D0, "ldur", "x4, [x1, #7]", "primary is logical field offset eight"),
    (0x73BD98, "ldur", "d0, [x1, #0xf]", "red is logical offset 0x10"),
    (0x73BDA0, "ldur", "d0, [x1, #0x17]", "green is logical offset 0x18"),
    (0x73BC10, "ldur", "d0, [x1, #0x1f]", "blue is logical offset 0x20"),
    (0x773B00, "ldur", "d0, [x1, #7]", "alpha is logical offset eight"),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def review(root):
    result = inspect(root, methods=METHODS, selected_anchors=ANCHORS, operand_anchors=OPERANDS,
        filenames=("appearance_controller_theme_controller.dart", "theme_mode_tile.dart",
            "flex_color_scheme_src_flex_theme_data_extensions.dart", "flex_color_scheme_src_flex_scheme_color.dart",
            "flutter_src_material_app_bar_theme.dart", "flutter_src_material_typography.dart", "dart_ui.dart",
            "pure_black_dark_mode_tile.dart", "theme_select_tile.dart", "blend_level_slider_tile.dart"),
        pool_markers={"0x3a110": "themeBlendLevel", "0x3a118": "themePureBlackDarkMode", "0x3a120": "themeKey",
                      "0x38c08": "themeMode", "0x10d08": "default", "0xc020": "primary"})
    own = Path(__file__).parent.parent
    directory = root / "flutter-full/appearance-followup"
    query_path = directory / "appearance-pool.json"
    query = json.loads(query_path.read_text())
    if (query["warnings"] or query["target_executed"] is not False or query["pool_entries"] != 71800
            or query["snapshot_hash"] != "f956f595844a2f845a55707faaaa51e4"):
        raise ValueError("Wrong snapshot query")
    provenance = json.loads((own / "validation/rea/tachimanga-5.1-pool-followup.json").read_text())["provenance"]
    if sha(root / "flutter-full/tooling/dae-target/release/pool_audit") != provenance["binary_sha256"]:
        raise ValueError("Pool tool changed")
    values = {e["offset"]: e["value"] for e in query["entries"]}
    app = (root / "FlutterApp").read_bytes()
    decoded = {}
    for offset in ["0xd938", "0x27910"]:
        value = values[offset];begin,end = value["serialized_range"]
        if not 0 <= begin < end <= len(app): raise ValueError("Numeric range outside image")
        bits = signed_bits(app[begin:end]);number = struct.unpack('<d',bits.to_bytes(8,'little'))[0]
        if hex(bits) != value["double_bits"] or number != value["double"]: raise ValueError("Independent numeric decode disagrees")
        decoded[offset] = {"value":number,"bits":value["double_bits"],"serialized_range":[begin,end]}
    if decoded["0xd938"]["value"] != 10.0 or decoded["0x27910"]["value"] != 44.0:
        raise ValueError("Theme numeric constants changed")
    descriptors = {offset:[v.get('integer',v.get('string')) for v in values[offset]['elements']]
                   for offset in ["0x1e9f8","0x1ea00"]}
    if descriptors["0x1e9f8"][4] != "toolbarHeight" or descriptors["0x1ea00"][4] != "appBarTheme":
        raise ValueError("Theme override argument mapping changed")
    objects_path = root / "flutter-full/dae-export-single-cpu/text/objs.txt"
    objects = objects_path.read_text()
    def obj(typ,reference):
        m=re.search(r'^Obj!'+re.escape(typ)+'@'+re.escape(reference)+r'[^\n]*\n(.*?)(?=\n\n|\Z)',objects,re.M|re.S)
        if not m: raise ValueError("Missing object: "+typ+"@"+reference)
        return m[1]
    modes=[]
    for value in values['0x25880']['elements']:
        block=obj('ThemeMode',value['reference'][2:])
        modes.append(re.search(r'off_10: "([^"\n]+)"',block)[1])
    if modes != ['system','light','dark'] or values['0xb890']['reference'] != values['0x25880']['elements'][0]['reference']:
        raise ValueError("Theme mode default/options changed")
    def color_rgba(reference):
        block=obj('Color',reference);rgba=[]
        for field in ['10','18','20','8']:
            m=re.search(r'^  off_'+field+r': (double|int)\(([^)]+)\)',block,re.M)
            v=float(m[2]) if m[1]=='double' else float(int(m[2],0))
            if not 0<=v<=1: raise ValueError("Invalid color component")
            rgba.append(v)
        if '"sRGB"' not in block: raise ValueError("Unknown color space")
        return rgba
    scheme=obj('FlexSchemeData',values['0x254f0']['reference'][2:]);palette={}
    for mode,slot in [('light','18'),('dark','20')]:
        ref=re.search(r'^  off_'+slot+r'_Obj!FlexSchemeColor@([0-9a-f]+)',scheme,re.M)[1]
        color=re.search(r'^  off_8_Obj!Color@([0-9a-f]+)',obj('FlexSchemeColor',ref),re.M)[1]
        rgba=color_rgba(color)
        palette[mode]={"scheme_reference":"0x"+ref,"primary_reference":"0x"+color,"rgba":rgba,
                       "rgb_hex":"#"+''.join(f'{round(v*255):02X}' for v in rgba[:3])}
    if [palette[k]['rgb_hex'] for k in ['light','dark']] != ['#335CA8','#AEC6FF']:
        raise ValueError("Default primary colors changed")
    if color_rgba(values['0xc0a8']['reference'][2:]) != [0.0,0.0,0.0,1.0]:
        raise ValueError("Pure black scaffold constant changed")
    base=obj('FlexScaffoldBaseColor',values['0x39a98']['reference'][2:])
    if 'off_10: "surfaceContainer"' not in base: raise ValueError("Normal scaffold base changed")
    pool=(root/'flutter-full/dae-export-single-cpu/text/pp.txt').read_text()
    typography={}
    for offset in ['0xc668','0xc670']:
        block=re.search(re.escape('[pp+'+offset+']')+r'[^\n]*\n(.*?)(?=\n\[pp\+|\Z)',pool,re.S)[1]
        families=sorted(set(re.findall(r'off_20: "(CupertinoSystem[^"\n]+)"',block)))
        if families != ['CupertinoSystemDisplay','CupertinoSystemText']: raise ValueError("Cupertino font pair changed")
        typography[offset]=families
    ios=re.search(r'\[pp\+0xc370\][^\n]*\n(.*?)(?=\n\[pp\+|\Z)',pool,re.S)[1]
    if 'off_10: "iOS"' not in ios: raise ValueError("Typography platform mapping changed")
    font=directory/'FontManifest.json'
    inventory=json.loads((own/'validation/rea/tachimanga-5.1-package-inventory.json').read_text())
    record=next(v for v in inventory if v['path'].endswith('/flutter_assets/FontManifest.json'))
    if sha(font)!=record['sha256']: raise ValueError("Font manifest differs from inventoried IPA")
    result['scope']='Static appearance defaults, seed colors, toolbar override and framework typography branch'
    result['defaults']={'themeMode':'system','themeKey':'default','themeBlendLevel':10.0,'themePureBlackDarkMode':False}
    result['theme_mode_options']=modes
    result['dark_scaffold_policy']={'pure_black':{'blend_level':0,'color':'#000000'},'normal_base':'surfaceContainer'}
    result['default_primary_palette']=palette;result['verified_numeric_constants']=decoded
    result['argument_descriptors']=descriptors;result['framework_ios_typography']=typography
    result['packaged_font_manifest']=json.loads(font.read_text())
    result['query_sha256']=sha(query_path);result['query_offsets']=[v['offset'] for v in query['entries']]
    result['export_files_sha256'].update({'../text/objs.txt':sha(objects_path),'FontManifest.json':sha(font)})
    result['limits']=['Seed colors are not measured final screen colors or every theme option',
        'Cupertino typography is a framework fallback branch, not proof of every app label or Arabic fallback glyph',
        'Final geometry can be changed by widgets, native iOS 26 shell, safe areas and text scaling',
        'No proprietary font copied; no specimen code executed; no production app changes']
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('analysis_root',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();r=review(a.analysis_root);a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r['totals']))
