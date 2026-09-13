#!/usr/bin/env python3
"""Offline primitive checks. Run only on test-env or an authorized build host."""

import ctypes
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    library_path = Path(sys.argv[1]).resolve()
    lib = ctypes.CDLL(str(library_path))
    byte_pointer = ctypes.POINTER(ctypes.c_ubyte)
    array = lambda value: (ctypes.c_ubyte * len(value)).from_buffer_copy(value)
    empty = lambda size, byte=0: array(bytes([byte]) * size)
    for name in ("bili_p256_new", "bili_p256_public"):
        getattr(lib, name).argtypes = [byte_pointer, byte_pointer]
        getattr(lib, name).restype = ctypes.c_int
    lib.bili_p256_derive.argtypes = [byte_pointer, byte_pointer, byte_pointer]
    lib.bili_p256_derive.restype = ctypes.c_int
    for name in ("bili_aes256_ecb_encrypt", "bili_aes256_ecb_decrypt"):
        getattr(lib, name).argtypes = [byte_pointer, byte_pointer, ctypes.c_ulong, byte_pointer]
        getattr(lib, name).restype = ctypes.c_int

    order = int("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
    cases = []
    scalars = [1, 2, order - 1] + [
        int.from_bytes(hashlib.sha256(f"bili-portable-vector-{index}".encode()).digest(), "big")
        % (order - 1) + 1 for index in range(29)
    ]
    for scalar in scalars:
        private = array(scalar.to_bytes(32, "big"))
        public = empty(65)
        assert lib.bili_p256_public(private, public) == 1
        cases.append({"private": bytes(private).hex(), "public": bytes(public).hex()})
    generated = []
    for _ in range(24):
        private, public = empty(32), empty(65)
        assert lib.bili_p256_new(private, public) == 1
        generated.append(bytes(private))
        cases.append({"private": bytes(private).hex(), "public": bytes(public).hex()})
    assert len(set(generated)) == len(generated)

    reference_script = r'''
const crypto = require("node:crypto");
const fs = require("node:fs");
const cases = JSON.parse(fs.readFileSync(0, "utf8"));
const keys = cases.map(item => {
  const key = crypto.createECDH("prime256v1");
  key.setPrivateKey(Buffer.from(item.private, "hex"));
  if (key.getPublicKey("hex", "uncompressed") !== item.public) throw Error("public mismatch");
  return key;
});
process.stdout.write(JSON.stringify(keys.map((key, index) =>
  key.computeSecret(keys[(index + 1) % keys.length].getPublicKey()).toString("hex"))));
'''
    secrets = json.loads(subprocess.check_output(
        ["node", "-e", reference_script], input=json.dumps(cases).encode()))
    for index, item in enumerate(cases):
        private = array(bytes.fromhex(item["private"]))
        peer = array(bytes.fromhex(cases[(index + 1) % len(cases)]["public"]))
        secret = empty(32)
        assert lib.bili_p256_derive(private, peer, secret) == 1
        assert bytes(secret).hex() == secrets[index]

    valid_private = array((1).to_bytes(32, "big"))
    valid_public = array(bytes.fromhex(cases[0]["public"]))
    for scalar in (0, order, order + 1, (1 << 256) - 1):
        private = array(scalar.to_bytes(32, "big"))
        public, secret = empty(65, 0xAA), empty(32, 0xAA)
        assert lib.bili_p256_public(private, public) == 0 and not any(public)
        assert lib.bili_p256_derive(private, valid_public, secret) == 0 and not any(secret)
    bad_points = [b"\x04" + bytes(64), bytes([2]) + bytes(valid_public)[1:]]
    bad_points.append(bytes(valid_public)[:-1] + bytes([valid_public[64] ^ 1]))
    prime = int("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    bad_points.append(b"\x04" + prime.to_bytes(32, "big") + bytes(valid_public)[33:])
    bad_points.append(bytes(valid_public)[:33] + prime.to_bytes(32, "big"))
    for point in bad_points:
        secret = empty(32, 0xAA)
        assert lib.bili_p256_derive(valid_private, array(point), secret) == 0 and not any(secret)
    secret = empty(32, 0xAA)
    assert lib.bili_p256_derive(None, valid_public, secret) == 0 and not any(secret)

    key = array(bytes.fromhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"))
    plaintext = bytes.fromhex(
        "6bc1bee22e409f96e93d7e117393172a" "ae2d8a571e03ac9c9eb76fac45af8e51"
        "30c81c46a35ce411e5fbc1191a0a52ef" "f69f2445df4f9b17ad2b417be66c3710")
    expected = bytes.fromhex(
        "f3eed1bdb5d2a03c064b5a7e3db181f8" "591ccb10d410ed26dc5ba74a31362870"
        "b6ed21b99ca6f4f9f153e7b1beafed1d" "23304b7a39f9f3ff067d8d8f9e24ecc7")
    encrypted = empty(len(plaintext))
    assert lib.bili_aes256_ecb_encrypt(key, array(plaintext), len(plaintext), encrypted) == 1
    assert bytes(encrypted) == expected
    assert lib.bili_aes256_ecb_decrypt(key, encrypted, len(encrypted), encrypted) == 1
    assert bytes(encrypted) == plaintext
    assert lib.bili_aes256_ecb_encrypt(key, None, 0, None) == 1
    assert lib.bili_aes256_ecb_encrypt(key, array(plaintext), 15, encrypted) == 0
    assert lib.bili_aes256_ecb_encrypt(None, array(plaintext), 16, encrypted) == 0
    assert lib.bili_aes256_ecb_encrypt(key, None, 16, encrypted) == 0
    assert lib.bili_aes256_ecb_encrypt(key, array(plaintext), 16, None) == 0

    print(json.dumps({
        "library_sha256": hashlib.sha256(library_path.read_bytes()).hexdigest(),
        "p256_node_interoperability_cases": len(cases),
        "p256_generated_unique_keys": len(generated),
        "p256_invalid_scalars_rejected": 4,
        "p256_invalid_peers_rejected": len(bad_points),
        "p256_failed_outputs_zeroed": True,
        "aes256_nist_sp800_38a_f1_5_blocks": 4,
        "aes256_encrypt_decrypt_and_in_place": True,
        "aes256_invalid_arguments_rejected": True,
        "result": "passed",
    }, indent=2))


if __name__ == "__main__":
    main()
