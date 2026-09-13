"""Bind the final development candidate to complete public acceptance receipts.

This program reads public code, archives and reports only. It neither reads a
private session nor runs any application, test suite or network request.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import zipfile


EXPECTED_ARCHIVE = "43999a0ea657216a8f6206c74641a4c5f3832f95e66f02d9920b90c016905cbd"
EXPECTED_COMMON = "a0b80892866598c0d4491e389a8a781044e1b8aacd3f5e231f34306149336dd6"
COMMON_SUITES = set("""package reader-native auth-protocol auth-crypto session-manager
session-controller session-storage session-import qr-ui-zh qr-ui-en protocol-client
protocol-native-crypto controller controller-authentication controller-product
controller-diagnostics controller-prefetch purchase-dispatch jobs download-connectivity
storage storage-source-refresh storage-version-replacement source-refresh-workflow
version-replacement-workflow purchase-single purchase-ordinal-range purchase-ordinal-transaction
purchase-selection reader-defaults startup-contract startup-production startup-fallback
reading-integration""".split())
CONCURRENCY_CASES = {
    "runner": set("""settings_and_runner_contracts runner_real_overlap_1 runner_real_overlap_2
runner_real_overlap_4 running_four_to_one_drains_without_cancellation
ordinary_priorities_do_not_preempt_during_downshift visible_page_preempts_background_and_restarts_once
protected_work_survives_downshift_and_suspend parent_storage_reservations_bound_four_workers
retry_and_preemption_reacquire_storage_reservations reservations_follow_the_filesystem_across_directories
cancel_and_timeout_release_reservations_after_reap""".split()),
    "service": set("""legacy_settings_without_concurrency_keep_one_page_window
