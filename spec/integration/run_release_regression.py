"""Run one synthetic release matrix through ssh test-env from a frozen snapshot."""
from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import traceback


VERSION = "v2026.07.1"
ASSETS = {
    "efae82c96a7eef44bee5.wasm": "39bc0676953752c461197df592e1f5894f1a7492a29400c946e560fc109a8e2e",
    "e461bfa6b471a22c06fc.wasm": "3b499622e9a5f6181f0709d1485498f533428f9a30ae32694f6f6852ec47184c",
}
SOURCE_CASES = ("success", "changed_bytes", "topology", "legacy_unknown", "native_positions",
                "cancel", "suspend", "account_close", "interrupted", "preempt", "final_update_failure",
                "resume_throw", "unpinned_preflight", "unpinned_inflight")
VERSION_CASES = ("success", "same_identity", "topology", "cancel", "suspend", "account_close", "account_switch",
                 "stale_index", "stale_basis", "mutual_exclusion", "interrupted", "fresh_access", "fresh_index",
                 "database_failure", "resume_throw", "binding", "unbound", "unpinned_cancel", "unpinned_success")
READER_MODES = ("render", "ui", "ui-reopen", "page", "page-reopen", "pan", "pan-reopen", "ui-online", "thumbnail")
JOB_SUITES = ("runner", "download", "worker", "extensions", "budget", "cover", "parent-exit")
STORAGE_MODES = ("core", "integration-safety", "crash-after_journal", "recover-after_journal",
                 "crash-after_rename", "recover-after_rename", "crash-after_database", "recover-after_database",
                 "crash-invalid-commit", "recover-invalid-commit", "crash-retry-commit", "recover-retry-commit")
EXCLUSIONS = [
    {"scope": "Real QR login, refresh, confirmation, and long-term renewal",
     "reason": "Requires a real user session and phone interaction; this matrix supplies only synthetic credentials.",
     "reference": "docs/session-renewal.md"},
    {"scope": "Live reading and existing private image samples",
     "reason": "Requires explicitly selected live account/image inputs; never inferred from files on test-env.",
     "command": "python3 spec/integration/run_live_reading.py --runtime RUNTIME --source SOURCE --work FRESH_WORK --selection SELECTION --guard GUARD --session SESSION --execute-live-read"},
    {"scope": "Physical Scribe and Android runtime acceptance",
     "reason": "Linux native rendering and startup do not prove device behavior; device setup and acceptance remain separate.",
     "reference": "spec/integration/android/README.md"},
    {"scope": "Actual charge, coupon consumption, and entitlement delivery",
     "reason": "Real payment is excluded. Synthetic purchase suites use memory-only transport and isolated SQLite."},
    {"scope": "Protocol acquisition using historical research fixtures",
     "reason": "The broad protocol runner conditionally consumes research/protocol/image-legacy-fixtures.json. This matrix runs client and native crypto explicitly and does not import historical account-derived research data.",
     "reference": "spec/protocol/run_remote.py"},
]
ACTIVE_PROCESSES = {}
CANCELLED = False


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    require(path.is_file() and not path.is_symlink(), "A required input is not a regular file: " + str(path))
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def read_json(path):
    require(path.is_file() and not path.is_symlink(), "Missing regular evidence file: " + str(path))
    return json.loads(path.read_text(encoding="utf-8"))


def source_manifest(source):
    production, tests = {}, {}
    forbidden = {".secrets", "accounts", "session.dat", "session.json", "cookies.txt", "cookies.json", "state.sqlite3"}
    for directory in ("bilicomics", "l10n", "patches", "tools", "spec"):
        root = source / directory
        require(root.is_dir() and not root.is_symlink(), "Missing source directory: " + directory)
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(source)
            require(not forbidden.intersection(relative.parts), "Account data is not permitted in the source snapshot")
            require(not path.is_symlink(), "Source snapshots must not contain symlinks")
            if path.is_file() and (directory != "spec" or path.suffix in (".lua", ".py")):
                target = tests if directory in ("spec", "tools") else production
                target[relative.as_posix()] = digest(path)
    for name in ("main.lua", "_meta.lua"):
        production[name] = digest(source / name)
    encoded = json.dumps({"production": production, "tests": tests}, sort_keys=True, separators=(",", ":")).encode()
    return {"production_sha256": production, "test_source_sha256": tests,
            "snapshot_sha256": hashlib.sha256(encoded).hexdigest()}


