"""Run isolated reader integration inside the existing official Android APK.

Execute only on test-env after an explicit exclusive APK-slot handoff. The
launcher never installs, modifies, or signs an APK and never reads account
directories or credential files. The in-app driver owns private-setting and
synthetic-session cleanup.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shlex
import subprocess
import sys
import tarfile
import time
import uuid


WORKSPACE = Path("/var/tmp/bili-android-emulator-20260912")
PACKAGE = "org.koreader.launcher"
PLUGIN = "/sdcard/koreader/plugins/bili-native-probe.koplugin"
DATA_ROOT = "/sdcard/koreader"
OFFICIAL_APK_SHA256 = "3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144"
PRODUCTION_ROOTS = ("bilicomics", "patches", "l10n", "main.lua", "_meta.lua")
SHARED_STATE = (
    "history.lua", "history.lua.old", "settings", "cache",
    "settings.reader.lua", "settings.reader.lua.old",
    "defaults.custom.lua", "defaults.custom.lua.old",
)
CRITICAL_SOURCES = (
    "main.lua", "bilicomics/runtime.lua", "bilicomics/controller.lua",
    "bilicomics/session_storage.lua", "bilicomics/jobs/runner.lua",
    "bilicomics/jobs/worker.lua", "bilicomics/reader/defaults.lua",
    "bilicomics/jobs/download_service.lua", "bilicomics/storage/store.lua",
    "bilicomics/storage/page_store.lua", "bilicomics/storage/files.lua",
    "bilicomics/storage/image_header.lua", "bilicomics/reader/document.lua",
    "bilicomics/reader/image_backend.lua", "bilicomics/reader/geometry.lua",
    "bilicomics/reader/integration.lua", "bilicomics/reader/anchors.lua",
    "bilicomics/reader/compatibility.lua",
)
PHASE_SECONDS = 45


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def write_json(path, value):
    temporary = path.with_name(path.name + ".pending")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(value):
    path = PurePosixPath(value)
    require(not path.is_absolute() and ".." not in path.parts, "Unsafe archive or source path")
    return path.as_posix()


def credential_path(value):
    parts = PurePosixPath(value).parts
    return any(part.lower() in ("accounts", "session.dat") for part in parts)


def archive_manifest(path, allowed_roots=None):
    """Hash regular archived bytes without extracting or following links."""
    manifest = {}
    with tarfile.open(path, "r:") as archive:
        for entry in archive:
            name = safe_relative(entry.name)
            if name == ".":
                continue
            require(not credential_path(name), "The allowed backup tree contains account credentials")
            if allowed_roots is not None:
                require(PurePosixPath(name).parts[0] in allowed_roots,
                        "The shared-state archive contains an unexpected root")
            require(name not in manifest, "The archive contains duplicate paths")
            if entry.isdir():
                item = {"type": "directory"}
            elif entry.isfile():
                source = archive.extractfile(entry)
                require(source is not None, "Cannot read an archived regular file")
                digest = hashlib.sha256()
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
                item = {"type": "file", "size": entry.size, "sha256": digest.hexdigest()}
            elif entry.issym() and allowed_roots is None:
                item = {"type": "symlink", "target": entry.linkname}
            else:
                raise RuntimeError("Unsupported archive entry: " + name)
            manifest[name] = item
    return manifest


def source_manifest(snapshot):
    manifest = {}
    for name in PRODUCTION_ROOTS:
        root = snapshot / name
        require(root.exists() and not root.is_symlink(), "Missing or linked production root: " + name)
        paths = sorted(root.rglob("*")) if root.is_dir() else [root]
        for path in paths:
            require(not path.is_symlink(), "Production snapshot must not contain symlinks")
            if path.is_file():
                require(path.resolve().is_relative_to(snapshot), "Source escaped the frozen snapshot")
                relative = path.relative_to(snapshot).as_posix()
                require(not credential_path(relative), "Production snapshot contains account credentials")
                manifest[relative] = sha256(path)
    for name in CRITICAL_SOURCES:
        require(name in manifest, "Missing critical production source: " + name)
    return manifest


class Guest:
    def __init__(self):
        self.environment = dict(os.environ, ADB_SERVER_SOCKET="tcp:127.0.0.1:5038")
        self.prefix = [str(WORKSPACE / "sdk/platform-tools/adb"), "-P", "5038", "-s", "emulator-5580"]
        self.allowed_roots = {}

    def command(self, *arguments, check=True, binary=False, timeout=20):
        result = subprocess.run(self.prefix + list(map(str, arguments)), env=self.environment,
                                capture_output=True, text=not binary, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError("ADB command failed: " + str(result.stdout) + str(result.stderr))
        return result

    def shell(self, *arguments, **options):
        return self.command("shell", shlex.join(list(map(str, arguments))), **options)

    def read(self, path, **options):
        return self.command("exec-out", shlex.join(["cat", path]), **options)

    def exists(self, path):
        return self.shell("test", "-e", path, check=False).returncode == 0 or \
            self.shell("test", "-L", path, check=False).returncode == 0

    def realpath(self, path):
        resolved = self.shell("readlink", "-f", path).stdout.strip()
        require(resolved.startswith("/") and "\n" not in resolved, "Cannot resolve guest path")
        return resolved

    def guard_backup_tree(self, root):
        """Inspect names only before any full-tree copy can read credentials."""
        found = self.shell("find", root, "(", "-iname", "accounts", "-o", "-iname", "session.dat", ")",
                           "-print", "-prune").stdout.strip()
        require(not found, "Refusing to copy an account directory or credential file in: " + root)

    def archive(self, root, names, destination):
        for name in names:
            safe_relative(name)
            self.guard_backup_tree(root if name == "." else root + "/" + name)
        if not names:
            with tarfile.open(destination, "w"):
                pass
            return
        arguments = self.prefix + ["exec-out", shlex.join(["tar", "-C", root, "-cf", "-", *names])]
        with destination.open("wb") as output:
            result = subprocess.run(arguments, env=self.environment, stdout=output, stderr=subprocess.PIPE, timeout=40)
        require(result.returncode == 0, "Guest archive failed: " + result.stderr.decode("utf-8", "replace"))

    def validate_owned_path(self, path, root, relative):
        """Resolve an exact allowed path without following a substituted root."""
        relative = safe_relative(relative)
        require(relative != ".", "Refusing to delete an allowed root")
        require(PurePosixPath(path) == PurePosixPath(root) / relative, "Unexpected deletion target")
        root_real = self.realpath(root)
        require(root_real == self.allowed_roots.get(root), "The allowed deletion root changed after backup")
        if not self.exists(path):
            return False
        require(self.shell("test", "-L", path, check=False).returncode != 0,
                "Refusing to remove a symlink as an owned target")
        target_real = self.realpath(path)
        expected = str(PurePosixPath(root_real) / relative)
        require(target_real == expected and target_real.startswith(root_real.rstrip("/") + "/"),
                "Deletion target escaped its allowed root")
        return True

    def remove_inside(self, path, root, relative, recursive=False):
        """Resolve every deletion target before removing an exact owned path."""
        if not self.validate_owned_path(path, root, relative):
            return
        self.shell("rm", "-rf" if recursive else "-f", "--", path)

    def hashes(self, root, relative_paths):
        manifest = {}
        relative_paths = sorted(relative_paths)
        for start in range(0, len(relative_paths), 40):
            paths = relative_paths[start:start + 40]
            output = self.shell("sha256sum", *[root + "/" + name for name in paths]).stdout
            for line in output.splitlines():
                digest, full_path = line.split(None, 1)
                full_path = full_path.lstrip(" *")
                require(full_path.startswith(root + "/") and re.fullmatch(r"[0-9a-f]{64}", digest),
                        "Unexpected deployed hash output")
                manifest[full_path[len(root) + 1:]] = digest
        require(set(manifest) == set(relative_paths), "Deployed hash inventory is incomplete")
        return manifest


def main():
    require(sys.platform == "linux", "Execute only through ssh test-env")
    import fcntl

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--slot-confirmed", action="store_true")
    args = parser.parse_args()
    require(args.slot_confirmed, "Wait for the previous APK operator's explicit exclusive slot handoff")
    args.snapshot = args.snapshot.resolve(strict=True)
    args.fixture = args.fixture.resolve(strict=True)
    require(args.fixture.is_file(), "The synthetic PNG fixture must be a regular file")
    driver = args.snapshot / "spec/integration/android/main.lua"
    chain = args.snapshot / "spec/integration/android/chain.lua"
    for source in (driver, chain):
        require(source.is_file() and not source.is_symlink() and source.resolve().is_relative_to(args.snapshot),
                "The frozen Android driver and chain must exist inside the snapshot")
    production = source_manifest(args.snapshot)
    args.output = args.output.resolve()
    require(not args.output.is_relative_to(args.snapshot) and not args.snapshot.is_relative_to(args.output),
            "The output directory and frozen snapshot must not contain one another")
    args.output.mkdir(parents=True, exist_ok=False)
    backups = args.output / "backups"
    backups.mkdir()
    run_id = uuid.uuid4().hex
    run_relative = "integration-" + run_id
    guest_run = PLUGIN + "/" + run_relative
    bundle_relative = run_relative + "/bundle"
    guest_bundle = PLUGIN + "/" + bundle_relative
    mid = "986541" + str(time.time_ns()) + str(secrets.randbelow(10**8)).zfill(8)
    inputs = {
        "run_id": run_id, "mid": mid, "plugin_name": "bili-native-probe",
        "bundle_relative": bundle_relative,
        "source_sha256": {name: production[name] for name in CRITICAL_SOURCES},
    }
    evidence = {
        "run_id": run_id, "host": "test-env", "adb_port": 5038, "serial": "emulator-5580",
        "plugin": PLUGIN, "bundle_relative": bundle_relative, "mid": mid,
        "source_sha256": inputs["source_sha256"], "production_sha256": production,
        "test_sha256": {"main.lua": sha256(driver), "chain.lua": sha256(chain), "fixture.png": sha256(args.fixture)},
        "apk_modified": False, "production_modified": False, "research_main_restored": False,
        "research_input_restored": False, "research_plugin_restored": False,
        "shared_native_state_restored": False, "private_cleanup_passed": False,
        "passed": False, "phases": {},
        "scope": "Official APK; actual plugin, native ReaderUI, fork/IPC and storage; synthetic content only",
    }
    results_path = args.output / "results.json"
    write_json(args.output / "input.json", inputs)
    write_json(results_path, evidence)
    guest = Guest()
    plugin_manifest = None
    state_manifest = None
    state_existing = []
    original_files = {}
    run_created = False
    driver_installed = False
    apk_path = None
    shared_mutation_possible = False

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

    def report_error(key, error):
        evidence.setdefault(key, []).append(repr(error))
        evidence["passed"] = False
        save()

    def collect_artifacts():
        root = DATA_ROOT + "/bili-integration-" + run_id
        if not guest.exists(root):
            return
        require(guest.realpath(root) == evidence["data_root_real"] + "/bili-integration-" + run_id,
                "The synthetic evidence directory escaped its assigned UUID root")
        names = [phase + "-report.json" + suffix for phase in ("setup", "online", "offline", "cleanup")
                 for suffix in ("", ".pending")]
        names += ["expected-offline.json", "first-image-blocked.json"]
        audit_root = root + "/worker-audit"
        if guest.exists(audit_root):
            require(guest.realpath(audit_root) == evidence["data_root_real"] + "/bili-integration-" + run_id + "/worker-audit",
                    "The synthetic worker audit escaped its assigned directory")
            entries = guest.shell("find", audit_root, "-maxdepth", "1", "-type", "f", "-name", "*.json", "-print").stdout
            for entry in entries.splitlines():
                require(entry.startswith(audit_root + "/"), "Unexpected worker audit path")
                name = entry[len(audit_root) + 1:]
                require(re.fullmatch(r"[0-9]+\.json", name) is not None, "Unexpected synthetic worker audit name")
                names.append("worker-audit/" + name)
        collected = {}
        for name in names:
            source = root + "/" + name
            if not guest.exists(source):
                continue
            require(guest.shell("test", "-L", source, check=False).returncode != 0 and
                    guest.realpath(source) == evidence["data_root_real"] + "/bili-integration-" + run_id + "/" + name,
                    "Refusing to collect a substituted synthetic report")
            destination = args.output / "guest-artifacts" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(guest.read(source, binary=True).stdout)
            collected[name] = sha256(destination)
        evidence["collected_artifact_sha256"] = collected
        save()

    def run_phase(phase):
        phase_evidence = {"passed": False, "report": None, "status": "starting"}
        evidence["phases"][phase] = phase_evidence
        save()
        started = time.monotonic()
        deadline = started + PHASE_SECONDS

        def remaining(maximum=20):
            available = deadline - time.monotonic()
            require(available > 0, "The " + phase + " phase exceeded its 45-second deadline")
            return min(maximum, available)

        try:
            guest.shell("am", "force-stop", PACKAGE, timeout=remaining(5))
            phase_input = dict(inputs, phase=phase)
            input_path = args.output / (phase + "-input.json")
            write_json(input_path, phase_input)
            guest.command("push", input_path, PLUGIN + "/integration-input.json", timeout=remaining(8))
            try:
                launch = guest.shell("am", "start", "-W", "-n", PACKAGE + "/.MainActivity",
                                     check=False, timeout=remaining(15))
                (args.output / (phase + "-launch.txt")).write_text(launch.stdout + launch.stderr, encoding="utf-8")
                phase_evidence["launch_returncode"] = launch.returncode
            except subprocess.TimeoutExpired as error:
                phase_evidence["launch_timeout"] = str(error)
            phase_evidence["status"] = "waiting"
            save()
            report_paths = list(dict.fromkeys([
                DATA_ROOT + "/bili-integration-" + run_id + "/" + phase + "-report.json",
                evidence["data_root_real"] + "/bili-integration-" + run_id + "/" + phase + "-report.json",
            ]))
            while time.monotonic() < deadline:
                for guest_report in report_paths:
                    if time.monotonic() >= deadline:
                        break
                    try:
                        observed = guest.read(guest_report, check=False, timeout=remaining(2))
                    except subprocess.TimeoutExpired:
                        continue
                    if observed.returncode != 0:
                        continue
                    try:
                        (args.output / (phase + "-report.last.json")).write_text(observed.stdout, encoding="utf-8")
                    except Exception as error:
                        report_error("output_errors", error)
                    try:
                        candidate = json.loads(observed.stdout)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(candidate, dict) or candidate.get("run_id") != run_id:
                        continue
                    phase_evidence["report"] = candidate
                    phase_evidence["guest_report"] = guest_report
                    save()
                    if candidate.get("phase") == "complete":
                        break
                report = phase_evidence["report"]
                if report and report.get("phase") == "complete":
                    break
                time.sleep(min(0.5, max(0, deadline - time.monotonic())))
            report = phase_evidence["report"]
            require(report and report.get("phase") == "complete", "The " + phase + " phase did not complete")
            try:
                write_json(args.output / (phase + "-report.json"), report)
            except Exception as error:
                report_error("output_errors", error)
            require(isinstance(report.get("uid"), int) and report["uid"] >= 10000,
                    "The driver did not run under an ordinary application UID")
            require(isinstance(report.get("pid"), int) and report["pid"] > 0, "The driver did not report a valid PID")
            processes = guest.shell("ps", "-A", "-o", "PID,UID,NAME", timeout=remaining(3)).stdout
            rows = [line for line in processes.splitlines() if line.split() and line.split()[0] == str(report["pid"])]
            phase_evidence["app_process_rows"] = rows
            require(len(rows) == 1, "The reported application PID does not exist uniquely")
            fields = rows[0].split()
            require(len(fields) == 3 and fields[1] == str(report["uid"]) and fields[2] == PACKAGE,
                    "The reported PID and UID do not belong to the actual KOReader APK")
            require(report.get("source_sha256") == inputs["source_sha256"],
                    "The app did not observe the exact staged critical source bytes")
            require(report.get("passed") is True or report.get("ok") is True,
                    "The " + phase + " driver report failed")
            if phase == "offline":
                require(report["pid"] != evidence["phases"]["online"]["report"]["pid"],
                        "Offline reopening must use a fresh application process")
            if phase == "cleanup":
                require(report.get("settings_restored") is True and report.get("synthetic_session_removed") is True,
                        "The in-app driver did not confirm private settings and synthetic-session cleanup")
                if evidence["phases"].get("setup", {}).get("passed"):
                    require(report.get("no_owned_session_created") is not True,
                            "Successful setup lost its ownership record before private cleanup")
            phase_evidence["status"] = "complete"
            phase_evidence["passed"] = True
        except Exception as error:
            phase_evidence["error"] = repr(error)
            phase_evidence["status"] = "failed"
        finally:
            phase_evidence["elapsed_seconds"] = round(time.monotonic() - started, 3)
            save()
        return phase_evidence["passed"]

    with (WORKSPACE / "apk-operation.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            report_error("errors", RuntimeError("The exclusive APK operation slot is already locked"))
            raise RuntimeError("The exclusive APK operation slot is already locked") from error
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
            require(version_name is not None and version_code is not None, "Cannot determine the installed APK version")
            evidence["apk_version_name"] = version_name.group(1)
            evidence["apk_version_code"] = int(version_code.group(1))
            package_paths = guest.shell("pm", "path", PACKAGE).stdout.strip().splitlines()
            require(len(package_paths) == 1 and package_paths[0].startswith("package:/"),
                    "The installed official APK must have one package path")
            apk_path = package_paths[0].removeprefix("package:")
            evidence["installed_apk_path"] = apk_path
            evidence["installed_apk_sha256"] = guest.shell("sha256sum", apk_path).stdout.split()[0]
            require(evidence["installed_apk_sha256"] == OFFICIAL_APK_SHA256,
                    "The installed APK differs from the pinned unmodified official release")
            evidence["plugin_real"] = guest.realpath(PLUGIN)
            evidence["data_root_real"] = guest.realpath(DATA_ROOT)
            guest.allowed_roots = {PLUGIN: evidence["plugin_real"], DATA_ROOT: evidence["data_root_real"]}
            require(evidence["plugin_real"] == evidence["data_root_real"] + "/plugins/bili-native-probe.koplugin",
                    "The research plugin is outside the expected native data directory")
            require(guest.shell("test", "-d", PLUGIN, check=False).returncode == 0, "The existing research plugin is missing")
            require(not guest.exists(guest_run), "The integration UUID directory already exists")
            require(not guest.exists(DATA_ROOT + "/bili-integration-" + run_id), "The report UUID directory already exists")
            guest.shell("am", "force-stop", PACKAGE)
            guest.archive(PLUGIN, ["."], backups / "research-plugin.tar")
            plugin_manifest = archive_manifest(backups / "research-plugin.tar")
            write_json(backups / "research-plugin-manifest.json", plugin_manifest)
            evidence["research_plugin_backup_sha256"] = sha256(backups / "research-plugin.tar")
            with tarfile.open(backups / "research-plugin.tar", "r:") as archive:
                by_name = {safe_relative(member.name): member for member in archive}
                for name in ("main.lua", "integration-input.json"):
                    member = by_name.get(name)
                    if member is None:
                        require(name != "main.lua", "The existing research main.lua must be preserved")
                        original_files[name] = None
                    else:
                        require(member.isfile(), "The replaceable research file must be regular: " + name)
                        destination = backups / name
                        destination.write_bytes(archive.extractfile(member).read())
                        original_files[name] = destination
            state_existing = [name for name in SHARED_STATE if guest.exists(DATA_ROOT + "/" + name)]
            for name in state_existing:
                require(guest.shell("test", "-L", DATA_ROOT + "/" + name, check=False).returncode != 0,
                        "The shared native state root must not be a symlink")
            guest.archive(DATA_ROOT, state_existing, backups / "shared-native-state.tar")
            state_manifest = archive_manifest(backups / "shared-native-state.tar", set(SHARED_STATE))
            write_json(backups / "shared-native-state-manifest.json", state_manifest)
            evidence["shared_native_state_existing"] = state_existing
            evidence["shared_native_state_absent"] = sorted(set(SHARED_STATE) - set(state_existing))
            evidence["shared_native_state_backup_sha256"] = sha256(backups / "shared-native-state.tar")
            save()
            run_created = True
            guest.shell("mkdir", "-p", guest_bundle)
            for name in PRODUCTION_ROOTS:
                guest.command("push", args.snapshot / name, guest_bundle + "/" + name, timeout=40)
            guest.shell("mkdir", "-p", guest_bundle + "/spec/integration/android")
            guest.command("push", chain, guest_bundle + "/spec/integration/android/chain.lua")
            guest.command("push", args.fixture, guest_bundle + "/fixture.png")
            evidence["deployed_production_sha256"] = guest.hashes(guest_bundle, production)
            require(evidence["deployed_production_sha256"] == production, "The deployed production snapshot differs")
            evidence["deployed_test_sha256"] = guest.hashes(guest_bundle, ["spec/integration/android/chain.lua", "fixture.png"])
            require(evidence["deployed_test_sha256"]["fixture.png"] == evidence["test_sha256"]["fixture.png"] and
                    evidence["deployed_test_sha256"]["spec/integration/android/chain.lua"] == evidence["test_sha256"]["chain.lua"],
                    "The deployed chain or synthetic fixture differs")
            driver_installed = True
            guest.command("push", driver, PLUGIN + "/main.lua")
            evidence["deployed_driver_sha256"] = guest.hashes(PLUGIN, ["main.lua"])["main.lua"]
            require(evidence["deployed_driver_sha256"] == evidence["test_sha256"]["main.lua"], "The deployed driver differs")
            shared_mutation_possible = True
            for phase in ("setup", "online", "offline"):
                if not run_phase(phase):
                    break
        except Exception as error:
            report_error("errors", error)
        finally:
            if driver_installed:
                shared_mutation_possible = True
                try:
                    evidence["private_cleanup_passed"] = run_phase("cleanup")
                except Exception as error:
                    report_error("cleanup_errors", error)
            try:
                if run_created or driver_installed:
                    guest.shell("am", "force-stop", PACKAGE)
                    evidence["final_force_stopped"] = True
            except Exception as error:
                report_error("cleanup_errors", error)
            if driver_installed:
                try:
                    collect_artifacts()
                except Exception as error:
                    report_error("collection_errors", error)
            if state_manifest is not None:
                try:
                    if shared_mutation_possible:
                        require(evidence.get("final_force_stopped"), "Cannot restore shared state while the app may still run")
                        restore_tar = guest_run + "/restore-shared-native-state.tar"
                        guest.command("push", backups / "shared-native-state.tar", restore_tar, timeout=40)
                        require(guest.hashes(guest_run, ["restore-shared-native-state.tar"])["restore-shared-native-state.tar"]
                                == evidence["shared_native_state_backup_sha256"], "The guest restoration archive differs")
                        for name in SHARED_STATE:
                            guest.validate_owned_path(DATA_ROOT + "/" + name, DATA_ROOT, name)
                        restorable_names = []
                        deletion_errors = []
                        for name in SHARED_STATE:
                            try:
                                guest.remove_inside(DATA_ROOT + "/" + name, DATA_ROOT, name, recursive=name in ("settings", "cache"))
                                require(not guest.exists(DATA_ROOT + "/" + name), "A shared-state root remains after removal")
                                if name in state_existing:
                                    restorable_names.append(name)
                            except Exception as error:
                                deletion_errors.append(name + ": " + repr(error))
                        extraction_errors = []
                        for name in restorable_names:
                            try:
                                guest.shell("tar", "-C", DATA_ROOT, "-xf", restore_tar, name, timeout=40)
                            except Exception as error:
                                extraction_errors.append(name + ": " + repr(error))
                        require(not deletion_errors and not extraction_errors,
                                "Shared-state restoration needs recovery: " + repr(deletion_errors + extraction_errors))
                    restored_names = [name for name in SHARED_STATE if guest.exists(DATA_ROOT + "/" + name)]
                    require(restored_names == state_existing, "Restored shared native state root inventory differs")
                    guest.archive(DATA_ROOT, restored_names, backups / "shared-native-state-restored.tar")
                    restored_state = archive_manifest(backups / "shared-native-state-restored.tar", set(SHARED_STATE))
                    write_json(backups / "shared-native-state-restored-manifest.json", restored_state)
                    require(restored_state == state_manifest, "Restored shared native state differs from its full backup")
                    evidence["shared_native_state_restored"] = True
                    if shared_mutation_possible:
                        guest.remove_inside(guest_run + "/restore-shared-native-state.tar", PLUGIN,
                                            run_relative + "/restore-shared-native-state.tar")
                except Exception as error:
                    report_error("restore_errors", error)
            if original_files:
                for name, backup in original_files.items():
                    try:
                        require(not shared_mutation_possible or evidence.get("final_force_stopped"),
                                "Cannot restore the research entry point while the app may still run")
                        require(guest.realpath(PLUGIN) == evidence["plugin_real"],
                                "The research plugin root changed after backup")
                        if backup is None:
                            guest.remove_inside(PLUGIN + "/" + name, PLUGIN, name)
                        else:
                            require(guest.shell("test", "-L", PLUGIN + "/" + name, check=False).returncode != 0,
                                    "Refusing to overwrite a linked research file")
                            if guest.exists(PLUGIN + "/" + name):
                                require(guest.realpath(PLUGIN + "/" + name) == evidence["plugin_real"] + "/" + name,
                                        "The research restoration target escaped its original root")
                            guest.command("push", backup, PLUGIN + "/" + name)
                            restored = guest.read(PLUGIN + "/" + name, binary=True).stdout
                            require(restored == backup.read_bytes(), "The restored research file differs: " + name)
                        evidence["research_main_restored" if name == "main.lua" else "research_input_restored"] = True
                    except Exception as error:
                        report_error("restore_errors", error)
            if run_created:
                try:
                    require(not shared_mutation_possible or evidence.get("final_force_stopped"),
                            "Cannot remove the integration bundle while the app may still run")
                    require(not shared_mutation_possible or evidence["shared_native_state_restored"],
                            "Preserving the integration directory and restoration archive for shared-state recovery")
                    guest.remove_inside(guest_run, PLUGIN, run_relative, recursive=True)
                    evidence["integration_bundle_removed"] = not guest.exists(guest_run)
                except Exception as error:
                    report_error("restore_errors", error)
            if plugin_manifest is not None:
                try:
                    guest.archive(PLUGIN, ["."], backups / "research-plugin-restored.tar")
                    restored_plugin = archive_manifest(backups / "research-plugin-restored.tar")
                    write_json(backups / "research-plugin-restored-manifest.json", restored_plugin)
                    require(restored_plugin == plugin_manifest, "The research plugin differs from its full original backup")
                    evidence["research_plugin_restored"] = True
                except Exception as error:
                    report_error("restore_errors", error)
            if apk_path:
                try:
                    evidence["final_apk_sha256"] = guest.shell("sha256sum", apk_path).stdout.split()[0]
                    require(evidence["final_apk_sha256"] == OFFICIAL_APK_SHA256, "The official installed APK changed")
                except Exception as error:
                    report_error("restore_errors", error)
            evidence["passed"] = all(evidence["phases"].get(phase, {}).get("passed") is True
                                     for phase in ("setup", "online", "offline", "cleanup")) and all(
                evidence.get(key) is True for key in ("private_cleanup_passed", "shared_native_state_restored",
                                                     "research_plugin_restored", "research_main_restored",
                                                     "research_input_restored", "integration_bundle_removed")) and not any(
                evidence.get(key) for key in ("errors", "cleanup_errors", "restore_errors", "output_errors", "collection_errors"))
            save()
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
