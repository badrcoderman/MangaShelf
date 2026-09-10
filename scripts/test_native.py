#!/usr/bin/env python3
"""Compile and exercise the exact C core consumed by the iOS Swift package."""
import ctypes as C
import gzip
import io
import json
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TEMP = tempfile.TemporaryDirectory(prefix="mangashelf-native-")
LIB = Path(TEMP.name) / "libmangashelf.so"
subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Werror", "-O2", "-shared", "-fPIC",
                "-I", str(ROOT / "Sources/CSafeArchive/include"), str(ROOT / "Sources/CSafeArchive/archive.c"),
                "-lz", "-o", str(LIB)], check=True)
lib = C.CDLL(str(LIB))

class Limits(C.Structure):
    _fields_ = [("entry_limit", C.c_uint32), ("entry_bytes_limit", C.c_uint32),
                ("total_bytes_limit", C.c_uint64), ("ratio_limit", C.c_uint32)]

class Zip(C.Structure):
    _fields_ = [("bytes", C.c_void_p), ("size", C.c_size_t), ("central_offset", C.c_size_t),
                ("central_end", C.c_size_t), ("cursor", C.c_size_t), ("count", C.c_uint32),
                ("seen", C.c_uint32), ("expanded_total", C.c_uint64), ("limits", Limits)]

class Entry(C.Structure):
    _fields_ = [("name", C.c_void_p), ("name_length", C.c_uint16), ("method", C.c_uint16), ("flags", C.c_uint16),
                ("compressed_size", C.c_uint32), ("uncompressed_size", C.c_uint32), ("crc", C.c_uint32), ("data_offset", C.c_size_t)]

class Field(C.Structure):
    _fields_ = [("number", C.c_uint32), ("wire_type", C.c_uint32), ("integer", C.c_uint64),
                ("bytes", C.c_void_p), ("length", C.c_size_t)]

lib.ms_zip_open.argtypes = [C.c_void_p, C.c_size_t, Limits, C.POINTER(Zip)]
lib.ms_zip_next.argtypes = [C.POINTER(Zip), C.POINTER(Entry)]
lib.ms_zip_extract.argtypes = [C.POINTER(Zip), C.POINTER(Entry), C.c_void_p, C.c_size_t]
lib.ms_gzip_decode.argtypes = [C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]
lib.ms_pb_next.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t), C.POINTER(Field)]

def archive(items=None, method=zipfile.ZIP_DEFLATED, comment=b""):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=method) as z:
        for name, data in (items if items is not None else [("01.jpg", b"image bytes"), ("nested/02.png", b"next")]): z.writestr(name, data)
        z.comment = comment
    return stream.getvalue()

def parse(data, limits=None, extract=True):
    raw = C.create_string_buffer(bytes(data)); z = Zip()
    status = lib.ms_zip_open(raw, len(data), limits or Limits(4096, 32*1024*1024, 1024*1024*1024, 500), C.byref(z))
    if status: return status, []
    entries = []
    while True:
        e = Entry(); status = lib.ms_zip_next(C.byref(z), C.byref(e))
        if status == 6: return 0, entries
        if status: return status, entries
        content = None
        if extract:
            output = C.create_string_buffer(max(1, e.uncompressed_size))
            status = lib.ms_zip_extract(C.byref(z), C.byref(e), output, len(output))
            if status: return status, entries
            content = output.raw[:e.uncompressed_size]
        entries.append((C.string_at(e.name, e.name_length).decode("utf-8"), content))

def varint(value):
    out = bytearray()
    while value >= 128: out.append((value & 127) | 128); value >>= 7
    out.append(value); return bytes(out)

def pb(data):
    raw = C.create_string_buffer(data); offset = C.c_size_t(0); fields = []
    while True:
        f = Field(); status = lib.ms_pb_next(raw, len(data), C.byref(offset), C.byref(f))
        if status: return status, fields
        fields.append((f.number, f.wire_type, f.integer, C.string_at(f.bytes, f.length) if f.bytes else b""))