def evidence(value):
    """Reject absent, false, empty, or internally inconsistent assertion evidence."""
    require(type(value) is dict and bool(value), "Evidence must be a nonempty object")
    if "failed" in value:
        require(value["failed"] == 0 or value["failed"] == [], "Evidence contains failed cases")
    recognized = False
    if "passed" in value:
        passed = value["passed"]
        require(passed is True or (type(passed) is int and passed > 0), "Evidence did not pass")
        recognized = True
        if type(passed) is int:
            names = value.get("cases", value.get("checks", value.get("assertions")))
            named = type(names) is list and bool(names) and (
                all(type(name) is str and name for name in names)
                or all(type(item) is dict and item.get("passed") is True for item in names))
            require(named and len(names) == passed,
                    "A numeric pass count must match its named cases")
    if "success" in value:
        require(value["success"] is True, "Evidence did not succeed")
        recognized = True
    for key in ("assertions", "checks", "tests", "groups", "cases"):
        if key not in value:
            continue
        items = value.get(key)
        if type(items) is list:
            require(bool(items), "The " + key + " evidence cannot be empty")
            if all(type(item) is str and item for item in items):
                require(key in ("cases", "checks") and type(value.get("passed")) is int
                        and value["passed"] == len(items), "Named cases require a matching numeric pass count")
            else:
                require(all(type(item) is dict and item.get("passed") is True for item in items),
                    "One or more " + key + " did not pass")
            recognized = True
            if key == "assertions" and "count" in value:
                require(value["count"] == len(items), "Assertion count differs from the evidence")
        elif key in ("assertions", "groups") and type(items) is int:
            require(items > 0, "An evidence count cannot be empty")
            supporting = value.get("tests", value.get("groups"))
            require(type(supporting) is list and bool(supporting), "A count alone is not assertion evidence")
            if key == "groups":
                require(items == len(supporting), "Group count differs from the named tests")
        else:
            raise ValueError("Unexpected " + key + " evidence schema")
    require(recognized, "No explicit pass marker or passing assertions were recorded")


def rows(report, key, identity, expected, inner="result"):
    values = report.get(key)
    require(type(values) is list and [item.get(identity) for item in values] == list(expected),
            "The expected " + key + " matrix was not completed")
    for item in values:
        require(item.get("returncode") == 0, "A nested process did not exit successfully")
        if "passed" in item:
            require(item["passed"] is True, "A nested run did not pass")
        evidence(item.get(inner))
    return values


