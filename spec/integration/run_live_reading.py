"""Stage or explicitly execute one authorized live-reading probe on test-env.

Preparation compiles code without opening selection or session contents. Live
execution requires --execute-live-read and runs the offline phase in a new
network namespace. All logs and control files remain inside the private work
directory. This launcher never prints subprocess output or exception details.
"""

import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import traceback


PRODUCTION_ROOTS = ("bilicomics", "patches", "l10n", "main.lua", "_meta.lua")
RUNTIME_FILES = (
    "luajit", "frontend/apps/reader/readerui.lua",
    "frontend/document/document.lua", "ffi/mupdf.lua",
)
EXPECTED_VERSION = "v2026.07.1"
MAX_REPORT_BYTES = 2 * 1024 * 1024
MAX_PID_BYTES = 2 * 1024 * 1024
STOP_GRACE = 5.0
TERM_GRACE = 2.0
KILL_GRACE = 3.0
cancel_requested = False
protected_inputs = set()
GATED_EXEC = (
    "import json,os,sys; descriptor=int(sys.argv[1]); "
    "token=os.read(descriptor,1); os.close(descriptor); "
    "argv=json.loads(sys.argv[2]); "
    "os.execvpe(argv[0],argv,os.environ) if token==b'1' else os._exit(124)"
)


class ProbeError(Exception):
    """A private failure whose message must not reach public evidence."""


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ProbeError("Invalid launcher arguments")


def require(condition):
    if not condition:
        raise ProbeError("A launcher precondition failed")


def digest(path):
    info = path.stat()
    require((info.st_dev, info.st_ino) not in protected_inputs)
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def regular_path(path):
    """Inspect metadata only; never open an input credential or selection."""
    require(path is not None and not path.is_symlink())
    info = path.stat()
    require(stat.S_ISREG(info.st_mode))
    return path.resolve(strict=True)


def mkdir_private(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not path.is_symlink() and path.is_dir())
    require(path.stat().st_uid == os.geteuid())
    path.chmod(0o700)


def write_bytes(path, value):
    require(not path.is_symlink())
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())
    path.chmod(0o600)


