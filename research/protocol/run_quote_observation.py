"""Run a separately approved, bounded quote observation in a private SSH directory.

This launcher has no preparation mode that opens credentials. Merely writing or
syntax-compiling this file grants no approval to execute the observation.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time
import zipfile


APPROVED_ARCHIVES = {
    "38a01da12c74271a631af57e9ac45c9e90b48472e390bd4aae5ded42e37f8383": 95,
    "bee9a0d95afd617e067d3b6b6e97b1c0c15ab6cc8508a87ea5fba35ba5bb8435": 96,
}
cancel_requested = False


class PrivateParser(argparse.ArgumentParser):
    def error(self, message):
        raise RuntimeError("Invalid private observer arguments")


def interrupted(_signal, _frame):
    global cancel_requested
    cancel_requested = True


def check_cancellation():
    if cancel_requested:
        raise InterruptedError("The private observation was canceled")


def regular(path):
    path = path.absolute()
    if any(item.is_symlink() for item in (path, *path.parents)) or not path.is_file():
        raise RuntimeError("A regular nonsymlink input is required")
    return path


def main():
    parser = PrivateParser(description=__doc__)
    for name in ("runtime", "source", "source-manifest", "session-file", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--range-selection-file", type=Path)
    parser.add_argument("--verify-range-construction", action="store_true")
    parser.add_argument("--approved-readonly-quote-observation", action="store_true", required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Use ssh test-env only")
    if not args.approved_readonly_quote_observation:
        raise RuntimeError("Separate user approval for read-only quote observation is required")
    if args.range_selection_file and args.verify_range_construction:
        raise RuntimeError("Select one bounded observation mode")
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    os.umask(0o077)
    output = args.output.absolute()
    if output.resolve() != output or not output.is_relative_to(Path("/tmp")) or output == Path("/tmp") or output.exists():
        raise RuntimeError("Use a new private directory below /tmp")
    session_file = regular(args.session_file)
    metadata = session_file.stat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077 or not (1 <= metadata.st_size <= 131072):
        raise RuntimeError("The session input must be private and owned by the current SSH user")
    runtime = args.runtime.resolve()
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the recorded official KOReader version")
    manifest_path = regular(args.source_manifest)
    manifest = json.loads(manifest_path.read_text())
    expected_files = APPROVED_ARCHIVES.get(manifest["sha256"])
    if expected_files is None or Path(manifest["archive"]).name != manifest["archive"]:
        raise RuntimeError("Use the reviewed preview archive")
    archive_path = regular(manifest_path.with_name(manifest["archive"]))
    archive_bytes = archive_path.read_bytes()
    if hashlib.sha256(archive_bytes).hexdigest() != manifest["sha256"]:
        raise RuntimeError("The preview archive identity differs")
    source = args.source.resolve()
    entries = manifest["files"]
    if len(entries) != expected_files or len({item["path"] for item in entries}) != len(entries):
        raise RuntimeError("Use the reviewed packaged source")
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        expected = {"bilicomics.koplugin/" + item["path"] for item in entries}
        if len(archive.namelist()) != len(expected) or set(archive.namelist()) != expected:
            raise RuntimeError("The source manifest does not match the reviewed archive")
        for entry in entries:
            data = archive.read("bilicomics.koplugin/" + entry["path"])
            if hashlib.sha256(data).hexdigest() != entry["sha256"] or len(data) != entry["bytes"]:
                raise RuntimeError("The source manifest changed a reviewed member")
    output.mkdir(mode=0o700)
    snapshot = output / "source"
    snapshot.mkdir(mode=0o700)
    source_sha256 = {}
    for entry in entries:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or "\\" in entry["path"]:
            raise RuntimeError("The source manifest contains an invalid path")
        original = regular(source / relative)
        if not original.resolve().is_relative_to(source) or (original.stat().st_dev, original.stat().st_ino) == (metadata.st_dev, metadata.st_ino):
            raise RuntimeError("The source manifest must not include the private input")
        data = original.read_bytes()
        value = hashlib.sha256(data).hexdigest()
        if value != entry["sha256"] or len(data) != entry["bytes"]:
            raise RuntimeError("The source differs from its packaged manifest")
        target = snapshot / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(data)
        source_sha256[entry["path"]] = value
    probe_name = "quote-ranges-readonly.lua" if args.range_selection_file else "quote-readonly.lua"
    probe = output / probe_name
    shutil.copyfile(regular(Path(__file__).with_name(probe_name)), probe)
    selection = None
    if args.range_selection_file:
        original_selection = regular(args.range_selection_file)
        info = original_selection.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077 or not (1 <= info.st_size <= 65536):
            raise RuntimeError("The range selection must be a private bounded file")
        selection = output / "range-selection-private.json"
        shutil.copyfile(original_selection, selection)
        selection.chmod(0o600)
    private_session = output / "session-input-private.txt"
    env = {"PATH": "/usr/bin:/bin", "HOME": str(output), "LANG": "C.UTF-8", "TZ": "UTC", "KO_MULTIUSER": "1",
           "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
           "LUA_CPATH": "./?.so;./libs/?.so"}
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = output / ("xdg-" + kind.lower())
        directory.mkdir(mode=0o700)
        env["XDG_" + kind + "_HOME"] = str(directory)
    command = [str(regular(runtime / "luajit")), str(probe), str(snapshot), str(private_session), str(output),
               "approved-readonly-quote-observation"]
    if selection:
        command.append(str(selection))
    elif args.verify_range_construction:
        command.append("build-ordinal-proofs")
    timed_out, process = False, None
    try:
        # Copy credentials only after all source and scope preconditions have passed.
        check_cancellation()
        shutil.copyfile(session_file, private_session)
        private_session.chmod(0o600)
        with (output / "process-private.log").open("wb") as log:
            check_cancellation()
            # Signal handlers only set a flag, so a child cannot lose its handle during Popen.
            process = subprocess.Popen(command, cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 480
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
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=15)
        raise
    finally:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        private_session.unlink(missing_ok=True)
    result = {"source_sha256": source_sha256, "probe_sha256": hashlib.sha256(probe.read_bytes()).hexdigest(),
              "mode": "range_followup" if selection else "initial",
              "returncode": returncode, "timed_out": timed_out, "credential_copy_removed": not private_session.exists(),
              "user_input_modified": False, "purchase_submitted": False,
              "scope": "Bounded authenticated quote observation; raw responses remain private; no purchase acceptance claim"}
    (output / "launcher-public.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"returncode": returncode, "timed_out": timed_out, "credential_copy_removed": result["credential_copy_removed"]}))
    return 0 if returncode == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        # Do not echo session paths, raw response bodies or subprocess logs.
        print("The private quote observer could not complete.", file=sys.stderr)
        raise SystemExit(1)
