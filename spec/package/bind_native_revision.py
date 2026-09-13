"""Bind an ARM-only package revision to prior Lua evidence and current primitive checks."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser()
    for name in ("manifest", "previous", "glibc220", "glibc241", "package-result", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    manifest, previous, old_glibc, new_glibc, package = map(read,
        (args.manifest, args.previous, args.glibc220, args.glibc241, args.package_result))
    assert package["passed"] and old_glibc["passed"] and new_glibc["passed"]
    assert old_glibc["diagnostic_modified_loader"] and not new_glibc["diagnostic_modified_loader"]
    assert old_glibc["probe"]["passed"] == new_glibc["probe"]["passed"] == 9
    assert old_glibc["libraries"] == new_glibc["libraries"]
    current = {item["path"]: item["sha256"] for item in manifest["files"]}
    baseline = {item["path"]: item["sha256"] for item in previous["files"]}
    changed = sorted(name for name, value in current.items() if baseline.get(name) != value)
    native = "bilicomics/protocol/native/"
    expected = {native + suffix for suffix in ("manifest.json", "portable/manifest.json", "README.md", "portable/README.md",
                                               "bin/linux-armhf/libbiliwasm.so", "bin/linux-armhf/libbilicrypto.so")}
    assert set(changed) <= expected
    assert all(value == baseline.get(name) for name, value in current.items() if name.endswith(".lua"))
    for name, record in old_glibc["libraries"].items():
        assert current[native + "bin/linux-armhf/" + name] == record["sha256"]
    archive = args.manifest.with_name(manifest["archive"])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert digest == manifest["sha256"] == package["archive"]["sha256"]
    with zipfile.ZipFile(archive) as content:
        assert not any("ld-linux" in name or "ld-2.20" in name or "/sysroot/" in name for name in content.namelist())
    report = {"archive_file": archive.name, "archive_sha256": digest, "archive_bytes": archive.stat().st_size,
              "packaged_files": len(current), "previous_archive_sha256": previous["sha256"],
              "changed_since_previous_archive": changed, "unchanged_files": len(current) - len(changed),
              "all_lua_files_unchanged": True, "native_libraries_match_both_runtime_probes": True,
              "native_runtime_evidence": {"glibc220_diagnostic_loader": str(args.glibc220), "glibc241": str(args.glibc241)},
              "native_libraries": old_glibc["libraries"], "package_checks": len(package["checks"]),
              "diagnostic_loader_packaged": False, "device_verified": False, "purchase_tests_executed": False,
              "scope": "Only ARM binaries, their manifests and native documentation changed; earlier Lua/quote evidence retains its original scope"}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"archive_sha256": digest, "bytes": archive.stat().st_size, "files": len(current), "changed": changed}))


if __name__ == "__main__":
    main()
