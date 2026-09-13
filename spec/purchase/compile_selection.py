"""Compile changed Lua chunks without loading or executing purchase modules.

Run only on the remote test environment. This is syntax evidence, not a purchase
test, a quote request, or behavioral validation of any module or UI path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


FILES = ("bilicomics/controller.lua", "bilicomics/jobs/worker.lua", "bilicomics/protocol/client.lua",
         "bilicomics/purchase/quote.lua", "bilicomics/purchase/service.lua",
         "bilicomics/purchase/selection.lua", "bilicomics/purchase/candidate.lua",
         "bilicomics/purchase/quote_fetch.lua", "bilicomics/ui/screens.lua",
         "bilicomics/ui/model.lua", "l10n/bilicomics_zh_CN.lua")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    for name in ("runtime", "source", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "linux":
        raise RuntimeError("Use the remote test environment for compilation")
    runtime, source, output = (path.resolve() for path in (args.runtime, args.source, args.output))
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("The pinned official runtime is required")
    output.mkdir(parents=True, exist_ok=False)
    records = []
    for index, name in enumerate(FILES):
        path = source / name
        before = digest(path)
        bytecode = output / (str(index) + ".ljbc")
        command = ["unshare", "-n", str(runtime / "luajit"), "-b", str(path), str(bytecode)]
        result = subprocess.run(command, cwd=runtime, capture_output=True, text=True, timeout=30)
        records.append({"path": name, "sha256": before, "returncode": result.returncode,
                        "source_unchanged": before == digest(path), "bytecode_written": bytecode.is_file(),
                        "mode": "LuaJIT -b compile only", "network_namespace_isolated": True,
                        "compiler_output": (result.stdout + result.stderr)[:2000]})
    passed = all(item["returncode"] == 0 and item["source_unchanged"] and item["bytecode_written"] for item in records)
    report = {"passed": passed, "scope": "Syntax compilation only; no application or purchase behavior was executed",
              "runtime_version": "v2026.07.1", "luajit_sha256": digest(runtime / "luajit"),
              "files": records, "modules_executed": False, "purchase_tests_executed": False,
              "quote_requests": 0, "wallet_requests": 0, "purchase_requests": 0,
              "launcher_sha256": digest(Path(__file__))}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"syntax_passed": passed, "files": len(records), "report": str(output / "result.json")}))
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