def validate(report, kind, directory):
    if kind == "evidence":
        evidence(report)
    elif kind == "session":
        evidence(report)
        rows(report, "results", "suite", ("spec/protocol/session_refresh_spec.lua", "spec/controller/qr_authentication_spec.lua"))
        require(report.get("real_network_requests") == 0 and report.get("synthetic_credentials_only") is True,
                "Session scope does not remain synthetic")
    elif kind == "qr":
        evidence(report)
        cases = report.get("cases", [])
        require([(item.get("width"), item.get("height")) for item in cases] == [(480, 640), (600, 800)],
                "Both QR display sizes are required")
        for item in cases:
            require(item.get("passed") is True and item.get("returncode") == 0 and item.get("assertions", 0) > 0,
                    "A QR display case failed")
            evidence(read_json(directory / f"{item['width']}x{item['height']}" / "qr-login-result.json"))
    elif kind == "client":
        require(report.get("returncode") == 0 and report.get("session_mode") == "0o600", "Client or session permissions failed")
        evidence(report.get("result"))
    elif kind == "purchase-dispatch":
        evidence(report)
        evidence(report.get("result"))
        require(report.get("source_unchanged") is True and report.get("returncode") == 0
                and report.get("timed_out") is False, "Purchase dispatch did not finish with unchanged sources")
    elif kind == "jobs":
        evidence(report)
        rows(report, "suites", "suite", JOB_SUITES)
    elif kind == "connectivity":
        evidence(report)
        rows(report, "suites", "suite", ("service", "runner"))
        require(report.get("network_requests") == 0 and report.get("real_session_used") is False,
                "Connectivity checks must use synthetic data")
    elif kind == "storage":
        evidence(report)
        runs = report.get("suites", [])
        require([item.get("mode") for item in runs] == list(STORAGE_MODES), "The storage recovery matrix is incomplete")
        for item in runs:
            expected = 73 if item["mode"].startswith("crash-") else 0
            require(item.get("expected_returncode") == expected and item.get("returncode") == expected,
                    "A storage phase did not reach its expected terminal state")
            if expected == 0:
                evidence(item.get("result"))
            else:
                require(item.get("result") is None, "Crash evidence must come from its subsequent recovery process")
    elif kind == "storage-focused":
        evidence(report)
        evidence(report.get("suite"))
        require(report.get("source_unchanged") is True and report.get("returncode") == 0, "Focused storage check failed")
    elif kind in ("source-workflow", "version-workflow"):
        evidence(report)
        expected = SOURCE_CASES if kind == "source-workflow" else VERSION_CASES
        require(report.get("complete_matrix") is True and report.get("requested_cases") == list(expected),
                "The full workflow matrix is required")
        for item in rows(report, "runs", "case", expected):
            require(item.get("tracked_processes_terminal") is True and item.get("timed_out") is False,
                    "Workflow process cleanup was not proven")
            require(item["result"].get("all_children_reaped") is True
                    and item["result"].get("all_worker_pids_terminal") is True, "Workflow workers were not reaped")
    elif kind in ("selection", "range"):
        evidence(report)
        evidence(report.get("result"))
        require(type(report["result"].get("groups")) is list and bool(report["result"]["groups"]),
                "Quote groups are missing")
        require(report.get("network_namespace_isolated") is True and report.get("buy_episode_calls") == 0
                and report.get("forbidden_module_attempts") == 0 and report.get("user_session_accessed") is False,
                "Quote isolation evidence failed")
    elif kind in ("single-purchase", "ordinal-purchase"):
        evidence(report)
        if kind == "single-purchase":
            expected = ["state_machine", "protocol_boundary"] + [f"restart-{purpose}-{phase}"
                for purpose in ("read", "download") for phase in ("prepare", "recover", "confirm", "inspect")]
        else:
            expected = ["state_machine", "protocol_boundary"] + ["ordinal_transaction_spec-" + phase for phase in
                ("unit", "seed", "recover", "owned", "inspect_pending", "late_accepted", "inspect_cleared", "seed_timeout", "recover_timeout")]
        for item in rows(report, "runs", "name", expected, "evidence"):
            require(type(item.get("case_names")) is list and len(item["case_names"]) == item.get("passed_cases", 0)
                    and item["passed_cases"] > 0, "Purchase cases were not recorded")
            require(item["evidence"].get("network_namespace_isolated") is True
                    and item["evidence"].get("real_transport_attempts") == 0
                    and item["evidence"].get("forbidden_module_attempts") == 0, "Purchase isolation evidence failed")
        require(report.get("actual_http_permitted") is False and report.get("actual_purchases_permitted") is False
                and report.get("user_session_accessed") is False, "Purchase scope is not synthetic")
    elif kind == "reader":
        rows(report, "runs", "mode", READER_MODES)
    elif kind == "defaults":
        expected = [(case, phase) for case, phases in (
            ("auto_strip", ("open", "reopen")), ("auto_page", ("open",)), ("forced_page", ("open",)),
            ("forced_strip", ("open",)), ("saved_native", ("open",)), ("legacy_anchor", ("open", "reopen")),
            ("anchor_only", ("open",)), ("stale_free_anchor", ("open",)), ("changed_native", ("open", "reopen")),
            ("rtl_mirrored", ("open",)), ("ltr_mirrored", ("open",)), ("rtl_pan", ("open", "reopen")),
            ("free_pan", ("open", "reopen"))) for phase in phases]
        runs = report.get("runs", [])
        require([(item.get("case"), item.get("phase")) for item in runs] == expected, "Reader default matrix is incomplete")
        for item in runs:
            require(item.get("returncode") == 0, "Reader defaults exited unsuccessfully")
            evidence(item.get("result"))
    elif kind == "fallback":
        for item in rows(report, "runs", "phase", ("read", "recover")):
            observations = item["result"].get("observations")
            require(type(observations) is dict and bool(observations) and all(value is True for value in observations.values()),
                    "Fallback startup observations did not all pass")
    elif kind == "startup-contract":
        require(type(report) is list and [item.get("mode") for item in report]
                == ["plugin-init", "plugin-top-level", "late-hook"], "Startup contract matrix is incomplete")
        for item in report:
            require(item.get("passed") is True and item.get("returncode") == 0, "Startup contract did not pass")
            expected = item["mode"] == "late-hook"
            observed = item.get("report", {})
            require(observed.get("reader_opened") is expected
                    and observed.get("first_show", {}).get("provider_available") is expected
                    and observed.get("plugins_loaded_at_late_patch") is False, "Startup observation differs from its contract")
    elif kind == "startup-production":
        evidence(report)
        observed = report.get("report", {})
        first = observed.get("first_show", {})
        require(report.get("returncode") == 0 and observed.get("reader_provider") == "bilicomics_document"
                and first.get("provider_available") is True and first.get("plugins_loaded") is False
                and first.get("runtime_initialized") is False and observed.get("actual_plugin_present") is True
                and observed.get("reader_integration_attached") is True and observed.get("filemanager_opened") is False
                and type(observed.get("visible_pixel")) in (int, float) and abs(observed["visible_pixel"] - 40) <= 2,
                "Production startup observations did not satisfy the reader contract")
    elif kind == "integration":
        evidence(report)
        rows(report, "runs", "name", ("online", "offline-reopen", "offline-smoke"))
    elif kind == "package":
        evidence(report)
        require(type(report.get("checks")) is list and len(report["checks"]) >= 10, "Package check matrix is missing")
        archive = directory / "bilicomics-0.1.0-dev.zip"
        manifest = read_json(archive.with_suffix(".manifest.json"))
        require(digest(archive) == manifest.get("sha256") == report.get("archive", {}).get("sha256"),
                "The produced package is not the verified archive")
    else:
        raise ValueError("Unknown evidence schema: " + kind)


