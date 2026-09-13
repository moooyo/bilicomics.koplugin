"""Record static-only source provenance for the separate quote-adapter preview."""
import argparse
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser()
    for name in ("manifest", "baseline", "syntax", "package-result", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    manifest, baseline, syntax, packaged = map(read,
        (args.manifest, args.baseline, args.syntax, args.package_result))
    assert syntax["passed"] and syntax["modules_executed"] is False and packaged["passed"]
    current = {item["path"]: item["sha256"] for item in manifest["files"]}
    previous = {item["path"]: item["sha256"] for item in baseline["files"]}
    compiled = {item["path"]: item["sha256"] for item in syntax["files"]}
    assert all(current.get(name) == value for name, value in compiled.items())
    changed = sorted(name for name, value in current.items() if previous.get(name) != value)
    assert all(name in compiled or name.endswith(".md") for name in changed)
    archive = args.manifest.with_name(manifest["archive"])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert digest == manifest["sha256"] == packaged["archive"]["sha256"]
    report = {"archive_sha256": digest, "archive_file": archive.name,
              "archive_bytes": archive.stat().st_size, "packaged_files": len(current),
              "reference_runtime_archive_sha256": baseline["sha256"],
              "syntax_checked_files": compiled, "syntax_evidence": str(args.syntax),
              "changed_or_added_since_runtime_archive": changed, "unchanged_files": len(current) - len(changed),
              "package_checks": len(packaged["checks"]), "this_archive_runtime_verified": False,
              "payment_ui_behavior_verified": False, "live_quote_contract_verified": False,
              "purchase_tests_executed": False,
              "scope": "Changed Lua bytes match syntax-only compilation; the preview is not a runtime or purchasing acceptance result"}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"static_source_bound": True, "files": len(current), "changed": len(changed), "sha256": digest}))


if __name__ == "__main__":
    main()
