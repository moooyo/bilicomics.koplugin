#!/usr/bin/env python3
"""Inspect cross-built Android libraries on the authorized remote host."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ndk = Path('/var/tmp/bili-android-ndk-20260912/android-ndk-r27c')
root = Path('/var/tmp/bili-android-ndk-20260912/host-build')
tools = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
source_root = Path('/tmp/bili-native-protocol-20260912')
targets = {
    'android-arm64-v8a': 'aarch64-linux-android21-clang',
    'android-armeabi-v7a': 'armv7a-linux-androideabi21-clang',
    'android-x86_64': 'x86_64-linux-android21-clang',
    'android-x86': 'i686-linux-android21-clang',
}


def execute(tool, *arguments):
    return subprocess.check_output([str(tools / tool), *map(str, arguments)], text=True)


results = []
for platform, compiler in targets.items():
    library = root / platform / 'libbiliwasm.so'
    dynamic = execute('llvm-readelf', '--dynamic', library)
    headers = execute('llvm-readelf', '--program-headers', '--wide', library)
    file_header = execute('llvm-readelf', '--file-header', library)
    attributes = execute('llvm-readelf', '--arch-specific', library)
    symbols = execute('llvm-readelf', '--dyn-syms', '--wide', library)
    notes = execute('llvm-readelf', '--notes', library)
    exports = sorted(line.split()[-1] for line in execute('llvm-nm', '-D', '--defined-only', library).splitlines())
    needed = re.findall(r'\(NEEDED\).*\[(.*?)\]', dynamic)
    soname = re.findall(r'\(SONAME\).*\[(.*?)\]', dynamic)
    alignments = [int(line.split()[-1], 16) for line in headers.splitlines()
                  if line.strip().startswith('LOAD ')]
    assert exports == ['biliwasm_free', 'biliwasm_run'], exports
    assert soname == ['libbiliwasm.so'], soname
    assert needed and set(needed) <= {'libc.so', 'libm.so', 'libdl.so'}, needed
    assert 'GLIBC_' not in symbols and 'libpthread' not in dynamic
    assert alignments and all(value == 16384 for value in alignments), alignments
    assert not any(line.strip().startswith('TLS ') for line in headers.splitlines())
    assert '__tls_get_addr' not in symbols and 'TLSDESC' not in symbols
    data = library.read_bytes()
    results.append({
        'platform': platform,
        'path': str(library),
        'compiler': compiler,
        'minimum_android_api': 21,
        'ndk_revision': '27.2.12479018',
        'sha256': hashlib.sha256(data).hexdigest(),
        'bytes': len(data),
        'soname': soname[0],
        'exports': exports,
        'needed': needed,
        'load_segment_alignment': alignments,
        'native_tls_segment': False,
        'verification': 'cross-compiled-elf-inspected-only',
        'device_verified': False,
        'elf_header': file_header,
        'elf_attributes': attributes,
        'elf_notes': notes,
    })
record = {
    'compiler_version': execute('clang', '--version'),
    'source_sha256': {name: hashlib.sha256((source_root / name).read_bytes()).hexdigest()
                      for name in ['biliwasm.c', 'biliwasm.h', 'biliwasm.exports.map', 'build.sh', 'build-android.sh']},
    'libraries': results,
}
(root / 'android-build-results.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps([{key: value for key, value in item.items() if not key.startswith('elf_')}
                  for item in results], indent=2))
