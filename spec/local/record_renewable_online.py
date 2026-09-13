"""Bind the bounded native online observation and retain a normal window without its observer."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from launch_koreader import owned_process


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    for name in ("profile", "runtime", "archive", "manifest", "import-report", "report"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    profile = args.profile.resolve()
    assert sys.platform == "linux" and os.getuid() != 0 and profile.parent.name.startswith("candidate-45385c6f-")
    native = json.loads((profile / "renewable-online-native.json").read_text())
    events = [json.loads(line) for line in (profile / "renewable-online-events.jsonl").read_text().splitlines()]
    manifest = json.loads(args.manifest.read_text())
    prior = json.loads(args.import_report.read_text())
    assert prior["passed"] and prior["profile"] == str(profile)
    assert digest(args.archive) == manifest["sha256"] == prior["archive_sha256"]
    assert all(native.get(key) is True for key in ("callback_succeeded", "session_valid", "renewable_session",
        "session_manager_ready", "maintenance_checked", "no_pending_rotation", "workers_settled", "same_active_account", "production_runner"))
    assert native["callback_count"] == 1
    assert [event["category"] for event in events[:3]] == ["cookie_info", "navigation", "favorites"]
    assert events[0]["refresh_required"] is False and events[0]["business_code"] == 0
    assert events[1]["logged_in"] is True and events[1]["business_code"] == 0
    assert all(event.get("http_status") == 200 for event in events[:3])
    counts = Counter(event["category"] for event in events)
    assert counts["cookie_info"] == counts["navigation"] == counts["favorites"] == 1
    assert not any(counts[name] for name in ("cookie_refresh", "refresh_confirmation", "correspondence", "other"))
    incidental = events[3:]
    assert all(event["category"] in ("cover_or_asset", "signing_asset") for event in incidental)
    assert not any(event.get("error_kind") == "verification_guard" for event in events)
    old_saved = json.loads((profile / "launcher.json").read_text())
    deadline = time.monotonic() + 8
    while owned_process(old_saved, profile) and time.monotonic() < deadline:
        time.sleep(0.1)
    assert owned_process(old_saved, profile) is None, "Close the temporary observation window through its normal window action first"
    launcher = Path(__file__).with_name("launch_koreader.py")
    command = [sys.executable, str(launcher), "--profile", str(profile), "--runtime", str(args.runtime),
               "--plugin", str(args.archive), "--video-driver", "x11"]
    started = subprocess.run(command, capture_output=True, text=True, timeout=25)
    assert started.returncode == 0, "The normal retained window could not start"
    deadline = time.monotonic() + 30
    while not (profile / "native-ui-ready.json").exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    ready = json.loads((profile / "native-ui-ready.json").read_text())
    saved = json.loads((profile / "launcher.json").read_text())
    current = owned_process(saved, profile)
    assert current and current["pid"] != old_saved["pid"] and ready["session_valid"] and ready["renewable_session"]
    environment = Path(f"/proc/{current['pid']}/environ").read_bytes().split(b"\0")
    assert b"BILICOMICS_ACCEPTANCE_REFRESH_FAVORITES=0" in environment
    assert b"BILICOMICS_ACCEPTANCE_IMPORT_FILE=" in environment
    assert not (profile / "native-ui-before-import.png").exists() and not (profile / "native-account-before-import.png").exists()
    staged = Path(saved["plugin"])
    assert all(digest(staged / item["path"]) == item["sha256"] for item in manifest["files"])
    sources = (Path(__file__), launcher, Path(__file__).with_name("startup.lua"),
               Path(__file__).with_name("readonly_guard.lua"), Path(__file__).with_name("renewable_online.lua"))
    report = {"passed": True, "environment": "User-authorized local Debian WSL2 and visible WSLg X11",
              "runtime_version": (args.runtime / "git-rev").read_text().strip(), "archive_sha256": manifest["sha256"],
              "packaged_files": len(manifest["files"]), "profile": str(profile),
              "same_profile_as_native_import": True, "native_import_report_sha256": digest(args.import_report),
              "first_online_request_after_reopen": True, "native": native, "request_counts": dict(counts),
              "events": events, "business_requests_succeeded": 3,
              "incidental_cover_failures": dict(Counter(event["error_kind"] for event in incidental if event.get("error_kind"))),
              "incidental_cover_failure_origin": "Existing production Transport encoded-byte response limit; Controller requests a 4 MiB cover bound",
              "guard_rejections": 0, "actual_credential_rotation": False, "wallet_requests": 0, "purchase_requests": 0,
              "response_injection": False, "authenticated_screenshots_saved": False,
              "temporary_observer_process_exited": True, "normal_visible_window_running": True,
              "retained_window_observer_disabled": True, "final_process": current,
              "source_sha256": {path.name: digest(path) for path in sources},
              "completed_at": datetime.now(timezone.utc).isoformat()}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