def write_json(path, value):
    write_bytes(path, (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode())


def read_json(path, maximum=MAX_REPORT_BYTES):
    require(not path.is_symlink() and stat.S_ISREG(path.stat().st_mode))
    require(path.stat().st_size <= maximum)
    with path.open("rb") as handle:
        value = handle.read(maximum + 1)
    require(len(value) <= maximum)
    return json.loads(value, parse_constant=lambda _: (_ for _ in ()).throw(ProbeError()))


def code_manifest(root):
    result = {}
    for name in PRODUCTION_ROOTS:
        start = root / name
        require(start.exists() and not start.is_symlink())
        paths = sorted(start.rglob("*")) if start.is_dir() else [start]
        for path in paths:
            require(not path.is_symlink())
            relative = path.relative_to(root)
            require(not any(part.lower() in ("accounts", "session.dat") for part in relative.parts))
            require(path.is_dir() or path.is_file())
            if path.is_file():
                require(path.resolve().is_relative_to(root))
                result[relative.as_posix()] = digest(path)
    require(result and "main.lua" in result and "bilicomics/reader/document.lua" in result)
    return result


def manifest_digest(manifest):
    encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def copy_code(source, target):
    mkdir_private(target.parent)
    require(not target.is_symlink())
    shutil.copyfile(source, target)
    target.chmod(0o600 | (source.stat().st_mode & stat.S_IXUSR))


def lua_literal(value):
    """Quote paths as Lua bytes without depending on JSON escape semantics."""
    return '"' + "".join("\\%03d" % byte for byte in str(value).encode("utf-8")) + '"'


def stage(args, report):
    source_hashes = code_manifest(args.source)
    driver = regular_path(Path(__file__).resolve().with_name("live_reading.lua"))
    launcher = regular_path(Path(__file__).resolve())
    test_hashes = {driver.name: digest(driver), launcher.name: digest(launcher)}
    expected = {"schema": 1, "source_sha256": source_hashes, "test_sha256": test_hashes}
    package = args.work / "bundle/bilicomics.koplugin"
    tests = args.work / "spec/integration"
    marker = args.work / "private/staging.json"
    if args.work.exists() and any(args.work.iterdir()):
        require(marker.is_file() and not marker.is_symlink())
        require(read_json(marker) == expected)
        require(code_manifest(package) == source_hashes)
        require(all(digest(tests / name) == value for name, value in test_hashes.items()))
        require(not (args.work / "private/execution-started").exists())
        require(not (args.work / "private/data/bilicomics").exists())
        require(not any((args.work / (phase + "-results.json")).exists() for phase in ("online", "offline")))
    else:
        mkdir_private(args.work)
        for path in (args.work / "private", args.work / "private/data", package, tests):
            mkdir_private(path)
        for relative in source_hashes:
            copy_code(args.source / relative, package / relative)
        for path in (driver, launcher):
            copy_code(path, tests / path.name)
        settings = "return {quickstart_shown_version=9999999999,color_rendering=false," \
            "start_with=\"filemanager\",extra_plugin_paths={" + lua_literal(package.parent) + "}}\n"
        write_bytes(args.work / "private/data/settings.reader.lua", settings.encode())
        require(code_manifest(package) == source_hashes)
        require(code_manifest(args.source) == source_hashes)
        write_json(marker, expected)
    for path in (args.work, args.work / "private", args.work / "private/data"):
        mkdir_private(path)
    report["code_sha256"] = {
        "production": source_hashes,
        "production_manifest": manifest_digest(source_hashes),
        "tests": test_hashes,
        "runtime": {name: digest(regular_path(args.runtime / name)) for name in RUNTIME_FILES},
    }
    if args.guard is not None:
        guard_hash = digest(args.guard)
        guard_marker = args.work / "private/guard.sha256"
        if guard_marker.exists():
            require(not guard_marker.is_symlink() and guard_marker.read_text().strip() == guard_hash)
        else:
            write_bytes(guard_marker, (guard_hash + "\n").encode())
        report["code_sha256"]["guard"] = guard_hash
    report["status"]["staged"] = True
    return package, tests


def syntax_check(args, package, tests, report):
    private = args.work / "private"
    bytecode = private / "bytecode"
    mkdir_private(bytecode)
    compile((tests / "run_live_reading.py").read_bytes(), "run_live_reading.py", "exec")
    report["status"]["python_syntax_valid"] = True
    paths = sorted(package.rglob("*.lua")) + [tests / "live_reading.lua"]
    if args.guard is not None:
        paths.append(args.guard)
    count = 0
    log = private / "syntax.log"
    with log.open("wb") as handle:
        log.chmod(0o600)
        for index, path in enumerate(paths):
            require(not cancel_requested)
            completed = subprocess.run(
                [str(args.runtime / "luajit"), "-b", str(path), str(bytecode / (str(index) + ".bc"))],
                cwd=args.runtime, stdout=handle, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, close_fds=True, timeout=20,
            )
            require(completed.returncode == 0)
            count += 1
    report["counts"]["lua_files_compiled"] = count
    report["status"]["lua_syntax_valid"] = True


def process_identity(pid):
    try:
        value = Path("/proc") / str(pid) / "stat"
        text = value.read_bytes()
        tail = text[text.rfind(b")") + 2:].split()
        return {"pid": pid, "state": tail[0].decode("ascii"), "ppid": int(tail[1]),
                "pgid": int(tail[2]), "sid": int(tail[3]), "starttime": int(tail[19])}
    except (FileNotFoundError, ProcessLookupError):
        return None


def same_identity(left, right):
    return left is not None and right is not None and all(
        left[key] == right[key] for key in ("pid", "starttime", "sid"))


def all_processes():
    result = []
    for path in Path("/proc").iterdir():
        if path.name.isdigit():
            identity = process_identity(int(path.name))
            if identity is not None:
                result.append(identity)
    return result


def enable_lifetime_control():
    require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"))
    probe_fd = os.pidfd_open(os.getpid(), 0)
    os.close(probe_fd)
    libc = ctypes.CDLL(None, use_errno=True)
    require(libc.prctl(36, 1, 0, 0, 0) == 0)  # PR_SET_CHILD_SUBREAPER.


class PhaseProcess:
    """Track the complete native session, including independent worker PGIDs."""

    def __init__(self, process, private, phase):
        self.process = process
        self.root = process_identity(process.pid)
        require(self.root is not None and self.root["sid"] == process.pid)
        self.sid = self.root["sid"]
        self.private = private
        self.pid_file = private / (phase + "-children.jsonl")
        self.stop_file = private / (phase + "-stop")
        self.held = {}
        self.records_valid = True
        self.cleaned = False
        self.forced = False
        self.control_valid = True
        self.track(self.root)

    def track(self, identity):
        require(identity["pid"] > 1 and identity["pid"] != os.getpid())
        key = (identity["pid"], identity["starttime"])
        if key in self.held:
            return
        try:
            descriptor = os.pidfd_open(identity["pid"], 0)
        except ProcessLookupError:
            return
        current = process_identity(identity["pid"])
        if not same_identity(identity, current):
            os.close(descriptor)
            return
        self.held[key] = {"identity": current, "fd": descriptor}

    def read_child_records(self):
        if not self.pid_file.exists():
            return
        try:
            require(not self.pid_file.is_symlink() and self.pid_file.is_file())
            require(self.pid_file.stat().st_size <= MAX_PID_BYTES)
            value = self.pid_file.read_bytes()
            for line in value.splitlines(keepends=True):
                if not line.endswith(b"\n"):
                    continue
                require(len(line) <= 512)
                record = json.loads(line)
                require(isinstance(record, dict) and set(record).issubset({"pid", "pgid", "sid", "starttime"}))
                require(all(type(record.get(key)) is int and record[key] > 0 for key in ("pid", "pgid", "starttime")))
                current = process_identity(record["pid"])
                if current is None or current["starttime"] != record["starttime"]:
                    continue
                require(current["sid"] == self.sid and current["pid"] != os.getpid())
                if "sid" in record:
                    require(record["sid"] == self.sid)
                # Runner may complete setpgid after the parent records its PID.
                require(current["pgid"] in (record["pgid"], current["pid"], self.sid))
                require(current["starttime"] >= self.root["starttime"])
                self.track(current)
        except Exception:
            self.records_valid = False

    def refresh(self):
        identities = all_processes()
        live_held = [item["identity"] for item in self.held.values()
                     if same_identity(item["identity"], process_identity(item["identity"]["pid"]))]
        # The launcher starts no concurrent subprocesses during a phase. Direct
        # children adopted by the subreaper therefore also establish ownership.
        adopted = [item for item in identities if item["ppid"] == os.getpid()
                   and item["starttime"] >= self.root["starttime"]]
        session_owned = any(item["sid"] == self.sid for item in live_held + adopted)
        for identity in identities:
            if identity in adopted or (session_owned and identity["sid"] == self.sid
                                       and identity["starttime"] >= self.root["starttime"]):
                self.track(identity)
        self.read_child_records()

    def reap(self):
        self.process.poll()
        for item in self.held.values():
            identity = item["identity"]
            if identity["pid"] == self.process.pid:
                continue
            current = process_identity(identity["pid"])
            if same_identity(identity, current) and current["ppid"] == os.getpid():
                try:
                    os.waitpid(identity["pid"], os.WNOHANG)
                except ChildProcessError:
                    pass

    def remaining(self):
        return [item for item in self.held.values()
                if same_identity(item["identity"], process_identity(item["identity"]["pid"]))]

    def signal_remaining(self, signum, refresh=True):
        if refresh:
            try:
                self.refresh()
            except Exception:
                self.control_valid = False
        for item in self.remaining():
            original = item["identity"]
            current = process_identity(original["pid"])
            if not same_identity(original, current):
                continue
            # Recheck the current PGID, but signal the stable PID handle rather
            # than a numeric process group that could be recycled by the kernel.
            try:
                current["pgid"] = os.getpgid(current["pid"])
                signal.pidfd_send_signal(item["fd"], signum, None, 0)
            except ProcessLookupError:
                pass
            except OSError:
                self.control_valid = False

    def settle(self, seconds, repeat_kill=False):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.refresh()
            if repeat_kill:
                self.signal_remaining(signal.SIGKILL, refresh=False)
            self.reap()
            if self.process.poll() is not None and not self.remaining():
                return True
            time.sleep(0.05)
        return False

    def cleanup(self):
        try:
            try:
                write_bytes(self.stop_file, b"stop\n")
            except Exception:
                self.control_valid = False
            for signum, grace in ((None, STOP_GRACE), (signal.SIGTERM, TERM_GRACE),
                                  (signal.SIGKILL, KILL_GRACE)):
                if signum is not None:
                    self.forced = True
                    try:
                        self.signal_remaining(signum)
                    except Exception:
                        self.control_valid = False
                try:
                    if self.settle(grace, repeat_kill=signum == signal.SIGKILL):
                        self.cleaned = self.control_valid
                        return
                except Exception:
                    self.control_valid = False
        finally:
            for item in self.held.values():
                os.close(item["fd"])


def clean_isolated_sessions(work):
    """Unlink only session files and their strict temporary names in this root."""
    descriptors = []
    removed = 0
    valid = True
    try:
        descriptor = os.open(work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(descriptor)
        for component in ("private", "data", "bilicomics", "accounts"):
            try:
                descriptor = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                     dir_fd=descriptor)
            except FileNotFoundError:
                return True, removed
            descriptors.append(descriptor)
        for name in os.listdir(descriptor):
            info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode):
                valid = False
                continue
            account = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            try:
                for filename in os.listdir(account):
                    if filename != "session.dat" and not re.fullmatch(r"session\.dat\.new-[0-9]+-[0-9]+", filename):
                        continue
                    os.unlink(filename, dir_fd=account)
                    os.fsync(account)
                    removed += 1
                    try:
                        os.stat(filename, dir_fd=account, follow_symlinks=False)
                        valid = False
                    except FileNotFoundError:
                        pass
                if any(filename == "session.dat" or re.fullmatch(r"session\.dat\.new-[0-9]+-[0-9]+", filename)
                       for filename in os.listdir(account)):
                    valid = False
            finally:
                os.close(account)
        return valid, removed
    except Exception:
        return False, removed
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def clear_native_cache(work):
    """Remove only the isolated native cache, retaining PageStore and settings."""
    current = work
    require(current.resolve(strict=True) == current and not current.is_symlink())
    for component in ("private", "data"):
        current = current / component
        require(current.is_dir() and not current.is_symlink())
    cache = current / "cache"
    if not cache.exists():
        require(not cache.is_symlink())
        return 0
    require(cache.is_dir() and not cache.is_symlink())
    require(cache.resolve(strict=True) == work / "private/data/cache")
    paths = list(cache.rglob("*"))
    for path in paths:
        require(not path.is_symlink() and (path.is_file() or path.is_dir()))
        require(path.resolve(strict=True).is_relative_to(cache))
    shutil.rmtree(cache)
    require(not cache.exists() and not cache.is_symlink())
    return len(paths)


