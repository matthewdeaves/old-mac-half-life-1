#!/usr/bin/env python3
"""Exercise the shipped ZIP reader with valid and damaged archives on macOS.

Pass --source to demonstrate failures against an unpatched OMArchive.m.
The 7z entry point is stubbed because these cases exclusively use ZIP.
"""
import argparse
import io
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=ROOT / 'installer/OMArchive.m')
parser.add_argument('--fixtures', type=Path, help='emit ZIPs and expected exit codes for legacy hardware')
args = parser.parse_args()

def archive(method=zipfile.ZIP_DEFLATED, payload=b'game "Test"\n'):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=method) as z:
        z.writestr('liblist.gam', payload)
    return bytearray(stream.getvalue())

cases = []
for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
    for payload in (b'', b'game "Test"\n', b'a' * 524288):
        cases.append((f'valid-{method}-{len(payload)}', archive(method, payload), True))
cases.append(('valid-multiple-input-buffers', archive(payload=os.urandom(524288)), True))

data = archive()
cd = data.index(b'PK\x01\x02')
end = data.index(b'PK\x05\x06')
broken = bytearray(data)
struct.pack_into('<H', broken, cd + 28, 1000)
cases.append(('truncated-name', broken, False))
broken = bytearray(data)
struct.pack_into('<H', broken, cd + 30, 1000)
cases.append(('truncated-extra', broken, False))
broken = bytearray(data)
struct.pack_into('<I', broken, cd + 24, 999)
cases.append(('wrong-output-size', broken, False))
broken = bytearray(data)
struct.pack_into('<H', broken, end + 8, 2)
struct.pack_into('<H', broken, end + 10, 2)
cases.append(('missing-entry', broken, False))
broken = bytearray(data)
struct.pack_into('<H', broken, end + 4, 1)
cases.append(('split-archive', broken, False))
broken = bytearray(data)
broken[cd + 46] = 255
cases.append(('invalid-utf8', broken, False))
broken = bytearray(data)
broken[cd + 47] = 0
cases.append(('embedded-nul', broken, False))
# A complete empty deflate stream is two bytes. Without its final byte,
# inflate produces zero output with the expected CRC but never reaches END.
broken = archive(payload=b'')
empty_cd = broken.index(b'PK\x01\x02')
struct.pack_into('<I', broken, empty_cd + 20, 1)
cases.append(('unfinished-deflate', broken, False))

if args.fixtures:
    args.fixtures.mkdir(parents=True, exist_ok=True)
    for name, data, expected in cases:
        (args.fixtures / (name + '.zip')).write_bytes(data)
    (args.fixtures / 'expected.txt').write_text(''.join(
        f'{name} {0 if expected else 1}\n' for name, _, expected in cases))
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='halflife-zip-') as tmp:
    tmp = Path(tmp)
    stub = tmp / 'stub.c'
    stub.write_text('#include "om7z.h"\nint om7z_extract(const char*a,const char*b,'
                    'const char*c,const char*d,om7z_sink*e,char*f,size_t g){return -1;}\n')
    exe = tmp / 'zip-test'
    zlib = ROOT / 'vendor/zlib-installer'
    subprocess.run(['clang', '-fsanitize=address,undefined', '-g', '-O1',
                    '-Wno-deprecated-declarations', '-I' + str(ROOT / 'installer'),
                    '-I' + str(zlib), str(args.source),
                    str(ROOT / 'installer/omarchive-test.m'), str(stub),
                    *[str(zlib / (s + '.c')) for s in
                      ('adler32', 'crc32', 'inflate', 'inftrees', 'inffast', 'zutil')],
                    '-framework', 'Cocoa', '-o', str(exe)], check=True)
    failures = 0
    for name, data, expected in cases:
        src = tmp / (name + '.zip')
        src.write_bytes(data)
        result = subprocess.run([str(exe), str(src), 'zip', '.', str(tmp / name)],
                                capture_output=True, text=True,
                                env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
        clean = not any(marker in result.stderr for marker in
                        ('AddressSanitizer', 'runtime error:', 'uncaught exception'))
        passed = clean and result.returncode == (0 if expected else 1)
        print(('PASS ' if passed else 'FAIL ') + name)
        if not passed:
            failures += 1
            print((result.stdout + result.stderr)[:4000])
    print(f'{len(cases) - failures} passed, {failures} failed')
    raise SystemExit(bool(failures))
