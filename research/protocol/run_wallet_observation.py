"""Execute one explicitly approved wallet read through unmodified production code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time


cancel_requested = False


class PrivateParser(argparse.ArgumentParser):
    def error(self, _message):
        raise RuntimeError("Invalid private observer arguments")


def interrupted(_signal, _frame):
    global cancel_requested
    cancel_requested = True


def check_cancellation():
    if cancel_requested:
        raise InterruptedError("The private wallet read was canceled")


def regular(path):
    path = path.absolute()
    if any(item.is_symlink() for item in (path, *path.parents)) or not path.is_file():
        raise RuntimeError("A regular nonsymlink input is required")
    return path


def identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mode, value.st_uid, value.st_mtime_ns, value.st_ctime_ns)


def copy_session(original, destination, expected):
    fd = os.open(original, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if identity(before) != identity(expected):
            raise RuntimeError("The private input identity changed")
        with destination.open("xb") as output:
            os.fchmod(output.fileno(), 0o600)
            count = 0
            while True:
                block = os.read(fd, 65536)
                if not block:
                    break
                count += len(block)
                if count > 131072:
                    raise RuntimeError("The private input exceeds its bound")
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if count != expected.st_size or identity(os.fstat(fd)) != identity(expected):
            raise RuntimeError("The private input changed while copying")
    finally:
        os.close(fd)


def main():
    parser = PrivateParser(description=__doc__)
    for name in ("runtime", "source", "session-file", "basic-file", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--approved-readonly-wallet-observation", action="store_true", required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Use ssh test-env only")
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    os.umask(0o077)
    output = args.output.absolute()
    if output.resolve() != output or output.exists() or output.parent != args.session_file.absolute().parent:
        raise RuntimeError("Use a new child directory beside the approved private input")
    session = regular(args.session_file)
    metadata = session.stat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600 or not (1 <= metadata.st_size <= 131072):
        raise RuntimeError("The session input must be private and owned by this SSH user")
    if stat.S_IMODE(session.parent.stat().st_mode) != 0o700:
        raise RuntimeError("The session parent must remain private")
    baseline = regular(args.basic_file)
    baseline_metadata = baseline.stat()
    if not baseline.is_relative_to(session.parent) or baseline_metadata.st_uid != os.getuid() or stat.S_IMODE(baseline_metadata.st_mode) & 0o077:
        raise RuntimeError("The comparison record must be in the approved private directory")
    runtime, source = args.runtime.resolve(), args.source.resolve()
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the recorded official KOReader version")
    output.mkdir(mode=0o700)
    snapshot = output / "source"
    snapshot.mkdir(mode=0o700)
    hashes = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("The source snapshot must not contain links")
        if not path.is_file():
            continue
        path = regular(path)
        if (path.stat().st_dev, path.stat().st_ino) == (metadata.st_dev, metadata.st_ino):
            raise RuntimeError("The source snapshot must not contain the credential input")
        relative = path.relative_to(source)
        target = snapshot / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        data = path.read_bytes()
        hashes[str(relative)] = hashlib.sha256(data).hexdigest()
        target.write_bytes(data)
    probe = output / "wallet-observation.lua"
    shutil.copyfile(regular(Path(__file__).with_name("wallet-observation.lua")), probe)
    (output / "assets").mkdir(mode=0o700)
    private_session = output / "session-input-private.txt"
    env = {"PATH": "/usr/bin:/bin", "HOME": str(output), "LANG": "C.UTF-8", "TZ": "UTC", "KO_MULTIUSER": "1",
           "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
           "LUA_CPATH": "./?.so;./libs/?.so"}
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = output / ("xdg-" + kind.lower())
        directory.mkdir(mode=0o700)
        env["XDG_" + kind + "_HOME"] = str(directory)
    command = [str(regular(runtime / "luajit")), str(probe), str(snapshot), str(private_session), str(baseline), str(output),
               "approved-readonly-wallet-observation"]
    process, returncode, timed_out, observer_failed = None, None, False, False
    try:
        check_cancellation()
        copy_session(session, private_session, metadata)
        with (output / "process-private.log").open("wb") as log:
            check_cancellation()
            process = subprocess.Popen(command, cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 100
            while True:
                check_cancellation()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    os.killpg(process.pid, signal.SIGKILL)
                    returncode = process.wait(timeout=15)
                    break
                try:
                    returncode = process.wait(timeout=min(0.2, remaining))
                    break
                except subprocess.TimeoutExpired:
                    pass
    except BaseException:
        observer_failed = True
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            returncode = process.wait(timeout=15)
    finally:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        private_session.unlink(missing_ok=True)
    observation_path = output / "wallet-public.json"
    observation = json.loads(observation_path.read_text()) if observation_path.exists() else {"completed": False, "request_count": 0}
    source_unchanged = all(hashlib.sha256((snapshot / name).read_bytes()).hexdigest() == value for name, value in hashes.items())
    original_unchanged = identity(session.stat()) == identity(metadata)
    baseline_unchanged = identity(baseline.stat()) == identity(baseline_metadata)
    result = {"passed": returncode == 0 and observation.get("completed") is True and source_unchanged and original_unchanged and baseline_unchanged,
              "observation": observation, "source_sha256": hashes,
              "probe_sha256": hashlib.sha256(probe.read_bytes()).hexdigest(),
              "launcher_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "runtime_version": "v2026.07.1", "returncode": returncode, "timed_out": timed_out,
              "observer_failed": observer_failed, "child_terminal_and_reaped": process is not None and process.poll() is not None,
              "credential_copy_removed": not private_session.exists(), "original_credential_unchanged": original_unchanged,
              "private_baseline_unchanged": baseline_unchanged, "source_unchanged": source_unchanged,
              "purchase_submitted": False, "real_purchases": False, "account_mutations": False,
              "scope": "Exactly one approved production Client.wallet/Transport read; field shapes and equality only; raw financial data stays private"}
    result["passed"] = result["passed"] and result["child_terminal_and_reaped"] and result["credential_copy_removed"]
    (output / "wallet-observation-public.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"passed": result["passed"], "request_count": observation.get("request_count"),
                      "child_terminal_and_reaped": result["child_terminal_and_reaped"],
                      "credential_copy_removed": result["credential_copy_removed"]}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print("The private wallet observer could not complete.", file=sys.stderr)
        raise SystemExit(1)
