"""Launch the real KOReader UI in a private, read-only acceptance profile."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time
import zipfile


def private_directory(path: Path) -> Path:
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.getuid():
        raise RuntimeError("The acceptance directory must belong to the current user")
    path.chmod(0o700)
    return path


def process_record(pid: int) -> dict | None:
    try:
        directory = Path(f"/proc/{pid}")
        fields = (directory / "stat").read_text().rsplit(")", 1)[1].split()
        return {"pid": pid, "pgid": int(fields[2]), "start_time": fields[19],
                "uid": directory.stat().st_uid, "state": fields[0]}
    except (OSError, ValueError, IndexError):
        return None


def owned_process(saved: dict, profile: Path) -> dict | None:
    current = process_record(int(saved.get("pid", 0)))
    if not current or current["state"] == "Z" or current["uid"] != os.getuid():
        return None
    if any(current[key] != saved.get(key) for key in ("pid", "pgid", "start_time", "uid")):
        return None
    if current["pgid"] != current["pid"] or saved.get("profile") != str(profile):
        return None
    try:
        marker = f"BILICOMICS_ACCEPTANCE_ID={saved['token']}".encode()
        if marker not in Path(f"/proc/{current['pid']}/environ").read_bytes().split(b"\0"):
            return None
    except (OSError, KeyError):
        return None
    return current


def stage_plugin(source: Path, profile: Path) -> Path:
    if source.is_file() and zipfile.is_zipfile(source):
        identity = hashlib.sha256(source.read_bytes()).hexdigest()[:20]
        root = private_directory(profile / "staged" / identity)
        target = root / "bilicomics.koplugin"
        if not (target / "main.lua").exists():
            with zipfile.ZipFile(source) as archive:
                for item in archive.infolist():
                    parts = Path(item.filename).parts
                    if not parts or parts[0] != "bilicomics.koplugin" or ".." in parts or "\\" in item.filename:
                        raise RuntimeError("The archive does not contain one safe plugin directory")
                    if stat.S_ISLNK(item.external_attr >> 16):
                        raise RuntimeError("Plugin archive links are not accepted")
                archive.extractall(root)
    else:
        if not (source / "main.lua").is_file():
            raise RuntimeError("Supply a packaged plugin ZIP or extracted plugin directory")
        root = private_directory(profile / "staged" / secrets.token_hex(8))
        target = root / "bilicomics.koplugin"
        target.mkdir(mode=0o700)
        for name in ("main.lua", "_meta.lua"):
            shutil.copyfile(source / name, target / name)
        for name in ("bilicomics", "l10n", "patches"):
            shutil.copytree(source / name, target / name)
    if not (target / "_meta.lua").is_file():
        raise RuntimeError("The staged plugin is incomplete")
    return target


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--plugin", type=Path)
    parser.add_argument("--profile", type=Path, default=Path.home() / ".local/share/bilicomics-acceptance/profile")
    parser.add_argument("--width", type=int, default=720)
    parser.add_argument("--height", type=int, default=960)
    parser.add_argument("--video-driver", choices=("x11", "dummy"), default="x11",
                        help="Keep x11 for the visible app; dummy is for disposable headless checks")
    parser.add_argument("--capture-account", action="store_true", help="Capture the anonymous native account screen for acceptance")
    parser.add_argument("--autoclose", type=int, default=0, help="Exit through the native menu after 1 to 30 seconds")
    parser.add_argument("--import-session-file", type=Path, help="Consume this candidate profile's one-time fresh authentication input")
    parser.add_argument("--refresh-favorites-once", action="store_true", help="Observe one production favorites refresh after native startup")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--status", action="store_true")
    action.add_argument("--stop", action="store_true")
    args = parser.parse_args()
    if sys.platform != "linux" or os.getuid() == 0:
        raise RuntimeError("Run inside WSL as the ordinary desktop user, not root")
    profile = args.profile.expanduser().resolve()
    if not profile.is_relative_to(Path.home().resolve()) or profile == Path.home().resolve():
        raise RuntimeError("Use a dedicated acceptance profile below the current user's Linux home")
    os.umask(0o077)
    private_directory(profile)
    state_path = profile / "launcher.json"
    saved = json.loads(state_path.read_text()) if state_path.is_file() else {}
    active = owned_process(saved, profile) if saved else None
    if args.status or args.stop:
        if args.stop and active:
            os.killpg(active["pgid"], signal.SIGTERM)
            deadline = time.monotonic() + 5
            while owned_process(saved, profile) and time.monotonic() < deadline:
                time.sleep(0.1)
            if owned_process(saved, profile):
                os.killpg(active["pgid"], signal.SIGKILL)
            active = owned_process(saved, profile)
        print(json.dumps({"running": active is not None, "pid": active and active["pid"], "profile": str(profile)}))
        return 0
    if active:
        print(json.dumps({"running": True, "pid": active["pid"], "profile": str(profile)}))
        return 0
    if not args.runtime or not args.plugin:
        parser.error("--runtime and --plugin are required to launch")
    runtime, source = args.runtime.resolve(), args.plugin.resolve()
    if not (runtime / "luajit").is_file() or not (runtime / "reader.lua").is_file():
        raise RuntimeError("The official KOReader runtime was not found")
    if not (480 <= args.width <= 900 and 640 <= args.height <= 1200):
        raise RuntimeError("Use a visible desktop window between 480x640 and 900x1200")
    if args.autoclose < 0 or args.autoclose > 30:
        raise RuntimeError("Use an acceptance auto-close delay from 0 through 30 seconds")
    import_file = None
    if args.import_session_file:
        import_file = args.import_session_file.expanduser()
        expected = profile.parent / "fresh-auth-input.json"
        details = import_file.lstat()
        if import_file.is_symlink() or import_file.resolve() != expected or details.st_uid != os.getuid() \
                or not stat.S_ISREG(details.st_mode) or stat.S_IMODE(details.st_mode) != 0o600 or details.st_nlink != 1 \
                or not 0 < details.st_size <= 131072:
            raise RuntimeError("Use this candidate's private, singly linked fresh-auth-input.json with mode 0600")
    plugin = stage_plugin(source, profile)
    home = private_directory(profile / "data")
    patches = private_directory(home / "patches")
    support = private_directory(profile / "support")
    browse = private_directory(profile / "browse")
    local_source = Path(__file__).resolve().parent
    shutil.copyfile(local_source / "readonly_guard.lua", support / "readonly_guard.lua")
    shutil.copyfile(local_source / "startup.lua", patches / "2-00-local-acceptance.lua")
    if args.refresh_favorites_once:
        shutil.copyfile(local_source / "renewable_online.lua", support / "renewable_online.lua")
    settings = home / "settings.reader.lua"
    if not settings.exists():
        disabled = ",".join(f"[{json.dumps(path.name[:-9])}]=true" for path in (runtime / "plugins").glob("*.koplugin"))
        settings.write_text("return {start_with='filemanager',language='zh_CN',quickstart_shown_version=9999999999,"
            "color_rendering=false,"
            f"plugins_disabled={{{disabled}}},extra_plugin_paths={{{json.dumps(str(plugin.parent))}}},"
            f"home_dir={json.dumps(str(browse))}}}\n")
    token = secrets.token_hex(24)
    environment = os.environ.copy()
    environment.update(KO_HOME=str(home), DISPLAY=environment.get("DISPLAY") or ":0", SDL_VIDEODRIVER=args.video_driver,
        SDL_AUDIODRIVER="dummy", EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
        BILICOMICS_ACCEPTANCE_ID=token, BILICOMICS_ACCEPTANCE_PROFILE=str(profile),
        BILICOMICS_ACCEPTANCE_PLUGIN=str(plugin),
        BILICOMICS_ACCEPTANCE_CAPTURE_ACCOUNT="1" if args.capture_account else "0",
        BILICOMICS_ACCEPTANCE_AUTOCLOSE=str(args.autoclose),
        BILICOMICS_ACCEPTANCE_IMPORT_FILE=str(import_file) if import_file else "",
        BILICOMICS_ACCEPTANCE_REFRESH_FAVORITES="1" if args.refresh_favorites_once else "0")
    if args.video_driver == "dummy":
        environment["SDL_RENDER_DRIVER"] = "software"
    for key in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
        environment.pop(key, None)
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        environment[key] = str(private_directory(profile / key.lower()))
    log_path = profile / "koreader-private.log"
    for name in ("native-ui-ready.json", "native-ui-before-import.png", "native-account-before-import.png", "native-ui-closed.json"):
        previous = profile / name
        if previous.is_symlink():
            raise RuntimeError("The previous acceptance marker must not be a symbolic link")
        previous.unlink(missing_ok=True)
    if args.refresh_favorites_once:
        for name in ("renewable-online-events.jsonl", "renewable-online-native.json"):
            previous = profile / name
            if previous.is_symlink():
                raise RuntimeError("The acceptance observation must not be a symbolic link")
            previous.unlink(missing_ok=True)
    with log_path.open("ab", buffering=0) as log:
        process = subprocess.Popen([str(runtime / "luajit"), "reader.lua"], cwd=runtime, env=environment,
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    record = process_record(process.pid)
    if not record:
        raise RuntimeError("KOReader exited before the launcher could record its process")
    record.update(token=token, profile=str(profile), runtime=str(runtime), plugin=str(plugin), log=str(log_path))
    state_path.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"started": True, "pid": process.pid, "profile": str(profile), "private_log": str(log_path)}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
