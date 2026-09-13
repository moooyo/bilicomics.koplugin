"""Inspect or explicitly clean one fixed remote live-reading workspace.

Default invocation performs metadata and terminal-record checks only. Never run
--execute before the operator confirms that all live work has finished. No
credential, image, catalog, context, wire or raw-log content is opened.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys


ROOT = Path("/tmp/bilicomics-live-chapter-8g1JFqtw")
KEEP_ROOTS = {"source", "source-final", "package", "package-final", "cover-url-check"}
CODE_SUFFIXES = {".py", ".lua", ".sh", ".c", ".h", ".so", ".wasm", ".bc"}
CAPTURE_ROOTS = {"selection", "header-confirmation", "page4-fixed"}
RUN_ROOTS = {"run1", "run2", "run3"}
CAPTURE_KEEP = {"authenticated-readonly-result.json", "results.json", "result.json", "index-shape.json"}
CAPTURE_REMOVE_DIRS = {"assets", "images", "captures", "wires", "contexts", "private", "logs"}
PRIVATE_REMOVE_DIRS = {"data", "home", "cache-online", "cache-offline", "assets", "images", "captures", "wires", "contexts", "logs"}
PRIVATE_REMOVE_FILES = {"offline-state.json", "online-unpublishable.json", "offline-unpublishable.json",
                        "online.log", "offline.log", "syntax.log", "launcher-error.log", "stdout.log", "stderr.log"}
PRIVATE_KEEP = {"staging.json", "guard.sha256", "execution-started", "allow-images", "online-stop", "offline-stop",
                "progress.json", "opening-observation.json", "submission-observation.json", "index-observation-failed.json",
                "index-shape.json", "first-image-blocked.json", "online-children.jsonl", "offline-children.jsonl"}
MAX_JSON = 8 * 1024 * 1024
MAX_PROC_METADATA = 16 * 1024 * 1024
FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def require(value):
    if not value:
        raise RuntimeError("Cleanup precondition failed")


def identity(info):
    return info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)


def fingerprint(info):
    return identity(info) + (info.st_size, info.st_mtime_ns, info.st_mode, info.st_uid)


@contextmanager
def directory_at(root_fd, relative=""):
    opened = []
    current = root_fd
    try:
        require(not relative.startswith("/") and ".." not in Path(relative).parts)
        for component in Path(relative).parts:
            current = os.open(component, FLAGS, dir_fd=current)
            opened.append(current)
        yield current
    finally:
        for descriptor in reversed(opened):
            os.close(descriptor)


def info_at(root_fd, relative):
    path = Path(relative)
    with directory_at(root_fd, path.parent.as_posix() if path.parent != Path(".") else "") as parent:
        return os.stat(path.name, dir_fd=parent, follow_symlinks=False)


def safe_json(root_fd, relative, json_lines=False):
    """Only call for the launcher's known sanitized reports or PID records."""
    path = Path(relative)
    with directory_at(root_fd, path.parent.as_posix()) as parent:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_JSON)
        with os.fdopen(os.dup(descriptor), "rb") as handle:
            value = handle.read(MAX_JSON + 1)
        require(len(value) <= MAX_JSON)
        if not json_lines:
            return json.loads(value)
        require(not value or value.endswith(b"\n"))
        return [json.loads(line) for line in value.splitlines()]
    finally:
        os.close(descriptor)


