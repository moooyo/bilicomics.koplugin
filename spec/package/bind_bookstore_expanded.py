"""Bind the expanded Bookstore archive, native layouts and anonymous live evidence."""
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
        ("bookshelf", "spec/ui/bookshelf-expanded-grid-verification.json"),
        ("bookstore", "spec/ui/bookstore-expanded-verification.json"),
    ):
        report = read(report_path)
        check(kind + "_native_matrix_passed", report["passed"] and len(report["cases"]) == 8
              and all(case["passed"] and case["returncode"] == 0 for case in report["cases"]))
        source_map(kind + "_ui_executed_current_sources", report["sources"])
        totals[kind + "_native_cases"] = len(report["cases"])
        totals[kind + "_native_assertions"] = sum(case["assertions"] for case in report["cases"])

    controller = read("spec/controller/bookstore-expanded-controller-verification.json")
    check("bookstore_controller_passed", controller["passed"] and controller["returncode"] == 0
          and controller["result"]["passed"] and all(case["passed"] for case in controller["result"]["tests"]))
    source_map("bookstore_controller_executed_current_sources", controller["source_sha256"])
    totals["bookstore_controller_cases"] = len(controller["result"]["tests"])
    regression = read("spec/controller/bookstore-expanded-regression-result.json")
    check("controller_regression_passed", regression["count"] == 69
          and len(regression["assertions"]) == 69 and all(item["passed"] for item in regression["assertions"]))
    totals["controller_regression_assertions"] = 69
    covers = read("spec/controller/bookstore-expanded-cover-regression-result.json")
    check("cover_regression_passed", covers["passed"] and len(covers["tests"]) == 33
          and all(item["passed"] for item in covers["tests"]))
    totals["cover_regression_assertions"] = 33

    protocol = read("spec/protocol/recommendations-expanded-verification.json")
    source_map("recommendation_protocol_executed_current_sources", protocol["source_sha256"])
    check("expanded_recommendation_protocol_passed", protocol["passed"] and protocol["source_unchanged"]
          and protocol["returncode"] == 0 and protocol["result"]["assertions"] == 153
          and protocol["result"]["passed"] and protocol["result"]["live_fixture_checked"])
    totals["recommendation_protocol_assertions"] = protocol["result"]["assertions"]

    live = read("spec/ui/bookstore-expanded-live-verification.json")
    source_map("live_bookstore_executed_current_sources", live["source_sha256"])
    native = live["native_result"]
    check("real_native_bookstore_and_visible_covers_loaded", live["passed"] and live["source_unchanged"]
          and live["returncode"] == 0 and native["passed"] and native["first_screen_covers_loaded"]
          and native["runner_idle"] and native["runtime_closed"] and native["synthetic_data"] is False)
    check("expanded_feed_and_two_dense_pages_verified", live["native_identity_verified"]
          and live["recommendation_count"] > 7 and live["captured_card_count"] == 12
          and len(native["captured_pages"]) == 2 and native["visible_ids_unique_and_ordered"]
          and all(len(page["cards"]) == 6 and page["all_covers_loaded"] for page in native["captured_pages"]))
    check("live_bookstore_requests_were_public_read_only", live["all_requests_public_and_read_only"]
          and live["all_responses_successful"] and live["boundary_failures"] == []
          and live["isolated_profile_contains_no_session_file"] and native["session_present"] is False
          and native["favorite_count"] == 0 and native["history_count"] == 0 and native["download_count"] == 0)
    for record in live["screenshots"]:
        expected = "bookstore-expanded-live-page-{:02d}.png".format(record["page"])
        screenshot = "spec/ui/screens/bookstore-expanded-live/" + expected
        check("delivered_live_framebuffer_page_{}".format(record["page"]), record["screenshot"] == expected
              and sha((source / screenshot).read_bytes()) == record["sha256"])
        evidence[screenshot] = record["sha256"]
    totals["live_recommendations"] = len(native["recommendations"])
    totals["live_captured_pages"] = len(native["captured_pages"])
    totals["live_visible_covers"] = live["captured_card_count"]
    totals["live_public_get_requests"] = len(live["requests"])

    result = {
        "passed": True, "execution_host": "test-env", "bound_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Delivered expanded Bookstore source, deterministic archive, native compact grid and real anonymous multi-page browsing",
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
