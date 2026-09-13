"""Reap and inspect real orphaned workers after their isolated reader parent exits."""
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import traceback


def wait_child(pid, deadline):
    while time.monotonic() < deadline:
        found, status = os.waitpid(pid, os.WNOHANG)
        if found == pid:
            return status
        time.sleep(0.005)
    return None


def run(runtime: Path, source: Path, output: Path, environment):
    libc = ctypes.CDLL(None, use_errno=True)
    # Adopt only this supervisor's descendants so every orphan remains reapable.
    libc.prctl.restype = ctypes.c_int
    result = libc.prctl(ctypes.c_int(36), ctypes.c_ulong(1), ctypes.c_ulong(0), ctypes.c_ulong(0), ctypes.c_ulong(0))
    if result != 0:
        raise OSError(ctypes.get_errno(), "The remote supervisor cannot become a child subreaper")
    tests = []
    for mode in ("registered", "before_registration"):
        directory = output / f"parent-exit-{mode}"
        directory.mkdir()
        evidence = {"mode": mode, "forced_cleanup": False}
        parent = None
        child_pid = None
        child_status = None
        try:
            with (directory / "parent.log").open("w") as log:
                parent = subprocess.Popen([str(runtime / "luajit"), str(source / "spec/jobs/parent_exit_fixture.lua"),
                                           str(source), str(directory), mode], cwd=runtime, env=environment,
                                          stdout=log, stderr=subprocess.STDOUT)
                parent_code = parent.wait(timeout=3)
            evidence["parent_returncode"] = parent_code
            processes = json.loads((directory / "processes.json").read_text())
            child_pid = processes["child_pid"]
            evidence.update(processes)
            assert parent_code == 71, "The isolated parent did not reach its intentional ungraceful exit"
            assert processes["parent_pid"] == parent.pid, "The fixture reported an unrelated parent PID"
            started = time.monotonic()
            child_status = wait_child(child_pid, started + 0.65)
            evidence["reap_delay_seconds"] = time.monotonic() - started
            assert child_status is not None, "A worker survived beyond its reader's exit deadline"
            evidence["child_wait_status"] = child_status
            if mode == "registered":
                assert (directory / "worker-started").exists(), "The registered worker never reached its execution body"
                assert os.WIFSIGNALED(child_status) and os.WTERMSIG(child_status) == signal.SIGKILL, \
                    "An executing orphan must be killed by its parent-death signal"
            else:
                assert not (directory / "worker-started").exists(), "The stale parent PID check allowed an orphan to execute"
                assert os.WIFEXITED(child_status) and os.WEXITSTATUS(child_status) == 0, \
                    "A worker whose parent died before registration must exit at the parent-PID guard"
            assert not (directory / "late-write").exists(), "An orphan wrote a file after its reader parent exited"
            evidence["late_write_absent"] = True
            try:
                os.waitpid(child_pid, os.WNOHANG)
            except ChildProcessError:
                evidence["child_reaped"] = True
            else:
                raise AssertionError("The supervisor left a child wait status uncollected")
            evidence["passed"] = True
        except Exception:
            evidence["passed"] = False
            evidence["error"] = traceback.format_exc()
        finally:
            if parent and parent.poll() is None:
                parent.kill()
                parent.wait(timeout=2)
            if child_pid and child_status is None:
                evidence["forced_cleanup"] = True
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    evidence["cleanup_wait_status"] = wait_child(child_pid, time.monotonic() + 2)
                except ChildProcessError:
                    pass
        tests.append(evidence)
    result = {"tests": tests, "passed": all(test["passed"] for test in tests),
              "scope": "Real Linux parent exit, PDEATHSIG, parent-PID race and adopted child reaping; no network"}
    (output / "parent-exit-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result
