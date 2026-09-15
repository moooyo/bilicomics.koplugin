"""Run fake-metadata entitlement display specs in the remote KOReader runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
from run_ui_sources import ui_source_names


REQUIRED_SIZES = ((600, 800), (480, 640))
SOURCE_FILES = (
    "bilicomics/ui/model.lua",
    "bilicomics/ui/screens.lua",
    "l10n/bilicomics_zh_CN.lua",
)
RESULT_NAME = "entitlement-display-result.json"
LOG_NAME = "entitlement-display.log"
VERIFICATION_NAME = "entitlement-display-verification.json"


def hash_sources(plugin):
    return {name: hashlib.sha256((plugin / name).read_bytes()).hexdigest()
        for name in sorted(set(SOURCE_FILES).union(ui_source_names(plugin)))}


def screen_size(value):
    try:
        width, height = (int(part) for part in value.lower().split("x"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use WIDTHxHEIGHT, such as 600x800.") from error
    if width < 1 or height < 1:
        raise argparse.ArgumentTypeError("Screen dimensions must be positive.")
    return width, height


def positive_seconds(value):
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("The timeout must be an integer.") from error
    if seconds < 1:
        raise argparse.ArgumentTypeError("The timeout must be positive.")
    return seconds


def stop_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def read_spec_result(path):
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        return False, "The native spec result could not be read: " + str(error)
    if not isinstance(result, dict):
        return False, "The native spec result must be a JSON object."
    if result.get("passed") is not True:
        return False, "The native spec result did not report passed=true."
    return True, None


def run_spec(runtime, plugin, output, size, timeout):
    width, height = size
    output.mkdir()
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update({
        "KO_MULTIUSER": "1",
        "EMULATE_READER_W": str(width),
        "EMULATE_READER_H": str(height),
        "SDL_AUDIODRIVER": "dummy",
    })
    command = [
        "xvfb-run", "-a", str(runtime / "luajit"),
        str(plugin / "spec/ui/entitlement_display_spec.lua"), str(output), str(plugin),
    ]
    interrupted = False
    try:
        process = subprocess.Popen(
            command, cwd=runtime, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", start_new_session=True,
        )
    except OSError as error:
        stdout, stderr, returncode = "", "The native UI spec could not start: " + str(error) + "\n", 127
    else:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            returncode = process.returncode
        except subprocess.TimeoutExpired:
            stop_process_group(process)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated entitlement display spec exceeded its time limit.\n"
            returncode = 124
        except KeyboardInterrupt:
            stop_process_group(process)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated entitlement display spec was interrupted.\n"
            returncode, interrupted = 130, True
    log = stdout + stderr
    (output / LOG_NAME).write_text(log, encoding="utf-8")
    print(log, end="" if log.endswith("\n") else "\n")
    result_passed, result_error = read_spec_result(output / RESULT_NAME)
    result = {
        "width": width,
        "height": height,
        "returncode": returncode,
        "result_passed": result_passed,
        "passed": returncode == 0 and result_passed,
        "result_file": f"{width}x{height}/{RESULT_NAME}",
        "log_file": f"{width}x{height}/{LOG_NAME}",
    }
    if result_error:
        result["error"] = result_error
    print(f"Entitlement display {width}x{height}: exit {returncode}; passed: {result['passed']}; output: {output}")
    return result, interrupted


def write_verification(output, report):
    (output / VERIFICATION_NAME).write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path, help="A new directory for isolated per-size results.")
    parser.add_argument("--sizes", nargs="+", type=screen_size,
                        default=list(REQUIRED_SIZES), metavar="WIDTHxHEIGHT",
                        help="Screen sizes to run; both default sizes are required for overall passed=true.")
    parser.add_argument("--timeout", type=positive_seconds, default=60,
                        help="Maximum seconds for each screen size (default: 60).")
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("Run this harness through ssh test-env in the isolated Linux runtime.")
    if len(set(args.sizes)) != len(args.sizes):
        parser.error("Each screen size must be unique.")
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    if not (runtime / "luajit").is_file():
        parser.error("The runtime directory must contain the official KOReader luajit executable.")
    if not (plugin / "spec/ui/entitlement_display_spec.lua").is_file():
        parser.error("The plugin snapshot must contain spec/ui/entitlement_display_spec.lua.")
    try:
        source_sha256 = hash_sources(plugin)
    except OSError as error:
        parser.error("The required source files could not be hashed: " + str(error))
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error("A fresh output directory is required: " + str(error))
    report = {
        "spec": "native-entitlement-display",
        "passed": False,
        "source_sha256": source_sha256,
        "source_unchanged": False,
        "purchase_tests_executed": False,
        "required_sizes": [f"{width}x{height}" for width, height in REQUIRED_SIZES],
        "requested_sizes": [f"{width}x{height}" for width, height in args.sizes],
        "runs": [],
        "interrupted": False,
    }
    write_verification(output, report)
    for size in args.sizes:
        directory = output / f"{size[0]}x{size[1]}"
        try:
            result, interrupted = run_spec(runtime, plugin, directory, size, args.timeout)
        except OSError as error:
            result, interrupted = {
                "width": size[0], "height": size[1], "returncode": None,
                "result_passed": False, "passed": False,
                "error": "The isolated run could not be completed: " + str(error),
            }, False
        report["runs"].append(result)
        report["interrupted"] = interrupted
        write_verification(output, report)
        if interrupted:
            break
    completed_sizes = {(run["width"], run["height"]) for run in report["runs"]}
    try:
        report["source_sha256_after"] = hash_sources(plugin)
        report["source_unchanged"] = report["source_sha256_after"] == source_sha256
    except OSError as error:
        report["source_hash_error"] = "The source files could not be hashed after the runs: " + str(error)
    report["passed"] = (
        not report["interrupted"]
        and report["source_unchanged"]
        and set(REQUIRED_SIZES).issubset(completed_sizes)
        and all(run["passed"] for run in report["runs"])
    )
    write_verification(output, report)
    print(f"Overall entitlement display passed: {report['passed']}; report: {output / VERIFICATION_NAME}")
    if report["interrupted"]:
        raise SystemExit(130)
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
