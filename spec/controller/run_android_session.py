"""Run synthetic private-session checks in the already-provisioned official APK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    adb = Path("/var/tmp/bili-android-emulator-20260912/sdk/platform-tools/adb")
    environment = dict(os.environ, ADB_SERVER_SOCKET="tcp:127.0.0.1:5038")
    target = "/sdcard/koreader/plugins/bili-native-probe.koplugin"

    def command(*values, check=True):
        return subprocess.run([str(adb), "-P", "5038", "-s", "emulator-5580", *map(str, values)],
                              env=environment, text=True, capture_output=True, check=check, timeout=60)

    command("shell", "am", "force-stop", "org.koreader.launcher")
    command("shell", "mkdir", "-p", target + "/bilicomics", target + "/spec/controller")
    for name in ["controller.lua", "session_storage.lua", "settings.lua", "util.lua"]:
        command("push", args.source / "bilicomics" / name, target + "/bilicomics/" + name)
    for name in ["catalog", "jobs", "purchase", "reader", "storage", "ui"]:
        command("push", args.source / "bilicomics" / name, target + "/bilicomics/")
    command("push", args.source / "l10n", target + "/")
    command("push", args.source / "spec/controller/session_storage_cases.lua", target + "/spec/controller/session_storage_cases.lua")
    command("push", args.source / "spec/controller/android_session_plugin.lua", target + "/main.lua")
    command("push", args.fixture, target + "/fixture.png")
    command("shell", "rm", "-f", target + "/session-reopen.json")
    command("shell", "rm", "-f", "/sdcard/koreader/bili-native-probe.json")
    command("shell", "am", "start", "-W", "-n", "org.koreader.launcher/.MainActivity")
    def await_report():
        for _ in range(45):
            value = command("shell", "cat", "/sdcard/koreader/bili-native-probe.json", check=False)
            if value.returncode == 0:
                try:
                    candidate = json.loads(value.stdout)
                except json.JSONDecodeError:
                    candidate = {}
                if candidate.get("phase") == "complete":
                    return candidate
            time.sleep(1)
        raise RuntimeError("The existing Android app did not complete its synthetic session probe")

    report = await_report()
    if report.get("passed"):
        private_path = report["result"]["private_session_path"]
        state_path = args.output.with_suffix(".reopen-input.json")
        state_path.write_text(json.dumps({"root": report["synthetic_data_root"], "private_path": private_path,
                                          "account_key": private_path.split("/")[-2]}))
        command("shell", "am", "force-stop", "org.koreader.launcher")
        command("push", state_path, target + "/session-reopen.json")
        command("shell", "rm", "-f", "/sdcard/koreader/bili-native-probe.json")
        command("shell", "am", "start", "-W", "-n", "org.koreader.launcher/.MainActivity")
        reopened = await_report()
        report["process_restart"] = reopened
        report["passed"] = reopened.get("passed", False) and report["process_pid"] != reopened.get("process_pid")
    report["production_sha256"] = {
        name: hashlib.sha256((args.source / name).read_bytes()).hexdigest()
        for name in ["bilicomics/controller.lua", "bilicomics/session_storage.lua"]
    }
    report["test_sha256"] = {
        name: hashlib.sha256((args.source / name).read_bytes()).hexdigest()
        for name in ["spec/controller/session_storage_cases.lua", "spec/controller/android_session_plugin.lua"]
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report.get("passed") else 1)


if __name__ == "__main__":
    main()
