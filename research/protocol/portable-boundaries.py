#!/usr/bin/env python3
"""Inspect P-256 boundary scalars on the authorized remote test host."""
import ctypes
import json
import sys

lib = ctypes.CDLL(sys.argv[1])
order = int("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
cases = [(str(value), value) for value in range(1, 20)]
cases += [(f"n-{value}", order - value) for value in range(1, 20)]
cases += [(f"floor(n/2)+{value}", order // 2 + value) for value in range(-5, 6)]
results = []
for label, scalar in cases:
    private = (ctypes.c_ubyte * 32).from_buffer_copy(scalar.to_bytes(32, "big"))
    public = (ctypes.c_ubyte * 65)()
    results.append({"scalar": label, "success": lib.bili_p256_public(private, public)})
print(json.dumps(results, indent=2))
