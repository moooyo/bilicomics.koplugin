"""Capture the synthetic native UI review matrix only through ssh test-env."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time


MATRIX_LANGUAGE = re.compile(r"^(zh_CN|C)-\d+x\d+$")
IGNORED_IMAGE_DIRECTORIES = {"fixtures", "home", "ko_home", "profile"}


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def task_definitions():
    tasks = []

    def add(suite, runner, spec, suffix="", arguments=()):
        tasks.append({
            "id": suite + suffix,
            "suite": suite,
            "runner": "spec/ui/" + runner + ".py",
            "spec": "spec/ui/" + spec + ".lua",
            "arguments": list(arguments),
            "language": "zh_CN",
        })

    for width, height in ((600, 800), (480, 640)):
        add("native", "run_native", "native_probe", f"-{width}x{height}",
            ("--width", str(width), "--height", str(height)))
    add("bookshelf-finishing", "run_bookshelf_finishing", "bookshelf_finishing_spec")
    add("bookstore-categories", "run_bookstore_categories", "bookstore_categories_spec")
    add("bookstore-expanded", "run_bookstore_expanded", "bookstore_expanded_spec")
    add("qr-login", "run_qr_login", "qr_login_spec", arguments=("--language", "zh_CN"))
    for width, height in ((600, 800), (480, 640)):
        add("session-import", "run_session_import", "session_import_spec", f"-{width}x{height}",
            ("--width", str(width), "--height", str(height)))
    for suite, basename in (
        ("quote-selection", "quote_selection"),
        ("ordinal-range", "ordinal_range"),
        ("download-recovery", "download_recovery"),
        ("version-replacement", "version_replacement"),
        ("entitlement-display", "entitlement_display"),
    ):
        add(suite, "run_" + basename, basename + "_spec")
    add("review-supplement", "run_review_supplement", "review_supplement")
    add("review-reader", "run_review_reader", "review_reader")
    add("optimization", "run_optimization", "optimization_spec")
    return tasks


def source_hashes(plugin, tasks):
    paths = {plugin / "main.lua", plugin / "_meta.lua",
        plugin / "spec/ui/run_review_capture.py", plugin / "spec/ui/run_bookshelf_grid.py",
        plugin / "spec/ui/run_ui_sources.py"}
    for directory in ("bilicomics", "l10n", "patches"):
        paths.update((plugin / directory).rglob("*.lua"))
    for task in tasks:
        paths.update((plugin / task["runner"], plugin / task["spec"]))
    return {path.relative_to(plugin).as_posix(): sha256(path) for path in sorted(paths)}


def excluded_image(path, task_output):
    relative = path.relative_to(task_output)
    return path.name == "oversized-cover.png" or any(
        part in IGNORED_IMAGE_DIRECTORIES or part.startswith(("xdg_", "xdg-"))
        for part in relative.parts[:-1]
    )


def screenshot_record(path, output, task_output, task):
    with path.open("rb") as handle:
        header = handle.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("The capture does not have a valid PNG header: " + str(path))
    width, height = struct.unpack(">II", header[16:24])
    language = task["language"]
    for part in path.relative_to(task_output).parts[:-1]:
        match = MATRIX_LANGUAGE.fullmatch(part)
        if match:
            language = match.group(1)
            break
    return {
        "path": path.relative_to(output).as_posix(),
        "name": path.stem,
        "task": task["id"],
        "suite": task["suite"],
        "width": width,
        "height": height,
        "language": language,
        "spec": task["spec"],
        "runner": task["runner"],
        "sha256": sha256(path),
        "synthetic_data": True,
        "capture_method": "KOReader native framebuffer",
    }


def result_record(path, output):
    record = {"path": path.relative_to(output).as_posix(), "sha256": sha256(path)}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        record.update(passed=False, error=str(error))
        return record
    if not isinstance(payload, dict):
        record.update(passed=False, error="The result document is not a JSON object.")
        return record
    assertions = payload.get("assertions")
    if isinstance(assertions, list):
        record["assertion_count"] = len(assertions)
        record["failed_assertions"] = [item for item in assertions
            if isinstance(item, dict) and item.get("passed") is not True]
    passed = payload.get("passed", payload.get("success"))
    if isinstance(passed, bool):
        record["passed"] = passed
    elif isinstance(assertions, list):
        record["passed"] = bool(assertions) and not record["failed_assertions"]
    for key in ("count", "width", "height", "language", "synthetic_only", "actual_purchase_executed"):
        if key in payload and isinstance(payload[key], (bool, int, str)):
            record[key] = payload[key]
    return record


def run_task(task, runtime, plugin, output, pillow):
    started = time.monotonic()
    task_output = output / "suites" / task["id"]
    log_path = output / "logs" / (task["id"] + ".log")
    command = ["unshare", "--net", "--", sys.executable, str(plugin / task["runner"]),
        str(runtime), str(plugin), str(task_output), *task["arguments"]]
    if task["suite"] == "review-reader":
        command.extend(("--pillow", str(pillow)))
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(pillow)
    for name in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
        environment.pop(name, None)
    result = {
        "id": task["id"], "suite": task["suite"], "spec": task["spec"], "runner": task["runner"],
        "started_at": timestamp(), "command": command,
        "output": task_output.relative_to(output).as_posix(),
        "log": log_path.relative_to(output).as_posix(),
        "network_isolation_requested": True, "screenshots": [], "results": [], "collection_errors": [],
    }
    try:
        with log_path.open("w", encoding="utf-8") as log:
            log.write("Command: " + json.dumps(command) + "\n")
            log.flush()
            # Each existing runner owns its bounded native subprocess timeout.
            completed = subprocess.run(command, cwd=plugin, env=environment,
                stdout=log, stderr=subprocess.STDOUT, check=False)
        result["returncode"] = completed.returncode
    except OSError as error:
        result.update(returncode=127, error=str(error))
        with log_path.open("a", encoding="utf-8") as log:
            log.write("The capture runner could not start: " + str(error) + "\n")
    if task_output.is_dir():
        for path in sorted(task_output.rglob("*.png")):
            if excluded_image(path, task_output):
                continue
            try:
                result["screenshots"].append(screenshot_record(path, output, task_output, task))
            except (OSError, ValueError) as error:
                result["collection_errors"].append(str(error))
        for path in sorted(task_output.rglob("*.json")):
            if "result" not in path.name and "verification" not in path.name:
                continue
            if excluded_image(path, task_output):
                continue
            try:
                result["results"].append(result_record(path, output))
            except OSError as error:
                result["collection_errors"].append(str(error))
    result["screenshot_count"] = len(result["screenshots"])
    result["result_count"] = len(result["results"])
    result["passed"] = (result["returncode"] == 0 and bool(result["screenshots"])
        and bool(result["results"]) and not result["collection_errors"]
        and all(record.get("passed") is not False for record in result["results"]))
    result["finished_at"] = timestamp()
    result["duration_seconds"] = round(time.monotonic() - started, 3)
    return result


def save_manifest(output, manifest):
    temporary = output / "review-capture-manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "review-capture-manifest.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--pillow", type=Path, required=True,
        help="The existing isolated Pillow dependency directory on test-env.")
    parser.add_argument("--jobs", type=int, choices=(1, 2, 3), default=3,
        help="Maximum concurrent capture runners (default: 3).")
    parser.add_argument("--tasks", nargs="+", choices=[task["id"] for task in task_definitions()],
        help="Capture only the named tasks into a fresh output directory.")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Run only through ssh test-env; local verification is not authorized.")
    runtime, plugin, output, pillow = (path.resolve() for path in
        (args.runtime, args.plugin, args.output, args.pillow))
    tasks = task_definitions()
    if args.tasks:
        tasks = [task for task in tasks if task["id"] in args.tasks]
    if not (runtime / "luajit").is_file():
        parser.error("The runtime must contain the official KOReader luajit executable.")
    if not (pillow / "PIL").is_dir():
        parser.error("The isolated Pillow directory must contain PIL.")
    if not shutil.which("unshare"):
        parser.error("The remote capture requires unshare for network isolation.")
    for task in tasks:
        for name in ("runner", "spec"):
            if not (plugin / task[name]).is_file():
                parser.error("The source snapshot is missing " + task[name])
    try:
        before = source_hashes(plugin, tasks)
        output.mkdir(parents=True, exist_ok=False)
        (output / "logs").mkdir()
        (output / "suites").mkdir()
    except OSError as error:
        parser.error("A readable source snapshot and fresh output directory are required: " + str(error))
    version_file = runtime / "git-rev"
    manifest = {
        "schema_version": 1,
        "scope": "Synthetic native KOReader UI previews from the supplied plugin source; no live service or real account.",
        "environment": "ssh test-env, isolated Linux network namespaces",
        "runtime": str(runtime),
        "runtime_version": version_file.read_text(encoding="utf-8").strip() if version_file.is_file() else None,
        "plugin": str(plugin), "output": str(output), "started_at": timestamp(),
        "max_concurrency": args.jobs, "expected_task_count": len(tasks),
        "source_sha256": before, "source_unchanged": None,
        "tasks": [], "screenshots": [], "screenshot_count": 0, "passed": False,
    }
    save_manifest(output, manifest)
    order = {task["id"]: index for index, task in enumerate(tasks)}
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {executor.submit(run_task, task, runtime, plugin, output, pillow): task for task in tasks}
        for future in as_completed(futures):
            task = futures[future]
            try:
                result = future.result()
            except Exception as error:
                result = {"id": task["id"], "suite": task["suite"], "spec": task["spec"],
                    "runner": task["runner"], "passed": False, "error": str(error),
                    "returncode": None, "screenshots": [], "results": [], "screenshot_count": 0}
            manifest["tasks"].append(result)
            manifest["tasks"].sort(key=lambda item: order[item["id"]])
            manifest["screenshots"] = [screen for item in manifest["tasks"] for screen in item["screenshots"]]
            manifest["screenshot_count"] = len(manifest["screenshots"])
            save_manifest(output, manifest)
            print(json.dumps({"task": task["id"], "passed": result["passed"],
                "returncode": result["returncode"], "screenshots": result["screenshot_count"],
                "completed_tasks": len(manifest["tasks"]), "total_tasks": len(tasks)}), flush=True)
    try:
        manifest["source_sha256_after"] = source_hashes(plugin, tasks)
        manifest["source_unchanged"] = before == manifest["source_sha256_after"]
    except OSError as error:
        manifest.update(source_unchanged=False, source_hash_error=str(error))
    manifest["finished_at"] = timestamp()
    manifest["passed"] = manifest["source_unchanged"] and all(task["passed"] for task in manifest["tasks"])
    save_manifest(output, manifest)
    print(json.dumps({"passed": manifest["passed"], "screenshots": manifest["screenshot_count"],
        "manifest": str(output / "review-capture-manifest.json")}), flush=True)
    return 0 if manifest["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