single_chapter_real_parallel_download_1 single_chapter_real_parallel_download_2 single_chapter_real_parallel_download_4
live_increase_refills_the_current_chapter out_of_order_settlement_refills_distinct_pages
live_chapter_downshift_stops_new_page_starts visible_owner_promotes_one_page_and_pause_preserves_reader
one_page_failure_retires_other_job_owners failure_counts_ready_pages_before_deferred_refill
immediate_resume_ignores_old_parallel_cancellation_callbacks source_generation_change_retires_only_the_stale_page
session_wrapper_and_real_default_settings_keep_account_isolation""".split()),
}
CONTROLLER_CASES = set("""Uncached getters and unauthenticated automatic entry never dispatch
A successful empty bookshelf is cached and stays distinct from no cache after restart
Corrupt or cross account snapshot metadata cannot certify an empty bookshelf cache
Legacy favorites are usable stale cache and synchronize in server order
The fifteen minute boundary refreshes once and manual refresh bypasses freshness
Both library responses publish atomically when favorites completes first
Both library responses publish atomically when history completes first
A failed favorites response retains the entire preceding snapshot
A failed history response retains the entire preceding snapshot
A snapshot storage failure rolls back both libraries and their comic mutations
Submission exceptions finish single flight and allow a clean manual retry
Repeated worker completion cannot publish a partial result or invoke waiters twice
Malformed and duplicate synchronized identities never replace usable cache
Local exact anchors survive conflicting chapter level server history
A completed concurrent following change to false wins over old sync data
A completed concurrent following change to true wins over old sync data
An in flight following operation preserves prior state until its confirmed completion
A late library completion after account does not notify or publish
A late library completion after close does not notify or publish
Automatic entry respects reader activity suspension offline state and invalid authentication
Offline cache and failure backoff stay usable while manual retry can immediately recover
Automatic retry begins at sixty seconds and a clock rollback makes cache stale
View changes merge preserve focus and persist across a restart
View state and sync snapshots are account scoped and reject stale account saves
Corrupt view fields normalize safely and a failed save retains prior persistent view
Concurrency settings initialize the runner persist and notify both live schedulers
Invalid concurrency values cannot change persistent settings or scheduler policy
A concurrency persistence failure cannot alter the effective setting or runtime policy
A native settings write failure is detected even when LuaSettings flush returns normally
Reader close returns on the next tick and newer reader or opening state suppresses it
Closing the active reader cannot return while another tracked reader is still open""".splitlines())
FORBIDDEN = {"private", ".secrets", "accounts", "session.dat", "session.json", "cookies.json", "cookies.txt"}


def relative_name(name: str) -> str:
    if not isinstance(name, str) or not name or "\\" in name or "\0" in name:
        raise ValueError("Invalid public relative path")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in (".", "..") or part.lower() in FORBIDDEN for part in path.parts):
        raise ValueError("Private or escaping paths are outside this binder")
    return path.as_posix()


def public_file(root: Path, name: str) -> Path:
    name = relative_name(name)
    path = root
    for part in PurePosixPath(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Public evidence must not traverse a symbolic link")
    if not path.is_file() or not path.resolve().is_relative_to(root):
        raise ValueError("Required public file is unavailable")
    return path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def all_true(values, names=None) -> bool:
    return isinstance(values, dict) and bool(values) and all(values.get(name) is True for name in (names or values))


def unique_cases(cases, expected, key="name") -> bool:
    return isinstance(cases, list) and len(cases) == len(expected) and {case.get(key) for case in cases} == expected


def peak(intervals):
    active = maximum = 0
    overlap, previous = 0.0, None
    events = [(item["started_seconds"], 1) for item in intervals]
    events += [(item["finished_seconds"], -1) for item in intervals]
    for moment, change in sorted(events):
        if previous is not None and active >= 2:
            overlap += moment - previous
        active += change
        maximum = max(maximum, active)
        previous = moment
    return maximum, overlap


def main() -> None:
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise SystemExit("Run through ssh test-env.")
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "evidence-root", "delivery", "regression-output", "ui-output", "guard", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--source-archive", type=Path)
    args = parser.parse_args()
    source, receipts, delivery = (path.resolve(strict=True) for path in (args.source, args.evidence_root, args.delivery))
    regression_root = args.regression_output.resolve(strict=True)
    checks, evidence = [], {}

    def check(name, condition):
        checks.append({"name": name, "passed": condition is True})
        if condition is not True:
            raise ValueError(name)

    def read(name):
        path = public_file(receipts, name)
        evidence[name] = digest(path)
        return json.loads(path.read_text())

    def matches(mapping, prefix=""):
        return isinstance(mapping, dict) and bool(mapping) and all(
            digest(public_file(source, prefix + name)) == value for name, value in mapping.items())

    production_paths = [public_file(source, "main.lua"), public_file(source, "_meta.lua")]
    for directory in ("bilicomics", "l10n", "patches"):
        production_paths.extend(public_file(source, path.relative_to(source).as_posix())
                                for path in (source / directory).rglob("*") if path.is_file())
    production = {path.relative_to(source).as_posix(): digest(path) for path in production_paths}
    uploaded_source_sha = None
    if args.source_archive is not None:
        source_archive = args.source_archive.resolve(strict=True)
        check("uploaded_source_archive_is_public", not args.source_archive.is_symlink()
              and not any(part.lower() in FORBIDDEN for part in source_archive.parts))
        uploaded = {}
        with tarfile.open(source_archive) as archive:
            for item in archive:
                if item.isdir():
                    continue
                if not item.isfile():
                    raise ValueError("Uploaded source contains a nonregular file")
                name = relative_name(item.name)
                if name in uploaded:
                    raise ValueError("Uploaded source contains duplicate paths")
                uploaded[name] = hashlib.sha256(archive.extractfile(item).read()).hexdigest()
        check("actual_uploaded_source_matches_all_208_verified_production_files", uploaded == production)
        uploaded_source_sha = digest(source_archive)
    common = read("spec/integration/finishing-regression-results.json")
    check("final_208_file_production_matches_identified_common_snapshot", len(production) == 208
          and production == common["production_sha256"] and common["snapshot_sha256"] == EXPECTED_COMMON)
    check("all_34_named_common_suites_passed", common["passed"] is True and common["source_unchanged"] is True
          and common["host"] == "test-env" and common["network_namespace_isolated"] is True
          and common["actual_purchases_permitted"] is False and common["cancelled"] is False
          and unique_cases(common["suites"], COMMON_SUITES, "suite")
          and set(common["planned_suites"]) == COMMON_SUITES
          and all(case["passed"] is True and case["returncode"] == 0 for case in common["suites"]))
    check("all_common_child_receipts_match_recorded_bytes", all(
        digest(public_file(regression_root, case["report"])) == case["report_sha256"] for case in common["suites"]))

    package = read("spec/package/finishing-results.json")
    check("all_27_package_checks_passed", package["passed"] is True and len(package["checks"]) == 27
          and len({case["name"] for case in package["checks"]}) == 27 and all(case["passed"] is True for case in package["checks"]))
    package_case = next(case for case in common["suites"] if case["suite"] == "package")
    check("package_receipt_is_the_common_suite_receipt",
          evidence["spec/package/finishing-results.json"] == package_case["report_sha256"])
    archive_path = public_file(delivery, "bilicomics-0.1.0-dev.zip")
    manifest_path = public_file(delivery, "bilicomics-0.1.0-dev.manifest.json")
    manifest = json.loads(manifest_path.read_text())
    archive_sha = digest(archive_path)
    check("canonical_bytes_match_the_108_file_verified_candidate", archive_sha == EXPECTED_ARCHIVE
          and archive_sha == manifest["sha256"] == package["archive"]["sha256"]
          and manifest["archive"] == archive_path.name
          and archive_path.stat().st_size == package["archive"]["bytes"] and package["archive"]["files"] == 108)
    entries = {relative_name(item["path"]): item for item in manifest["files"]}
    # Match the explicit production packaging policy; 100 native build sources are intentionally omitted.
    packaged_paths = {name for name in production if
                      (PurePosixPath(name).suffix in {".lua", ".so", ".json", ".md"}
                       or "licenses" in PurePosixPath(name).parts or PurePosixPath(name).name in {"LICENSE", "NOTICE", "COPYING"})
                      and not set(PurePosixPath(name).parts).intersection({"node_modules", "build", "test", "tests", "temporary", "documents", "covers"})}
    check("manifest_contains_the_complete_packaging_allowlist", len(manifest["files"]) == len(entries) == 108
          and set(entries) == packaged_paths)
    with zipfile.ZipFile(archive_path) as archive:
        check("archive_has_exact_unique_regular_paths", len(archive.infolist()) == 108
              and set(archive.namelist()) == {"bilicomics.koplugin/" + name for name in entries}
              and all(stat.S_IFMT(info.external_attr >> 16) in (0, stat.S_IFREG) for info in archive.infolist()))
        check("every_archive_byte_matches_manifest_and_final_production", all(
            hashlib.sha256(archive.read("bilicomics.koplugin/" + name)).hexdigest() == item["sha256"] == production[name]
            and len(archive.read("bilicomics.koplugin/" + name)) == item["bytes"] for name, item in entries.items()))
    preview = read("spec/package/finishing-preview-binding.json")
    check("existing_preview_identity_is_preserved", preview["passed"] is True and preview["goal_complete"] is False
          and preview["archive_sha256"] == archive_sha and preview["production_sha256"] == production
          and preview["common_snapshot_sha256"] == EXPECTED_COMMON)

    ui = read("spec/ui/bookshelf-finishing-verification.json")
    configurations = {(language, width, height) for language in ("C", "zh_CN")
                      for width, height in ((480, 640), (600, 800), (720, 960), (960, 720))}
    check("ui_has_the_eight_exact_configurations_and_1154_assertions", ui["passed"] is True and matches(ui["sources"])
          and len(ui["cases"]) == 8 and {(case["language"], case["width"], case["height"]) for case in ui["cases"]} == configurations
          and sum(case["assertions"] for case in ui["cases"]) == 1154
          and all(case["passed"] is True and case["returncode"] == 0 and not case["failures"] for case in ui["cases"]))
    for case in ui["cases"]:
        name = "spec/ui/bookshelf-finishing-results/{language}-{width}x{height}.json".format(**case)
        child = read(name)
        check("ui_receipt_" + str(case["language"]) + "_" + str(case["width"]), child["passed"] is True
              and child["language"] == case["language"] and child["width"] == case["width"] and child["height"] == case["height"]
              and len(child["assertions"]) == case["assertions"] and all(item["passed"] is True for item in child["assertions"]))
    ui_root = args.ui_output.resolve(strict=True)
    check("native_screenshot_origin_is_the_verified_ui_run", digest(public_file(ui_root, "bookshelf-finishing-verification.json"))
          == evidence["spec/ui/bookshelf-finishing-verification.json"])
    screenshot_hashes = {}
    for screen in ("default", "concurrency"):
        image = "synthetic-bookshelf-finishing-" + screen + ".png"
        name = "spec/ui/screens/bookshelf-finishing/zh_CN-600x800/" + image
        image_hash = digest(public_file(receipts, name))
        check("native_600_chinese_" + screen + "_screenshot_matches_original_bytes",
              image_hash == digest(public_file(ui_root, "zh_CN-600x800/" + image)))
        evidence[name] = screenshot_hashes[name] = image_hash
    controller = read("spec/controller/finishing-bookshelf-controller-verification.json")
    check("controller_has_all_31_named_cases_on_final_sources", controller["passed"] is True and matches(controller["source_sha256"])
          and controller["source_sha256"] == controller["source_after_sha256"] and controller["source_unchanged"] is True
          and controller["returncode"] == 0 and controller["result"]["passed"] is True
          and unique_cases(controller["result"]["tests"], CONTROLLER_CASES)
          and all(case["passed"] is True for case in controller["result"]["tests"]))
    protocol = read("spec/protocol/site-context-verification.json")
    check("site_context_protocol_and_guard_match_final_sources", matches(protocol["source_hashes"])
          and protocol["passed"] is True and protocol["protocol"]["passed"] is True and protocol["guard"]["passed"] is True)
    concurrency = read("spec/jobs/finishing-concurrency-results.json")
    concurrency_scope = {name: value for name, value in concurrency["source_sha256_before"].items()
                         if (name in production and not name.startswith("bilicomics/ui/"))
                         or name in ("spec/jobs/concurrency_spec.lua", "spec/jobs/run_concurrency.py")}
    check("real_fork_concurrency_sources_and_isolation_match", matches(concurrency_scope) and concurrency["passed"] is True
          and concurrency["source_unchanged"] is True and concurrency["source_sha256_before"] == concurrency["source_sha256_after"]
          and concurrency["source_sha256_before"] == concurrency["staged_sha256_before"] == concurrency["staged_sha256_after"]
          and concurrency["network_namespace_isolated"] is True and concurrency["network_requests"] == 0
          and concurrency["real_session_used"] is False and concurrency["purchase_tests_executed"] is False
          and unique_cases(concurrency["suites"], {"runner", "service"}, "suite"))
    for case in concurrency["suites"]:
        check("concurrency_" + case["suite"] + "_named_cases", case["passed"] is True and case["returncode"] == 0
              and case["timed_out"] is False and case["result"]["passed"] is True
              and unique_cases(case["result"]["tests"], CONCURRENCY_CASES[case["suite"]])
              and all(item["passed"] is True for item in case["result"]["tests"])
              and all(item["passed"] is True for item in case["result"]["assertions"]))
    concurrency_totals = {key: sum(case["result"]["counts"][key] for case in concurrency["suites"])
                          for key in ("tests", "assertions", "actual_forks")}
    check("concurrency_totals_are_25_cases_668_assertions_126_forks", concurrency_totals == {"tests": 25, "assertions": 668, "actual_forks": 126})

    live_names = {key: "spec/integration/finishing-live-" + filename + "-results.json" for key, filename in (
        ("login", "login"), ("restart", "restart"), ("preflight", "preflight"),
        ("reading", "reading"), ("online", "online"), ("offline", "offline"))}
    live = {key: read(name) for key, name in live_names.items()}
    auth_required = {"production_main_initialized", "controller_initialized", "native_menu_opened_bookshelf", "site_context_saved",
                     "saved_session_verified", "controller_closed", "workers_closed", "bookshelf_cards_match_current_page",
                     "bookshelf_help_dismissed", "bookshelf_native_frame_rendered", "bookshelf_unobstructed", "visible_cover_workers_settled"}
    for phase, code in (("login", 20), ("restart", 21)):
        receipt = live[phase]
        driver, hashes = receipt["driver"], receipt["hashes"]
        required = auth_required | ({"login_confirmed", "native_menu_opened_account", "native_account_qr_button_used",
                                    "automatic_bookshelf_sync_verified", "favorites_sync_completed", "history_sync_completed"}
                                   if phase == "login" else {"restart_loaded_session", "cookie_info_verified", "maintenance_verified", "bookshelf_cache_restored"})
        check("fresh_" + phase + "_passed_on_final_production", receipt["passed"] is True and receipt["code"] == code
              and receipt["live_executed"] is True and receipt["deferred"] is False and receipt["cancelled"] is False
              and all_true(receipt, ("children_cleaned", "within_deadline", "sources_unchanged", "qr_removed"))
              and driver["passed"] is True and driver["running"] is False and driver["code"] == code
              and all_true(driver["checks"], required) and hashes["production"] == production
              and matches(hashes["harness"], "spec/integration/"))
        check(phase + "_performed_no_credential_rotation", all(driver["checks"][name] is False for name in (
            "server_refresh_required", "refresh_verified", "confirmation_verified", "credential_rotation_deferred"))
              and driver["counts"]["confirmRefresh"] == 0 and driver["counts"]["rejected_submissions"] == 0
              and not set(driver["network"]).difference({"qr_generate", "qr_poll", "site_context", "cookie_info", "identity_check", "library_favorites", "library_history", "visible_cover"})
              and all(item["rejections"] == 0 for item in driver["network"].values()))
        check(phase + "_rendered_complete_cards_with_expected_help_state", driver["counts"]["visible_cards"] > 0
              and driver["counts"]["visible_cards"] == driver["counts"]["expected_visible_cards"]
              and driver["counts"]["bookshelf_help_acknowledgements"] == (1 if phase == "login" else 0))
    check("authentication_phases_share_source_and_runtime", live["login"]["hashes"] == live["restart"]["hashes"])
    check("fresh_qr_generation_confirmation_and_initialization_were_observed", live["login"]["driver"]["counts"]["generateQR"] == 1
          and live["login"]["driver"]["counts"]["pollQR"] > 0
          and live["login"]["driver"]["network"]["site_context"]["responses"] > 0)

    preflight, reading, online, offline = (live[name] for name in ("preflight", "reading", "online", "offline"))
    check("preflight_selected_a_complete_free_chapter_on_final_sources", preflight["passed"] is True and all_true(preflight["checks"])
          and preflight["execution"]["host"] == "test-env" and preflight["execution"]["wsl"] is False
          and preflight["code_sha256"]["production"] == production and preflight["counts"]["page_count"] == 45
          and matches(preflight["code_sha256"]["tests"], "spec/integration/"))
    check("combined_reading_binds_exact_online_and_offline_receipts", reading["passed"] is True
          and reading["online"] == online and reading["offline"] == offline
          and reading["execution"]["host"] == "test-env" and reading["execution"]["wsl"] is False
          and reading["code_sha256"]["production"] == production
          and reading["code_sha256"]["production_manifest"] == canonical_digest(production)
          and matches(reading["code_sha256"]["tests"], "spec/integration/"))
    check("reading_finished_both_phases_with_unchanged_code_and_clean_sessions", all_true(reading["status"], (
        "live_requested", "online_executed", "offline_executed", "guard_unchanged", "isolated_sessions_absent",
        "source_unchanged", "staged_source_unchanged", "tests_unchanged", "runtime_unchanged",
        "native_cache_cleared_before_offline", "online_driver_removed_session"))
          and reading["status"]["cancelled"] is False and reading["status"]["unexpected_error"] is False)
    guard = args.guard.resolve(strict=True)
    check("reading_guard_matches_executed_public_guard", not any(part.lower() in FORBIDDEN for part in guard.parts) and not args.guard.is_symlink()
          and digest(guard) == reading["code_sha256"]["guard"])
    for phase, receipt, minimum in (("online", online, 51), ("offline", offline, 30)):
        check(phase + "_retains_every_business_assertion_and_process_cleanup", receipt["passed"] is True
              and receipt["report_schema_valid"] is True and len(receipt["checks"]) >= minimum and all_true(receipt["checks"])
              and all_true(receipt["launcher"], ("children_cleaned", "pid_records_valid", "process_completed", "within_deadline"))
              and receipt["launcher"]["forced_cleanup"] is False)
    check("the_same_45_pages_are_complete_and_pinned_after_reader_close", online["counts"]["completed_pages"] == offline["counts"]["completed_pages"] == 45
          and online["counts"]["image_bytes"] == offline["counts"]["image_bytes"] == 92022101
          and online["dimensions"] == offline["dimensions"] and len(online["dimensions"]) == 45
          and online["counts"]["pages_completed_after_reader_close"] > 0
          and online["counts"]["image_workers_started_after_close"] > 0)
    check("offline_has_no_session_routes_or_worker_activity", all_true(offline["checks"], (
        "fresh_process_has_no_session", "offline_network_namespace_isolated", "offline_has_no_network_routes",
        "offline_dispatches_zero_workers", "offline_same_descriptor", "offline_native_anchor_restored", "offline_real_native_pixels_rendered"))
          and all(offline["counts"][key] == 0 for key in ("transport_requests", "worker_starts", "worker_submissions", "image_worker_starts")))
    timing = online["image_worker_timing"]
    intervals = timing["intervals"]
    check("all_45_timed_calls_have_complete_public_intervals", timing["passed"] is True and all_true(timing["checks"])
          and len(intervals) == timing["observed_calls"] == online["counts"]["image_worker_starts"] == 45
          and timing["calls_without_complete_timing"] == 0
          and {item["worker_number"] for item in intervals} == set(range(1, 46))
          and all(type(item["started_seconds"]) in (int, float) and math.isfinite(item["started_seconds"])
                  and type(item["finished_seconds"]) in (int, float) and math.isfinite(item["finished_seconds"])
                  and 0 <= item["started_seconds"] < item["finished_seconds"]
                  and type(item["after_initial_gate"]) is bool and item["returned_normally"] is True for item in intervals))
    all_peak, all_overlap = peak(intervals)
    ungated_peak, ungated_overlap = peak([item for item in intervals if item["after_initial_gate"]])
    check("default_two_workers_really_overlap_without_the_initial_gate", all_peak == ungated_peak == 2
          and all_peak == timing["peak_worker_calls"] and ungated_peak == timing["peak_ungated_worker_calls"]
          and timing["peak_image_processes"] == online["counts"]["peak_image_processes"] == 2
          and online["counts"]["configured_download_concurrency"] == online["counts"]["configured_image_resource_limit"] == 2
          and ungated_overlap > 0 and math.isclose(ungated_overlap, timing["ungated_overlap_seconds"], abs_tol=1e-8)
          and math.isclose(all_overlap, timing["all_call_overlap_seconds"], abs_tol=1e-8)
          and all_true(timing, ("clock_is_monotonic", "observer_file_writes_outside_call_interval", "observer_adds_no_artificial_delay")))
    runtime_sha = common["runtime_sha256"]["luajit"]
    check("all_live_phases_used_the_same_verified_runtime", live["login"]["hashes"]["runtime"]["luajit"] == runtime_sha
          and preflight["code_sha256"]["runtime_luajit"] == runtime_sha
          and reading["code_sha256"]["runtime"]["luajit"] == runtime_sha == concurrency["runtime_sha256"]["luajit"])

    helper_name = "spec/integration/finishing_handoff_runner.py"
    helper_sha = digest(public_file(receipts, helper_name))
    evidence[helper_name] = helper_sha
    report_hashes = {name: evidence[live_names[name]] for name in ("login", "restart", "preflight", "reading")}
    for phase in ("select", "read"):
        receipt = read("spec/integration/finishing-handoff-" + phase + ".json")
        expected = {name: value for name, value in report_hashes.items() if phase == "read" or name != "reading"}
        check("executed_" + phase + "_handoff_binds_the_confirmed_qr_input", receipt["schema"] == 1 and receipt["phase"] == phase
              and receipt["execution_host"] == "test-env" and receipt["passed"] is True
              and receipt["input_from_confirmed_qr"] is True and receipt["input_unchanged"] is True
              and receipt["private_input_contents_read_by_wrapper"] is False
              and receipt["same_input_as_selection"] is (True if phase == "read" else None)
              and receipt["helper_sha256"] == helper_sha and receipt["public_reports_sha256"] == expected)

    result = {
        "passed": True, "acceptance_complete": True, "release_ready": False,
        "scope": "Final development-candidate acceptance: public source and package binding, fresh QR session handoff, and full live reading with measured parallel image workers",
        "bound_at": datetime.now(timezone.utc).isoformat(), "execution_host": "test-env",
        "archive": "dist/bilicomics-0.1.0-dev.zip", "archive_sha256": archive_sha,
        "archive_bytes": archive_path.stat().st_size, "manifest_sha256": digest(manifest_path),
        "uploaded_source_archive_sha256": uploaded_source_sha,
        "uploaded_source_bytes_verified": uploaded_source_sha is not None,
        "packaged_files": len(entries), "production_files": len(production), "production_sha256": production,
        "production_manifest_sha256": canonical_digest(production), "common_snapshot_sha256": common["snapshot_sha256"],
        "checks": checks, "evidence_sha256": evidence, "binder_sha256": digest(Path(__file__)),
        "native_screenshots_sha256": screenshot_hashes,
        "verification": {"common_suites": 34, "package_checks": 27, "ui_cases": 8, "ui_assertions": 1154,
                         "controller_cases": 31, "synthetic_concurrency": concurrency_totals,
                         "live_pages": 45, "live_image_bytes": 92022101, "live_worker_peak": all_peak,
                         "ungated_overlap_seconds": ungated_overlap,
                         "background_overlap_seconds": timing["background_overlap_seconds"],
                         "fresh_login_code": 20, "independent_restart_code": 21,
                         "same_qr_input_used_for_complete_reading": True},
        "reading_instrumentation_note": reading["image_worker_timing_note"],
        "scope_note": "The 108-file package excludes 100 native build sources. Synthetic concurrency binds its executed non-UI sources; UI has separate current receipts. Authentication uses native callbacks. This binding identifies candidate bytes and does not itself publish or replace an installed candidate.",
        "deferred_unverified": ["Actual purchase and asset consumption", "Real credential rotation and old-token confirmation",
                                "Physical Scribe acceptance", "1/5/10 GB offline-library capacity"],
        "release_readiness_note": "release_ready refers to the broader stable release and its deferred device, payment and capacity gates; acceptance_complete covers the agreed finishing work for this development candidate.",
        "binder_private_inputs_read": False, "binder_network_requests": 0, "local_runtime_verification": False,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ("passed", "acceptance_complete", "archive_sha256", "production_manifest_sha256", "verification")}))


if __name__ == "__main__":
    main()
