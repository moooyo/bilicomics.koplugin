"""Bind the finishing preview to verified sources without claiming live acceptance."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import zipfile


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise SystemExit("Run through ssh test-env.")
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--delivery", type=Path, required=True)
    parser.add_argument("--regression-output", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, delivery = args.source.resolve(), args.delivery.resolve()
    checks, evidence = [], {}

    def check(name, condition):
        checks.append({"name": name, "passed": bool(condition)})
        if not condition:
            raise RuntimeError(name)

    def read(path):
        evidence[path] = digest(source / path)
        return json.loads((source / path).read_text())

    def matches(mapping):
        return bool(mapping) and all((source / path).is_file()
                                    and digest(source / path) == value
                                    for path, value in mapping.items())

    production_paths = [source / "main.lua", source / "_meta.lua"]
    for directory in ("bilicomics", "l10n", "patches"):
        production_paths.extend(path for path in (source / directory).rglob("*") if path.is_file())
    production = {path.relative_to(source).as_posix(): digest(path) for path in production_paths}
    common = read("spec/integration/finishing-regression-results.json")
    check("complete_production_tree_matches_common_regression", production == common["production_sha256"])
    check("all_34_common_suites_passed", common["passed"] and common["source_unchanged"]
          and len(common["suites"]) == 34 and all(case["passed"] and case["returncode"] == 0
                                               for case in common["suites"]))
    check("common_child_receipts_match_recorded_hashes", all(
        digest(args.regression_output / case["report"]) == case["report_sha256"]
        for case in common["suites"]))

    package = read("spec/package/finishing-results.json")
    check("all_27_package_checks_passed", package["passed"] and len(package["checks"]) == 27
          and all(case["passed"] for case in package["checks"]))
    package_case = next(case for case in common["suites"] if case["suite"] == "package")
    check("package_receipt_is_from_common_regression",
          evidence["spec/package/finishing-results.json"] == package_case["report_sha256"])
    manifest = json.loads((delivery / "bilicomics-finishing-preview.manifest.json").read_text())
    archive_path = delivery / "bilicomics-finishing-preview.zip"
    archive_sha = digest(archive_path)
    check("preview_archive_matches_manifest_and_verified_archive",
          archive_sha == manifest["sha256"] == package["archive"]["sha256"])
    entries = {item["path"]: item for item in manifest["files"]}
    with zipfile.ZipFile(archive_path) as archive:
        check("archive_paths_exactly_match_manifest", len(archive.namelist()) == len(entries)
              and set(archive.namelist()) == {"bilicomics.koplugin/" + path for path in entries})
        check("every_packaged_file_matches_verified_production", all(
            hashlib.sha256(archive.read("bilicomics.koplugin/" + path)).hexdigest()
            == item["sha256"] == production[path]
            and len(archive.read("bilicomics.koplugin/" + path)) == item["bytes"]
            for path, item in entries.items()))

    ui = read("spec/ui/bookshelf-finishing-verification.json")
    check("native_ui_sources_and_eight_cases_match", matches(ui["sources"]) and ui["passed"]
          and len(ui["cases"]) == 8 and all(case["passed"] and case["returncode"] == 0 for case in ui["cases"]))
    controller = read("spec/controller/finishing-bookshelf-controller-verification.json")
    check("final_controller_sources_and_31_cases_match", matches(controller["source_sha256"])
          and controller["source_unchanged"] and controller["returncode"] == 0
          and controller["result"]["passed"] and len(controller["result"]["tests"]) == 31
          and all(case["passed"] for case in controller["result"]["tests"]))
    protocol = read("spec/protocol/site-context-verification.json")
    check("site_context_sources_and_verification_match", matches(protocol["source_hashes"])
          and protocol["passed"] and protocol["protocol"]["passed"] and protocol["guard"]["passed"])
    concurrency = read("spec/jobs/finishing-concurrency-results.json")
    # The real-fork fixture imports jobs, sessions, settings and storage directly;
    # it never loads the plugin UI. UI acceptance has its own source-bound matrix.
    concurrency_scope = {path: value for path, value in concurrency["source_sha256_before"].items()
                         if (path in production and not path.startswith("bilicomics/ui/"))
                         or path in ("spec/jobs/concurrency_spec.lua", "spec/jobs/run_concurrency.py")}
    check("executed_concurrency_sources_and_cases_match", matches(concurrency_scope)
          and concurrency["passed"] and concurrency["source_unchanged"]
          and all(case["passed"] and case["returncode"] == 0 for case in concurrency["suites"]))
    totals = {key: sum(case["result"]["counts"][key] for case in concurrency["suites"])
              for key in ("tests", "assertions", "actual_forks")}
    check("recorded_real_process_concurrency_totals_match", totals == {
        "tests": 25, "assertions": 668, "actual_forks": 126})

    inventory_changes = {}
    for report_name, mapping in (("common", common["test_source_sha256"]),
                                 ("concurrency", concurrency["source_sha256_before"])):
        inventory_changes[report_name] = [path for path, value in mapping.items()
                                         if not (source / path).is_file() or digest(source / path) != value]
    result = {
        "passed": True,
        "scope": "Preview source, deterministic archive, and already executed remote verification binding only",
        "bound_at": datetime.now(timezone.utc).isoformat(), "execution_host": "test-env",
        "base_commit": common["base_commit"], "includes_uncommitted_changes": True,
        "goal_complete": False, "release_ready": False, "canonical_candidate_replaced": False,
        "archive": "dist/bilicomics-finishing-preview.zip", "archive_sha256": archive_sha,
        "packaged_files": len(entries), "production_files": len(production),
        "production_sha256": production, "common_snapshot_sha256": common["snapshot_sha256"],
        "checks": checks, "evidence_sha256": evidence,
        "verification": {"common_suites": 34, "package_checks": 27, "controller_cases": 31,
                         "ui_cases": 8, "ui_assertions": sum(case["assertions"] for case in ui["cases"]),
                         "concurrency": totals},
        "inventory_changes_since_receipts": inventory_changes,
        "scope_note": "Inventory hashes do not imply every inventoried harness ran. Common regression production matches exactly. Focused concurrency binds non-UI production and its executed fixture; the plugin UI has a separate source-bound matrix. Live-reading telemetry is pending real execution.",
        "pending": ["Fresh phone-confirmed QR login and persisted-session restart",
                    "Complete real free-chapter online, parallel download, and new-process offline workflow",
                    "Final canonical package, complete acceptance binding, and completion audit"],
        "local_runtime_verification": False, "final_live_account_acceptance": False,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in (
        "passed", "goal_complete", "archive_sha256", "packaged_files", "production_files", "verification",
        "inventory_changes_since_receipts")}))


if __name__ == "__main__":
    main()
