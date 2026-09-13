"""Bind a remotely built archive to explicit integration and native-UI snapshots."""
import argparse
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser()
    for name in ("manifest", "baseline", "integration", "ui-source", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    manifest, previous, integration = read(args.manifest), read(args.baseline), read(args.integration)
    assert integration["passed"] and integration["source_unchanged"] and integration["complete_matrix"]
    current = {item["path"]: item["sha256"] for item in manifest["files"]}
    baseline = {item["path"]: item["sha256"] for item in previous["files"]}
    tested = integration["source_sha256"]
    for name, digest in tested.items():
        if name.startswith("bilicomics/"):
            assert current.get(name) == digest, "Integration source mismatch: " + name
    ui = {}
    for name in ("bilicomics/ui/screens.lua", "bilicomics/ui/model.lua", "l10n/bilicomics_zh_CN.lua"):
        digest = hashlib.sha256((args.ui_source / name).read_bytes()).hexdigest()
        assert current.get(name) == digest, "Native UI source mismatch: " + name
        ui[name] = digest
    changed = sorted(name for name, digest in current.items() if baseline.get(name) != digest)
    assert all(name in tested or name in ui for name in changed), "A changed file lacks source evidence"
    entries = ["_meta.lua", "main.lua", "patches/2-bilicomics-provider.lua"]
    assert all(current[name] == baseline[name] for name in entries)
    archive = args.manifest.with_name(manifest["archive"])
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest["sha256"]
    result = {"archive_sha256": manifest["sha256"], "packaged_files": len(current),
              "archive_bytes": archive.stat().st_size, "baseline_archive_sha256": previous["sha256"],
              "integration_modules_match_tested_source": True, "integration_evidence": str(args.integration),
              "ui_files_match_frozen_test_snapshot": ui, "ui_snapshot": str(args.ui_source),
              "unchanged_entrypoints": entries, "changed_or_added_since_previous_package": changed,
              "unchanged_files": len(current) - len(changed), "live_account_workflow_rerun": False,
              "purchase_testing": False,
              "scope": "Source identity binds focused synthetic reading evidence; it does not establish all module behavior or live payment contracts"}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"files": len(current), "changed": len(changed), "archive_sha256": manifest["sha256"]}))


if __name__ == "__main__":
    main()