def public_value(value, depth=0):
    require(depth <= 12)
    if type(value) is bool:
        return value
    if type(value) in (int, float):
        require(math.isfinite(value) and abs(value) <= 10 ** 18)
        return value
    if type(value) is list:
        require(len(value) <= 10000)
        return [public_value(item, depth + 1) for item in value]
    require(type(value) is dict and len(value) <= 10000)
    result = {}
    for key, item in value.items():
        require(type(key) is str and re.fullmatch(r"[a-z][a-z0-9_]{0,95}", key))
        require(key not in ("id", "pid", "uid", "url", "uri", "path", "token", "cookie", "session")
                and not key.endswith(("_id", "_pid", "_uid", "_url", "_uri", "_path", "_token", "_cookie")))
        result[key] = public_value(item, depth + 1)
    return result


def phase_report(work, phase):
    path = work / (phase + "-results.json")
    try:
        value = public_value(read_json(path))
        require(type(value) is dict and type(value.get("passed")) is bool)
        value["report_schema_valid"] = True
    except Exception:
        if path.exists() and not path.is_symlink() and path.is_file():
            path.replace(work / "private" / (phase + "-unpublishable.json"))
        value = {"passed": False, "report_schema_valid": False}
    write_json(path, value)
    return value


def run_phase(args, package, tests, phase):
    private = args.work / "private"
    cache = private / ("cache-" + phase)
    home = private / "home"
    mkdir_private(cache)
    mkdir_private(home)
    environment = os.environ.copy()
    environment.pop("BILI_LIVE_AUTHORIZED", None)
    environment.update(
        KO_HOME=str(args.work / "private/data"), HOME=str(home), CURL_HOME=str(home),
        XDG_CONFIG_HOME=str(args.work / "private/data/xdg-config"),
        XDG_DATA_HOME=str(args.work / "private/data/xdg-data"), XDG_CACHE_HOME=str(cache),
        EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy",
        BILI_PARENT_NETNS=os.readlink("/proc/self/ns/net"),
        BILI_PHASE_TIMEOUT=str(args.timeout),
        BILI_CHILD_PID_FILE=str(private / (phase + "-children.jsonl")),
        BILI_STOP_FILE=str(private / (phase + "-stop")),
    )
    if phase == "online":
        environment["BILI_LIVE_AUTHORIZED"] = "1"
    command = ["xvfb-run", "-a", str(args.runtime / "luajit"), str(tests / "live_reading.lua"),
               str(package), str(args.work), phase, str(args.selection), str(args.guard), str(args.session)]
    if phase == "offline":
        command = ["unshare", "-n", "--"] + command
    log = private / (phase + ".log")
    monitor = None
    process = None
    within_deadline = False
    gate_read, gate_write = os.pipe()
    with log.open("wb") as handle:
        log.chmod(0o600)
        try:
            gated = [sys.executable, "-I", "-c", GATED_EXEC, str(gate_read), json.dumps(command)]
            process = subprocess.Popen(gated, cwd=args.runtime, env=environment,
                                       stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT,
                                       close_fds=True, pass_fds=(gate_read,), start_new_session=True)
            os.close(gate_read)
            gate_read = None
            monitor = PhaseProcess(process, private, phase)
            # No native code or descendant process can start before a fully
            # initialized monitor holds the launcher's stable PID handle.
            require(os.write(gate_write, b"1") == 1)
            os.close(gate_write)
            gate_write = None
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline and not cancel_requested:
                monitor.refresh()
                if not monitor.records_valid:
                    break
                if process.poll() is not None:
                    within_deadline = True
                    break
                time.sleep(0.1)
        finally:
            if gate_read is not None:
                os.close(gate_read)
            if gate_write is not None:
                os.close(gate_write)
            if monitor is not None:
                monitor.cleanup()
            elif process is not None:
                # EOF closes an unreleased gate before any native code starts.
                # The sole child is still ours until wait and cannot have workers.
                try:
                    process.wait(timeout=KILL_GRACE)
                except subprocess.TimeoutExpired:
                    descriptor = os.pidfd_open(process.pid, 0)
                    try:
                        signal.pidfd_send_signal(descriptor, signal.SIGKILL, None, 0)
                        process.wait(timeout=KILL_GRACE)
                    finally:
                        os.close(descriptor)
    result = phase_report(args.work, phase)
    result["launcher"] = {
        "process_completed": process is not None and process.returncode == 0,
        "within_deadline": within_deadline,
        "children_cleaned": monitor is not None and monitor.cleaned,
        "pid_records_valid": monitor is not None and monitor.records_valid,
        "forced_cleanup": monitor is not None and monitor.forced,
        "processes_observed": len(monitor.held) if monitor is not None else 0,
    }
    result["passed"] = result["passed"] and all(result["launcher"][key] for key in
        ("process_completed", "within_deadline", "children_cleaned", "pid_records_valid"))
    write_json(args.work / (phase + "-results.json"), result)
    return result