@dataclass(frozen=True)
class Suite:
    name: str
    command: list
    report: str
    kind: str
    timeout: int = 180
    dependencies: tuple = ()
    direct: bool = False


def plan(args):
    suites = []
    python, source, runtime, output = sys.executable, args.source, args.runtime, args.output

    def script(name, relative, report, kind="evidence", extra=(), named=False, destination="output", timeout=180, dependencies=()):
        target = output / name / "data"
        command = [python, str(source / relative)]
        command += (["--runtime", str(runtime), "--source", str(source), "--" + destination, str(target)]
                    if named else [str(runtime), str(source), str(target)])
        suites.append(Suite(name, command + list(extra), report, kind, timeout, dependencies))

    def native(name, relative, report, extra=()):
        suites.append(Suite(name, [str(runtime / "luajit"), str(source / relative), str(source),
                                  str(output / name / "data"), *map(str, extra)], report, "evidence", direct=True))

    suites.append(Suite("package", [python, str(source / "spec/package/verify_package.py"), "--source", str(source),
                                   "--output", str(output / "package/data")], "result.json", "package"))
    suites.append(Suite("reader-native", [python, str(source / "spec/reader/run_native.py"), "--runtime", str(runtime),
        "--plugin", str(source), "--output", str(output / "reader-native/data"), "--pillow", str(args.pillow_root)],
        "results.json", "reader", 300))
    native("auth-protocol", "spec/protocol/auth_spec.lua", "auth-result.json")
    native("auth-crypto", "spec/protocol/auth_crypto_spec.lua", "auth-crypto-result.json")
    native("session-manager", "spec/controller/session_manager_spec.lua", "session-manager-result.json")
    script("session-controller", "spec/controller/run_session_authentication.py", "session-authentication-summary.json", "session")
    script("session-storage", "spec/controller/run_remote.py", "session-storage-result.json", extra=("--spec", "session_storage_spec.lua"))
    script("session-import", "spec/ui/run_session_import.py", "session-import-result.json", extra=("--width", "480", "--height", "640"))
    script("qr-ui-zh", "spec/ui/run_qr_login.py", "qr-login-verification.json", "qr")
    script("qr-ui-en", "spec/ui/run_qr_login.py", "qr-login-verification.json", "qr", extra=("--language", "C"))
    script("protocol-client", "spec/protocol/run_remote.py", "summary.json", "client")
    native("protocol-native-crypto", "spec/protocol/crypto_spec.lua", "crypto-result.json", (args.assets,))
    for name, filename, report in (
        ("controller", "controller_spec.lua", "controller-result.json"),
        ("controller-authentication", "authentication_spec.lua", "authentication-result.json"),
        ("controller-product", "product_features_spec.lua", "product-features-result.json"),
        ("controller-diagnostics", "diagnostics_native_spec.lua", "diagnostics-native-result.json"),
        ("controller-prefetch", "prefetch_spec.lua", "prefetch-result.json")):
        script(name, "spec/controller/run_remote.py", report, extra=("--spec", filename))
    script("purchase-dispatch", "spec/controller/run_purchase_dispatch.py", "purchase-dispatch-report.json", "purchase-dispatch")
    script("jobs", "spec/jobs/run_remote.py", "results.json", "jobs", named=True,
           extra=("--suites", ",".join(JOB_SUITES)), timeout=330)
    script("download-connectivity", "spec/jobs/run_download_connectivity.py", "results.json", "connectivity", named=True, destination="work", timeout=220)
    script("storage", "spec/storage/run_remote.py", "summary.json", "storage", extra=("--pillow-root", str(args.pillow_root)), timeout=600)
    script("storage-source-refresh", "spec/storage/run_source_refresh.py", "results.json", "storage-focused", named=True, destination="work")
    script("storage-version-replacement", "spec/storage/version_replacement_remote.py", "results.json", "storage-focused", named=True, destination="work")
    script("source-refresh-workflow", "spec/integration/run_source_refresh_workflow.py", "results.json", "source-workflow",
           named=True, destination="work", extra=("--assets", str(args.assets)), timeout=700)
    script("version-replacement-workflow", "spec/integration/run_version_replacement_workflow.py", "results.json", "version-workflow",
           named=True, destination="work", extra=("--assets", str(args.assets)), timeout=950)
    script("purchase-single", "spec/purchase/run_nonspending_regression.py", "results.json", "single-purchase", named=True, timeout=500)
    script("purchase-ordinal-range", "spec/purchase/run_ordinal_range.py", "results.json", "range", named=True)
    script("purchase-ordinal-transaction", "spec/purchase/run_ordinal_transaction.py", "results.json", "ordinal-purchase", named=True, timeout=550)
    archive = output / "package/data/bilicomics-0.1.0-dev.zip"
    suites.append(Suite("purchase-selection", [python, str(source / "spec/purchase/run_quote_selection.py"),
        "--runtime", str(runtime), "--archive", str(archive), "--manifest", str(archive.with_suffix(".manifest.json")),
        "--output", str(output / "purchase-selection/data")], "results.json", "selection", dependencies=("package",)))
    suites.append(Suite("reader-defaults", [python, str(source / "spec/reader/defaults_run.py"), "--runtime", str(runtime),
        "--plugin", str(source), "--output", str(output / "reader-defaults/data"), "--pillow", str(args.pillow_root)],
        "results.json", "defaults", 550))
    fixture = output / "reader-native/data/fixtures/page-1.png"
    for name, relative, report, kind in (
        ("startup-contract", "run_startup.py", "startup-results.json", "startup-contract"),
        ("startup-production", "run_production_startup.py", "production-startup-results.json", "startup-production"),
        ("startup-fallback", "run_fallback_startup.py", "fallback-results.json", "fallback")):
        suites.append(Suite(name, [python, str(source / "spec/reader" / relative), "--runtime", str(runtime),
            "--plugin", str(source), "--output", str(output / name / "data"), "--fixture", str(fixture)],
            report, kind, dependencies=("reader-native",)))
    script("reading-integration", "spec/integration/run_integration.py", "integration-results.json", "integration",
           named=True, destination="work", extra=("--fixture", str(fixture)), dependencies=("reader-native",))
    return suites


