"""Deploy and observe the Runner probe only after the exclusive APK slot handoff."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


def main():
    if sys.platform != "linux":
        raise RuntimeError("Execute only through ssh test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--slot-confirmed", action="store_true")
    args = parser.parse_args()
    if not args.slot_confirmed:
        raise RuntimeError("Wait for the previous APK operator's explicit slot handoff")
    args.output.mkdir(parents=True, exist_ok=False)
    workspace = Path("/var/tmp/bili-android-emulator-20260912")
    adb = workspace / "sdk/platform-tools/adb"
    environment = dict(os.environ, ADB_SERVER_SOCKET="tcp:127.0.0.1:5038")
    plugin = "/sdcard/koreader/plugins/bili-native-probe.koplugin"
    guest_report = "/sdcard/koreader/bili-jobs-android-result.json"

    def command(*arguments, check=True, binary=False, timeout=20):
        result = subprocess.run([str(adb), "-P", "5038", "-s", "emulator-5580", *map(str, arguments)],
                                env=environment, capture_output=True, text=not binary, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(str(result.stdout) + str(result.stderr))
        return result

    production = ["bilicomics/jobs/runner.lua", "bilicomics/util.lua", "bilicomics/storage/codec.lua"]
    run_id = uuid.uuid4().hex
    inputs = {"run_id": run_id, "source_sha256": {
        relative: hashlib.sha256((args.snapshot / relative).read_bytes()).hexdigest() for relative in production}}
    manifest_path = args.output / "input.json"
    manifest_path.write_text(json.dumps(inputs, indent=2) + "\n")
    evidence = {"run_id": run_id, "host": "test-env", "adb_port": 5038, "serial": "emulator-5580",
                "plugin": plugin, "source_sha256": inputs["source_sha256"],
                "probe_sha256": hashlib.sha256((args.snapshot / "spec/jobs/android/main.lua").read_bytes()).hexdigest(),
                "apk_modified": False, "production_modified": False, "research_main_restored": False}
    backups = {}
    with (workspace / "apk-operation.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        command("get-state")
        evidence["boot_completed"] = command("shell", "getprop", "sys.boot_completed").stdout.strip()
        evidence["abi_list"] = command("shell", "getprop", "ro.product.cpu.abilist").stdout.strip()
        evidence["selinux"] = command("shell", "getenforce").stdout.strip()
        evidence["android_api"] = command("shell", "getprop", "ro.build.version.sdk").stdout.strip()
        package_info = command("shell", "dumpsys", "package", "org.koreader.launcher").stdout
        evidence["apk_version_name"] = re.search(r"versionName=([^\s]+)", package_info).group(1)
        evidence["apk_version_code"] = int(re.search(r"versionCode=(\d+)", package_info).group(1))
        apk_path = command("shell", "pm", "path", "org.koreader.launcher").stdout.strip().splitlines()[0].removeprefix("package:")
        evidence["installed_apk_sha256"] = command("shell", "sha256sum", apk_path).stdout.split()[0]
        assert evidence["installed_apk_sha256"] == "3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144", \
            "The installed APK does not match the pinned official release asset"
        for relative in [*production, "jobs-probe-input.json", "main.lua"]:
            exists = command("shell", "test", "-f", plugin + "/" + relative, check=False).returncode == 0
            if exists:
                original = command("exec-out", "cat", plugin + "/" + relative, binary=True)
                destination = args.output / "backups" / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(original.stdout)
                backups[relative] = destination
            else:
                backups[relative] = None
        assert backups["main.lua"], "The existing research main.lua must be preserved before deployment"
        try:
            command("shell", "am", "force-stop", "org.koreader.launcher")
            command("shell", "mkdir", "-p", plugin + "/bilicomics/jobs", plugin + "/bilicomics/storage")
            for relative in production:
                command("push", args.snapshot / relative, plugin + "/" + relative)
            command("push", args.snapshot / "spec/jobs/android/main.lua", plugin + "/main.lua")
            command("push", manifest_path, plugin + "/jobs-probe-input.json")
            command("shell", "rm", "-f", guest_report, guest_report + ".pending")
            launch = command("shell", "am", "start", "-W", "-n", "org.koreader.launcher/.MainActivity", timeout=30)
            (args.output / "launch.txt").write_text(launch.stdout + launch.stderr)
            deadline = time.monotonic() + 45
            last_report = None
            while time.monotonic() < deadline:
                observed = command("exec-out", "cat", guest_report, check=False)
                if observed.returncode == 0:
                    try:
                        candidate = json.loads(observed.stdout)
                    except json.JSONDecodeError:
                        candidate = None
                    if candidate and candidate.get("run_id") == run_id:
                        last_report = candidate
                        if candidate.get("phase") == "complete":
                            break
                time.sleep(0.5)
            evidence["report"] = last_report
            evidence["passed"] = bool(last_report and last_report.get("phase") == "complete" and last_report.get("ok"))
            if last_report:
                assert last_report["uid"] >= 10000, "The probe did not execute under an ordinary app UID"
                assert last_report["source_sha256"] == inputs["source_sha256"], "The app did not load the staged source bytes"
                processes = command("shell", "ps", "-A", "-o", "PID,UID,NAME", check=False)
                evidence["app_process_row"] = [line for line in processes.stdout.splitlines()
                                                if line.split() and line.split()[0] == str(last_report["pid"])]
                assert len(evidence["app_process_row"]) == 1, "The reported app PID must still exist"
                fields = evidence["app_process_row"][0].split()
                assert fields[1] == str(last_report["uid"]) and fields[2] == "org.koreader.launcher", \
                    "The reported PID and UID must belong to the actual KOReader APK"
            if not evidence["passed"]:
                logcat = command("logcat", "-d", "-v", "brief", check=False, timeout=30)
                (args.output / "logcat.txt").write_text(logcat.stdout + logcat.stderr)
        except Exception as error:
            evidence["passed"] = False
            evidence["error"] = repr(error)
        finally:
            if not evidence.get("passed"):
                try:
                    command("shell", "am", "force-stop", "org.koreader.launcher")
                    evidence["failed_probe_force_stopped"] = True
                except Exception as error:
                    evidence["cleanup_error"] = repr(error)
            evidence["restored_files"] = []
            evidence["removed_probe_files"] = []
            for relative, backup in backups.items():
                try:
                    if backup:
                        command("push", backup, plugin + "/" + relative)
                        current = command("exec-out", "cat", plugin + "/" + relative, binary=True).stdout
                        assert current == backup.read_bytes(), "Restored research file differs from its backup"
                        evidence["restored_files"].append(relative)
                    else:
                        command("shell", "rm", "-f", plugin + "/" + relative)
                        evidence["removed_probe_files"].append(relative)
                    if relative == "main.lua":
                        evidence["research_main_restored"] = True
                except Exception as error:
                    evidence["passed"] = False
                    evidence.setdefault("restore_errors", []).append({"path": relative, "error": repr(error)})
            (args.output / "results.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))
    return 0 if evidence.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
