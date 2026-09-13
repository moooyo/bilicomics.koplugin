"""Import the current scan's private input through the real visible candidate and reopen it."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time

from launch_koreader import owned_process


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    for name in ("profile", "runtime", "archive", "manifest", "report"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or os.getuid() == 0 or not os.environ.get("WAYLAND_DISPLAY"):
        raise RuntimeError("Use the authorized ordinary-user WSLg desktop")
    os.umask(0o077)
    profile, runtime, archive = args.profile.resolve(), args.runtime.resolve(), args.archive.resolve()
    assert profile.parent.name.startswith("candidate-45385c6f-") and profile.name == "profile"
    manifest = json.loads(args.manifest.read_text())
    assert digest(archive) == manifest["sha256"] == "45385c6ff3cc99d2639f92575fb6db0ac363ab20aa76800aa7bbdbdbe93f5342"
    launcher = Path(__file__).with_name("launch_koreader.py")
    report = {"environment": "User-authorized local Debian WSL2 with visible WSLg X11",
              "archive_sha256": manifest["sha256"], "packaged_files": len(manifest["files"]),
              "runtime_version": (runtime / "git-rev").read_text().strip(),
              "existing_profiles_touched": False, "real_purchases": 0, "authenticated_screenshots_saved": False,
              "source_sha256": {path.name: digest(path) for path in (Path(__file__), launcher,
                  Path(__file__).with_name("startup.lua"), Path(__file__).with_name("readonly_guard.lua"))}}

    def command(*arguments: str) -> dict:
        process = subprocess.run([sys.executable, str(launcher), "--profile", str(profile), *arguments],
                                 capture_output=True, text=True, timeout=25)
        with (profile.parent / "session-launcher-private.log").open("a") as log:
            log.write(process.stdout + process.stderr)
        assert process.returncode == 0, "The private candidate launcher failed"
        return json.loads(process.stdout)

    def running() -> bool:
        saved = json.loads((profile / "launcher.json").read_text())
        return owned_process(saved, profile) is not None

    def ready() -> dict:
        deadline = time.monotonic() + 90
        while not (profile / "native-ui-ready.json").exists() and time.monotonic() < deadline:
            assert running(), "The candidate exited before the account operation completed"
            time.sleep(0.2)
        return json.loads((profile / "native-ui-ready.json").read_text())

    try:
        assert not command("--stop")["running"]
        private_input = profile.parent / "fresh-auth-input.json"
        assert private_input.is_file(), "The current scan's one-time private input is unavailable"
        command("--runtime", str(runtime), "--plugin", str(archive), "--video-driver", "x11", "--autoclose", "3",
                "--import-session-file", str(private_input))
        imported_ready = ready()
        imported = json.loads((profile / "native-session-import.json").read_text())
        report["import"] = imported
        assert all(imported.get(key) is True for key in ("succeeded", "account_changed", "session_present", "session_valid",
                                                       "renewable_session", "production_runner"))
        assert imported["validation_worker_submissions"] == 1
        assert imported_ready["selected_plugin_loaded"] and not private_input.exists()
        sessions = list((profile / "data/bilicomics/accounts").glob("*/session.dat"))
        assert len(sessions) == 1
        details = sessions[0].lstat()
        assert stat.S_ISREG(details.st_mode) and stat.S_IMODE(details.st_mode) == 0o600 and details.st_uid == os.getuid()
        report["private_session_saved_with_mode_0600"] = True
        report["one_time_input_removed"] = True
        deadline = time.monotonic() + 20
        while running() and time.monotonic() < deadline:
            time.sleep(0.1)
        closed = json.loads((profile / "native-ui-closed.json").read_text())
        assert not running() and closed["native_exit_requested"] and closed["runtime_closed"]
        report["native_exit_after_import"] = closed
        command("--runtime", str(runtime), "--plugin", str(archive), "--video-driver", "x11")
        restored = ready()
        assert running() and restored["session_present"] and restored["session_valid"] and restored["renewable_session"]
        assert not restored["invalidated_session"] and restored["selected_plugin_loaded"]
        assert not (profile / "native-ui-before-import.png").exists() and not (profile / "native-account-before-import.png").exists()
        saved = json.loads((profile / "launcher.json").read_text())
        staged = Path(saved["plugin"])
        assert all(digest(staged / item["path"]) == item["sha256"] for item in manifest["files"])
        report.update(passed=True, session_restored_after_native_exit=True, selected_archive_files_match=True,
                      visible_authenticated_candidate_left_running=True, profile=str(profile))
    except Exception as error:
        report.update(passed=False, error=str(error))
    report["completed_at"] = datetime.now(timezone.utc).isoformat()
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
