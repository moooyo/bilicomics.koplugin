"""Verify the selected candidate in a new visible WSLg profile, preserving all existing profiles."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time

from launch_koreader import owned_process


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or os.getuid() == 0 or not os.environ.get("WAYLAND_DISPLAY"):
        raise RuntimeError("Use the authorized ordinary-user WSLg desktop")
    os.umask(0o077)
    runtime, archive = args.runtime.resolve(), args.archive.resolve()
    manifest = json.loads(args.manifest.read_text())
    assert digest(archive) == args.expected_sha256 == manifest["sha256"], "The candidate archive identity changed"
    assert (runtime / "git-rev").read_text().strip() == "v2026.07.1", "Use the pinned official runtime"
    root = Path.home() / ".local/share/bilicomics-acceptance"
    root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="candidate-45385c6f-", dir=root))
    profile = work / "profile"
    launcher = Path(__file__).with_name("launch_koreader.py")
    screenshots = args.report.resolve().parent / "candidate-startup-images"
    screenshots.mkdir(parents=True, exist_ok=True)
    report = {"environment": "User-authorized local Debian WSL2 with visible WSLg X11 windows",
              "runtime_version": "v2026.07.1", "runtime_luajit_sha256": digest(runtime / "luajit"),
              "archive_sha256": manifest["sha256"], "packaged_files": len(manifest["files"]),
              "existing_profiles_touched": False, "real_purchases": 0, "session_imported": False,
              "profile": str(profile), "phases": [], "source_sha256": {
                  path.name: digest(path) for path in (launcher, Path(__file__),
                      Path(__file__).with_name("startup.lua"), Path(__file__).with_name("readonly_guard.lua"))}}

    def command(*arguments: str) -> dict:
        run = subprocess.run([sys.executable, str(launcher), "--profile", str(profile), *arguments],
                             capture_output=True, text=True, timeout=25)
        with (work / "launcher-private.log").open("a") as log:
            log.write(run.stdout + run.stderr)
        assert run.returncode == 0, "The candidate launcher failed; inspect its private log"
        return json.loads(run.stdout)

    def running() -> bool:
        saved = json.loads((profile / "launcher.json").read_text())
        return owned_process(saved, profile) is not None

    try:
        marker = profile / "data/bilicomics/acceptance-preserved.txt"
        previous_pid = None
        for width, height in ((720, 960), (600, 800)):
            command("--runtime", str(runtime), "--plugin", str(archive), "--width", str(width), "--height", str(height),
                    "--video-driver", "x11", "--capture-account", "--autoclose", "3")
            deadline = time.monotonic() + 35
            while not (profile / "native-ui-ready.json").exists() and time.monotonic() < deadline:
                assert running(), "KOReader exited before native UI readiness"
                time.sleep(0.1)
            ready = json.loads((profile / "native-ui-ready.json").read_text())
            assert all(ready.get(key) is True for key in ("native_plugin_ui_opened", "readonly_guard_installed",
                "selected_plugin_loaded", "source_refresh_available", "version_replacement_available",
                "qr_signin_available", "session_maintenance_available")), "A required native startup capability is absent"
            saved = json.loads((profile / "launcher.json").read_text())
            plugin = Path(saved["plugin"])
            assert all(digest(plugin / item["path"]) == item["sha256"] for item in manifest["files"])
            assert len([path for path in plugin.rglob("*") if path.is_file()]) == len(manifest["files"])
            assert str(plugin) in (profile / "data/patches/2-bilicomics-provider.lua").read_text()
            if previous_pid is not None:
                assert saved["pid"] != previous_pid and marker.read_text() == "Synthetic preserved candidate profile\n"
            for name in ("native-ui-before-import.png", "native-account-before-import.png"):
                screenshot = profile / name
                header = screenshot.read_bytes()[:24]
                assert header[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", header[16:24]) == (width, height)
                shutil.copyfile(screenshot, screenshots / f"{width}x{height}-{name}")
            deadline = time.monotonic() + 15
            while running() and time.monotonic() < deadline:
                time.sleep(0.1)
            closed = json.loads((profile / "native-ui-closed.json").read_text())
            assert not running() and closed.get("native_exit_requested") and closed.get("runtime_closed")
            report["phases"].append({"width": width, "height": height, "video_driver": "x11", "native_ui_ready": True,
                "selected_archive_files_match": True, "provider_patch_matches": True, "native_exit_completed": True,
                "pid": saved["pid"], "anonymous_screenshots": 2})
            marker.write_text("Synthetic preserved candidate profile\n")
            previous_pid = saved["pid"]
        command("--runtime", str(runtime), "--plugin", str(archive), "--width", "720", "--height", "960", "--video-driver", "x11")
        deadline = time.monotonic() + 30
        while not (profile / "native-ui-ready.json").exists() and time.monotonic() < deadline:
            assert running(), "The retained visible candidate exited before readiness"
            time.sleep(0.1)
        assert (profile / "native-ui-ready.json").exists() and running()
        report.update(passed=True, profile_marker_preserved=True, visible_candidate_left_running=True,
                      live_account_acceptance_completed=False)
    except Exception as error:
        report.update(passed=False, error=str(error))
        if (profile / "launcher.json").exists():
            report["cleanup"] = command("--stop")
    report["completed_at"] = datetime.now(timezone.utc).isoformat()
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
