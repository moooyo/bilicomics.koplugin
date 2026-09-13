"""Bind the integrated artifact to separately scoped public evidence; no API calls."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bind_reading_revision import digest, file_hashes, function_bytes, manifest_archive, package_sources, read_json, remote_only, write_new_json
from stage_integrated_quote_revision import BASELINE, CHANGED


CLIENT = "bilicomics/protocol/client.lua"
PURCHASE = "bilicomics/purchase/"


def main():
    remote_only()
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "alias-manifest", "stage", "result", "evidence", "identity-source", "verifier", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    manifest, packaged = manifest_archive(args.manifest)
    alias, alias_files = manifest_archive(args.alias_manifest)
    assert manifest["sha256"] == alias["sha256"] and packaged == alias_files
    assert manifest["archive"] == "bilicomics-0.1.0-dev.zip" and alias["archive"] == "bilicomics-quote-preview.zip"
    hashes = file_hashes(packaged)
    stage = read_json(args.stage)
    assert stage["staged"] is True and len(hashes) == stage["packaged_files"] == 96
    assert hashes == stage["source_sha256"] == file_hashes(package_sources(Path(stage["source_root"])))
    _, baseline = manifest_archive(Path(stage["baseline_manifest"]), BASELINE)
    assert set(packaged) - set(baseline) == {PURCHASE + "range.lua"} and set(baseline) <= set(packaged)
    assert {name for name in packaged if baseline.get(name) != packaged[name]} == set(CHANGED)
    syntax_path = args.stage.with_name("syntax.json")
    syntax = read_json(syntax_path)
    assert syntax["passed"] is True and syntax["application_modules_executed"] is False
    assert digest(syntax_path.read_bytes()) == stage["syntax_report_sha256"]
    assert {item["path"] for item in syntax["files"]} == set(CHANGED)
    for item in syntax["files"]:
        assert item["sha256"] == hashes[item["path"]] and item["returncode"] == 0
        assert all(item[key] is True for key in ("source_unchanged", "bytecode_written", "network_namespace_isolated",
                                               "lua_initialization_disabled", "lua_search_paths_pinned_to_runtime"))
    result = read_json(args.result)
    assert result["passed"] is True and result["archive"]["sha256"] == manifest["sha256"]
    assert len(result["checks"]) == 27 and all(item["passed"] is True for item in result["checks"])
    proofs = {}

    def evidence(relative):
        path = args.evidence / relative
        return read_json(path), {"report": relative, "report_sha256": digest(path.read_bytes())}

    def matching(report, names):
        found = {name: report["source_sha256"][name] for name in names}
        assert all(hashes[name] == value for name, value in found.items()), "An evidence source differs from the artifact"
        return found

    identity, tag = evidence("spec/protocol/purchase-info-identity-result.json")
    old_client = args.identity_source.read_bytes()
    assert identity["passed"] is True and identity["source_unchanged"] is True and identity["returncode"] == 0
    assert digest(old_client) == identity["source_sha256"][CLIENT]
    assert identity["result"]["assertions"] == 115 and all(item["passed"] is True for item in identity["result"]["groups"])
    assert identity["result"]["real_transport_attempts"] == identity["result"]["buy_episode_attempts"] == 0
    slices = {}
    for symbol in ("id", "responseId", "Client:purchaseInfo"):
        original, current = function_bytes(old_client, symbol), function_bytes(packaged[CLIENT], symbol)
        assert original == current
        slices[symbol] = digest(current)
    proofs["identity_115"] = dict(tag, binding_kind="exact_function_slices", function_sha256=slices,
        tested_client_sha256=digest(old_client), artifact_client_sha256=hashes[CLIENT], assertions=115,
        scope="Unchanged Client identity functions only; the old Client/QuoteFetch combination is not claimed for the current collector")

    range_report, tag = evidence("spec/purchase/ordinal-range-result.json")
    assert range_report["passed"] is True and range_report["source_unchanged"] is True and range_report["returncode"] == 0
    assert range_report["result"]["assertions"] == 240 and all(item["passed"] is True for item in range_report["result"]["groups"])
    assert range_report["actual_http_permitted"] is False and range_report["actual_purchases_permitted"] is False
    range_names = [PURCHASE + name + ".lua" for name in ("range", "selection", "quote_fetch", "candidate", "quote", "value")]
    proofs["ordinal_range_240"] = dict(tag, binding_kind="exact_module_versions", source_sha256=matching(range_report, range_names),
        assertions=240, scope=range_report["scope"])

    ui, tag = evidence("spec/ui/ordinal-range-verification.json")
    assert ui["spec"] == "native-ordinal-range" and ui["passed"] is True and ui["source_unchanged"] is True
    assert ui["actual_purchase_executed"] is False and ui["source_sha256_after"] == ui["source_sha256"]
    assert len(ui["runs"]) == 2 and {(run["width"], run["height"]) for run in ui["runs"]} == {(600, 800), (480, 640)}
    assert all(run["passed"] is True and run["returncode"] == 0 and run["count"] == 106
        and run["synthetic_only"] is True and run["actual_purchase_executed"] is False for run in ui["runs"])
    proofs["ordinal_ui_212"] = dict(tag, binding_kind="exact_module_versions", source_sha256=matching(ui, ui["source_sha256"]),
        assertions=212, resolutions=["600x800", "480x640"], scope="Native widgets with synthetic controller and quote data; production transaction modules were not exercised")

    transaction, tag = evidence("spec/purchase/ordinal-transaction-result.json")
    assert transaction["passed"] is True and transaction["source_unchanged"] is True and len(transaction["runs"]) == 11
    assert all(transaction[key] is False for key in ("actual_http_permitted", "actual_purchases_permitted", "user_session_accessed", "server_confirmed_episode_ids_assumed"))
    for run in transaction["runs"]:
        assert run["returncode"] == 0 and run["evidence"]["passed"] is True and run["evidence"]["network_namespace_isolated"] is True
        assert run["evidence"]["real_transport_attempts"] == run["evidence"]["forbidden_module_attempts"] == 0
    ordinal_runs = [run for run in transaction["runs"] if "ordinal_assertions" in run["evidence"]]
    assert len(ordinal_runs) == 9 and sum(run["evidence"]["ordinal_assertions"] for run in ordinal_runs) == 489
    assert sum(run["passed_cases"] for run in transaction["runs"]) == 66
    transaction_modules = range_names + [PURCHASE + "service.lua", "bilicomics/storage/store.lua",
        "bilicomics/storage/codec.lua", "bilicomics/storage/migrations.lua"]
    proofs["synthetic_transaction"] = dict(tag, binding_kind="scoped_modules_and_functions",
        source_sha256=matching(transaction, transaction_modules),
        input_source_inventory_sha256=matching(transaction, transaction["source_sha256"]),
        client_function_sha256={name: digest(function_bytes(packaged[CLIENT], name))
            for name in ("Client:buyEpisode", "Client:_post", "Client:_headers", "Client:_envelope")},
        processes=11, cases=66, ordinal_processes=9, ordinal_assertions=489, scope=transaction["scope"],
        limits=["Crypto was replaced; image/normalize were only loaded; Transport.request was replaced",
                "Files was used for Store directory setup and Session used synthetic cookies; the full source inventory is not behavior coverage"])

    reading, tag = evidence("spec/jobs/download-connectivity-results.json")
    assert reading["passed"] is True and reading["source_unchanged"] is True
    assert len(reading["suites"]) == 2 and {suite["suite"] for suite in reading["suites"]} == {"service", "runner"}
    assert all(suite["passed"] is True and suite["returncode"] == 0 for suite in reading["suites"])
    assert sum(len(suite["result"]["tests"]) for suite in reading["suites"]) == 25
    reading_names = ["bilicomics/controller.lua", "bilicomics/jobs/download_service.lua", "bilicomics/jobs/runner.lua"]
    proofs["reading_connectivity_25"] = dict(tag, binding_kind="unchanged_module_versions",
        source_sha256=matching(reading, reading_names), cases=25, scope=reading["scope"])

    live, live_tag = evidence("research/protocol/ordinal-range-live-result.json")
    launcher, launcher_tag = evidence("research/protocol/ordinal-range-launcher-result.json")
    assert all(live[key] is True for key in ("completed", "session_validated", "quote_builder_executed"))
    assert all(live[key] is False for key in ("purchase_submitted", "wallet_requested", "image_requested", "account_mutation_requested", "exact_scope_verified"))
    assert launcher["returncode"] == 0 and launcher["timed_out"] is False and launcher["purchase_submitted"] is False
    assert launcher["credential_copy_removed"] is True and launcher["user_input_modified"] is False
    assert (live["business_requests"], live["quote_requests"], live["public_assets"]) == (7, 4, 1)
    assert live["blocked_requests"] == 0 and len(live["requests"]) == 8
    assert [request["operation"] for request in live["requests"]] == ["session", "favorites", "pinned_signing", "catalog", "basic", "single", "batch-1", "batch-2"]
    assert all(request["status"] == 200 for request in live["requests"])
    assert set(live["range_construction"]) == {"batch-1", "batch-2"}
    for name, count, remaining in (("batch-1", 20, False), ("batch-2", 123, True)):
        item = live["range_construction"][name]
        assert item["episode_count"] == count and item["remaining"] is remaining
        assert all(item[key] is True for key in ("collector_returned", "quote_returned", "submittable", "payload_uses_server_amount", "payload_preserves_range_limit"))
        assert item["real_submit_executed"] is False and item["server_confirmed_ids"] is False
        assert item["contract"] == "bilibili_pc_ordinal_range_v1"
        assert item["provenance"] == "primary_sdk_ordinal_contract_and_quote_catalog_consistency"
    proofs["live_range_construction"] = dict(live_tag, launcher=launcher_tag, binding_kind="matching_observer_snapshot_modules",
        source_sha256=matching(launcher, [CLIENT] + range_names), observed_range_sizes=[20, 123], business_requests=7,
        quote_requests=4, public_assets=1, captured_memo_reads=6, service_executed=False,
        source_unchanged_after_run_verified=False, original_reports_cryptographically_linked=False,
        scope="Authenticated quote reads followed by local Fetch/Range/Quote construction using captured memo responses; Service and submission were not executed",
        limits=["Launcher records a copy-time source inventory, not a post-run hash map",
                "The owner supplied the public report pair; the original launcher has no observation digest or run ID",
                "Submittable is a local ordinal-contract decision, not server-echoed chapter IDs or confirmed range delivery"])

    native, tag = evidence("spec/package/source-evidence-before-connectivity.json")
    assert native["native_libraries_match_both_runtime_probes"] is True and native["device_verified"] is False
    libraries = {}
    for name, item in native["native_libraries"].items():
        path = "bilicomics/protocol/native/bin/linux-armhf/" + name
        assert hashes[path] == item["sha256"] and len(packaged[path]) == item["bytes"]
        libraries[path] = item["sha256"]
    proofs["arm_native_unchanged"] = dict(tag, binding_kind="unchanged_binary_bytes", source_sha256=libraries,
        scope="Prior ARM primitive checks retain their original diagnostic-loader and glibc scope; no device acceptance is added")
    assert all(packaged[name] == baseline[name] for name in baseline if name.endswith(".so"))

    report = {"bound": True, "archive_file": manifest["archive"], "preview_alias": alias["archive"],
        "archive_sha256": manifest["sha256"], "archive_bytes": args.manifest.with_name(manifest["archive"]).stat().st_size,
        "packaged_files": 96, "baseline_preview_sha256": BASELINE["sha256"], "changed_paths": sorted(CHANGED),
        "new_paths": [PURCHASE + "range.lua"], "unchanged_baseline_files": 88, "proof_tags": proofs,
        "source_sha256": hashes, "stage_sha256": digest(args.stage.read_bytes()), "syntax_sha256": digest(syntax_path.read_bytes()),
        "package_result_sha256": digest(args.result.read_bytes()), "verifier_sha256": digest(args.verifier.read_bytes()),
        "binding_script_sha256": digest(Path(__file__).read_bytes()), "package_checks": 27, "syntax_files": 8,
        "preview_alias_same_bytes": True, "real_purchase_executed": False, "server_confirmed_episode_ids": False,
        "server_atomic_range_delivery_verified": False, "whole_archive_live_acceptance": False,
        "device_verified": False, "local_visible_window_verified": False,
        "scope": "Integrated artifact provenance with separately scoped synthetic, read-only live, reading and inherited ARM evidence; no full payment or device acceptance claim"}
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    write_new_json(args.output / "integrated-quote-source-binding.json", report)
    for filename, archive, previous in (("source-evidence.json", manifest["archive"], "1aa7c223470d0a366d0209a22938ba8dd3d4399f42154ed8ad8388f728442d22"),
                                      ("quote-preview-source-evidence.json", alias["archive"], BASELINE["sha256"])):
        write_new_json(args.output / filename, {"archive_file": archive, "archive_sha256": manifest["sha256"],
            "archive_bytes": report["archive_bytes"], "packaged_files": 96, "previous_archive_sha256": previous,
            "bound": True, "source_binding": "integrated-quote-source-binding.json", "syntax_evidence": "integrated-quote-syntax.json",
            "package_checks": 27, "preview_alias_same_bytes": True, "real_purchase_executed": False,
            "server_confirmed_episode_ids": False, "whole_archive_live_acceptance": False,
            "device_verified": False, "local_visible_window_verified": False, "scope": report["scope"]})
    write_new_json(args.output / "remote-results.json", result)
    alias_result = json.loads(json.dumps(result)); alias_result["archive"]["file"] = alias["archive"]
    alias_result["alias_of"] = manifest["archive"]
    write_new_json(args.output / "quote-preview-results.json", alias_result)
    print(json.dumps({"bound": True, "archive_sha256": manifest["sha256"], "proof_tags": list(proofs), "output": str(args.output)}))


if __name__ == "__main__":
    main()
