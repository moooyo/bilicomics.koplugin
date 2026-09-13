"""Run only the synthetic free-chapter version-replacement integration on authorized test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import zlib


CASES = ("success", "same_identity", "topology", "cancel", "suspend", "account_close", "account_switch",
         "stale_index", "stale_basis", "mutual_exclusion", "interrupted", "fresh_access",
         "fresh_index", "database_failure", "resume_throw", "binding", "unbound", "unpinned_cancel", "unpinned_success")
ASSET = "efae82c96a7eef44bee5.wasm"
ASSET_SHA = "39bc0676953752c461197df592e1f5894f1a7492a29400c946e560fc109a8e2e"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png(path, gray):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = b"".join(b"\0" + bytes([gray]) * 40 for _ in range(80))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def same_process(record):
    try:
        fields = Path(f"/proc/{int(record['pid'])}/stat").read_text().rsplit(") ", 1)[1].split()
        return fields[19] == str(record["start_time"]) and fields[0] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


def records(output):
    path = output / "process-records.json"
    return json.loads(path.read_text()) if path.exists() else []


def terminate_owned(process, output):
    for record in reversed(records(output)):
        if same_process(record):
            pid = int(record["pid"])
            try:
                if os.getpgid(pid) == pid:
                    os.killpg(pid, signal.SIGKILL)
                else:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait(timeout=5)


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on authorized remote test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    args = parser.parse_args()
    args.runtime, args.source, args.assets, args.work = (path.resolve() for path in
        (args.runtime, args.source, args.assets, args.work))
    if args.work.exists():
        raise RuntimeError("A fresh isolated work directory is required")
    if (args.runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("The official v2026.07.1 runtime is required")
    if digest(args.assets / ASSET) != ASSET_SHA:
        raise RuntimeError("The public signing fixture does not match its production pin")
    args.work.mkdir(mode=0o700, parents=True)
    stage = args.work / "source"
    stage.mkdir()
    shutil.copytree(args.source / "bilicomics", stage / "bilicomics")
    script = stage / "version_replacement_workflow.lua"
    shutil.copyfile(args.source / "spec/integration/version_replacement_workflow.lua", script)
    hashes = {str(path.relative_to(stage)): digest(path) for path in sorted(stage.rglob("*.lua"))}
    results = []
    for case in args.cases:
        output = args.work / case
        home = output / "koreader"
        assets = home / "bilicomics/protocol-assets"
        assets.mkdir(parents=True)
        shutil.copyfile(args.assets / ASSET, assets / ASSET)
        for index, gray in enumerate((35, 95, 155, 210), 1):
            png(output / f"fixture-{index}.png", gray)
        env = os.environ.copy()
        env.update(BILI_PARENT_NETNS=os.readlink("/proc/self/ns/net"), KO_HOME=str(home), EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
        command = ["unshare", "-n", "--", "xvfb-run", "-a", str(args.runtime / "luajit"), str(script), str(stage), str(output), case]
        timed_out = False
        with (output / "runtime.log").open("wb") as log:
            process = subprocess.Popen(command, cwd=args.runtime, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                returncode = process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                timed_out = True
                terminate_owned(process, output)
                returncode = 124
        report_path = output / "results.json"
        result = json.loads(report_path.read_text()) if report_path.exists() else {"passed": False, "error": "Driver produced no result"}
        if timed_out:
            result["passed"], result["error"] = False, "The bounded remote driver timed out"
        tracked_terminal = not any(same_process(record) for record in records(output))
        if not tracked_terminal:
            terminate_owned(process, output)
        assertions = result.get("assertions", [])
        passed = (returncode == 0 and result.get("passed") is True and tracked_terminal and bool(assertions)
                  and all(item.get("passed") is True for item in assertions)
                  and result.get("all_children_reaped") is True and result.get("all_worker_pids_terminal") is True)
        results.append({"case": case, "passed": passed, "returncode": returncode, "timed_out": timed_out,
                        "tracked_processes_terminal": tracked_terminal, "result": result})
        print(json.dumps({"case": case, "passed": passed, "checks": len(assertions),
                          "error": result.get("error")}), flush=True)
    unchanged = all(digest(stage / name) == value for name, value in hashes.items())
    report = {"passed": unchanged and all(item["passed"] for item in results),
              "source_unchanged": unchanged, "source_sha256": hashes, "runs": results,
              "requested_cases": list(args.cases), "complete_matrix": tuple(args.cases) == CASES,
              "runtime_version": "v2026.07.1", "runtime_sha256": {name: digest(args.runtime / name)
                  for name in ("luajit", "libs/libsqlite3.so.0")},
              "launcher_sha256": digest(Path(__file__)), "asset_sha256": {ASSET: ASSET_SHA},
              "source_package_sha256": digest(args.package.resolve()) if args.package else None,
              "network_namespace_isolated": True, "purchase_scenarios_executed": False,
              "scope": "Real Controller, coordinator, SQLite, PageStore, version replacement, Worker/Client and native ReaderUI, fork/IPC and UIManager; synthetic transport responses"}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