class NativeTests(unittest.TestCase):
    def test_deflate_roundtrip(self): self.assertEqual(parse(archive())[1], [("01.jpg", b"image bytes"), ("nested/02.png", b"next")])
    def test_stored_roundtrip(self): self.assertEqual(parse(archive(method=0))[0], 0)
    def test_empty_entry(self): self.assertEqual(parse(archive([("folder/", b""), ("01.jpg", b"x")]))[0], 0)
    def test_empty_archive(self): self.assertEqual(parse(archive([])), (0, []))
    def test_unicode(self): self.assertEqual(parse(archive([("فصل/صفحة.jpg", b"one")]))[1][0][0], "فصل/صفحة.jpg")
    def test_maximum_comment(self): self.assertEqual(parse(archive(comment=b"x"*65535))[0], 0)
    def test_fake_eocd_in_comment(self): self.assertEqual(parse(archive(comment=b"PK\x05\x06" + b"x"*40))[0], 0)
    def test_all_truncations(self):
        value = archive()
        for i in range(len(value)): self.assertNotEqual(parse(value[:i])[0], 0, i)
    def test_trailing_garbage(self): self.assertNotEqual(parse(archive()+b"garbage")[0], 0)
    def test_bad_crc(self):
        value = bytearray(archive(method=0)); value[36] ^= 1
        self.assertNotEqual(parse(value)[0], 0)
    def test_path_traversal(self):
        for name in ("../a.jpg", "/a.jpg", "a/../../b.jpg", "C:/a.jpg", "a\\b.jpg", "a//b.jpg", "./a.jpg"):
            self.assertNotEqual(parse(archive([(name, b"x")]))[0], 0, name)
    def test_encrypted_flag(self):
        value = bytearray(archive()); central=value.index(b"PK\x01\x02")
        struct.pack_into("<H",value,central+8,1); self.assertEqual(parse(value)[0],3)
    def test_symlink(self):
        value=bytearray(archive()); central=value.index(b"PK\x01\x02")
        struct.pack_into("<I",value,central+38,0o120777<<16); self.assertEqual(parse(value)[0],3)
    def test_local_name_mismatch(self):
        value=bytearray(archive()); value[30]=ord("z"); self.assertNotEqual(parse(value)[0],0)
    def test_unsupported_compression(self): self.assertEqual(parse(archive(method=zipfile.ZIP_BZIP2))[0],3)
    def test_entry_count_limit(self): self.assertEqual(parse(archive(),Limits(1,100,100,500))[0],2)
    def test_entry_size_limit(self): self.assertEqual(parse(archive(),Limits(10,2,100,500))[0],2)
    def test_total_size_limit(self): self.assertEqual(parse(archive(),Limits(10,100,12,500))[0],2)
    def test_expansion_bomb(self): self.assertEqual(parse(archive([("01.jpg",b"0"*1_000_000)]))[0],2)
    def test_zip64_sentinel(self):
        value=bytearray(archive()); struct.pack_into("<I",value,len(value)-6,0xffffffff)
        self.assertEqual(parse(value)[0],3)
    def test_multidisk(self):
        value=bytearray(archive()); struct.pack_into("<H",value,len(value)-18,1)
        self.assertEqual(parse(value)[0],3)
    def test_bad_central_offset(self):
        value=bytearray(archive()); struct.pack_into("<I",value,len(value)-6,0xffffff00)
        self.assertNotEqual(parse(value)[0],0)
    def test_gzip(self):
        payload=b"protobuf index"*70; data=gzip.compress(payload)
        out=C.create_string_buffer(2000); count=C.c_size_t()
        self.assertEqual(lib.ms_gzip_decode(data,len(data),out,len(out),C.byref(count)),0)
        self.assertEqual(out.raw[:count.value],payload)
    def test_gzip_limit(self):
        data=gzip.compress(b"x"*1000); out=C.create_string_buffer(100); count=C.c_size_t()
        self.assertEqual(lib.ms_gzip_decode(data,len(data),out,len(out),C.byref(count)),2)
    def test_gzip_corrupt_and_concat(self):
        for data in (gzip.compress(b"ok")[:-1],gzip.compress(b"one")+gzip.compress(b"two")):
            out=C.create_string_buffer(100); count=C.c_size_t()
            self.assertNotEqual(lib.ms_gzip_decode(data,len(data),out,len(out),C.byref(count)),0)
    def test_pb_jar_501(self):
        url=b"https://example.test/extension.jar"; data=varint((501<<3)|2)+varint(len(url))+url
        self.assertEqual(pb(data),(6,[(501,2,0,url)]))
    def test_pb_uint64(self): self.assertEqual(pb(b"\x08"+varint(2**64-1))[1][0][2],2**64-1)
    def test_pb_unknown_fixed(self):
        self.assertEqual(pb(varint(123<<3|5)+b"1234"+varint(124<<3|1)+b"12345678")[0],6)
    def test_pb_overflow(self): self.assertEqual(pb(b"\x08"+b"\xff"*10)[0],1)
    def test_pb_illegal_tag(self):
        for data in (b"\0",varint(2**29<<3),b"\x0b",b"\x0a\xff"*2): self.assertNotEqual(pb(data)[0],6)
    def test_pb_truncated(self):
        for data in (b"\x08\x80",b"\x0a\x05abc",b"\x09abc",b"\x0dabc"): self.assertEqual(pb(data)[0],1)
    def test_pb_empty(self): self.assertEqual(pb(b""),(6,[]))
    def test_random_bytes_bounded(self):
        rng=random.Random(901)
        for _ in range(3000):
            data=rng.randbytes(rng.randrange(0,300)); self.assertIn(pb(data)[0],(1,3,6)); self.assertIn(parse(data)[0],range(7))
    def test_mutated_archive_bounded(self):
        rng=random.Random(77); original=archive()
        for _ in range(1500):
            data=bytearray(original)
            for _ in range(rng.randrange(1,5)): data[rng.randrange(len(data))]=rng.randrange(256)
            self.assertIn(parse(data)[0],range(7))

if __name__ == "__main__":
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(NativeTests)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    report={"native_tests":result.testsRun,"failures":len(result.failures),"errors":len(result.errors),
            "random_pb_and_zip_cases":3000,"mutated_zip_cases":1500,
            "compiler":"system cc with -Wall -Wextra -Wconversion -Werror", "swift_tests":"not run on Linux without Swift",
            "ios_build":"not run; Xcode is unavailable"}
    destination=ROOT/"validation"; destination.mkdir(exist_ok=True)
    (destination/"native-test-results.json").write_text(json.dumps(report,indent=2)+"\n")
    raise SystemExit(0 if result.wasSuccessful() else 1)
