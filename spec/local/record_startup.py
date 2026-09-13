"""Record only public metadata for the requested local native UI startup."""

import hashlib
import json
from pathlib import Path
import struct

from launch_koreader import owned_process


def main():
    profile = Path.home() / ".local/share/bilicomics-acceptance/profile"
    saved = json.loads((profile / "launcher.json").read_text())
    ready = json.loads((profile / "native-ui-ready.json").read_text())
    active = owned_process(saved, profile)
    repository = Path(__file__).resolve().parents[2]
    manifest = json.loads((repository / "dist/bilicomics-0.1.0-dev.manifest.json").read_text())
    plugin = Path(saved["plugin"])
    matches = all(hashlib.sha256((plugin / item["path"]).read_bytes()).hexdigest() == item["sha256"]
                  for item in manifest["files"])
    screenshot = profile / "native-ui-before-import.png"
    with screenshot.open("rb") as handle:
        header = handle.read(24)
    assert header[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", header[16:24])
    report = {
        "environment": "User-requested local Debian WSL2 with WSLg",
        "runtime_version": (Path(saved["runtime"]) / "git-rev").read_text().strip(),
        "native_plugin_ui_opened": ready.get("native_plugin_ui_opened") is True,
        "readonly_guard_installed": ready.get("readonly_guard_installed") is True,
        "recorded_application_running": active is not None,
        "staged_production_files_match_archive": matches,
        "archive_sha256": manifest["sha256"], "packaged_files": len(manifest["files"]),
        "framebuffer": {"width": width, "height": height, "anonymous_before_import": True},
        "session_imported_by_launcher": False,
        "purchase_tests_executed": False,
        "scope": "Actual native startup and anonymous UI rendering; live account reading remains manual",
    }
    report["passed"] = all(report[key] for key in ("native_plugin_ui_opened", "readonly_guard_installed",
                                                  "recorded_application_running", "staged_production_files_match_archive"))
    assert report["passed"]
    (repository / "spec/local/startup-result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