class Plan:
    def __init__(self, root_fd):
        self.root_fd = root_fd
        self.device = os.fstat(root_fd).st_dev
        self.targets = []
        self.removable = {}
        self.preserved = {}
        self.unknown = 0
        self.categories = {"credentials": 0, "capture_data": 0, "profiles": 0, "private_logs_and_state": 0}

    def snapshot(self, relative, deleting, output):
        info = info_at(self.root_fd, relative)
        output[relative] = fingerprint(info)
        if deleting:
            require(not stat.S_ISLNK(info.st_mode) and info.st_dev == self.device and info.st_uid == os.geteuid())
            require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))
        if stat.S_ISDIR(info.st_mode):
            with directory_at(self.root_fd, relative) as directory:
                require(identity(os.fstat(directory)) == identity(info))
                children = sorted(os.listdir(directory))
            for child in children:
                self.snapshot(relative + "/" + child, deleting, output)

    def children(self, relative=""):
        with directory_at(self.root_fd, relative) as directory:
            return [(name, os.stat(name, dir_fd=directory, follow_symlinks=False))
                    for name in sorted(os.listdir(directory))]

    def keep(self, relative):
        self.snapshot(relative, False, self.preserved)

    def remove(self, relative, category):
        require(relative and not relative.startswith("/") and ".." not in Path(relative).parts)
        require(Path(relative).parts[0] not in KEEP_ROOTS)
        self.snapshot(relative, True, self.removable)
        self.targets.append(relative)
        self.categories[category] += 1

    def capture(self, relative):
        for name, info in self.children(relative):
            item = relative + "/" + name
            if stat.S_ISLNK(info.st_mode):
                self.unknown += 1
            elif stat.S_ISDIR(info.st_mode):
                if name in CAPTURE_REMOVE_DIRS:
                    self.remove(item, "capture_data")
                elif name in ("source", "code"):
                    self.keep(item)
                else:
                    self.unknown += 1
            elif name in CAPTURE_KEEP or Path(name).suffix in CODE_SUFFIXES:
                self.keep(item)
            elif (re.search(r"(?:^|[-_.])private(?:[-_.]|$)", name)
                  or name in ("stdout.log", "stderr.log")
                  or Path(name).suffix.lower() in (".bin", ".part", ".jpg", ".jpeg", ".png", ".webp", ".avif")):
                self.remove(item, "capture_data")
            else:
                self.unknown += 1

    def private(self, relative):
        for name, info in self.children(relative):
            item = relative + "/" + name
            if stat.S_ISLNK(info.st_mode):
                self.unknown += 1
            elif stat.S_ISDIR(info.st_mode):
                if name in PRIVATE_REMOVE_DIRS:
                    self.remove(item, "profiles")
                elif name == "bytecode":
                    self.keep(item)
                else:
                    self.unknown += 1
            elif name in PRIVATE_REMOVE_FILES:
                self.remove(item, "private_logs_and_state")
            elif name in PRIVATE_KEEP or re.fullmatch(r"(?:token-approved-\d+-\d+|guard-failure-\d+)\.json", name):
                self.keep(item)
            else:
                self.unknown += 1

    def run(self, relative):
        for name, info in self.children(relative):
            item = relative + "/" + name
            if stat.S_ISLNK(info.st_mode):
                self.unknown += 1
            elif name == "private" and stat.S_ISDIR(info.st_mode):
                self.private(item)
            elif (name in ("bundle", "spec") and stat.S_ISDIR(info.st_mode)
                  or name in ("results.json", "online-results.json", "offline-results.json", "transport-count") and stat.S_ISREG(info.st_mode)
                  or re.fullmatch(r"transport-\d+\.jsonl", name) and stat.S_ISREG(info.st_mode)):
                self.keep(item)
            else:
                self.unknown += 1

    def build(self):
        for name, info in self.children():
            if stat.S_ISLNK(info.st_mode):
                self.unknown += 1
            elif name in KEEP_ROOTS and stat.S_ISDIR(info.st_mode):
                self.keep(name)
            elif name in CAPTURE_ROOTS or re.fullmatch(r"encrypted-[a-z0-9-]+", name):
                require(stat.S_ISDIR(info.st_mode))
                self.capture(name)
            elif name in RUN_ROOTS and stat.S_ISDIR(info.st_mode):
                self.run(name)
            elif name == "session.txt" and stat.S_ISREG(info.st_mode):
                self.remove(name, "credentials")
            elif stat.S_ISREG(info.st_mode) and (Path(name).suffix in CODE_SUFFIXES
                                    or name in ("live-reading-summary.json", "cleanup.lock")):
                self.keep(name)
            else:
                self.unknown += 1
        return self


