"""Prepare and supervise bounded native authentication acceptance on test-env.

Subprocess output is discarded. Public evidence contains only fixed status codes,
booleans, counts, numeric service codes and code hashes. Credentials and the QR
image remain in the private work directory and are never included in reports.
"""

import argparse
import ctypes
import fcntl
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


PRODUCTION_ROOTS = ("bilicomics", "patches", "l10n", "main.lua", "_meta.lua")
RUNTIME_FILES = ("luajit", "git-rev", "frontend/ui/widget/qrwidget.lua")
FILES = ("live_authentication.lua", "run_live_authentication.py", "live_acceptance_scope.lua")
MAX_JSON = 2 * 1024 * 1024
cancelled = False
GATED_EXEC = (
    "import json,os,sys; descriptor=int(sys.argv[1]); "
    "token=os.read(descriptor,1); os.close(descriptor); argv=json.loads(sys.argv[2]); "
    "os.execvpe(argv[0],argv,os.environ) if token==b'1' else os._exit(124)"
)


def require(value):
    if not value:
        raise RuntimeError("Authentication acceptance precondition failed")


class PrivateParser(argparse.ArgumentParser):
    def error(self, message):
        raise RuntimeError("Invalid authentication acceptance arguments")


def private_dir(path, fresh=False):
    require(not path.is_symlink())
    path.mkdir(mode=0o700, parents=True, exist_ok=not fresh)
    require(path.is_dir() and path.stat().st_uid == os.geteuid())
    path.chmod(0o700)


def write_bytes(path, content):
    require(not path.is_symlink())
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, path)


def write_json(path, value):
    write_bytes(path, (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode())


def read_json(path):
    require(not path.is_symlink())
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_size <= MAX_JSON)
    return json.loads(path.read_bytes(), parse_constant=lambda _: require(False))


def digest(path):
    require(not path.is_symlink() and path.is_file())
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(source):
    result = {}
    for name in PRODUCTION_ROOTS:
        root = source / name
        require(root.exists() and not root.is_symlink())
        for path in sorted(root.rglob("*")) if root.is_dir() else [root]:
            require(not path.is_symlink())
            if path.is_file():
                relative = path.relative_to(source)
                require(not any(part.lower() in ("accounts", "session.dat") for part in relative.parts))
                result[relative.as_posix()] = digest(path)
    return result


def identity(pid):
    try:
        text = (Path("/proc") / str(pid) / "stat").read_bytes()
        values = text[text.rfind(b")") + 2:].split()
        return {"pid": pid, "state": values[0].decode("ascii"), "ppid": int(values[1]),
                "sid": int(values[3]), "starttime": int(values[19])}
    except (FileNotFoundError, ProcessLookupError):
        return None


def matches(first, second):
    return first is not None and second is not None and all(
        first[key] == second[key] for key in ("pid", "sid", "starttime"))


def alive(record):
    current = identity(record["pid"])
    return matches(record, current) and current["state"] not in ("Z", "X")


def process_list():
    return [value for path in Path("/proc").iterdir() if path.name.isdigit()
            and (value := identity(int(path.name))) is not None]


class NativeProcess:
    """Keep pidfds for the native session and any children adopted by this subreaper."""

    def __init__(self, process):
        self.process = process
        self.root = identity(process.pid)
        require(self.root is not None and self.root["sid"] == process.pid)
        self.held = {}
        self.refresh()

    def refresh(self):
        for value in process_list():
            owned = value["sid"] == self.root["sid"] or value["ppid"] == os.getpid()
            if not owned or value["pid"] == os.getpid() or value["starttime"] < self.root["starttime"]:
                continue
            key = (value["pid"], value["starttime"])
            if key in self.held:
                continue
            try:
                descriptor = os.pidfd_open(value["pid"])
            except ProcessLookupError:
                continue
            if not matches(value, identity(value["pid"])):
                os.close(descriptor)
                continue
            self.held[key] = (value, descriptor)

    def running(self):
        self.refresh()
        return any(alive(value) for value, _descriptor in self.held.values())

    def send(self, signum):
        self.refresh()
        for value, descriptor in self.held.values():
            if alive(value):
                try:
                    signal.pidfd_send_signal(descriptor, signum)
                except ProcessLookupError:
                    pass

    def clean(self):
        for signum, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, 3)):
            if not self.running():
                break
            self.send(signum)
            deadline = time.monotonic() + grace
            while self.running() and time.monotonic() < deadline:
                time.sleep(0.05)
        self.process.poll()
        clean = not self.running()
        for value, descriptor in self.held.values():
            if value["pid"] != self.process.pid:
                try:
                    os.waitpid(value["pid"], os.WNOHANG)
                except ChildProcessError:
                    pass
            os.close(descriptor)
        return clean


