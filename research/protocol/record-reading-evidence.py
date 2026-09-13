"""Attach code provenance to an already sanitized reading-only report.

Run only on test-env. This script never reads a session or private catalog.
"""
import hashlib
import json
import pathlib
import sys

source, report_path, session_path = map(pathlib.Path, sys.argv[1:4])
report = json.loads(report_path.read_text())
files = (
    "bilicomics/protocol/client.lua",
    "bilicomics/protocol/crypto.lua",
    "bilicomics/protocol/normalize.lua",
    "bilicomics/protocol/transport.lua",
    "bilicomics/protocol/image.lua",
    "bilicomics/protocol/image_crypto.lua",
    "bilicomics/protocol/native_backend.lua",
    "bilicomics/protocol/native_library.lua",
    "bilicomics/protocol/native/manifest.json",
    "bilicomics/protocol/native/portable/manifest.json",
)
report["provenance"] = {
    "host": "test-env",
    "runtime": "Official KOReader v2026.07.1 Linux x86_64",
    "source_sha256": {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in files},
    "remote_session_input_removed": not session_path.exists(),
    "actual_purchase_testing": False,
    "quote_and_wallet_testing": False,
    "image_container_verification_is_not_native_rendering": True,
    "real_encrypted_image_observed": any(
        page.get("encrypted") for item in report["images"].values() for page in item.get("pages", [])
    ),
}
report_path.write_text(json.dumps(report, indent=2) + "\n")
