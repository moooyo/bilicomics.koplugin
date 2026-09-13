"""Observe the real default-namespace provider during an official-APK cold start.

Run only on test-env after an explicit exclusive APK-slot handoff. No APK is
installed or changed. Account and session contents are never inspected by the
host; only the unique synthetic account's directory metadata is checked.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tarfile
import time
import uuid

from run_apk import (
    DATA_ROOT, Guest, OFFICIAL_APK_SHA256, PACKAGE, PHASE_SECONDS, PLUGIN,
    PRODUCTION_ROOTS, SHARED_STATE, WORKSPACE, archive_manifest, credential_path,
    require, safe_relative, sha256, source_manifest, write_json,
)


PRODUCTION_PLUGIN = DATA_ROOT + "/plugins/bilicomics.koplugin"
DEFAULT_ROOT = DATA_ROOT + "/bilicomics"
DEFAULT_SETTINGS = ("settings.lua", "settings.lua.old")
STARTUP_RELATIVE = "patches/2-bilicomics-provider.lua"
STARTUP_PATCH = DATA_ROOT + "/" + STARTUP_RELATIVE
OWNER_MARKER = b"-- BiliComics managed startup provider bootstrap v1\n"
PHASES = ("prepare", "install", "cold", "cleanup")


def main():
    require(sys.platform == "linux", "Execute only through ssh test-env")
    import fcntl

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--slot-confirmed", action="store_true")
    args = parser.parse_args()
    require(args.slot_confirmed, "An explicit exclusive APK-slot handoff is required")
    args.snapshot = args.snapshot.resolve(strict=True)
    require(not args.fixture.is_symlink(), "The synthetic fixture must not be linked")
    args.fixture = args.fixture.resolve(strict=True)
    require(args.fixture.is_file() and not credential_path(args.fixture.as_posix()),
            "The synthetic fixture must be a regular non-credential file")
    sources = {name: args.snapshot / "spec/integration/android" / name
               for name in ("cold_main.lua", "cold_guard.lua")}
    for source in sources.values():
        require(source.is_file() and not source.is_symlink() and source.resolve().is_relative_to(args.snapshot),
                "The frozen cold-start drivers must exist inside the snapshot")
    production = source_manifest(args.snapshot)
    args.output = args.output.resolve()
    require(not args.output.is_relative_to(args.snapshot) and not args.snapshot.is_relative_to(args.output),
            "The output directory and frozen snapshot must not contain one another")
    args.output.mkdir(parents=True, exist_ok=False)
    backups = args.output / "backups"
    backups.mkdir()
    run_id = uuid.uuid4().hex
    mid = "986543" + str(time.time_ns()) + str(secrets.randbelow(10**8)).zfill(8)
    run_relative = "cold-" + run_id
    guest_run = PLUGIN + "/" + run_relative
    bundle_relative = run_relative + "/bundle"
    guest_bundle = PLUGIN + "/" + bundle_relative
    account_relative = "bilicomics/accounts/bili_" + mid
    account_path = DATA_ROOT + "/" + account_relative
    report_relative = "bili-cold-" + run_id
    report_root = DATA_ROOT + "/" + report_relative
    guard_relative = "patches/2-a-bili-cold-" + run_id + ".lua"
    guard_path = DATA_ROOT + "/" + guard_relative
    inputs = {
        "run_id": run_id, "mid": mid, "plugin_name": "bili-native-probe",
        "bundle_relative": bundle_relative, "source_sha256": production,
        "production_plugin": PRODUCTION_PLUGIN, "default_data_root": DEFAULT_ROOT,
        "account_dir": "bili_" + mid, "report_root": report_root,
    }
    evidence = {
        "run_id": run_id, "mid": mid, "host": "test-env", "adb_port": 5038,
        "serial": "emulator-5580", "research_plugin": PLUGIN,
        "production_plugin": PRODUCTION_PLUGIN, "bundle_relative": bundle_relative,
        "account_path": account_path, "guard_path": guard_path,
        "source_sha256": production, "production_sha256": production,
        "test_sha256": {name: sha256(path) for name, path in sources.items()},
        "fixture_sha256": sha256(args.fixture), "phases": {}, "passed": False,
        "private_cleanup_passed": False, "shared_native_state_restored": False,
        "default_settings_restored": False, "research_main_restored": False,
        "research_input_restored": False, "research_plugin_restored": False,
        "original_startup_patch_restored": False, "production_plugin_removed": False,
        "guard_removed": False, "owned_account_removed": False,
        "new_parent_directories_removed": False, "integration_bundle_removed": False,
        "scope": "Official APK cold start; real default plugin, provider and native ReaderUI; synthetic content only",
    }
    results_path = args.output / "results.json"
    guest = Guest()
    plugin_manifest = None
    shared_backup = None
    default_backup = None
    original_files = {}
    old_patch = None
    startup_backup_ready = False
    run_attempted = False
    driver_attempted = False
    production_attempted = False
    guard_attempted = False
    startup_changed = False
    app_may_have_run = False
    apk_path = None
    stopped = False

    def save():
        try:
            write_json(results_path, evidence)
        except Exception as error:
            message = repr(error)
            if message not in evidence.setdefault("output_errors", []):
                evidence["output_errors"].append(message)
            evidence["passed"] = False
            try:
                print("Cannot persist evidence: " + message, file=sys.stderr, flush=True)
            except OSError:
                pass

    def error(key, failure):
        evidence.setdefault(key, []).append(repr(failure))
        evidence["passed"] = False
        save()

    def persist(path, value, binary=False):
        try:
            if binary:
                path.write_bytes(value)
            elif isinstance(value, str):
                path.write_text(value, encoding="utf-8")
            else:
                write_json(path, value)
        except Exception as failure:
            error("output_errors", failure)

    def attempt(key, action):
        try:
            action()
            return True
        except Exception as failure:
            error(key, failure)
            return False

    def data_path(relative):
        return DATA_ROOT + "/" + safe_relative(relative)

    def validate(relative):
        return guest.validate_owned_path(data_path(relative), DATA_ROOT, relative)

    def directory(relative, create=False):
        path = data_path(relative)
        present = validate(relative)
        if not present and create:
            guest.shell("mkdir", "-p", path)
            present = validate(relative)
        if present:
            require(guest.shell("test", "-d", path, check=False).returncode == 0,
                    "An expected data directory is not a directory: " + relative)
        return present

    def regular_bytes(path, root, relative):
        if not guest.validate_owned_path(path, root, relative):
            return None
        require(guest.shell("test", "-f", path, check=False).returncode == 0,
                "An allowed file is not regular: " + path)
        return guest.read(path, binary=True).stdout

    def startup_bytes():
        contents = regular_bytes(STARTUP_PATCH, DATA_ROOT, STARTUP_RELATIVE)
        require(contents is None or contents.startswith(OWNER_MARKER),
                "Refusing a foreign startup provider patch")
        return contents

    def remove_startup():
        startup_bytes()
        guest.remove_inside(STARTUP_PATCH, DATA_ROOT, STARTUP_RELATIVE)
        require(not guest.exists(STARTUP_PATCH), "The test startup provider patch remains")

    def force_stop():
        nonlocal stopped
        stopped = False
        evidence["final_force_stopped"] = False
        guest.shell("am", "force-stop", PACKAGE, timeout=5)
        stopped = True
        evidence["final_force_stopped"] = True

    def backup_state(label, root, names, prefix=""):
        existing = []
        for name in names:
            relative = prefix + name
            if validate(relative):
                is_directory = name in ("settings", "cache") and root == DATA_ROOT
                kind = "-d" if is_directory else "-f"
                require(guest.shell("test", kind, root + "/" + name, check=False).returncode == 0,
                        "An allowed state root has an unexpected type: " + relative)
                existing.append(name)
        archive_path = backups / (label + ".tar")
        guest.archive(root, existing, archive_path)
        manifest = archive_manifest(archive_path, set(names))
        write_json(backups / (label + "-manifest.json"), manifest)
        record = {"root": root, "names": names, "existing": existing, "prefix": prefix,
                  "archive": archive_path, "manifest": manifest, "sha256": sha256(archive_path)}
        evidence[label + "_existing"] = existing
        evidence[label + "_absent"] = sorted(set(names) - set(existing))
        evidence[label + "_backup_sha256"] = record["sha256"]
        return record

    def restore_state(label, record, result_key):
        require(stopped, "Cannot restore native state while the app may still run")
        root, names, prefix = record["root"], record["names"], record["prefix"]
        restore_relative = run_relative + "/restore-" + label + ".tar"
        restore_path = PLUGIN + "/" + restore_relative
        if app_may_have_run:
            if root != DATA_ROOT and record["existing"]:
                directory(prefix.rstrip("/"), create=True)
            guest.command("push", record["archive"], restore_path, timeout=40)
            require(guest.hashes(guest_run, ["restore-" + label + ".tar"])["restore-" + label + ".tar"]
                    == record["sha256"], "The transferred restoration archive differs: " + label)
            for name in names:
                validate(prefix + name)
            failures = []
            restorable = []
            for name in names:
                try:
                    guest.remove_inside(root + "/" + name, DATA_ROOT, prefix + name,
                                        recursive=root == DATA_ROOT and name in ("settings", "cache"))
                    require(not guest.exists(root + "/" + name), "A state root remains after removal")
                    if name in record["existing"]:
                        restorable.append(name)
                except Exception as failure:
                    failures.append(name + ": " + repr(failure))
                    try:
                        if not validate(prefix + name) and name in record["existing"]:
                            restorable.append(name)
                    except Exception as inventory_failure:
                        failures.append(name + " after removal: " + repr(inventory_failure))
            for name in restorable:
                try:
                    validate(prefix + name)
                    guest.shell("tar", "-C", root, "-xf", restore_path, name, timeout=40)
                except Exception as failure:
                    failures.append(name + ": " + repr(failure))
            require(not failures, "State restoration needs recovery: " + repr(failures))
        restored = [name for name in names if validate(prefix + name)]
        require(restored == record["existing"], "Restored state root inventory differs: " + label)
        restored_archive = backups / (label + "-restored.tar")
        guest.archive(root, restored, restored_archive)
        manifest = archive_manifest(restored_archive, set(names))
        persist(backups / (label + "-restored-manifest.json"), manifest)
        require(manifest == record["manifest"], "Restored state bytes differ: " + label)
        evidence[result_key] = True
        if app_may_have_run:
            guest.remove_inside(restore_path, PLUGIN, restore_relative)

    def install_guard():
        nonlocal guard_attempted
        directory("patches", create=True)
        if guest.exists(guard_path):
            require(guard_attempted, "The unique startup guard already exists")
            contents = regular_bytes(guard_path, DATA_ROOT, guard_relative)
            require(contents is not None and hashlib.sha256(contents).hexdigest()
                    == evidence["test_sha256"]["cold_guard.lua"], "The unique startup guard was replaced")
            return
        guard_attempted = True
        guest.command("push", sources["cold_guard.lua"], guard_path)
        contents = regular_bytes(guard_path, DATA_ROOT, guard_relative)
        require(contents is not None and hashlib.sha256(contents).hexdigest()
                == evidence["test_sha256"]["cold_guard.lua"], "The deployed startup guard differs")

    def remove_production():
        require(stopped, "Cannot remove the real plugin while the app may still run")
        require(evidence.get("production_plugin_initially_absent"), "The real plugin was not initially absent")
        guest.remove_inside(PRODUCTION_PLUGIN, DATA_ROOT, "plugins/bilicomics.koplugin", recursive=True)
        require(not guest.exists(PRODUCTION_PLUGIN), "The real production plugin remains")
        evidence["production_plugin_removed"] = True

    def run_phase(phase):
        nonlocal app_may_have_run, stopped
        item = {"passed": False, "status": "starting", "report": None}
        evidence["phases"][phase] = item
        started = time.monotonic()
        deadline = started + PHASE_SECONDS
        save()

        def remaining(maximum=20):
            available = deadline - time.monotonic()
            require(available > 0, "The " + phase + " phase exceeded its 45-second deadline")
            return min(maximum, available)

        try:
            stopped = False
            evidence["final_force_stopped"] = False
            guest.shell("am", "force-stop", PACKAGE, timeout=remaining(5))
            stopped = True
            input_path = args.output / (phase + "-input.json")
            write_json(input_path, dict(inputs, phase=phase))
            guest.command("push", input_path, PLUGIN + "/cold-input.json", timeout=remaining(8))
            app_may_have_run = True
            stopped = False
            try:
                launched = guest.shell("am", "start", "-W", "-n", PACKAGE + "/.MainActivity",
                                       check=False, timeout=remaining(15))
                item["launch_returncode"] = launched.returncode
                persist(args.output / (phase + "-launch.txt"), launched.stdout + launched.stderr)
            except subprocess.TimeoutExpired as failure:
                item["launch_timeout"] = repr(failure)
            item["status"] = "waiting"
            path = evidence["data_root_real"] + "/" + report_relative + "/" + phase + "-report.json"
            while time.monotonic() < deadline:
                try:
                    regular = guest.shell("test", "-f", path, check=False, timeout=remaining(1))
                    if regular.returncode == 0:
                        require(guest.shell("test", "-L", path, check=False, timeout=remaining(1)).returncode != 0,
                                "Refusing a linked cold-start report")
                        resolved = guest.shell("readlink", "-f", path, timeout=remaining(1)).stdout.strip()
                        require(resolved == path, "The cold-start report escaped its UUID directory")
                        observed = guest.read(path, check=False, timeout=remaining(2))
                        if observed.returncode == 0:
                            persist(args.output / (phase + "-report.last.json"), observed.stdout)
                            try:
                                candidate = json.loads(observed.stdout)
                            except json.JSONDecodeError:
                                candidate = None
                            if isinstance(candidate, dict) and candidate.get("run_id") == run_id:
                                item["report"] = candidate
                                item["guest_report"] = path
                                save()
                                if candidate.get("phase") == "complete":
                                    break
                except subprocess.TimeoutExpired:
                    pass
                time.sleep(min(0.5, max(0, deadline - time.monotonic())))
            report = item["report"]
            require(report and report.get("phase") == "complete", "The " + phase + " phase did not complete")
            persist(args.output / (phase + "-report.json"), report)
            require(type(report.get("uid")) is int and report["uid"] >= 10000,
                    "The cold-start observer did not run under an ordinary application UID")
            require(type(report.get("pid")) is int and report["pid"] > 0, "The observer PID is invalid")
            process_output = guest.shell("ps", "-A", "-o", "PID,UID,NAME", timeout=remaining(3)).stdout
            rows = [line for line in process_output.splitlines()
                    if line.split() and line.split()[0] == str(report["pid"])]
            item["app_process_rows"] = rows
            require(len(rows) == 1 and rows[0].split() == [str(report["pid"]), str(report["uid"]), PACKAGE],
                    "The observer PID and UID do not belong to the actual KOReader APK")
            if phase == "cold":
                require(report["pid"] != evidence["phases"]["install"]["report"]["pid"],
                        "The cold start must use a different process from install")
            if phase == "cleanup":
                prepared = evidence["phases"].get("prepare", {}).get("report") or {}
                prepared_passed = prepared.get("passed") is True or prepared.get("ok") is True
                no_changes = report.get("no_owned_settings_changed") is True
                require(not (prepared_passed and no_changes),
                        "Successful prepare lost its private-settings ownership record")
                require(report.get("settings_restored") is True or (no_changes and not prepared_passed),
                        "The in-app driver did not confirm private-settings restoration")
                require(report.get("private_account_was_not_created") is True or
                        (no_changes and report.get("private_account_was_not_created") is not False),
                        "The private namespace contains an unexpected synthetic account")
                evidence["private_cleanup_passed"] = True
            require(report.get("source_sha256") == production, "The app did not observe the frozen production bytes")
            require(report.get("passed") is True or report.get("ok") is True, "The " + phase + " report failed")
            item["passed"] = True
            item["status"] = "complete"
        except Exception as failure:
            item["error"] = repr(failure)
            item["status"] = "failed"
        finally:
            item["elapsed_seconds"] = round(time.monotonic() - started, 3)
            save()
        return item["passed"]

    def recheck_cold():
        item = evidence["phases"].get("cold")
        if item is None:
            return
        try:
            require(stopped, "The app must stop before the final cold-start report is accepted")
            relative = report_relative + "/cold-report.json"
            contents = regular_bytes(data_path(relative), DATA_ROOT, relative)
            require(contents is not None, "The final cold-start report is missing")
            report = json.loads(contents)
            item["final_report"] = report
            persist(args.output / "cold-report.after-stop.json", report)
            require(isinstance(report, dict) and report.get("run_id") == run_id and
                    report.get("phase") == "complete", "The final cold-start report is invalid")
            previous = item.get("report") or {}
            require(report.get("pid") == previous.get("pid") and report.get("uid") == previous.get("uid"),
                    "The final cold-start report changed its observed process identity")
            item["report"] = report
            require(report.get("passed") is True and type(report.get("workers")) is int and report["workers"] == 0,
                    "The cold-start guard revoked success or observed a late worker submission")
            require(report.get("source_sha256") == production, "The final cold-start source evidence differs")
            item["final_report_verified_after_stop"] = True
        except Exception as failure:
            item["passed"] = False
            item["status"] = "failed"
            item["final_report_error"] = repr(failure)
            error("cold_report_errors", failure)
        save()

    def collect_artifacts():
        if not validate(report_relative):
            return
        names = ["seed.json"] + [phase + "-report.json" + suffix for phase in PHASES
                                  for suffix in ("", ".pending")]
        collected = {}
        for name in names:
            relative = report_relative + "/" + name
            contents = regular_bytes(data_path(relative), DATA_ROOT, relative)
            if contents is None:
                continue
            destination = args.output / "guest-artifacts" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            persist(destination, contents, binary=True)
            collected[name] = hashlib.sha256(contents).hexdigest()
        evidence["collected_artifact_sha256"] = collected

    def restore_regular(name, backup):
        require(stopped, "Cannot restore the research entry point while the app may still run")
        path = PLUGIN + "/" + name
        guest.validate_owned_path(path, PLUGIN, name)
        if backup is None:
            guest.remove_inside(path, PLUGIN, name)
            require(not guest.exists(path), "A previously absent research file remains: " + name)
        else:
            if guest.exists(path):
                require(guest.shell("test", "-f", path, check=False).returncode == 0,
                        "The research restoration target is not a regular file")
            guest.command("push", backup, path)
            require(regular_bytes(path, PLUGIN, name) == backup.read_bytes(),
                    "The restored research file differs: " + name)
        evidence["research_main_restored" if name == "main.lua" else "research_input_restored"] = True

    def restore_startup():
        require(stopped, "Cannot restore the startup patch while the app may still run")
        if old_patch is None:
            remove_startup()
        else:
            directory("patches", create=True)
            startup_bytes()
            guest.command("push", old_patch, STARTUP_PATCH)
            require(startup_bytes() == old_patch.read_bytes(), "The original startup patch bytes differ")
        evidence["original_startup_patch_restored"] = True

    def remove_guard():
        require(stopped, "Cannot remove the startup guard while the app may still run")
        guest.remove_inside(guard_path, DATA_ROOT, guard_relative)
        require(not guest.exists(guard_path), "The cold-start guard remains")
        evidence["guard_removed"] = True

    def remove_account():
        require(stopped and evidence["private_cleanup_passed"],
                "Preserving the synthetic account until private settings are restored")
        require(evidence["shared_native_state_restored"] and evidence["default_settings_restored"],
                "Preserving the synthetic account until native state is restored")
        require(evidence.get("owned_account_initially_absent"), "The unique account was not initially absent")
        guest.remove_inside(account_path, DATA_ROOT, account_relative, recursive=True)
        require(not guest.exists(account_path), "The unique synthetic account remains")
        evidence["owned_account_removed"] = True

    def remove_empty_parents():
        require(stopped, "Cannot remove empty parent directories while the app may still run")
        for relative, initially_present in (
            ("bilicomics/accounts", evidence["accounts_parent_initially_present"]),
            ("bilicomics", evidence["default_root_initially_present"]),
            ("patches", evidence["patches_root_initially_present"]),
        ):
            if not initially_present and validate(relative):
                guest.shell("rmdir", "--", data_path(relative))
                require(not guest.exists(data_path(relative)), "A new parent directory remains: " + relative)
        evidence["new_parent_directories_removed"] = True

    def remove_bundle():
        require(stopped, "Cannot remove recovery material while the app may still run")
        require(not driver_attempted or evidence["private_cleanup_passed"],
                "Preserving the research UUID directory for private-settings recovery")
        require(not app_may_have_run or (evidence["shared_native_state_restored"]
                                        and evidence["default_settings_restored"]),
                "Preserving transferred restoration archives for native-state recovery")
        guest.remove_inside(guest_run, PLUGIN, run_relative, recursive=True)
        require(not guest.exists(guest_run), "The cold-start research UUID directory remains")
        evidence["integration_bundle_removed"] = True

    def verify_research():
        destination = backups / "research-plugin-restored.tar"
        guest.archive(PLUGIN, ["."], destination)
        restored = archive_manifest(destination)
        persist(backups / "research-plugin-restored-manifest.json", restored)
        require(restored == plugin_manifest, "The research plugin differs from its full original backup")
        evidence["research_plugin_restored"] = True

    def verify_apk():
        evidence["final_apk_sha256"] = guest.shell("sha256sum", apk_path).stdout.split()[0]
        require(evidence["final_apk_sha256"] == OFFICIAL_APK_SHA256, "The installed official APK changed")
        evidence["apk_unchanged"] = True

    persist(args.output / "input.json", inputs)
    persist(args.output / "production-manifest.json", production)
    save()
    with (WORKSPACE / "apk-operation.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            error("errors", RuntimeError("The exclusive APK operation slot is already locked"))
            print(json.dumps(evidence, indent=2, sort_keys=True))
            return 1
        evidence["exclusive_slot_confirmed"] = True
        try:
            guest.command("get-state")
            evidence["boot_completed"] = guest.shell("getprop", "sys.boot_completed").stdout.strip()
            evidence["abi_list"] = guest.shell("getprop", "ro.product.cpu.abilist").stdout.strip()
            evidence["selinux"] = guest.shell("getenforce").stdout.strip()
            evidence["android_api"] = guest.shell("getprop", "ro.build.version.sdk").stdout.strip()
            package_info = guest.shell("dumpsys", "package", PACKAGE).stdout
            version_name = re.search(r"versionName=([^\s]+)", package_info)
            version_code = re.search(r"versionCode=(\d+)", package_info)
            require(version_name is not None and version_code is not None,
                    "Cannot determine the installed APK version")
            evidence["apk_version_name"] = version_name.group(1)
            evidence["apk_version_code"] = int(version_code.group(1))
            paths = guest.shell("pm", "path", PACKAGE).stdout.strip().splitlines()
            require(len(paths) == 1 and paths[0].startswith("package:/"), "The official APK must have one package path")
            apk_path = paths[0].removeprefix("package:")
            evidence["installed_apk_path"] = apk_path
            evidence["installed_apk_sha256"] = guest.shell("sha256sum", apk_path).stdout.split()[0]
            require(evidence["installed_apk_sha256"] == OFFICIAL_APK_SHA256, "The official APK differs from its pinned SHA")
            evidence["data_root_real"] = guest.realpath(DATA_ROOT)
            evidence["plugin_real"] = guest.realpath(PLUGIN)
            require(evidence["plugin_real"] == evidence["data_root_real"] + "/plugins/bili-native-probe.koplugin",
                    "The research plugin escaped the expected data root")
            guest.allowed_roots = {DATA_ROOT: evidence["data_root_real"], PLUGIN: evidence["plugin_real"]}
            require(directory("plugins/bili-native-probe.koplugin"), "The research plugin is missing")
            require(not guest.exists(PRODUCTION_PLUGIN), "The real production plugin must initially be absent")
            evidence["production_plugin_initially_absent"] = True
            for path in (guest_run, report_root, guard_path):
                require(not guest.exists(path), "An isolated cold-start path already exists: " + path)
            evidence["guard_initially_absent"] = True
            evidence["default_root_initially_present"] = directory("bilicomics")
            evidence["accounts_parent_initially_present"] = directory("bilicomics/accounts")
            evidence["patches_root_initially_present"] = directory("patches")
            require(not guest.exists(account_path), "The unique synthetic account must initially be absent")
            evidence["owned_account_initially_absent"] = True
            force_stop()
            patch_bytes = startup_bytes()
            if patch_bytes is not None:
                old_patch = backups / "2-bilicomics-provider.lua"
                old_patch.write_bytes(patch_bytes)
                evidence["original_startup_patch_sha256"] = sha256(old_patch)
            evidence["original_startup_patch_present"] = patch_bytes is not None
            startup_backup_ready = True
            guest.archive(PLUGIN, ["."], backups / "research-plugin.tar")
            plugin_manifest = archive_manifest(backups / "research-plugin.tar")
            write_json(backups / "research-plugin-manifest.json", plugin_manifest)
            evidence["research_plugin_backup_sha256"] = sha256(backups / "research-plugin.tar")
            with tarfile.open(backups / "research-plugin.tar", "r:") as archive:
                members = {safe_relative(member.name): member for member in archive}
                for name in ("main.lua", "cold-input.json"):
                    member = members.get(name)
                    if member is None:
                        require(name != "main.lua", "The existing research main.lua must be preserved")
                        original_files[name] = None
                    else:
                        require(member.isfile(), "The replaceable research file must be regular: " + name)
                        destination = backups / name
                        destination.write_bytes(archive.extractfile(member).read())
                        original_files[name] = destination
            shared_backup = backup_state("shared-native-state", DATA_ROOT, SHARED_STATE)
            default_backup = backup_state("default-settings", DEFAULT_ROOT, DEFAULT_SETTINGS, "bilicomics/")
            save()
            startup_changed = True
            remove_startup()
            run_attempted = True
            guest.shell("mkdir", "-p", guest_bundle)
            require(guest.validate_owned_path(guest_run, PLUGIN, run_relative),
                    "The staged UUID directory is missing")
            for name in PRODUCTION_ROOTS:
                guest.command("push", args.snapshot / name, guest_bundle + "/" + name, timeout=40)
            guest.command("push", args.fixture, guest_bundle + "/fixture.png")
            guest.command("push", sources["cold_guard.lua"], guest_run + "/cold_guard.lua")
            evidence["deployed_bundle_sha256"] = guest.hashes(guest_bundle, production)
            require(evidence["deployed_bundle_sha256"] == production, "The staged production bundle differs")
            require(guest.hashes(guest_bundle, ["fixture.png"])["fixture.png"] == evidence["fixture_sha256"],
                    "The staged synthetic fixture differs")
            driver_attempted = True
            guest.validate_owned_path(PLUGIN + "/main.lua", PLUGIN, "main.lua")
            guest.command("push", sources["cold_main.lua"], PLUGIN + "/main.lua")
            require(guest.hashes(PLUGIN, ["main.lua"])["main.lua"] == evidence["test_sha256"]["cold_main.lua"],
                    "The deployed cold-start observer differs")
            if run_phase("prepare"):
                force_stop()
                require(not guest.exists(PRODUCTION_PLUGIN), "Prepare unexpectedly installed the real production plugin")
                production_attempted = True
                guest.shell("mkdir", PRODUCTION_PLUGIN)
                require(directory("plugins/bilicomics.koplugin"), "The real plugin directory is missing")
                for name in PRODUCTION_ROOTS:
                    guest.command("push", args.snapshot / name, PRODUCTION_PLUGIN + "/" + name, timeout=40)
                evidence["deployed_production_sha256"] = guest.hashes(PRODUCTION_PLUGIN, production)
                require(evidence["deployed_production_sha256"] == production, "The real deployed production plugin differs")
                if run_phase("install"):
                    force_stop()
                    installed_patch = startup_bytes()
                    require(installed_patch is not None, "The real plugin did not install its managed startup provider")
                    evidence["installed_startup_patch_sha256"] = hashlib.sha256(installed_patch).hexdigest()
                    install_guard()
                    run_phase("cold")
        except Exception as failure:
            error("errors", failure)
        finally:
            if driver_attempted:
                cleanup_ready = attempt("cleanup_errors", force_stop)
                if cleanup_ready:
                    recheck_cold()
                    cleanup_ready = attempt("cleanup_errors", remove_production)
                    cleanup_ready = attempt("cleanup_errors", remove_startup) and cleanup_ready
                    cleanup_ready = attempt("cleanup_errors", install_guard) and cleanup_ready
                if cleanup_ready:
                    run_phase("cleanup")
                else:
                    evidence["phases"]["cleanup"] = {
                        "passed": False, "status": "blocked", "report": None,
                        "error": "Cannot safely enter cleanup without removing the real plugin and preparing its guard",
                    }
            attempt("cleanup_errors", force_stop)
            if stopped and "cold" in evidence["phases"] and not evidence["phases"]["cold"].get("final_report_verified_after_stop"):
                recheck_cold()
            if production_attempted and stopped:
                attempt("restore_errors", remove_production)
            if driver_attempted:
                attempt("collection_errors", collect_artifacts)
            if guard_attempted:
                attempt("restore_errors", remove_guard)
            elif evidence.get("guard_initially_absent"):
                evidence["guard_removed"] = True
            if shared_backup is not None:
                attempt("restore_errors", lambda: restore_state("shared-native-state", shared_backup,
                                                               "shared_native_state_restored"))
            if default_backup is not None:
                attempt("restore_errors", lambda: restore_state("default-settings", default_backup,
                                                               "default_settings_restored"))
            if startup_backup_ready and startup_changed:
                attempt("restore_errors", restore_startup)
            elif startup_backup_ready:
                evidence["original_startup_patch_restored"] = True
            if driver_attempted and evidence.get("owned_account_initially_absent"):
                attempt("restore_errors", remove_account)
            if evidence.get("owned_account_removed"):
                attempt("restore_errors", remove_empty_parents)
            for name, backup in original_files.items():
                attempt("restore_errors", lambda name=name, backup=backup: restore_regular(name, backup))
            if run_attempted:
                attempt("restore_errors", remove_bundle)
            if plugin_manifest is not None:
                attempt("restore_errors", verify_research)
            if apk_path:
                attempt("restore_errors", verify_apk)
            evidence["recovery_material_preserved"] = run_attempted and not evidence["integration_bundle_removed"]
            required = ("private_cleanup_passed", "shared_native_state_restored", "default_settings_restored",
                        "research_main_restored", "research_input_restored", "research_plugin_restored",
                        "original_startup_patch_restored", "production_plugin_removed", "guard_removed",
                        "owned_account_removed", "new_parent_directories_removed", "integration_bundle_removed",
                        "apk_unchanged")
            evidence["passed"] = all(evidence["phases"].get(phase, {}).get("passed") is True for phase in PHASES) \
                and all(evidence.get(key) is True for key in required) \
                and not any(evidence.get(key) for key in
                            ("errors", "cleanup_errors", "restore_errors", "output_errors", "collection_errors", "cold_report_errors"))
            save()
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