def config(work):
    require(work.is_dir() and not work.is_symlink() and work.stat().st_uid == os.geteuid()
            and stat.S_IMODE(work.stat().st_mode) == 0o700)
    return read_json(work / "private/config.json")


def verify(work, saved):
    require(manifest(work / "bundle/bilicomics.koplugin") == saved["hashes"]["production"])
    require(all(digest(work / "spec/integration" / name) == value
                for name, value in saved["hashes"]["harness"].items()))
    runtime = Path(saved["runtime"])
    require(all(digest(runtime / name) == value for name, value in saved["hashes"]["runtime"].items()))


def prepare(args):
    source, runtime, work = args.source.resolve(strict=True), args.runtime.resolve(strict=True), args.work.resolve()
    require(source.is_dir() and runtime.is_dir())
    require(not any(a.is_relative_to(b) for a, b in ((work, source), (source, work), (work, runtime), (runtime, work))))
    require((runtime / "git-rev").read_text().strip() == "v2026.07.1")
    private_dir(work, fresh=True)
    for path in (work / "private", work / "private/data", work / "spec/integration",
                 work / "private/xdg_config_home/koreader"):
        private_dir(path)
    hashes = {"production": manifest(source), "harness": {},
              "runtime": {name: digest(runtime / name) for name in RUNTIME_FILES}}
    bundle = work / "bundle/bilicomics.koplugin"
    for name in hashes["production"]:
        target = bundle / name
        private_dir(target.parent)
        shutil.copyfile(source / name, target)
        target.chmod(0o600)
    for name in FILES:
        original = Path(__file__).resolve().with_name(name)
        hashes["harness"][name] = digest(original)
        write_bytes(work / "spec/integration" / name, original.read_bytes())
    saved = {"runtime": str(runtime), "hashes": hashes, "schema": 1}
    write_json(work / "private/config.json", saved)
    write_bytes(work / "private/xdg_config_home/koreader/settings.reader.lua",
                b"return {quickstart_shown_version=9999999999,color_rendering=false}\n")
    compile((work / "spec/integration/run_live_authentication.py").read_bytes(), "run_live_authentication.py", "exec")
    count = 0
    for path in sorted(bundle.rglob("*.lua")) + [work / "spec/integration" / name for name in FILES if name.endswith(".lua")]:
        completed = subprocess.run([str(runtime / "luajit"), "-b", str(path), str(work / "private/syntax.bc")],
                                   cwd=runtime, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=20, check=False)
        require(completed.returncode == 0)
        count += 1
    (work / "private/syntax.bc").unlink()
    verify(work, saved)
    require(manifest(source) == hashes["production"])
    report = {"schema": 1, "code": 1, "passed": True, "live_executed": False,
              "lua_files_compiled": count, "hashes": hashes}
    write_json(work / "preparation.json", report)
    return {"code": 1, "prepared": True, "live_executed": False}


def supervisor_record(work):
    path = work / "private/supervisor.json"
    return read_json(path) if path.exists() else None


