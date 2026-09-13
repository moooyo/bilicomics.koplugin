"""Verify two real native boots in a disposable SDL-dummy acceptance profile."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zipfile


def main():
    repository = Path(__file__).resolve().parents[2]
    root = Path.home() / ".local/share/bilicomics-acceptance"
    work = Path(tempfile.mkdtemp(prefix="upgrade-check-", dir=root))
    profile = work / "profile"
    assert profile.resolve() != (root / "profile").resolve(), "The interactive profile must remain untouched"
    launcher = Path(__file__).with_name("launch_koreader.py")
    runtime = root / "runtime-v2026.07.1/lib/koreader"
    environment = os.environ.copy()
    report = {"environment": "User-authorized local WSL; SDL dummy video and disposable profile",
              "work": str(work), "existing_interactive_profile_touched": False,
              "display_server_started": False, "network_listener_started": False,
              "purchase_tests_executed": False, "session_imported": False, "phases": []}

    def command(arguments):
        result = subprocess.run([sys.executable, str(launcher), "--profile", str(profile), *arguments],
                                env=environment, capture_output=True, text=True, timeout=20)
        with (work / "launcher.log").open("a") as log:
            log.write(result.stdout + result.stderr)
        assert result.returncode == 0, "The isolated launcher failed"
        return json.loads(result.stdout)

    try:
        baseline = root / "downloads/baseline-65b38f.zip"
        current = repository / "dist/history/bilicomics-reading-2f337b48.zip"
        old_plugin = None
        preserved = profile / "data/bilicomics/acceptance-preserved.txt"
        for name, archive, expected_refresh, expected_files, digest_prefix in (
                ("baseline", baseline, False, 87, "65b38f"), ("updated", current, True, 91, "2f337b48")):
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            with zipfile.ZipFile(archive) as package:
                files = sum(not item.is_dir() for item in package.infolist())
            assert digest.startswith(digest_prefix) and files == expected_files, "The selected package is not the requested build"
            command(["--runtime", str(runtime), "--plugin", str(archive), "--video-driver", "dummy"])
            deadline = time.monotonic() + 30
            ready_path = profile / "native-ui-ready.json"
            while not ready_path.exists() and time.monotonic() < deadline:
                assert command(["--status"])["running"], "The isolated application exited before native startup"
                time.sleep(0.1)
            assert ready_path.exists(), "Native UI readiness was not reached"
            ready = json.loads(ready_path.read_text())
            assert ready["native_plugin_ui_opened"] and ready["selected_plugin_loaded"] and ready["readonly_guard_installed"]
            assert ready["source_refresh_available"] is expected_refresh
            assert ready["version_replacement_available"] is expected_refresh
            saved = json.loads((profile / "launcher.json").read_text())
            bootstrap = (profile / "data/patches/2-bilicomics-provider.lua").read_text()
            assert saved["plugin"] in bootstrap
            if old_plugin:
                assert saved["plugin"] != old_plugin and old_plugin not in bootstrap
                assert preserved.read_text() == "Synthetic retained profile data\n"
            assert (profile / "native-ui-before-import.png").is_file()
            report["phases"].append({"name": name, "native_ui_ready": True, "selected_build_loaded": True,
                                    "source_refresh_available": expected_refresh, "bootstrap_matches_build": True,
                                    "version_replacement_available": expected_refresh,
                                    "archive_files": files, "archive_sha256": digest, "pid": saved["pid"]})
            old_plugin = saved["plugin"]
            assert not command(["--stop"])["running"]
            preserved.write_text("Synthetic retained profile data\n")
        report.update(passed=True, profile_data_preserved=True, both_owned_applications_stopped=True)
    except Exception as error:
        report.update(passed=False, error=str(error))
    finally:
        if profile.exists():
            try:
                report["final_test_profile_stopped"] = not command(["--stop"])["running"]
            except Exception as error:
                report.update(passed=False, stop_error=str(error))
    (work / "upgrade-result.json").write_text(json.dumps(report, indent=2) + "\n")
    (repository / "spec/local/upgrade-result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