def namespace_child(arguments):
    marker, parent_net, parent_pid, *command = arguments
    network = os.readlink("/proc/self/ns/net")
    pid_namespace = os.readlink("/proc/self/ns/pid")
    require(os.getpid() == 1 and network != parent_net and pid_namespace != parent_pid,
            "The suite did not enter fresh network and PID namespaces")
    write_json(Path(marker), {"network_namespace_isolated": True, "pid_namespace_isolated": True,
        "namespace_init_pid": os.getpid(), "network_namespace": network, "pid_namespace": pid_namespace})
    os.execvpe(command[0], command, os.environ)


def stop_process_group(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def cancel_run(_signum, _frame):
    global CANCELLED
    CANCELLED = True
    for process in list(ACTIVE_PROCESSES.values()):
        stop_process_group(process)


def execute(suite, args):
    root = args.output / suite.name
    root.mkdir(mode=0o700)
    data = root / "data"
    if suite.direct:
        data.mkdir(mode=0o700)
    profile = root / "profile"
    profile.mkdir(mode=0o700)
    environment = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8", "TZ": "UTC",
        "HOME": str(profile), "KO_HOME": str(profile / "koreader"), "KO_MULTIUSER": "1",
        "SDL_AUDIODRIVER": "dummy", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(args.pillow_root),
        "PYTHONNOUSERSITE": "1", "SSH_CONNECTION": os.environ["SSH_CONNECTION"]}
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = profile / name.lower()
        directory.mkdir(mode=0o700)
        environment[name] = str(directory)
    Path(environment["KO_HOME"]).mkdir(mode=0o700)
    marker = root / "isolation.json"
    command = ["unshare", "--net", "--pid", "--fork", "--kill-child=KILL", "--mount-proc", "--",
        sys.executable, str(Path(__file__).resolve()), "--namespace-child", str(marker),
        os.readlink("/proc/self/ns/net"), os.readlink("/proc/self/ns/pid"), *suite.command]
    started = time.monotonic()
    result = {"suite": suite.name, "passed": False, "command": suite.command, "timeout_seconds": suite.timeout,
              "report": str((data / suite.report).relative_to(args.output)), "timed_out": False}
    process = None
    try:
        require(not CANCELLED, "The release regression was cancelled")
        with (root / "process.log").open("wb") as log:
            process = subprocess.Popen(command, cwd=args.runtime, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            ACTIVE_PROCESSES[process.pid] = process
            if CANCELLED:
                stop_process_group(process)
            try:
                result["returncode"] = process.wait(timeout=suite.timeout)
            except subprocess.TimeoutExpired:
                result["timed_out"] = True
                # Killing unshare also kills its PID-namespace init and every descendant,
                # including old drivers' workers that created separate process sessions.
                stop_process_group(process)
                result["returncode"] = process.wait(timeout=10)
        result["isolation"] = read_json(marker)
        require(result["returncode"] == 0 and not result["timed_out"], "The suite process did not finish successfully")
        report_path = data / suite.report
        validate(read_json(report_path), suite.kind, data)
        result["report_sha256"] = digest(report_path)
        result["passed"] = True
    except Exception:
        result["error"] = traceback.format_exc()
    finally:
        if process:
            stop_process_group(process)
            process.wait(timeout=10)
            ACTIVE_PROCESSES.pop(process.pid, None)
        result["cancelled"] = CANCELLED
        if CANCELLED:
            result["passed"] = False
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    write_json(root / "suite-result.json", result)
    print(json.dumps({"suite": suite.name, "passed": result["passed"], "elapsed_seconds": result["elapsed_seconds"]}), flush=True)
    return result


def run_matrix(suites, args):
    pending, complete, running = list(suites), {}, {}
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        while pending or running:
            for suite in list(pending):
                if len(running) >= args.jobs:
                    break
                if not CANCELLED and not all(name in complete for name in suite.dependencies):
                    continue
                pending.remove(suite)
                blocked = (["cancelled"] if CANCELLED else
                           [name for name in suite.dependencies if not complete[name]["passed"]])
                if blocked:
                    complete[suite.name] = {"suite": suite.name, "passed": False, "blocked_by": blocked}
                    directory = args.output / suite.name
                    directory.mkdir(mode=0o700)
                    write_json(directory / "suite-result.json", complete[suite.name])
                    print(json.dumps(complete[suite.name]), flush=True)
                else:
                    running[executor.submit(execute, suite, args)] = suite.name
            if running:
                finished, _ = wait(running, return_when=FIRST_COMPLETED)
                for future in finished:
                    name = running.pop(future)
                    complete[name] = future.result()
            else:
                require(not pending, "The suite dependency graph cannot make progress")
    return [complete[suite.name] for suite in suites]


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--namespace-child":
        namespace_child(sys.argv[2:])
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "source", "output", "pillow-root", "assets"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--base-commit", required=True, help="Full Git commit ID from which the frozen source snapshot was prepared")
    parser.add_argument("--revision", help="Optional review label; content identity is always the SHA256 snapshot manifest")
    parser.add_argument("--jobs", type=int, choices=(1, 2, 3), default=3)
    args = parser.parse_args()
    require(sys.platform == "linux" and os.environ.get("SSH_CONNECTION") and socket.gethostname().split(".")[0] == "test-env",
            "Execute only through ssh test-env; local verification is forbidden")
    require(re.fullmatch(r"[0-9a-fA-F]{40}", args.base_commit) is not None, "Use a full base commit ID")
    for name in ("runtime", "source", "pillow_root", "assets"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.output = args.output.resolve()
    require(args.source.is_relative_to(Path("/tmp")) and args.source != Path("/tmp"), "Use an isolated /tmp source snapshot")
    require(args.output.is_relative_to(Path("/tmp")) and args.output != Path("/tmp") and not args.output.exists(),
            "Use a fresh output directory under /tmp")
    for path in (args.source, args.runtime, args.pillow_root, args.assets):
        require(not args.output.is_relative_to(path) and not path.is_relative_to(args.output),
                "Output must be disjoint from every input directory")
    require(Path(__file__).resolve() == args.source / "spec/integration/run_release_regression.py", "Execute the runner from the same source snapshot")
    require((args.runtime / "git-rev").read_text().strip() == VERSION, "The pinned official KOReader runtime is required")
    require((args.pillow_root / "PIL/__init__.py").is_file(), "The existing isolated Pillow installation is required")
    for name, checksum in ASSETS.items():
        require(digest(args.assets / name) == checksum, "The public protocol asset does not match its pin")
    os.umask(0o077)
    args.output.mkdir(mode=0o700)
    initial = source_manifest(args.source)
    runtime_hashes = {name: digest(args.runtime / name) for name in ("git-rev", "luajit", "reader.lua", "libs/libsqlite3.so.0")}
    report = {"passed": False, "host": socket.gethostname(), "runtime_version": VERSION,
        "started_at": datetime.now(timezone.utc).isoformat(), "base_commit": args.base_commit.lower(),
        "base_commit_origin": "Caller-supplied snapshot provenance; SHA256 below identifies the actual tested content",
        "revision": args.revision, "source": str(args.source), "runtime": str(args.runtime), "max_parallel_suites": args.jobs,
        "runtime_sha256": runtime_hashes, "asset_sha256": ASSETS,
        "synthetic_credentials_only": True, "real_account_login_verified": False, "real_refresh_verified": False,
        "actual_purchases_permitted": False, "physical_device_verified": False, "excluded_acceptance": EXCLUSIONS,
        **initial, "suites": []}
    write_json(args.output / "release-regression.json", report)
    old_handlers = {number: signal.signal(number, cancel_run) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        suites = plan(args)
        report["planned_suites"] = [suite.name for suite in suites]
        report["suites"] = run_matrix(suites, args)
        report["source_unchanged"] = source_manifest(args.source) == initial
        report["runtime_unchanged"] = all(digest(args.runtime / name) == checksum for name, checksum in runtime_hashes.items())
        report["assets_unchanged"] = all(digest(args.assets / name) == checksum for name, checksum in ASSETS.items())
        report["network_namespace_isolated"] = all(item.get("isolation", {}).get("network_namespace_isolated") is True
                                                     for item in report["suites"])
        report["pid_namespace_isolated"] = all(item.get("isolation", {}).get("pid_namespace_isolated") is True
                                                 for item in report["suites"])
        report["passed"] = (len(report["suites"]) == len(suites) and report["source_unchanged"] and report["runtime_unchanged"]
                            and report["assets_unchanged"] and report["network_namespace_isolated"] and report["pid_namespace_isolated"]
                            and not CANCELLED and all(item["passed"] for item in report["suites"]))
    except Exception:
        report["error"] = traceback.format_exc()
    finally:
        report["cancelled"] = CANCELLED
        report["completed_at"] = datetime.now(timezone.utc).isoformat()
        write_json(args.output / "release-regression.json", report)
        for number, handler in old_handlers.items():
            signal.signal(number, handler)
    print(json.dumps({"passed": report["passed"], "suites": len(report["suites"]),
                      "snapshot_sha256": report["snapshot_sha256"], "report": str(args.output / "release-regression.json")}), flush=True)
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
