"""Run finishing bookshelf controller checks only in an isolated Linux test environment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run verification only through ssh test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.runtime, args.source, args.output = args.runtime.resolve(), args.source.resolve(), args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = args.output / key.lower()
        directory.mkdir()
        env[key] = str(directory)
    env.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    source_files = ("bilicomics/controller.lua", "bilicomics/bookshelf_state.lua", "bilicomics/settings.lua",
                    "bilicomics/catalog/init.lua", "bilicomics/storage/store.lua", "bilicomics/storage/codec.lua",
                    "bilicomics/storage/page_store.lua", "bilicomics/storage/files.lua",
                    "bilicomics/jobs/session_runner.lua", "bilicomics/session_manager.lua",
                    "bilicomics/jobs/download_service.lua", "bilicomics/jobs/runner.lua",
                    "spec/controller/bookshelf_finishing_spec.lua", "spec/controller/run_bookshelf_finishing.py")
    source_hashes = {name: hashlib.sha256((args.source / name).read_bytes()).hexdigest() for name in source_files}
    command = ["unshare", "--user", "--map-root-user", "--net", "xvfb-run", "-a", str(args.runtime / "luajit"),
               str(args.source / "spec/controller/bookshelf_finishing_spec.lua"), str(args.source), str(args.output)]
    result = subprocess.run(command, cwd=args.runtime, env=env, text=True, capture_output=True, timeout=55)
    (args.output / "finishing-bookshelf-controller.log").write_text(result.stdout + result.stderr)
    after_hashes = {name: hashlib.sha256((args.source / name).read_bytes()).hexdigest() for name in source_files}
    summary = {"host": "test-env", "runtime": (args.runtime / "git-rev").read_text().strip(),
               "network_isolated": True, "source_sha256": source_hashes, "source_after_sha256": after_hashes,
               "source_unchanged": source_hashes == after_hashes, "returncode": result.returncode}
    report = args.output / "finishing-bookshelf-controller-result.json"
    if report.exists():
        summary["result"] = json.loads(report.read_text())
    summary["passed"] = result.returncode == 0 and summary.get("result", {}).get("passed") is True and summary["source_unchanged"]
    (args.output / "finishing-bookshelf-controller-verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(result.stdout + result.stderr)
    for item in summary.get("result", {}).get("tests", []):
        if not item["passed"]:
            print(item["name"] + "\n" + item.get("failure", "Unknown failure"))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
