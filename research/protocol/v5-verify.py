"""Verify the native v5 ABI on test-env; never run this locally by default."""

import argparse
import base64
import ctypes
import hashlib
import json
import pathlib
import subprocess
import time
import urllib.parse


def binary(value):
    return bytes.fromhex(value)


def buffer(value):
    return ctypes.create_string_buffer(value) if value else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=pathlib.Path)
    parser.add_argument("--official-fixtures", type=pathlib.Path)
    args = parser.parse_args()
    started = time.monotonic()
    library = ctypes.CDLL(str(args.library.resolve()))
    pbkdf2 = library.bili_pbkdf2_sha512
    pbkdf2.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
    pbkdf2.restype = ctypes.c_int
    gcm = library.bili_aes_gcm_decrypt
    gcm.argtypes = [ctypes.c_void_p, ctypes.c_size_t] * 5 + [ctypes.c_void_p]
    gcm.restype = ctypes.c_int
    counts = {}

    def passed(group):
        counts[group] = counts.get(group, 0) + 1

    def derive(password, salt, iterations, outlen):
        output = ctypes.create_string_buffer(b"\xa5" * outlen, outlen)
        result = pbkdf2(buffer(password), len(password), buffer(salt), len(salt),
                        iterations, output, outlen)
        assert result == 1, "PBKDF2 unexpectedly rejected a valid input"
        return output.raw

    def decrypt(case, expected=True):
        fields = [binary(case[name]) for name in ("key", "iv", "aad", "cipher", "tag")]
        output = ctypes.create_string_buffer(b"\xa5" * max(len(fields[3]), 1),
                                            max(len(fields[3]), 1))
        call = []
        for value in fields:
            call += [buffer(value), len(value)]
        # The ABI has five input pointer/length pairs and one output pointer.
        result = gcm(*call, output)
        assert result == int(expected), "Unexpected GCM authentication result"
        if expected:
            assert output.raw[:len(fields[3])] == binary(case["plain"])
        else:
            assert output.raw == b"\xa5" * len(output), "Failed GCM call modified output"

    # These fixed SHA-512 answers are in the pinned upstream PKCS5 suite.
    known_pbkdf2 = [
        (b"password", b"salt", 1, "867f70cf1ade02cff3752599a3a53dc4af34c7a6"),
        (b"password", b"salt", 2, "e1d9c16aa681708a45f5c7c4e215ceb66e011a2e"),
        (b"password", b"salt", 4096, "d197b1b33db0143e018b12f3d1d1479e6cdebdcc"),
        (b"pass\x00word", b"sa\x00lt", 4096, "9d9e9c4cd21fe4be24d5b8244c759665"),
    ]
    for password, salt, iterations, expected in known_pbkdf2:
        assert derive(password, salt, iterations, len(expected) // 2) == binary(expected)
        passed("upstream_pbkdf2")

    # NIST GCM known answers are reproduced in the pinned upstream self-test.
    known_gcm = []
    for keylen, empty_tag, cipher, tag in [
        (16, "58e2fccefa7e3061367f1d57a4e7455a", "0388dace60b6a392f328c2b971b2fe78", "ab6e47d42cec13bdf53a67b21257bddf"),
        (24, "cd33b28ac773f74ba00ed1f312572435", "98e7247c07f0fe411c267e4384b0f600", "2ff58d80033927ab8ef4d4587514f0fb"),
        (32, "530f8afbc74536b9a963b4f1c4cb738b", "cea7403d4d606b6e074ec5d3baf39d18", "d0d1c8a799996bf0265b98b5d48ab919"),
    ]:
        base = {"key": "00" * keylen, "iv": "00" * 12, "aad": ""}
        known_gcm += [dict(base, cipher="", tag=empty_tag, plain=""),
                      dict(base, cipher=cipher, tag=tag, plain="00" * 16)]
    known_gcm.append({
        "key": "feffe9928665731c6d6a8f9467308308", "iv": "cafebabefacedbad",
        "aad": "feedfacedeadbeeffeedfacedeadbeefabaddad2",
        "cipher": "61353b4c2806934a777ff51fa22a4755699b2a714fcdc6f83766e5f97b6c742373806900e49f24b22b097544d4896b424989b5e1ebac0f07c23f4598",
        "tag": "3612d2e79e3b0785561be14aaca2fccb",
        "plain": "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39",
    })
    for case in known_gcm:
        decrypt(case)
        passed("nist_gcm")

    reference = json.loads(subprocess.check_output([
        "node", str(pathlib.Path(__file__).with_name("v5-fixtures.js"))], text=True))
    for case in reference["pbkdf2"]:
        assert derive(binary(case["password"]), binary(case["salt"]),
                      case["iterations"], case["outlen"]) == binary(case["expected"])
        passed("node_pbkdf2")
    for case in reference["gcm"]:
        decrypt(case)
        passed("node_gcm")
    tamper_case = reference["gcm"][2]
    for name in ("key", "iv", "aad", "cipher", "tag"):
        changed = dict(tamper_case)
        value = bytearray(binary(changed[name]))
        value[0] ^= 1
        changed[name] = value.hex()
        decrypt(changed, expected=False)
        passed("authentication_rejection")

    sentinel = ctypes.create_string_buffer(b"\xa5" * 2048, 2048)
    p, s = buffer(b"password"), buffer(b"salt")
    for call in [
        [None, 1, s, 4, 1, sentinel, 32], [p, 8, None, 1, 1, sentinel, 32],
        [p, 1025, s, 4, 1, sentinel, 32], [p, 8, s, 1025, 1, sentinel, 32],
        [p, 8, s, 4, 0, sentinel, 32], [p, 8, s, 4, 1000001, sentinel, 32],
        [p, 8, s, 4, 1000000, sentinel, 65], [p, 8, s, 4, 1, sentinel, 0],
        [p, 8, s, 4, 1, sentinel, 1025], [p, 8, s, 4, 1, None, 32],
        [p, 8, s, 4, 1, sentinel, ctypes.c_size_t(-1).value],
    ]:
        assert pbkdf2(*call) == 0
        assert sentinel.raw == b"\xa5" * 2048
        passed("pbkdf2_boundary_rejection")

    alias = ctypes.create_string_buffer(b"salt" + b"\xa5" * 76, 80)
    expected = hashlib.pbkdf2_hmac("sha512", b"password", b"salt", 2, 80)
    assert pbkdf2(p, 8, alias, 4, 2, alias, 80) == 1 and alias.raw == expected
    passed("pbkdf2_overlapping_output")

    values = [binary(tamper_case[name]) for name in ("key", "iv", "aad", "cipher", "tag")]
    default = []
    for value in values:
        default += [buffer(value), len(value)]
    default += [sentinel]
    for index, invalid in [(0, None), (1, 15), (1, 17), (1, 33), (2, None),
                           (3, 0), (3, 1025), (4, None), (5, 1048577),
                           (6, None), (7, 67108865), (8, None), (9, 15),
                           (9, 17), (10, None), (7, ctypes.c_size_t(-1).value)]:
        call = list(default)
        call[index] = invalid
        assert gcm(*call) == 0
        assert sentinel.raw == b"\xa5" * 2048
        passed("gcm_boundary_rejection")

    alias = buffer(values[3])
    call = list(default)
    call[6], call[10] = alias, alias
    assert gcm(*call) == 1 and alias.raw[:len(values[3])] == binary(tamper_case["plain"])
    passed("gcm_overlapping_output")
    assert gcm(buffer(b"\0" * 16), 16, buffer(b"\0" * 12), 12,
               None, 0, None, 0, buffer(binary(known_gcm[0]["tag"])), 16, None) == 1
    passed("gcm_null_empty_output")

    if args.official_fixtures:
        fixtures = json.loads(args.official_fixtures.read_text())
        if isinstance(fixtures, dict):
            fixtures = fixtures["fixtures"]
        for fixture in fixtures:
            if fixture["version"] != 5:
                continue
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(fixture["url"]).query)
            metadata = base64.b64decode(query["cpx"][0])
            body = base64.b64decode(fixture["bodyBase64"])
            length = int.from_bytes(body[1:5], "big")
            payload = body[5:5 + length]
            encrypted_prefix = payload[:30736]
            salt, iv = metadata[48:64], metadata[32:48]
            key = derive(binary(fixture["sharedHex"]), salt, 100000, 32)
            expected = base64.b64decode(fixture["expectedBase64"])
            decrypt({"key": key.hex(), "iv": iv.hex(), "aad": salt.hex(),
                     "cipher": encrypted_prefix[:-16].hex(), "tag": encrypted_prefix[-16:].hex(),
                     "plain": expected[:len(encrypted_prefix) - 16].hex()})
            assert expected[len(encrypted_prefix) - 16:] == payload[len(encrypted_prefix):]
            passed("official_v5_image_fixture")

    print(json.dumps({"status": "pass", "counts": counts,
                      "seconds": round(time.monotonic() - started, 3),
                      "library_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
                      "execution_host": "test-env", "device_execution": False}, indent=2))


if __name__ == "__main__":
    main()