def process_stat(pid):
    try:
        value = (Path("/proc") / str(pid) / "stat").read_text()
        fields = value[value.rfind(")") + 2:].split()
        return int(fields[19])
    except (FileNotFoundError, ProcessLookupError):
        return None


def terminal_records(root_fd):
    phases, records, live = 0, 0, 0
    runs = sorted(RUN_ROOTS)
    for run in runs:
        require(stat.S_ISDIR(info_at(root_fd, run).st_mode))
        report = safe_json(root_fd, run + "/results.json")
        for phase in ("online", "offline"):
            if report.get("status", {}).get(phase + "_executed") is not True:
                continue
            phases += 1
            result = report[phase]
            require(result["launcher"]["children_cleaned"] is True
                    and result["launcher"]["pid_records_valid"] is True
                    and result["checks"]["worker_lifetimes_closed"] is True)
            # A failed phase is acceptable when its lifetime cleanup is complete.
            # No record count equality is assumed: a fast child can exit before recording.
            path = run + "/private/" + phase + "-children.jsonl"
            try:
                info_at(root_fd, path)
            except FileNotFoundError:
                require(phase == "offline" and result.get("counts", {}).get("worker_starts") == 0)
                continue
            for record in safe_json(root_fd, path, True):
                require(isinstance(record, dict) and set(record).issubset({"pid", "pgid", "starttime", "sid"}))
                require(all(type(record.get(key)) is int and record[key] > 0 for key in ("pid", "pgid", "starttime")))
                records += 1
                if process_stat(record["pid"]) == record["starttime"]:
                    live += 1
    require(phases >= 4)  # The known run1/run2 failures and both run3 phases must remain documented.
    return {"executed_phases_checked": phases, "child_records_checked": records, "live_recorded_processes": live}


def references_root(value):
    value = value.removesuffix(" (deleted)")
    return value == str(ROOT) or value.startswith(str(ROOT) + "/")


def live_references():
    matches, unreadable = 0, 0
    for process in Path("/proc").iterdir():
        if not process.name.isdigit() or int(process.name) == os.getpid():
            continue
        found = False
        try:
            for name in ("cwd", "exe"):
                try:
                    found = found or references_root(os.readlink(process / name))
                except (FileNotFoundError, ProcessLookupError):
                    pass
            try:
                for entry in (process / "fd").iterdir():
                    try:
                        found = found or references_root(os.readlink(entry))
                    except (FileNotFoundError, ProcessLookupError):
                        pass
            except (FileNotFoundError, ProcessLookupError):
                pass
            try:
                with (process / "maps").open("rb") as handle:
                    maps = handle.read(MAX_PROC_METADATA + 1)
                require(len(maps) <= MAX_PROC_METADATA)
                for line in maps.decode(errors="replace").splitlines():
                    columns = line.split(None, 5)
                    if len(columns) == 6:
                        found = found or references_root(columns[5])
            except (FileNotFoundError, ProcessLookupError):
                pass
        except (PermissionError, OSError, RuntimeError):
            if process.exists():
                unreadable += 1
        matches += bool(found)
    return {"processes_referencing_workspace": matches, "unreadable_process_metadata": unreadable}


def no_nested_mounts():
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        field = line.split()[4]
        mount = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), field)
        require(not references_root(mount))


def remove_at(parent_fd, name, relative, expected, root_device, progress):
    info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    require(fingerprint(info) == expected[relative] and info.st_dev == root_device)
    if stat.S_ISREG(info.st_mode):
        os.unlink(name, dir_fd=parent_fd)
        progress["removed_files"] += 1
        progress["removed_bytes"] += info.st_size
        return 1, 0, info.st_size
    require(stat.S_ISDIR(info.st_mode))
    directory = os.open(name, FLAGS, dir_fd=parent_fd)
    files, directories, size = 0, 0, 0
    try:
        require(identity(os.fstat(directory)) == identity(info))
        children = os.listdir(directory)
        expected_children = {key[len(relative) + 1:].split("/", 1)[0] for key in expected if key.startswith(relative + "/")}
        require(set(children) == expected_children)
        for child in sorted(children):
            counts = remove_at(directory, child, relative + "/" + child, expected, root_device, progress)
            files, directories, size = files + counts[0], directories + counts[1], size + counts[2]
        # Directory mtimes change when this helper removes entries; recheck identity only.
        require(identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) == identity(info))
    finally:
        os.close(directory)
    os.rmdir(name, dir_fd=parent_fd)
    progress["removed_directories"] += 1
    return files, directories + 1, size


