#!/usr/bin/env python3
"""Run only on test-env or another explicitly authorized verification host."""
import ctypes
import json
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
wasm_root = Path(sys.argv[2]).resolve()
library = ctypes.CDLL(str(root / "libbiliwasm.so"))
library.biliwasm_run.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                ctypes.POINTER(ctypes.c_void_p)]
library.biliwasm_run.restype = ctypes.c_int
library.biliwasm_free.argtypes = [ctypes.c_void_p]
library.biliwasm_free.restype = None
sign = wasm_root / "efae82c96a7eef44bee5.wasm"
decoder = wasm_root / "e461bfa6b471a22c06fc.wasm"
query = "device=pc&platform=web&nov=27&eot=812"


def call(path, request):
    output = ctypes.c_void_p()
    status = library.biliwasm_run(str(path).encode(), json.dumps(request).encode(),
                                 ctypes.byref(output))
    assert output.value, "The library did not return structured output"
    try:
        data = json.loads(ctypes.string_at(output.value))
    finally:
        library.biliwasm_free(output)
    return status, data


cases = [
    (sign, {"function": "y1_z2w2a3", "args": [query, "{}", 1789171200000]},
     {"error": None, "sign": "Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf"}),
    (sign, {"function": "y1_z2w2a3", "args": [query, '{"comic_id":36215}', 1789171200000]},
     {"error": None, "sign": "dRas4960Rha0D2RL60weLdR0w6LK69ddXhkLYasGd1sKYaXf"}),
    (sign, {"function": "y1_z2w2a3", "args": []},
     {"error": "Invalid number of arguments. Expected 3 arguments (query, body, timestamp)"}),
    (decoder, {"function": "c1_r9k2m7", "args": []},
     {"error": "Expected 5 arguments (url, bytesData, buvid, platform, bodyJSON)", "data": None}),
    (decoder, {"function": "c1_r9k2m7", "args": ["/twirp/comic.v1.Comic/ComicDetail", "AAAA", "", "web", "{}"]},
     {"error": "aes decrypt error: ciphertext is not a multiple of the block size", "data": ""}),
    (decoder, {"function": "c1_r9k2m7", "args": ["/twirp/comic.v1.Comic/ComicDetail", "", "", "web", "{}"]},
     {"error": "decrypt result is not valid json", "data": ""}),
    (decoder, {"function": "c1_r9k2m7", "args": ["/twirp/comic.v1.Comic/ComicDetail",
     "yHEYgHkBOklQxZUed3mFB7VmJEAMe8nOHxniUEThJGI=", "SYNTHETIC-BUVID", "web", '{"comic_id":36215}']},
     {"error": "", "data": '{"fixture":"crypto"}'}),
]
start = time.monotonic()
for path, request, expected in cases:
    status, output = call(path, request)
    assert status == 0 and output == {"ok": True, "result": expected}, (request, status, output)
    cli = subprocess.run([str(root / "biliwasm"), str(path)], input=json.dumps(request),
                         text=True, capture_output=True, check=True)
    assert json.loads(cli.stdout) == output

for request in [{}, {"function": "not_permitted", "args": []},
                {"function": "y1_z2w2a3", "args": "invalid"}]:
    status, output = call(sign, request)
    assert status == 1 and output["ok"] is False
status, output = call(root / "missing.wasm", cases[0][1])
assert status == 1 and output["ok"] is False
with tempfile.TemporaryDirectory(prefix="biliwasm-invalid-") as temporary:
    fixture_root = Path(temporary)
    malformed = fixture_root / "malformed.wasm"
    malformed.write_bytes(b"invalid wasm")
    status, output = call(malformed, cases[0][1])
    assert status == 1 and output["ok"] is False
    for name, source in [
        ("data-out-of-bounds", '(module (memory 1) (data (i32.const 65536) "x"))'),
        ("memory-limit", '(module (memory 1025))'),
    ]:
        wat = fixture_root / (name + ".wat")
        wasm = fixture_root / (name + ".wasm")
        wat.write_text(source)
        subprocess.run([str(wasm_root / "wabt-1.0.41/bin/wat2wasm"), str(wat),
                        "-o", str(wasm)], check=True)
        status, output = call(wasm, cases[0][1])
        assert status == 1 and output["ok"] is False
resident = lambda: int(Path("/proc/self/status").read_text().split("VmRSS:")[1].split()[0])
rss_before = resident()
for _ in range(100):
    status, output = call(*cases[0][:2])
    assert status == 0 and output["result"] == cases[0][2]
rss_after = resident()
assert rss_after - rss_before < 16 * 1024, (rss_before, rss_after)
print(json.dumps({"golden_cases": len(cases), "cli_parity_cases": len(cases),
                  "host_failure_cases": 7, "repeated_ffi_calls": 100,
                  "rss_before_kib": rss_before, "rss_after_kib": rss_after,
                  "peak_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                  "elapsed_seconds": round(time.monotonic() - start, 3)}, indent=2))