def status(work):
    config(work)
    record = supervisor_record(work)
    running = record is not None and alive(record)
    latest_path = work / "private/latest.json"
    latest = read_json(latest_path) if latest_path.exists() else {}
    phase = latest.get("phase")
    require(phase is None or phase in ("login", "restart", "rehearse"))
    driver_path = work / "private" / f"{phase}-driver.json"
    driver = read_json(driver_path) if phase and driver_path.exists() else None
    output = {"code": 10 if running else 0, "running": running}
    if driver:
        output["driver"] = sanitize_driver(driver)
        output["code"] = driver["code"]
    result_path = work / f"{phase}-results.json"
    if phase and result_path.exists():
        result = read_json(result_path)
        output["result"] = {key: value for key, value in result.items() if key not in ("hashes", "driver")}
    png = work / "private/qr.png"
    if running and driver and driver["checks"].get("qr_ready") is True and png.is_file() and not png.is_symlink():
        output["qr_path"] = str(png)
    return output


def sanitize_driver(value):
    require(isinstance(value, dict))
    result = {}
    for key in ("schema", "code", "passed", "running", "deferred", "service_code", "http_code"):
        if key in value:
            require(type(value[key]) in (int, bool))
            result[key] = value[key]
    for group in ("checks", "counts", "network"):
        result[group] = value.get(group, {})
    def valid(tree):
        return isinstance(tree, dict) and all(isinstance(key, str) and key.replace("_", "").isalnum()
            and (type(item) in (int, bool) or isinstance(item, dict) and valid(item))
            for key, item in tree.items())
    require(all(valid(result[group]) for group in ("checks", "counts", "network")))
    return result


def launch(args, phase):
    work = args.work.resolve(strict=True)
    saved = config(work)
    verify(work, saved)
    record = supervisor_record(work)
    require(record is None or not alive(record))
    require(phase == "rehearse" or args.execute_live_auth)
    require(20 <= args.timeout <= 300)
    private = work / "private"
    if phase == "restart":
        previous = read_json(work / "login-results.json")
        require(previous.get("passed") is True)
        require(not (work / "restart-results.json").exists())
    else:
        require(not any((private / f"{previous}-started").exists() for previous in ("login", "rehearse")))
        require(not (private / "xdg_config_home/koreader/bilicomics").exists())
    require(not (private / f"{phase}-started").exists())
    for path in (private / "stop", private / "qr.png"):
        if path.exists():
            require(not path.is_symlink() and path.is_file())
            path.unlink()
    write_json(private / "latest.json", {"phase": phase})
    command = [sys.executable, str(work / "spec/integration/run_live_authentication.py"), "_serve",
               "--work", str(work), "--phase", phase, "--timeout", str(args.timeout)]
    if args.execute_live_auth:
        command.append("--execute-live-auth")
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)
    record = identity(child.pid)
    require(record is not None)
    write_json(private / "supervisor.json", record)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if (private / f"{phase}-started").exists() or child.poll() is not None:
            break
        time.sleep(0.1)
    return status(work)


def mark_cancelled(_signum, _frame):
    global cancelled
    cancelled = True