def parse_arguments():
    parser = PrivateArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--selection", type=Path)
    parser.add_argument("--guard", type=Path)
    parser.add_argument("--session", type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--execute-live-read", action="store_true")
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--syntax-only", action="store_true")
    return parser.parse_args()


def cancelled(_signum, _frame):
    global cancel_requested
    cancel_requested = True


def verify_code(args, package, tests, report):
    expected = report["code_sha256"]
    checks = {
        "source_unchanged": lambda: code_manifest(args.source) == expected["production"],
        "staged_source_unchanged": lambda: code_manifest(package) == expected["production"],
        "runtime_unchanged": lambda: all(digest(args.runtime / name) == value
                                         for name, value in expected["runtime"].items()),
        "tests_unchanged": lambda: all(digest(tests / name) == value for name, value in expected["tests"].items()),
        "guard_unchanged": lambda: args.guard is None or digest(args.guard) == expected["guard"],
    }
    for name, operation in checks.items():
        try:
            report["status"][name] = bool(operation())
        except Exception:
            report["status"][name] = False
    return all(report["status"][name] for name in checks)


def main():
    os.umask(0o077)
    report = {"passed": False, "status": {"staged": False, "live_requested": False,
              "online_executed": False, "offline_executed": False,
              "unexpected_error": False}, "counts": {"isolated_sessions_removed": 0}}
    args = None
    trusted_work = False
    package = tests = None
    try:
        require(sys.platform == "linux" and os.geteuid() == 0)
        args = parse_arguments()
        require(1 <= args.timeout <= 1800)
        report["status"]["live_requested"] = args.execute_live_read
        require(not args.work.is_symlink())
        args.work = args.work.resolve()
        args.source = args.source.resolve(strict=True)
        args.runtime = args.runtime.resolve(strict=True)
        require(args.source.is_dir() and args.runtime.is_dir())
        require(not any(left.is_relative_to(right) for left, right in (
            (args.work, args.source), (args.source, args.work),
            (args.work, args.runtime), (args.runtime, args.work))))
        require((args.runtime / "git-rev").read_text().strip() == EXPECTED_VERSION)
        for key in ("selection", "guard", "session"):
            value = getattr(args, key)
            if value is not None:
                value = regular_path(value)
                require(not value.is_relative_to(args.work))
                setattr(args, key, value)
            elif args.execute_live_read:
                require(False)
        for value in (args.selection, args.session):
            if value is not None:
                info = value.stat()
                protected_inputs.add((info.st_dev, info.st_ino))
        if args.guard is not None:
            info = args.guard.stat()
            require((info.st_dev, info.st_ino) not in protected_inputs)
        if args.work.exists():
            require(args.work.is_dir() and args.work.stat().st_uid == os.geteuid())
        signal.signal(signal.SIGTERM, cancelled)
        signal.signal(signal.SIGINT, cancelled)
        package, tests = stage(args, report)
        trusted_work = True
        syntax_check(args, package, tests, report)
        if args.execute_live_read:
            enable_lifetime_control()
            require(not cancel_requested)
            require(not (args.work / "private/data/bilicomics").exists())
            write_bytes(args.work / "private/execution-started", b"one authorized online chapter\n")
            report["status"]["online_executed"] = True
            report["online"] = run_phase(args, package, tests, "online")
            cleaned, count = clean_isolated_sessions(args.work)
            report["counts"]["isolated_sessions_removed"] += count
            report["status"]["online_driver_removed_session"] = cleaned and count == 0
            require(cleaned and count == 0 and report["online"]["passed"] and not cancel_requested)
            report["counts"]["native_cache_entries_removed"] = clear_native_cache(args.work)
            report["status"]["native_cache_cleared_before_offline"] = True
            report["status"]["offline_executed"] = True
            report["offline"] = run_phase(args, package, tests, "offline")
            require(report["offline"]["passed"])
        report["passed"] = True
    except (Exception, KeyboardInterrupt):
        report["status"]["unexpected_error"] = True
        report["passed"] = False
        if trusted_work:
            try:
                write_bytes(args.work / "private/launcher-error.log", traceback.format_exc().encode())
            except Exception:
                pass
    finally:
        report["status"]["cancelled"] = cancel_requested
        if trusted_work:
            unchanged = verify_code(args, package, tests, report)
            cleaned, count = clean_isolated_sessions(args.work)
            report["counts"]["isolated_sessions_removed"] += count
            report["status"]["isolated_sessions_absent"] = cleaned
            report["passed"] = report["passed"] and unchanged and cleaned and not cancel_requested
            try:
                for phase in ("online", "offline"):
                    if (args.work / (phase + "-results.json")).exists():
                        report[phase] = phase_report(args.work, phase)
                if report["status"]["online_executed"]:
                    report["passed"] = report["passed"] and all(
                        report.get(phase, {}).get("passed") is True for phase in ("online", "offline"))
                write_json(args.work / "results.json", report)
            except Exception:
                report["passed"] = False
        print(json.dumps({"passed": report["passed"], "prepared": report["status"]["staged"],
                          "live_executed": report["status"]["online_executed"]}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
