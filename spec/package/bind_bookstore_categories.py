"""Bind the categorized Bookstore archive, focused checks and anonymous live evidence."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile
import zipfile


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise SystemExit("Run through ssh test-env.")
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--delivery", type=Path, required=True)
    parser.add_argument("--package-result", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, delivery = args.source.resolve(), args.delivery.resolve()
    checks, evidence = [], {}

    def check(name, condition):
        checks.append({"name": name, "passed": bool(condition)})
        if not condition:
            raise RuntimeError(name)

    def read(relative):
        data = (source / relative).read_bytes()
        evidence[relative] = sha(data)
        return json.loads(data)

    def source_map(name, mapping):
        check(name, bool(mapping) and all(
            sha((source / path).read_bytes()) == digest for path, digest in mapping.items()))

    with tarfile.open(delivery / "final-source.tar") as archive:
        production = {item.name: sha(archive.extractfile(item).read())
                      for item in archive if item.isfile()}
    staged_files = [source / "main.lua", source / "_meta.lua"]
    for directory in ("bilicomics", "l10n", "patches"):
        staged_files.extend(path for path in (source / directory).rglob("*") if path.is_file())
    staged = {path.relative_to(source).as_posix(): sha(path.read_bytes()) for path in staged_files}
    check("complete_delivered_checkout_matches_remote_production_source", production == staged)

    package = json.loads(args.package_result.read_text())
    check("all_package_checks_passed", package["passed"] and len(package["checks"]) == 27
          and all(item["passed"] for item in package["checks"]))
    manifest = json.loads((delivery / "bilicomics-0.1.0-dev.manifest.json").read_text())
    archive_path = delivery / "bilicomics-0.1.0-dev.zip"
    archive_sha = sha(archive_path.read_bytes())
    check("delivered_archive_matches_manifest_and_package_report",
          archive_sha == manifest["sha256"] == package["archive"]["sha256"])
    entries = {item["path"]: item for item in manifest["files"]}
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        check("package_has_exact_unique_manifest_paths", len(names) == len(entries)
              and set(names) == {"bilicomics.koplugin/" + path for path in entries})
        check("all_package_bytes_match_checkout_and_manifest", all(
            sha(archive.read("bilicomics.koplugin/" + path)) == item["sha256"] == production[path]
            and len(archive.read("bilicomics.koplugin/" + path)) == item["bytes"]
            for path, item in entries.items()))

    totals = {"package_checks": 27}
    for kind, report_path in (
        ("bookshelf", "spec/ui/bookshelf-categories-grid-verification.json"),
        ("bookstore", "spec/ui/bookstore-categories-verification.json"),
    ):
        report = read(report_path)
        check(kind + "_native_matrix_passed", report["passed"] and len(report["cases"]) == 8
              and all(case["passed"] and case["returncode"] == 0 for case in report["cases"]))
        source_map(kind + "_ui_executed_current_sources", report["sources"])
        totals[kind + "_native_cases"] = len(report["cases"])
        totals[kind + "_native_assertions"] = sum(case["assertions"] for case in report["cases"])

    controller = read("spec/controller/bookstore-categories-controller-verification.json")
    check("bookstore_controller_passed", controller["passed"] and controller["returncode"] == 0
          and controller["result"]["passed"] and all(case["passed"] for case in controller["result"]["tests"]))
    source_map("bookstore_controller_executed_current_sources", controller["source_sha256"])
    totals["bookstore_controller_cases"] = len(controller["result"]["tests"])
    homepage = read("spec/controller/bookstore-categories-homepage-regression-result.json")
    check("homepage_cache_compatibility_passed", homepage["passed"]
          and len(homepage["tests"]) == 23 and all(case["passed"] for case in homepage["tests"]))
    totals["homepage_controller_cases"] = len(homepage["tests"])
    regression = read("spec/controller/bookstore-categories-regression-result.json")
    check("controller_regression_passed", regression["count"] == 69
          and len(regression["assertions"]) == 69 and all(item["passed"] for item in regression["assertions"]))
    totals["controller_regression_assertions"] = 69
    covers = read("spec/controller/bookstore-categories-cover-regression-result.json")
    check("cover_regression_passed", covers["passed"] and len(covers["tests"]) == 33
          and all(item["passed"] for item in covers["tests"]))
    totals["cover_regression_assertions"] = 33

    protocol = read("spec/protocol/bookstore-categories-verification.json")
    source_map("category_protocol_executed_current_sources", protocol["source_hashes"])
    check("category_protocol_passed", protocol["passed"] and protocol["source_unchanged"]
          and protocol["focused"]["passed"] and all(case["passed"] for case in protocol["focused"]["cases"]))
    check("real_anonymous_category_protocol_passed", protocol["live"]["passed"]
          and protocol["live"]["readonly_guard_installed"] and protocol["live"]["parent_session_absent"]
          and protocol["live"]["parent_session_update_absent"]
          and not protocol["live"]["account_credentials_used"] and not protocol["live"]["device_cookie_persisted"])
    totals["category_protocol_assertions"] = protocol["focused"]["assertions"]

    guard = read("spec/local/category-guard-results.json")
    check("category_readonly_guard_passed", guard["passed"] and guard["returncode"] == 0 and guard["source_unchanged"])
    source_map("category_guard_and_spec_match", {
        "spec/local/readonly_guard.lua": guard["guard_sha256"],
        "spec/local/readonly_guard_spec.lua": guard["spec_sha256"],
    })
    totals["readonly_guard_assertions"] = len(guard["suite"]["assertions"])

    live = read("spec/ui/bookstore-categories-live-verification.json")
    source_map("live_bookstore_executed_current_sources", live["source_sha256"])
    native = live["native_result"]
    check("real_native_bookstore_and_visible_covers_loaded", live["passed"] and live["source_unchanged"]
          and live["returncode"] == 0 and native["passed"]
          and len(native["visible_cards"]) == 6 and all(card["cover_loaded"] for card in native["visible_cards"])
          and native["runner_idle"] and native["runtime_closed"] and native["synthetic_data"] is False)
    check("real_category_picker_and_hot_blood_selection_verified", len(native["categories"]) == 16
          and native["comic_count"] == 18 and native["feed_source"] == "official_category"
          and native["selected_category"]["id"] == "999" and native["query"]["category_id"] == "999"
          and native["query"]["sort"] == 0 and native["picker_used_native_callback"]
          and native["selection_used_native_callback"] and native["loaded_pages"] == 1)
    check("live_bookstore_requests_were_public_read_only", live["all_requests_succeeded_with_existing_readonly_guard"]
          and live["isolated_profile_contains_no_session_file"] and native["session_present"] is False
          and native["account_key"] == "anonymous" and native["session_lookups"] == ["anonymous"]
          and native["favorite_count"] == 0 and native["history_count"] == 0 and native["download_count"] == 0)
    check("both_category_framebuffers_present", {record["name"] for record in live["screenshots"]} == {
        "bookstore-categories-live-picker.png", "bookstore-categories-live-heat.png"})
    for record in live["screenshots"]:
        screenshot = "spec/ui/screens/bookstore-categories-live/" + record["name"]
        check("delivered_" + record["name"], sha((source / screenshot).read_bytes()) == record["sha256"])
        evidence[screenshot] = record["sha256"]
    totals["live_categories"] = len(native["categories"])
    totals["live_category_comics"] = native["comic_count"]
    totals["live_visible_covers"] = len(native["visible_cards"])
    totals["live_public_requests"] = len(live["requests"])

    result = {
        "passed": True, "execution_host": "test-env", "bound_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Delivered categorized Bookstore source, deterministic archive, native subject selection and real anonymous browsing",
        "base_commit": "e86f894742dba66242e582dbfb8510e941ebd616", "includes_uncommitted_changes": True,
        "archive": "dist/bilicomics-0.1.0-dev.zip", "archive_sha256": archive_sha,
        "archive_bytes": archive_path.stat().st_size, "packaged_files": len(entries),
        "production_files": len(production), "production_sha256": production,
        "checks": checks, "verification": totals, "evidence_sha256": evidence,
        "package_report_sha256": sha(args.package_result.read_bytes()),
        "provenance_note": "Each focused runner binds its executed source subset. Controller and cover regressions use the same final remote source. Earlier Client/Worker and native business/session/QR receipts retain their original scope; they are not repeated acceptance for this revision. Real anonymous browsing does not claim account reading, charging or physical-device compatibility.",
        "local_runtime_verification": False, "new_live_account_reading": False, "actual_payment": False,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in (
        "passed", "archive_sha256", "packaged_files", "production_files", "verification")}))


if __name__ == "__main__":
    main()
