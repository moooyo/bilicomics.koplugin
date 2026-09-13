#!/usr/bin/env python3
"""Provision an isolated, remote-only Android emulator for native plugin checks."""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
import urllib.request
import zipfile


ROOT = Path("/var/tmp/bili-android-emulator-20260912")
SDK = ROOT / "sdk"
AVD_HOME = ROOT / "avd"
ANDROID_USER = ROOT / "android-user"
ADB_PORT = 5038
EMULATOR_PORT = 5580
SERIAL = f"emulator-{EMULATOR_PORT}"
AVD_NAME = "bili-koreader-api30-x86"
APK = Path("/var/tmp/bili-android-emulator-plan-20260912/koreader-android-x86-v2026.07.1.apk")
APK_SHA256 = "3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144"

PACKAGES = [
    {
        "name": "emulator",
        "url": "https://dl.google.com/android/repository/emulator-linux_x64-15917651.zip",
        "bytes": 334378080,
        "sha1": "1b1f78891abf8ec268264356e1365c25519e8379",
        "destination": SDK,
    },
    {
        "name": "platform-tools",
        "url": "https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip",
        "bytes": 9054187,
        "sha1": "477254aa5f903c15cf51001717bdf347fb6b53e0",
        "destination": SDK,
    },
    {
        "name": "api30-google-apis-x86",
        "url": "https://dl.google.com/android/repository/sys-img/google_apis/x86-30_r16.zip",
        "bytes": 1240551553,
        "sha1": "a58447e540a8581394dd04ee419c6771d62723d8",
        "destination": SDK / "system-images/android-30/google_apis",
    },
]


def emit(value):
    print(json.dumps(value), flush=True)


