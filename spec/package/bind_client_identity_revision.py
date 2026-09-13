"""Stage or bind the single-file Client identity fix; never publish or call an API."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bind_reading_revision import (
    digest, file_hashes, function_bytes, function_span, manifest_archive,
    new_temporary_directory, package_sources, read_json, remote_only,
    replace_functions, write_new_json,
)


CLIENT = "bilicomics/protocol/client.lua"
SOURCE_SHA256 = "67b201c66a5eb10aef26a27535877b764a56af3ffad3b2792f4b99c9de94135d"
BASELINES = {
    "reading": {"sha256": "1aa7c223470d0a366d0209a22938ba8dd3d4399f42154ed8ad8388f728442d22", "files": 91},
    "preview": {"sha256": "38a01da12c74271a631af57e9ac45c9e90b48472e390bd4aae5ded42e37f8383", "files": 95},
}


def identity_evidence(path):
    evidence = read_json(path)
    assert evidence["passed"] is True and evidence["source_unchanged"] is True and evidence["returncode"] == 0
    assert evidence["runtime_version"] == "v2026.07.1" and evidence["source_sha256"][CLIENT] == SOURCE_SHA256
    assert evidence["user_session_accessed"] is False and evidence["profile_accessed"] is False
    result = evidence["result"]
    assert result["passed"] is True and result["network_namespace_isolated"] is True
    assert result["synthetic_session_only"] is True and result["assertions"] == 115
    assert len(result["groups"]) == 10 and all(group["passed"] is True for group in result["groups"])
    assert all(result[key] == 0 for key in ("real_transport_attempts", "buy_episode_attempts", "forbidden_module_attempts", "rejected_routes"))
    return evidence


def expected_sources(client, manifests):
    assert digest(client) == SOURCE_SHA256, "Client must match the final identity-tested source"
    baselines = {kind: manifest_archive(path, BASELINES[kind])[1] for kind, path in manifests.items()}
    old_reading, old_preview = baselines["reading"][CLIENT], baselines["preview"][CLIENT]
    for symbol in ("id", "Client:purchaseInfo"):
        assert function_bytes(old_reading, symbol) == function_bytes(old_preview, symbol), "Old Client function differs: " + symbol
    assert function_bytes(client, "id") == function_bytes(old_reading, "id"), "The shared id helper changed"
    helper_start, helper_end = function_span(client, "responseId")
    anchor, _ = function_span(client, "invalid")
    assert helper_start < helper_end < anchor and not client[helper_end:anchor].strip()
    addition = client[helper_start:anchor]
    output = {}
    for kind, original in baselines.items():
        assert function_span(original[CLIENT], "responseId", False) is None
        assert function_bytes(original[CLIENT], "invalid") == function_bytes(client, "invalid")
        changed, _ = replace_functions(original[CLIENT], old_preview, client, ["Client:purchaseInfo"])
        position, _ = function_span(changed, "invalid")
        changed = changed[:position] + addition + changed[position:]
        assert function_bytes(changed, "responseId") == function_bytes(client, "responseId")
        assert function_bytes(changed, "Client:purchaseInfo") == function_bytes(client, "Client:purchaseInfo")
        output[kind] = dict(original)
        output[kind][CLIENT] = changed
        assert {name for name in original if output[kind][name] != original[name]} == {CLIENT}
    assert output["preview"][CLIENT] == client, "The full working Client includes an unapproved extra change"
    return output


def stage(args):
    destination = new_temporary_directory(args.output)
    client = args.client.read_bytes()
    evidence = identity_evidence(args.identity)
    manifests = {kind: getattr(args, kind + "_manifest").resolve() for kind in BASELINES}
    expected = expected_sources(client, manifests)
    runtime = args.runtime.resolve()
    assert (runtime / "git-rev").read_text().strip() == "v2026.07.1"
    assert digest((runtime / "luajit").read_bytes()) == evidence["runtime_sha256"]
    package_tool = args.package_tool.read_bytes()
    destination.mkdir(mode=0o700)
    packages, syntax = {}, {}
    for kind, files in expected.items():
        root = destination / kind
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as output:
                output.write(data)
        (root / "tools").mkdir()
        (root / "tools/package.py").write_bytes(package_tool)
        hashes = file_hashes(files)
        assert file_hashes(package_sources(root)) == hashes
        home = destination / (kind + "-compiler")
        home.mkdir()
        compiled = home / "client.luac"
        environment = {"PATH": os.defpath, "HOME": str(home), "KO_HOME": str(home), "LANG": "C.UTF-8",
                       "LUA_PATH": str(runtime / "?.lua"), "LUA_CPATH": str(runtime / "libs/?.so")}
        result = subprocess.run(["unshare", "-n", "--", str(runtime / "luajit"), "-b", str(root / CLIENT), str(compiled)],
                                cwd=runtime, env=environment, capture_output=True, text=True, timeout=30)
        syntax[kind] = {"path": CLIENT, "sha256": hashes[CLIENT], "returncode": result.returncode,
            "source_unchanged": digest((root / CLIENT).read_bytes()) == hashes[CLIENT], "bytecode_written": compiled.is_file(),
            "compiler_output": result.stdout + result.stderr, "network_namespace_isolated": True,
            "lua_initialization_disabled": True, "lua_search_paths_pinned_to_runtime": True}
        packages[kind] = {"source_root": str(root), "source_sha256": hashes, "files": len(files),
            "baseline_manifest": str(manifests[kind]), "baseline_archive_sha256": BASELINES[kind]["sha256"],
            "changed_paths": [CLIENT], "unchanged_files": len(files) - 1,
            "packaging_tool_sha256": digest(package_tool)}
    syntax_report = {"passed": all(item["returncode"] == 0 and item["source_unchanged"] and item["bytecode_written"] for item in syntax.values()),
        "files": syntax, "application_modules_executed": False, "runtime_version": "v2026.07.1",
        "luajit_sha256": evidence["runtime_sha256"], "scope": "Syntax compilation of the two staged Client files only"}
    write_new_json(destination / "syntax.json", syntax_report)
    assert syntax_report["passed"], "A staged Client file failed syntax compilation"
    receipt = {"staged": True, "packages": packages, "client_source": str(args.client.resolve()), "client_source_sha256": SOURCE_SHA256,
        "staging_script_sha256": digest(Path(__file__).read_bytes()),
        "parser_script_sha256": digest(Path(__file__).with_name("bind_reading_revision.py").read_bytes()),
        "identity_evidence": str(args.identity.resolve()), "identity_evidence_sha256": digest(args.identity.read_bytes()),
        "id_helper_sha256": digest(function_bytes(client, "id")),
        "response_id_helper_sha256": digest(function_bytes(client, "responseId")),
        "purchase_info_function_sha256": digest(function_bytes(client, "Client:purchaseInfo")),
        "syntax_report_sha256": digest((destination / "syntax.json").read_bytes()),
        "scope": "Reading migrates only responseId and purchaseInfo; preview uses the identical full working Client; all other packaged bytes retain their own baseline"}
    write_new_json(destination / "staging.json", receipt)
    print(json.dumps({"staged": True, "syntax_passed": True, "receipt": str(destination / "staging.json")}))


def bind(args):
    destination = new_temporary_directory(args.output)
    receipt = read_json(args.staging)
    assert receipt["staged"] is True and set(receipt["packages"]) == set(BASELINES)
    identity_path = Path(receipt["identity_evidence"])
    identity_evidence(identity_path)
    assert digest(identity_path.read_bytes()) == receipt["identity_evidence_sha256"]
    client = Path(receipt["client_source"]).read_bytes()
    expected = expected_sources(client, {kind: Path(item["baseline_manifest"]) for kind, item in receipt["packages"].items()})
    syntax_path = args.staging.with_name("syntax.json")
    syntax = read_json(syntax_path)
    assert digest(syntax_path.read_bytes()) == receipt["syntax_report_sha256"]
    assert syntax["passed"] is True and syntax["application_modules_executed"] is False
    packages = {}
    for kind, files in expected.items():
        staged = receipt["packages"][kind]
        hashes = file_hashes(files)
        assert staged["source_sha256"] == file_hashes(package_sources(Path(staged["source_root"]))) == hashes
        assert staged["files"] == BASELINES[kind]["files"] and staged["changed_paths"] == [CLIENT]
        compiled = syntax["files"][kind]
        assert compiled["sha256"] == hashes[CLIENT] and compiled["returncode"] == 0
        assert all(compiled[key] is True for key in ("source_unchanged", "bytecode_written", "network_namespace_isolated",
                                                   "lua_initialization_disabled", "lua_search_paths_pinned_to_runtime"))
        manifest_path = getattr(args, kind + "_manifest").resolve()
        manifest, packaged = manifest_archive(manifest_path)
        assert file_hashes(packaged) == hashes, "Package differs from the bounded staged source"
        result_path = getattr(args, kind + "_result").resolve()
        result = read_json(result_path)
        assert result["passed"] is True and result["archive"]["sha256"] == manifest["sha256"]
        assert len(result["checks"]) == 27 and all(check["passed"] is True for check in result["checks"])
        packages[kind] = {"archive": manifest["archive"], "archive_sha256": manifest["sha256"], "files": len(files),
            "baseline_archive_sha256": BASELINES[kind]["sha256"], "changed_paths": [CLIENT], "unchanged_files": len(files) - 1,
            "client_sha256": hashes[CLIENT], "package_result": str(result_path), "package_result_sha256": digest(result_path.read_bytes())}
    report = {"bound": True, "packages": packages, "staging": str(args.staging.resolve()), "staging_sha256": digest(args.staging.read_bytes()),
        "syntax": str(syntax_path.resolve()), "syntax_sha256": receipt["syntax_report_sha256"],
        "identity_evidence": str(identity_path), "identity_evidence_sha256": receipt["identity_evidence_sha256"],
        "tested_client_sha256": SOURCE_SHA256, "selected_functions_match_identity_tested_source": True,
        "only_client_changed": True, "real_purchase_executed": False, "device_verified": False,
        "local_visible_window_verified": False, "whole_archive_live_verified": False, "dist_modified": False,
        "scope": "Single-file source identity and syntax binding to focused synthetic purchase-info validation; earlier package and live observations retain their own scope"}
    destination.mkdir(mode=0o700)
    write_new_json(destination / "source-binding.json", report)
    print(json.dumps({"bound": True, "report": str(destination / "source-binding.json")}))


def main():
    remote_only()
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    staging = commands.add_parser("stage")
    for name in ("client", "identity", "reading-manifest", "preview-manifest", "package-tool", "runtime", "output"):
        staging.add_argument("--" + name, type=Path, required=True)
    binding = commands.add_parser("bind")
    for name in ("staging", "reading-manifest", "preview-manifest", "reading-result", "preview-result", "output"):
        binding.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    {"stage": stage, "bind": bind}[args.command](args)


if __name__ == "__main__":
    main()