def remove_target(root_fd, relative, expected, progress):
    components = Path(relative).parts
    opened = []
    parent = root_fd
    try:
        for component in components[:-1]:
            parent = os.open(component, FLAGS, dir_fd=parent)
            opened.append(parent)
        return remove_at(parent, components[-1], relative, expected, os.fstat(root_fd).st_dev, progress)
    finally:
        for descriptor in reversed(opened):
            os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--all-live-work-finished", action="store_true")
    args = parser.parse_args()
    result = {"inspection_completed": False, "execution_requested": args.execute, "executed": False,
              "ready": False, "cleanup_success": False, "original_local_input_untouched": True}
    opened, lock = [], None
    try:
        require(sys.platform == "linux" and os.geteuid() == 0)
        require(not args.execute or args.all_live_work_finished)
        base = os.open("/", FLAGS); opened.append(base)
        temporary = os.open("tmp", FLAGS, dir_fd=base); opened.append(temporary)
        root_fd = os.open(ROOT.name, FLAGS, dir_fd=temporary); opened.append(root_fd)
        root_info = os.fstat(root_fd)
        require(root_info.st_uid == os.geteuid() and ROOT.resolve(strict=True) == ROOT)
        if args.execute:
            lock = os.open("cleanup.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=root_fd)
            require(stat.S_ISREG(os.fstat(lock).st_mode))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        no_nested_mounts()
        plan = Plan(root_fd).build()
        result.update(terminal_records(root_fd))
        result.update(live_references())
        result["categories"] = plan.categories
        result["planned_targets"] = len(plan.targets)
        result["planned_files"] = sum(stat.S_ISREG(item[2]) for item in plan.removable.values())
        result["planned_bytes"] = sum(item[3] for item in plan.removable.values() if stat.S_ISREG(item[2]))
        result["preserved_entries"] = len(plan.preserved)
        result["unknown_entries"] = plan.unknown
        result["inspection_completed"] = True
        result["ready"] = plan.unknown == 0 and result["live_recorded_processes"] == 0 \
            and result["processes_referencing_workspace"] == 0 and result["unreadable_process_metadata"] == 0
        if args.execute:
            require(result["ready"])
            require(identity(os.stat(ROOT.name, dir_fd=temporary, follow_symlinks=False)) == identity(root_info))
            repeated = Plan(root_fd).build()
            require(repeated.targets == plan.targets and repeated.removable == plan.removable
                    and repeated.preserved == plan.preserved and repeated.unknown == 0)
            latest = terminal_records(root_fd)
            current = live_references()
            require(latest["live_recorded_processes"] == 0 and not any(current.values()))
            no_nested_mounts()
            result.update(executed=True, removed_files=0, removed_directories=0, removed_bytes=0)
            for relative in plan.targets:
                remove_target(root_fd, relative, plan.removable, result)
            preserved = {}
            for relative in plan.preserved:
                preserved[relative] = fingerprint(info_at(root_fd, relative))
            require(preserved == plan.preserved)
            final = Plan(root_fd).build()
            require(not final.targets and final.unknown == 0)
            os.fsync(root_fd)
            result.update(cleanup_success=True, preserved_unchanged=True, sensitive_targets_remaining=0)
    except Exception:
        result["blocked_or_failed"] = True
        result["partial_cleanup"] = result.get("removed_files", 0) + result.get("removed_directories", 0) > 0
    finally:
        if lock is not None:
            os.close(lock)
        for descriptor in reversed(opened):
            os.close(descriptor)
    print(json.dumps(result, sort_keys=True))
    return int(not (result["cleanup_success"] if args.execute else result["inspection_completed"]))


if __name__ == "__main__":
    raise SystemExit(main())