def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open("rb") as source:
        for block in iter(lambda: source.read(2 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def fetch(package):
    archive = ROOT / "downloads" / package["url"].rsplit("/", 1)[1]
    partial = archive.with_suffix(archive.suffix + ".partial")
    if not archive.exists():
        offset = partial.stat().st_size if partial.exists() else 0
        headers = {"Range": f"bytes={offset}-"} if offset else {}
        request = urllib.request.Request(package["url"], headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            append = offset > 0 and response.status == 206
            if not append:
                offset = 0
            last_progress = int(offset * 4 / package["bytes"])
            emit({"phase": "download", "package": package["name"], "bytes": offset})
            with partial.open("ab" if append else "wb") as output:
                for block in iter(lambda: response.read(2 * 1024 * 1024), b""):
                    output.write(block)
                    offset += len(block)
                    progress = int(offset * 4 / package["bytes"])
                    if progress > last_progress:
                        emit({"phase": "download", "package": package["name"], "percent": min(100, progress * 25)})
                        last_progress = progress
        if partial.stat().st_size != package["bytes"] or digest(partial, "sha1") != package["sha1"]:
            raise RuntimeError(f"Official archive checksum mismatch: {package['name']}")
        partial.replace(archive)
    if archive.stat().st_size != package["bytes"] or digest(archive, "sha1") != package["sha1"]:
        raise RuntimeError(f"Existing archive checksum mismatch: {package['name']}")
    record = {key: value for key, value in package.items() if key != "destination"}
    record.update(path=str(archive), sha256=digest(archive, "sha256"))
    emit({"phase": "verified", **record})
    return archive, package, record


def extract(archive, package):
    destination = package["destination"]
    destination.mkdir(parents=True, exist_ok=True)
    resolved_root = destination.resolve()
    with zipfile.ZipFile(archive) as bundle:
        total = 0
        for entry in bundle.infolist():
            member = destination / entry.filename
            if not member.resolve().is_relative_to(resolved_root):
                raise RuntimeError(f"Archive path escapes extraction directory: {entry.filename}")
            total += entry.file_size
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = bundle.read(entry).decode("utf-8")
                if not (member.parent / target).resolve().is_relative_to(resolved_root):
                    raise RuntimeError(f"Archive symlink escapes extraction directory: {entry.filename}")
    if shutil.disk_usage(destination).free < total + 3 * 1024**3:
        raise RuntimeError(f"Insufficient isolated-disk capacity to extract {package['name']}")
    subprocess.run(["unzip", "-q", "-o", str(archive), "-d", str(destination)], check=True)
    emit({"phase": "extracted", "package": package["name"], "uncompressed_bytes": total})


def environment():
    env = os.environ.copy()
    env.update(
        ANDROID_HOME=str(SDK),
        ANDROID_SDK_ROOT=str(SDK),
        ANDROID_USER_HOME=str(ANDROID_USER),
        ANDROID_EMULATOR_HOME=str(ANDROID_USER),
        ANDROID_AVD_HOME=str(AVD_HOME),
        ADB_SERVER_SOCKET=f"tcp:127.0.0.1:{ADB_PORT}",
        ANDROID_ADB_SERVER_PORT=str(ADB_PORT),
        ADB_VENDOR_KEYS=str(ANDROID_USER / "adbkey"),
        TMPDIR=str(ROOT / "tmp"),
        QT_QPA_PLATFORM="offscreen",
    )
    env.pop("DISPLAY", None)
    return env


def run(command, env, timeout=30):
    return subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)


def adb_command(*arguments):
    return [str(SDK / "platform-tools/adb"), "-P", str(ADB_PORT), "-s", SERIAL, *arguments]


def prepare_avd():
    device = AVD_HOME / f"{AVD_NAME}.avd"
    device.mkdir(parents=True, exist_ok=True)
    (AVD_HOME / f"{AVD_NAME}.ini").write_text(
        f"avd.ini.encoding=UTF-8\npath={device}\ntarget=android-30\n"
    )
    config = {
        "AvdId": AVD_NAME,
        "avd.ini.encoding": "UTF-8",
        "abi.type": "x86",
        "hw.cpu.arch": "x86",
        "hw.cpu.ncore": "2",
        "hw.ramSize": "2048",
        "hw.lcd.width": "800",
        "hw.lcd.height": "1280",
        "hw.lcd.density": "160",
        "hw.gpu.enabled": "yes",
        "hw.gpu.mode": "swiftshader_indirect",
        "hw.keyboard": "yes",
        "disk.dataPartition.size": "2G",
        "image.sysdir.1": "system-images/android-30/google_apis/x86/",
        "tag.id": "google_apis",
        "tag.display": "Google APIs",
        "target": "android-30",
        "showDeviceFrame": "no",
    }
    (device / "config.ini").write_text("".join(f"{key}={value}\n" for key, value in config.items()))
    return device


def launch_and_wait():
    env = environment()
    adb = SDK / "platform-tools/adb"
    emulator = SDK / "emulator/emulator"
    device = prepare_avd()
    key = ANDROID_USER / "adbkey"
    if not key.exists():
        generated = run([str(adb), "keygen", str(key)], env)
        if generated.returncode:
            raise RuntimeError(generated.stderr)
    server = run([str(adb), "-P", str(ADB_PORT), "start-server"], env)
    if server.returncode:
        raise RuntimeError(server.stderr)
    acceleration = run([str(emulator), "-accel-check"], env)
    (ROOT / "accel-check.log").write_text(acceleration.stdout + acceleration.stderr)
    mode = "on" if acceleration.returncode == 0 else "off"
    command = [
        str(emulator), "-avd", AVD_NAME,
        "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
        "-gpu", "swiftshader_indirect", "-accel", mode,
        "-port", str(EMULATOR_PORT), "-memory", "2048", "-cores", "2",
    ]
    log_path = ROOT / "emulator.log"
    with log_path.open("a") as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    session = {
        "root": str(ROOT), "sdk": str(SDK), "adb": str(adb), "emulator": str(emulator),
        "avd": str(device), "avd_name": AVD_NAME, "pid": process.pid,
        "adb_server_port": ADB_PORT, "emulator_console_port": EMULATOR_PORT,
        "adb_serial": SERIAL, "log": str(log_path), "acceleration": mode,
        "command": command,
    }
    (ROOT / "session.json").write_text(json.dumps(session, indent=2) + "\n")
    emit({"phase": "started", **session})
    deadline = time.monotonic() + 300
    last_update = 0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Emulator exited with status {process.returncode}; inspect {log_path}")
        try:
            state = run(adb_command("shell", "getprop", "sys.boot_completed"), env, timeout=12)
            if state.returncode == 0 and state.stdout.strip() == "1":
                break
        except subprocess.TimeoutExpired:
            pass
        if time.monotonic() - last_update >= 30:
            emit({"phase": "waiting-for-boot", "pid": process.pid})
            last_update = time.monotonic()
        time.sleep(3)
    else:
        raise RuntimeError(f"Emulator boot did not complete within 300 seconds; inspect {log_path}")
    observations = {}
    for name, command in [
        ("api", ["getprop", "ro.build.version.sdk"]),
        ("abi_list", ["getprop", "ro.product.cpu.abilist"]),
        ("kernel_arch", ["uname", "-m"]),
        ("selinux", ["getenforce"]),
        ("page_size", ["getconf", "PAGE_SIZE"]),
        ("mounts", ["cat", "/proc/mounts"]),
    ]:
        result = run(adb_command("shell", *command), env)
        observations[name] = {"exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    if digest(APK, "sha256") != APK_SHA256:
        raise RuntimeError("Previously verified KOReader APK changed")
    install = run(adb_command("install", "-r", "-g", str(APK)), env, timeout=90)
    observations["apk_install"] = {"exit_code": install.returncode, "stdout": install.stdout, "stderr": install.stderr}
    if install.returncode:
        raise RuntimeError(f"KOReader APK installation failed: {install.stdout}{install.stderr}")
    session.update(boot_completed=True, observations=observations, apk_path=str(APK), apk_sha256=APK_SHA256)
    (ROOT / "session.json").write_text(json.dumps(session, indent=2) + "\n")
    emit({"phase": "ready", "pid": process.pid, "adb_serial": SERIAL, "api": observations["api"], "abi_list": observations["abi_list"], "selinux": observations["selinux"], "apk_install": observations["apk_install"]})


def main():
    for directory in [ROOT, ROOT / "downloads", ROOT / "tmp", SDK, AVD_HOME, ANDROID_USER]:
        directory.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        fetched = list(pool.map(fetch, PACKAGES))
    (ROOT / "download-manifest.json").write_text(json.dumps([item[2] for item in fetched], indent=2) + "\n")
    for archive, package, _ in fetched:
        extract(archive, package)
    launch_and_wait()


if __name__ == "__main__":
    main()
