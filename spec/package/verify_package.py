"""Verify archive contents and exclusion rules on the remote test environment."""
from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import traceback
import zipfile


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compatible_arm_relocations(data: bytes) -> bool:
    if data[:6] != b"\x7fELF\x01\x01" or struct.unpack_from("<H", data, 18)[0] != 40:
        return False
    offset = struct.unpack_from("<I", data, 28)[0]
    size, count = struct.unpack_from("<HH", data, 42)
    dynamic, relro = {}, False
    for index in range(count):
        kind, position, _, _, length, _, _, _ = struct.unpack_from("<8I", data, offset + index * size)
        if kind == 0x6474e552:
            relro = True
        elif kind == 2:
            for location in range(position, position + length, 8):
                tag, value = struct.unpack_from("<II", data, location)
                if tag == 0:
                    break
                dynamic[tag] = value
    now = 24 in dynamic or dynamic.get(30, 0) & 8 or dynamic.get(0x6ffffffb, 0) & 1
    return bool(relro and now and dynamic.get(19) == 8 and dynamic.get(20) == 17
                and dynamic.get(18, 0) > 0 and dynamic.get(2, 0) > 0
                and dynamic.get(17, -1) + dynamic[18] == dynamic.get(23))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    results = {"scope": "Deterministic packaging, native artifact integrity, and private-data exclusions", "checks": []}

    def check(name: str, condition: bool) -> None:
        results["checks"].append({"name": name, "passed": bool(condition)})
        assert condition, name

    def package(root: Path, destination: Path, success: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run([sys.executable, str(source / "tools/package.py"), "--root", str(root),
                                 "--output", str(destination)], capture_output=True, text=True, timeout=60)
        if success and result.returncode:
            raise RuntimeError(result.stderr)
        return result

    try:
        archive_path = output / "bilicomics-0.1.0-dev.zip"
        second_path = output / "repeat.zip"
        package(source, archive_path)
        package(source, second_path)
        check("repeated_package_bytes_are_identical", archive_path.read_bytes() == second_path.read_bytes())
        manifest = json.loads(archive_path.with_suffix(".manifest.json").read_text())
        with zipfile.ZipFile(archive_path) as archive:
            prefix = "bilicomics.koplugin/"
            names = archive.namelist()
            check("all_files_have_one_plugin_root", all(name.startswith(prefix) and ".." not in name.split("/") for name in names))
            required = {"main.lua", "_meta.lua", "bilicomics/settings.lua", "bilicomics/runtime.lua",
                        "bilicomics/controller.lua", "bilicomics/session_storage.lua", "bilicomics/jobs/storage_budget.lua",
                        "bilicomics/image_policy.lua", "bilicomics/reader/defaults.lua",
                        "bilicomics/ui/session_input.lua",
                        "bilicomics/jobs/source_refresh.lua", "bilicomics/storage/source_refresh.lua",
                        "bilicomics/jobs/version_replacement.lua", "bilicomics/storage/version_replacement.lua",
                        "bilicomics/protocol/native_library.lua",
                        "bilicomics/reader/document.lua", "l10n/bilicomics_zh_CN.lua", "patches/2-bilicomics-provider.lua"}
            if "bilicomics/purchase/selection" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.update({"bilicomics/purchase/selection.lua", "bilicomics/purchase/candidate.lua", "bilicomics/purchase/quote_fetch.lua"})
            if "bilicomics/session_manager" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.update({"bilicomics/session_manager.lua", "bilicomics/jobs/session_runner.lua",
                                 "bilicomics/protocol/auth.lua", "bilicomics/protocol/auth_crypto.lua", "bilicomics/ui/qr_login.lua"})
            if "bilicomics/cover_source" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.add("bilicomics/cover_source.lua")
            if "bilicomics/bookstore" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.add("bilicomics/bookstore.lua")
            if "bilicomics/bookstore_categories" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.add("bilicomics/bookstore_categories.lua")
            if "bilicomics/bookshelf_state" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.add("bilicomics/bookshelf_state.lua")
            if "bilicomics/recharge/controller" in archive.read(prefix + "bilicomics/controller.lua").decode("utf-8"):
                required.update({"bilicomics/recharge/controller.lua", "bilicomics/recharge/service.lua",
                                 "bilicomics/protocol/recharge.lua", "bilicomics/ui/recharge_screens.lua",
                                 "l10n/bilicomics_recharge_zh_CN.lua"})
            screens = archive.read(prefix + "bilicomics/ui/screens.lua").decode("utf-8")
            for name in ("catalog", "downloads", "account", "purchase"):
                if "bilicomics/ui/" + name + "_screens" in screens:
                    required.update({"bilicomics/ui/" + name + "_screens.lua",
                                     "bilicomics/ui/screen_helpers.lua", "l10n/bilicomics_" + name + "_zh_CN.lua"})
            if "bilicomics/protocol/recommendations" in archive.read(prefix + "bilicomics/protocol/client.lua").decode("utf-8"):
                required.add("bilicomics/protocol/recommendations.lua")
            if "bilicomics/protocol/categories" in archive.read(prefix + "bilicomics/protocol/client.lua").decode("utf-8"):
                required.add("bilicomics/protocol/categories.lua")
            auth = prefix + "bilicomics/protocol/auth.lua"
            if auth in names and "bilicomics/protocol/site_context" in archive.read(auth).decode("utf-8"):
                required.add("bilicomics/protocol/site_context.lua")
            collector = prefix + "bilicomics/purchase/quote_fetch.lua"
            if collector in names and "bilicomics/purchase/range" in archive.read(collector).decode("utf-8"):
                required.add("bilicomics/purchase/range.lua")
            check("production_entry_and_startup_dependencies_are_present", required <= {name[len(prefix):] for name in names})
            check("no_research_fixtures_or_account_directories", not any(
                {".secrets", "accounts", "research", "spec", "design", "temporary", "documents", "covers"} & set(name.split("/"))
                for name in names))
            check("no_duplicate_archive_paths", len(names) == len(set(names)))
            check("archive_manifest_covers_every_file", {entry["path"] for entry in manifest["files"]} == {name[len(prefix):] for name in names})
            check("archive_manifest_file_hashes_match", all(
                digest(archive.read(prefix + entry["path"])) == entry["sha256"]
                and len(archive.read(prefix + entry["path"])) == entry["bytes"] for entry in manifest["files"]))
            check("archive_digest_matches_manifest", digest(archive_path.read_bytes()) == manifest["sha256"])
            check("arm32_rel_tables_are_adjacent_with_bind_now_and_relro", all(compatible_arm_relocations(
                archive.read(prefix + "bilicomics/protocol/native/bin/linux-armhf/" + name))
                for name in ("libbiliwasm.so", "libbilicrypto.so")))
            artifacts = []
            for manifest_path in ("bilicomics/protocol/native/manifest.json", "bilicomics/protocol/native/portable/manifest.json"):
                native = json.loads(archive.read(prefix + manifest_path))
                for target, record in native["libraries"].items():
                    path = posixpath.normpath(posixpath.join(posixpath.dirname(manifest_path), record["path"]))
                    data = archive.read(prefix + path)
                    check("native_manifest_matches_" + Path(path).stem + "_" + target,
                          digest(data) == record["sha256"] and len(data) == record["bytes"])
                    artifacts.append({"target": target, "path": path, "device_verified": record["device_verified"]})
            licenses = {"bilicomics/protocol/native/licenses/wasm3-LICENSE", "bilicomics/protocol/native/licenses/cJSON-LICENSE",
                        "bilicomics/protocol/native/legacy_v5/vendor/mbedtls/LICENSE", "bilicomics/protocol/native/legacy_v5/NOTICE"}
            check("redistribution_notices_are_included", licenses <= {name[len(prefix):] for name in names})
        results["archive"] = {"file": archive_path.name, "sha256": manifest["sha256"], "bytes": archive_path.stat().st_size,
                              "files": len(manifest["files"]), "native_artifacts": artifacts}

        sandbox = Path(tempfile.mkdtemp(prefix="exclusion-fixture-", dir=output))
        (sandbox / "main.lua").write_text("return {}\n")
        (sandbox / "_meta.lua").write_text("return {name='synthetic'}\n")
        for relative in ("bilicomics/settings.lua", "bilicomics/.secrets/session.json", "bilicomics/accounts/a/session.dat",
                         "bilicomics/temporary/image.json", "research/session.json", "spec/fixture.lua", ".secrets/session.txt"):
            path = sandbox / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("SYNTHETIC_PACKAGE_EXCLUSION_SENTINEL\n")
        safe_archive = output / "safe-fixture.zip"
        package(sandbox, safe_archive)
        with zipfile.ZipFile(safe_archive) as archive:
            check("private_directories_excluded_even_under_production_root",
                  set(archive.namelist()) == {"bilicomics.koplugin/main.lua", "bilicomics.koplugin/_meta.lua",
                                            "bilicomics.koplugin/bilicomics/settings.lua"})
        misplaced = sandbox / "bilicomics/protocol/session.json"
        misplaced.parent.mkdir(parents=True)
        misplaced.write_text("SYNTHETIC_ACCOUNT_DATA\n")
        result = package(sandbox, output / "rejected-session.zip", success=False)
        check("misplaced_session_data_rejects_packaging", result.returncode != 0 and "Account data" in result.stderr)
        misplaced.unlink()
        (sandbox / "bilicomics/injected.lua").symlink_to(source / "main.lua")
        result = package(sandbox, output / "rejected-symlink.zip", success=False)
        check("symlink_inputs_reject_packaging", result.returncode != 0 and "inside the project" in result.stderr)
        results["passed"] = True
    except Exception:
        results["passed"], results["error"] = False, traceback.format_exc()
    (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps({"passed": results["passed"], "checks": len(results["checks"]), "result": str(output / "result.json")}))
    if not results["passed"]:
        print(results["error"], file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
