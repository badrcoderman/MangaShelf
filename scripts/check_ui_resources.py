#!/usr/bin/env python3
"""Check locale formats, bundled glyphs and Xcode resources; not an iOS build."""
import hashlib,json,plistlib,re,struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'iOS/MangaShelf'
RES=APP/'Resources'
failures=[]
def check(value,message):
    if not value:failures.append(message)
def strings(path):
    s=path.read_text();q=r'"(?:[^"\\]|\\.)*"'
    pattern=re.compile('('+q+r')\s*=\s*('+q+');')
    pairs=[(json.loads(k),json.loads(v)) for k,v in pattern.findall(s)]
    check(len(dict(pairs))==len(pairs),'Duplicate translation key: '+str(path))
    check(not pattern.sub('',re.sub(r'/\*.*?\*/','',s,flags=re.S)).strip(),'Invalid strings syntax: '+str(path))
    return dict(pairs)
en=strings(RES/'en.lproj/Localizable.strings');ar=strings(RES/'ar.lproj/Localizable.strings')
check(en.keys()==ar.keys(),'Locale keys differ')
formats=lambda s:re.findall(r'%(?:\d+\$)?[@dfiu]',s.replace('%%',''))
for key in en:check(formats(en[key])==formats(ar.get(key,'')),'Format mismatch: '+key)
for lang,expected in [('en',en),('ar',ar)]:
    check(strings(ROOT/f'Sources/ReaderCore/Resources/{lang}.lproj/Localizable.strings')==expected,'Core and app catalogs differ: '+lang)
for p in [*APP.glob('*.swift'),*ROOT.glob('Sources/ReaderCore/*.swift')]:
    for literal in re.findall(r'(?:L10n|ReaderText)\.(?:string|format)\(("(?:[^"\\]|\\.)*")',p.read_text()):
        check(json.loads(literal) in en,'Missing locale key in '+p.name+': '+literal)
font=(RES/'MaterialIcons-Regular.otf').read_bytes()
check(font[:4]==b'OTTO','Expected OpenType font')
tables={}
for i in range(struct.unpack_from('>H',font,4)[0]):
    tag,_,offset,length=struct.unpack_from('>4sIII',font,12+16*i)
    check(offset+length<=len(font),'Font table out of bounds')
    tables[tag]=font[offset:offset+length]
cmap=tables[b'cmap'];available=set()
for i in range(struct.unpack_from('>H',cmap,2)[0]):
    _,_,offset=struct.unpack_from('>HHI',cmap,4+8*i)
    fmt=struct.unpack_from('>H',cmap,offset)[0]
    if fmt==12:
        for j in range(struct.unpack_from('>I',cmap,offset+12)[0]):
            start,end,glyph=struct.unpack_from('>III',cmap,offset+16+12*j)
            available.update(range(start+(glyph==0),end+1))
    elif fmt==4:
        count=struct.unpack_from('>H',cmap,offset+6)[0]//2
        ends=offset+14;starts=ends+count*2+2;deltas=starts+count*2;ranges=deltas+count*2
        for j in range(count):
            end=struct.unpack_from('>H',cmap,ends+2*j)[0];start=struct.unpack_from('>H',cmap,starts+2*j)[0]
            delta=struct.unpack_from('>h',cmap,deltas+2*j)[0];address=ranges+2*j
            relative=struct.unpack_from('>H',cmap,address)[0]
            for point in range(start,end+1):
                if relative:
                    glyph=struct.unpack_from('>H',cmap,address+relative+2*(point-start))[0]
                    if glyph:glyph=(glyph+delta)&0xffff
                else:glyph=(point+delta)&0xffff
                if glyph:available.add(point)
glyphs={name:int(value,16) for name,value in re.findall(r'(\w+) = 0x([0-9A-F]+)',(APP/'TachiUI.swift').read_text())}
for name,point in glyphs.items():check(point in available,'Missing glyph: '+name)
name=tables[b'name'];_,count,offset=struct.unpack_from('>HHH',name,0);ps=[]
for i in range(count):
    platform,_,_,key,length,start=struct.unpack_from('>HHHHHH',name,6+12*i)
    if key==6:ps.append(name[offset+start:offset+start+length].decode('utf-16-be' if platform in (0,3) else 'latin1'))
check('MaterialIcons-Regular' in ps,'Incorrect font PostScript name')
info=plistlib.loads((APP/'Info.plist').read_bytes())
check(info.get('CFBundleDevelopmentRegion')=='en','English must be the default')
check(set(info.get('CFBundleLocalizations',[]))=={'en','ar'},'Declare both locales')
check(info.get('UIAppFonts')==['MaterialIcons-Regular.otf'],'Register icon font')
project=(ROOT/'iOS/MangaShelf.xcodeproj/project.pbxproj').read_text()
for resource in ('en.lproj','ar.lproj','MaterialIcons-Regular.otf','MaterialIcons-LICENSE.txt'):
    check('MangaShelf/Resources/'+resource in project,'Missing Xcode resource: '+resource)
report={'localization_keys':len(en),'icon_glyphs':len(glyphs),'font_sha256':hashlib.sha256(font).hexdigest(),
        'failures':failures,'scope':'Resource integrity and format checks; not Swift compilation or visual verification'}
(ROOT/'validation').mkdir(exist_ok=True)
(ROOT/'validation/ui-resources.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2));raise SystemExit(bool(failures))
