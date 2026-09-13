"""Stage the integrated 96-file quote/range candidate without publishing it."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bind_reading_revision import (
    digest, file_hashes, manifest_archive, new_temporary_directory,
    package_sources, remote_only, write_new_json,
)


BASELINE = {"sha256": "38a01da12c74271a631af57e9ac45c9e90b48472e390bd4aae5ded42e37f8383", "files": 95}
CHANGED = (
    "bilicomics/protocol/client.lua", "bilicomics/purchase/service.lua",
    "bilicomics/purchase/quote.lua", "bilicomics/purchase/quote_fetch.lua",
    "bilicomics/purchase/range.lua", "bilicomics/ui/model.lua",
    "bilicomics/ui/screens.lua", "l10n/bilicomics_zh_CN.lua",
)
RUNTIME_SHA256 = "d45e2e20df501f0aabc2eb55c5e6138090d48bae423d4de87ac3df113e8eee3c"


def main():
    remote_only()
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "baseline", "runtime", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    source, runtime = args.source.resolve(), args.runtime.resolve()
    destination = new_temporary_directory(args.output)
    manifest, baseline = manifest_archive(args.baseline.resolve(), BASELINE)
    working = package_sources(source)
    added, removed = set(working) - set(baseline), set(baseline) - set(working)
    assert added == {"bilicomics/purchase/range.lua"} and not removed, f"Unexpected packaged file additions/removals: {sorted(added)}, {sorted(removed)}"
    changed = {name for name, data in working.items() if baseline.get(name) != data}
    assert changed == set(CHANGED), f"Unexpected changed production paths: {sorted(changed)}"
    assert len(working) == 96
    assert (runtime / "git-rev").read_text().strip() == "v2026.07.1"
    assert digest((runtime / "luajit").read_bytes()) == RUNTIME_SHA256
    destination.mkdir(mode=0o700)
    root, compiler = destination / "plugin", destination / "compiler"
    root.mkdir(); compiler.mkdir()
    for name, data in sorted(working.items()):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as output:
            output.write(data)
    (root / "tools").mkdir()
    tool = (source / "tools/package.py").read_bytes()
    (root / "tools/package.py").write_bytes(tool)
    hashes = file_hashes(working)
    assert file_hashes(package_sources(root)) == hashes
    compiled = []
    for index, name in enumerate(CHANGED):
        home = compiler / str(index)
        home.mkdir()
        bytecode = home / "source.luac"
        environment = {"PATH": os.defpath, "HOME": str(home), "KO_HOME": str(home), "LANG": "C.UTF-8",
                       "LUA_PATH": str(runtime / "?.lua"), "LUA_CPATH": str(runtime / "libs/?.so")}
        result = subprocess.run(["unshare", "-n", "--", str(runtime / "luajit"), "-b", str(root / name), str(bytecode)],
                                cwd=runtime, env=environment, capture_output=True, text=True, timeout=30)
        compiled.append({"path": name, "sha256": hashes[name], "returncode": result.returncode,
            "source_unchanged": digest((root / name).read_bytes()) == hashes[name], "bytecode_written": bytecode.is_file(),
            "compiler_output": result.stdout + result.stderr, "network_namespace_isolated": True,
            "lua_initialization_disabled": True, "lua_search_paths_pinned_to_runtime": True})
    syntax = {"passed": all(item["returncode"] == 0 and item["source_unchanged"] and item["bytecode_written"] for item in compiled),
        "files": compiled, "application_modules_executed": False, "runtime_version": "v2026.07.1",
        "luajit_sha256": RUNTIME_SHA256, "scope": "Syntax compilation of the eight changed integrated candidate files only"}
    write_new_json(destination / "syntax.json", syntax)
    assert syntax["passed"], "A changed integrated source failed syntax compilation"
    report = {"staged": True, "packaged_files": len(working), "source_root": str(root), "working_source": str(source),
        "source_sha256": hashes, "baseline_manifest": str(args.baseline.resolve()),
        "baseline_archive_sha256": manifest["sha256"], "changed_paths": sorted(CHANGED),
        "added_paths": sorted(added), "unchanged_baseline_files": 88,
        "packaging_tool_sha256": digest(tool), "staging_script_sha256": digest(Path(__file__).read_bytes()),
        "parser_script_sha256": digest(Path(__file__).with_name("bind_reading_revision.py").read_bytes()),
        "syntax_report_sha256": digest((destination / "syntax.json").read_bytes()),
        "real_purchase_executed": False, "whole_archive_runtime_verified": False,
        "server_echo_scope_verified": False, "device_verified": False, "dist_modified": False,
        "scope": "Integrated candidate source and syntax identity only; focused module/function evidence and read-only live observations require separate binding"}
    write_new_json(destination / "staging.json", report)
    print(json.dumps({"staged": True, "files": len(working), "syntax_passed": True, "receipt": str(destination / "staging.json")}))


if __name__ == "__main__":
    main()
