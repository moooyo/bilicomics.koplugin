"""Exercise wrapper cancellation and optimization rejection without network access."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def wait_file(path, process, timeout=8):
    deadline = time.monotonic() + timeout
    while not path.exists() and time.monotonic() < deadline:
        if process.poll() is not None:
            break
        time.sleep(0.03)
    if not path.exists():
        raise RuntimeError("The isolated fixture did not reach its expected stage")


def fixture(kind, work, wrapper):
    if kind == "native":
        (work / "native-ready").touch()
        time.sleep(30)
    elif kind == "supervisor":
        stopping = False
        def stop(_signum, _frame):
            nonlocal stopping
            stopping = True
        signal.signal(signal.SIGTERM, stop)
        child = subprocess.Popen([sys.executable, __file__, "--fixture", "native", "--work", str(work)],
                                 start_new_session=True)
        try:
            wait_file(work / "native-ready", child)
            (work / "supervisor-ready").touch()
            while not stopping:
                time.sleep(0.02)
            # A force-killed supervisor cannot complete this delayed cleanup.
            time.sleep(0.25)
        finally:
            child.terminate()
            child.wait(timeout=5)
            (work / "supervisor-cleaned").touch()
    elif kind == "parent":
        module = load(wrapper, "local_wrapper")
        module.install_cancellation_handlers()
        copied = work / "synthetic-input"
        copied.write_text("synthetic fixture input")
        with (work / "fixture.log").open("wb") as log:
            status = module.run_managed_command([sys.executable, __file__, "--fixture", "supervisor",
                "--work", str(work)], log)
        result = {"signal_forwarded": module.cancellation_requested,
                  "supervisor_cleanup_completed_before_input_removal": (work / "supervisor-cleaned").exists(),
                  "managed_supervisor_terminal": module.active_process is None and status == 0}
        copied.unlink()
        result["copied_input_absent"] = not copied.exists()
        (work / "fixture-results.json").write_text(json.dumps(result))
        return int(not all(result.values()))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fixture", choices=("native", "supervisor", "parent"))
    parser.add_argument("--work", type=Path)
    parser.add_argument("--wrapper", type=Path)
    args = parser.parse_args()
    if args.fixture:
        return fixture(args.fixture, args.work, args.wrapper)
    os.umask(0o077)
    if sys.platform != "linux" or os.geteuid() == 0:
        raise RuntimeError("Run as the authorized ordinary WSL user")
    if any(line.strip() and not line.startswith("Iface")
           for line in Path("/proc/net/route").read_text().splitlines()):
        raise RuntimeError("These fixture checks must run in an empty network namespace")
    wrapper = args.repo / "spec/local/run_live_reading.py"
    shared = args.repo / "spec/integration/run_live_reading.py"
    results = {}
    with tempfile.TemporaryDirectory(prefix="bilicomics-wrapper-check-", dir=Path.home()) as temporary:
        root = Path(temporary)
        for name, signum in (("term", signal.SIGTERM), ("interrupt", signal.SIGINT)):
            work = root / name
            work.mkdir(mode=0o700)
            process = subprocess.Popen([sys.executable, __file__, "--fixture", "parent", "--work", str(work),
                "--wrapper", str(wrapper)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            try:
                wait_file(work / "supervisor-ready", process)
                process.send_signal(signum)
                returncode = process.wait(timeout=10)
                result = json.loads((work / "fixture-results.json").read_bytes())
                results[name] = returncode == 0 and all(result.values())
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    process.wait(timeout=10)
        check_code = (
            "import importlib.util,sys; p=sys.argv[1]; s=importlib.util.spec_from_file_location('shared',p); "
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
            "m.execution_context('local-wsl')"
        )
        for name, flags, env in (("explicit_optimization_rejected", ["-O"], os.environ.copy()),
                                ("environment_optimization_rejected", [], {**os.environ, "PYTHONOPTIMIZE": "1"})):
            process = subprocess.run([sys.executable] + flags + ["-c", check_code, str(shared)], env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            results[name] = process.returncode != 0
    report = {"passed": all(results.values()), "checks": results, "network_isolated": True,
              "production_responses_used": False, "counts": {"cases": len(results)}, "code_sha256": {}}
    for path in (wrapper, shared, Path(__file__).resolve(), args.repo / "spec/integration/prepare_live_reading.py",
                 args.repo / "spec/integration/prepare_live_reading.lua"):
        report["code_sha256"][path.relative_to(args.repo).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
