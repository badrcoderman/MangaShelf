#!/usr/bin/env python3
"""Generate deterministic, original test data. No manga artwork or app binaries."""
from pathlib import Path
import gzip
import struct
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Tests/ReaderCoreTests/Fixtures"
DEST.mkdir(parents=True, exist_ok=True)

def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind+data))
def png(page):
    width, height = 120, 180
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            border = x < 5 or x >= width-5 or y < 5 or y >= height-5
            panel = (15 <= x < 105 and 20 <= y < 70) or (15 <= x < 105 and 85 <= y < 165)
            rgb = (32,32,48) if border else ((35*page,70,170) if panel else (245,245,250))
            pixels.extend(rgb)
    header=struct.pack(">IIBBBBB",width,height,8,2,0,0,0)
    return b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",header)+chunk(b"IDAT",zlib.compress(pixels))+chunk(b"IEND",b"")

with zipfile.ZipFile(DEST/"TestComic.cbz","w",compression=zipfile.ZIP_DEFLATED) as archive:
    for page in (1,2,10):
        info=zipfile.ZipInfo(f"page{page}.png",(2026,1,1,0,0,0)); info.compress_type=zipfile.ZIP_DEFLATED
        archive.writestr(info,png(page % 4 + 1))

def varint(n):
    out=bytearray()
    while n>=128:out.append((n&127)|128);n>>=7
    out.append(n);return bytes(out)
def blob(number, data):
    if isinstance(data,str):data=data.encode()
    return varint(number<<3|2)+varint(len(data))+data
def integer(number,n):return varint(number<<3)+varint(n)

resources=blob(1,"https://example.invalid/unused.apk")+blob(2,"https://example.invalid/icon.png")+blob(501,"https://example.invalid/source.jar")
source=integer(1,4508733312114627536)+blob(2,"Test Source")+blob(3,"ar")+blob(4,"https://example.invalid")
extension=blob(1,"Test Extension")+blob(2,"test.extension")+blob(3,resources)+blob(4,"1.6")+integer(5,7)+blob(6,"1.6.7")+blob(8,source)
listing=blob(1,extension)
index=blob(1,"Test repository")+blob(101,listing)
(DEST/"index.pb").write_bytes(index)
(DEST/"index.pb.gz").write_bytes(gzip.compress(index,mtime=0))
(DEST/"external-list.pb").write_bytes(listing)
print("Generated four local-only fixtures in", DEST)
