"""Bind ordinary-user WSL real reading to one exact packaged candidate.

This wrapper uses the existing production preflight and complete online/offline
drivers with an explicit local-wsl execution context. It never changes protocol
responses or widens the complete-free-chapter transport guard.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import signal
import stat
import subprocess
import sys
import time
import zipfile

cancellation_requested = False
active_process = None


def request_cancellation(_signum, _frame):
    global cancellation_requested
    cancellation_requested = True


def install_cancellation_handlers():
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, request_cancellation)


def run_managed_command(command, log):
    """Forward cancellation without killing the inner launcher's cleanup supervisor."""
    global active_process
    if cancellation_requested:
        raise RuntimeError("Cancellation was requested before launch")
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                               start_new_session=True)
    active_process = process
    forwarded = False
    try:
        while process.poll() is None:
            if cancellation_requested and not forwarded:
                # The preflight's direct Lua child shares this new session group.
                # Full reading owns separate native sessions and handles its own
                # bounded PID-handle cleanup after receiving this same signal.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                forwarded = True
            time.sleep(0.05)
        return process.returncode
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            # Never use subprocess.run's exceptional force-kill path here:
            # the inner launcher must finish cleaning its independent sessions.
            process.wait()
        active_process = None


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-archive-sha256", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--session-input", type=Path, required=True)
    parser.add_argument("--execute-live-read", action="store_true")
    args = parser.parse_args()
    install_cancellation_handlers()
    report = {"passed": False, "checks": {}, "counts": {}, "phases": {}}
    private_input = None
    shared = None
    trusted_work = None
    try:
        args.repo = args.repo.resolve(strict=True)
        shared_path = args.repo / "spec/integration/run_live_reading.py"
        specification = importlib.util.spec_from_file_location("shared_live_reading", shared_path)
        shared = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(shared)
        report["execution"] = shared.execution_context("local-wsl")
        args.runtime = args.runtime.resolve(strict=True)
        args.archive = shared.regular_path(args.archive)
        args.manifest = shared.regular_path(args.manifest)
        args.session_input = shared.regular_path(args.session_input)
        assert 0 < args.session_input.stat().st_size <= 131072
        assert not args.work.exists() and not args.work.is_symlink()
        args.work = args.work.resolve()
        assert args.work.is_relative_to(Path.home().resolve()) and args.work != Path.home().resolve()
        assert not any(left.is_relative_to(right) for left, right in (
            (args.work, args.repo), (args.repo, args.work),
            (args.work, args.runtime), (args.runtime, args.work)))
        assert not args.session_input.is_relative_to(args.work)
        shared.protected_inputs.add((args.session_input.stat().st_dev, args.session_input.stat().st_ino))
        assert (args.runtime / "git-rev").read_text().strip() == shared.EXPECTED_VERSION
        namespace = subprocess.run(["unshare", "--user", "--map-current-user", "--net", "/bin/true"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert namespace.returncode == 0
        report["checks"]["unprivileged_network_namespace_available"] = True
        archive_hash = shared.digest(args.archive)
        assert archive_hash == args.expected_archive_sha256
        manifest = json.loads(args.manifest.read_bytes())
        assert manifest["sha256"] == archive_hash
        packaged = {item["path"]: item["sha256"] for item in manifest["files"]}
        assert len(packaged) == len(manifest["files"])
        production = shared.code_manifest(args.repo)
        assert all(production.get(name) == value for name, value in packaged.items())
        omitted = sorted(set(production) - set(packaged))
        assert all(name.startswith("bilicomics/protocol/native/")
            and Path(name).suffix not in {".lua", ".so", ".json", ".md"} for name in omitted)
        shared.mkdir_private(args.work)
        trusted_work = args.work
        drivers = args.work / "drivers"
        shared.mkdir_private(drivers)
        tests = {}
        for relative in ("spec/integration/run_live_reading.py", "spec/integration/live_reading.lua",
                         "spec/integration/prepare_live_reading.py", "spec/integration/prepare_live_reading.lua",
                         "research/protocol/live-reading-guard.lua"):
            source = shared.regular_path(args.repo / relative)
            tests[source.name] = shared.digest(source)
            shared.copy_code(source, drivers / source.name)
        candidate_root = args.work / "candidate"
        shared.mkdir_private(candidate_root)
        candidate = candidate_root / "bilicomics.koplugin"
        shared.mkdir_private(candidate)
        with zipfile.ZipFile(args.archive) as archive:
            entries = archive.infolist()
            names = []
            for entry in entries:
                path = PurePosixPath(entry.filename)
                assert not entry.is_dir() and not path.is_absolute() and ".." not in path.parts
                assert "\\" not in entry.filename and path.parts[0] == "bilicomics.koplugin"
                assert not stat.S_ISLNK(entry.external_attr >> 16)
                relative = path.relative_to("bilicomics.koplugin").as_posix()
                assert relative in packaged and relative not in names
                content = archive.read(entry)
                assert hashlib.sha256(content).hexdigest() == packaged[relative]
                destination = candidate / relative
                shared.mkdir_private(destination.parent)
                shared.write_bytes(destination, content)
                names.append(relative)
            assert set(names) == set(packaged)
        assert shared.code_manifest(candidate) == packaged
        report["checks"].update(candidate_archive_matches_manifest=True,
            every_packaged_file_matches_source=True, extracted_candidate_matches_archive=True)
        report["counts"].update(packaged_files=len(packaged), source_production_files=len(production),
                                omitted_native_source_files=len(omitted))
        report["code_sha256"] = {"archive": archive_hash, "source_production": production,
            "source_production_manifest": shared.manifest_digest(production),
            "candidate_production": packaged, "candidate_production_manifest": shared.manifest_digest(packaged),
            "drivers": tests, "wrapper": shared.digest(Path(__file__).resolve())}
        inputs = args.work / "input"
        shared.mkdir_private(inputs)
        private_input = inputs / "session.txt"
        descriptor = os.open(private_input, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with args.session_input.open("rb") as source, os.fdopen(descriptor, "wb") as destination:
            shutil.copyfileobj(source, destination)
        common = ["--execution-host", "local-wsl", "--runtime", str(args.runtime),
                  "--source", str(candidate), "--session", str(private_input)]

        def execute(name, command, result_path):
            with (args.work / (name + "-launcher.log")).open("xb") as log:
                returncode = run_managed_command(command, log)
            value = json.loads(result_path.read_bytes()) if result_path.exists() else {"passed": False}
            report["phases"][name] = value
            assert not cancellation_requested and returncode == 0 and value.get("passed") is True
            return value

        validation = args.work / "validation"
        validated = execute("validation", [sys.executable, str(drivers / "prepare_live_reading.py")]
            + common + ["--work", str(validation)], validation / "preflight-results.json")
        report["checks"]["real_session_validated"] = validated["checks"]["session_valid"] is True
        if args.execute_live_read:
            selection = args.work / "selection"
            execute("selection", [sys.executable, str(drivers / "prepare_live_reading.py")]
                + common + ["--work", str(selection), "--select"], selection / "preflight-results.json")
            live_work = args.work / "live"
            live = execute("live", [sys.executable, str(drivers / "run_live_reading.py")]
                + common + ["--work", str(live_work), "--selection", str(selection / "selection.json"),
                    "--guard", str(drivers / "live-reading-guard.lua"), "--execute-live-read"], live_work / "results.json")
            assert live["code_sha256"]["production"] == packaged
            report["checks"]["live_result_matches_exact_candidate"] = True
            report["checks"]["complete_online_and_independent_offline_passed"] = True
        report["checks"]["candidate_unchanged"] = shared.code_manifest(candidate) == packaged
        report["checks"]["source_unchanged"] = shared.code_manifest(args.repo) == production
        report["checks"]["archive_unchanged"] = shared.digest(args.archive) == archive_hash
        report["checks"]["staged_drivers_unchanged"] = all(shared.digest(drivers / name) == value
            for name, value in tests.items())
        report["passed"] = all(report["checks"].values())
    except (Exception, KeyboardInterrupt):
        report["passed"] = False
        report["checks"]["wrapper_completed"] = False
    finally:
        report["checks"]["child_launcher_terminal_before_input_cleanup"] = active_process is None
        if private_input is not None and private_input.exists():
            assert not private_input.is_symlink() and private_input.parent == trusted_work / "input"
            private_input.unlink()
        report["checks"]["copied_session_input_absent"] = private_input is None or not private_input.exists()
        report["cancelled"] = cancellation_requested
        report["passed"] = report["passed"] and not cancellation_requested and all(report["checks"].values())
        if trusted_work:
            shared.write_json(trusted_work / "local-live-reading-results.json", report)
        print(json.dumps({"passed": report["passed"], "session_valid": report["checks"].get("real_session_validated", False),
                          "live_passed": report["checks"].get("complete_online_and_independent_offline_passed", False)}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