def serve(args):
    work = args.work.resolve(strict=True)
    saved = config(work)
    verify(work, saved)
    phase, private = args.phase, work / "private"
    require(phase == "rehearse" or args.execute_live_auth)
    lock_fd = os.open(private / "supervisor.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    require(ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0)
    signal.signal(signal.SIGTERM, mark_cancelled)
    signal.signal(signal.SIGINT, mark_cancelled)
    environment = os.environ.copy()
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = private / ("data" if key == "XDG_DATA_HOME" else key.lower())
        private_dir(path)
        environment[key] = str(path)
    environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800",
                        "SDL_AUDIODRIVER": "dummy", "BILI_AUTH_DRIVER": "1",
                        "KO_HOME": str(private / "xdg_config_home/koreader"),
                        "BILI_LIVE_AUTHORIZED": "1" if phase != "rehearse" else "0"})
    runtime = Path(saved["runtime"])
    command = ["xvfb-run", "-a", str(runtime / "luajit"), str(work / "spec/integration/live_authentication.lua"),
               str(work / "bundle/bilicomics.koplugin"), str(work), phase]
    if phase == "rehearse":
        command = ["unshare", "--net"] + command
    child = scope = None
    gate_read = gate_write = None
    within_deadline, cleaned = True, False
    error = False
    try:
        write_bytes(private / f"{phase}-started", b"started\n")
        gate_read, gate_write = os.pipe()
        gated = [sys.executable, "-c", GATED_EXEC, str(gate_read), json.dumps(command)]
        child = subprocess.Popen(gated, cwd=runtime, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 close_fds=True, pass_fds=(gate_read,), start_new_session=True)
        os.close(gate_read)
        gate_read = None
        scope = NativeProcess(child)
        os.write(gate_write, b"1")
        os.close(gate_write)
        gate_write = None
        deadline = time.monotonic() + args.timeout
        while child.poll() is None:
            scope.refresh()
            if cancelled or (private / "stop").exists() or time.monotonic() >= deadline:
                within_deadline = time.monotonic() < deadline
                write_bytes(private / "stop", b"stop\n")
                grace = time.monotonic() + 5
                while child.poll() is None and time.monotonic() < grace:
                    scope.refresh()
                    time.sleep(0.1)
                break
            time.sleep(0.1)
    except Exception:
        error = True
    finally:
        for descriptor in (gate_read, gate_write):
            if descriptor is not None:
                os.close(descriptor)
        if scope:
            cleaned = scope.clean()
        elif child:
            child.kill()
            child.wait(timeout=5)
        png = private / "qr.png"
        if png.exists() and not png.is_symlink():
            png.unlink()
        driver_path = private / f"{phase}-driver.json"
        driver = sanitize_driver(read_json(driver_path)) if driver_path.exists() else {}
        unchanged = True
        try:
            verify(work, saved)
        except Exception:
            unchanged = False
        passed = (driver.get("passed") is True and child is not None and child.returncode == 0
                  and cleaned and within_deadline and not cancelled and not error and unchanged)
        report = {"schema": 1, "code": driver.get("code", 49), "passed": passed,
                  "deferred": driver.get("deferred") is True,
                  "live_executed": phase != "rehearse", "children_cleaned": cleaned,
                  "within_deadline": within_deadline, "cancelled": cancelled or (private / "stop").exists(),
                  "sources_unchanged": unchanged, "qr_removed": not png.exists(),
                  "driver": driver, "hashes": saved["hashes"]}
        write_json(work / f"{phase}-results.json", report)
        os.close(lock_fd)
    return {"code": report["code"], "passed": report["passed"]}


def stop(work):
    config(work)
    write_bytes(work / "private/stop", b"stop\n")
    record = supervisor_record(work)
    deadline = time.monotonic() + 12
    while record and alive(record) and time.monotonic() < deadline:
        time.sleep(0.1)
    if record and alive(record):
        descriptor = os.pidfd_open(record["pid"])
        try:
            if matches(record, identity(record["pid"])):
                signal.pidfd_send_signal(descriptor, signal.SIGTERM)
        finally:
            os.close(descriptor)
    return status(work)


def main():
    os.umask(0o077)
    parser = PrivateParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "start", "status", "stop", "restart", "rehearse", "_serve"))
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--phase", choices=("login", "restart", "rehearse"))
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--execute-live-auth", action="store_true")
    try:
        require(sys.platform == "linux" and hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"))
        args = parser.parse_args()
        if args.command == "prepare":
            require(args.source is not None and args.runtime is not None)
            output = prepare(args)
        elif args.command == "status":
            output = status(args.work.resolve(strict=True))
        elif args.command == "stop":
            output = stop(args.work.resolve(strict=True))
        elif args.command == "_serve":
            require(args.phase is not None and 20 <= args.timeout <= 300)
            output = serve(args)
        else:
            output = launch(args, {"start": "login", "restart": "restart", "rehearse": "rehearse"}[args.command])
        print(json.dumps(output, sort_keys=True, allow_nan=False))
        return 0
    except Exception:
        print(json.dumps({"code": 49, "passed": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
