"""Run the integrated authentication regression only in a remote test-env snapshot."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if sys.platform != "linux" or not str(args.source.resolve()).startswith("/tmp/"):
        raise SystemExit("Run only through ssh test-env in an isolated /tmp source snapshot.")
    args.output.mkdir(parents=True, exist_ok=False)
    source, runtime, output = args.source.resolve(), args.runtime.resolve(), args.output.resolve()
    production = sorted((source / "bilicomics").rglob("*.lua")) + sorted((source / "l10n").rglob("*.lua"))
    production += [source / "main.lua", source / "_meta.lua"]
    hashes = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest() for path in production}
    python = sys.executable
    suites = []

    def add_script(name, script, result, extra=()):
        destination = output / name
        suites.append((name, [python, str(source / script), str(runtime), str(source), str(destination), *extra],
                       destination / result, False))

    def add_lua(name, script, result):
        destination = output / name
        suites.append((name, [str(runtime / "luajit"), str(source / script), str(source), str(destination)],
                       destination / result, True))

    add_lua("auth-protocol", "spec/protocol/auth_spec.lua", "auth-result.json")
    add_lua("auth-crypto", "spec/protocol/auth_crypto_spec.lua", "auth-crypto-result.json")
    add_lua("session-manager", "spec/controller/session_manager_spec.lua", "session-manager-result.json")
    add_script("session-controller", "spec/controller/run_session_authentication.py", "session-authentication-summary.json")
    add_script("session-storage", "spec/controller/run_remote.py", "session-storage-result.json", ("--spec", "session_storage_spec.lua"))
    add_script("session-import", "spec/ui/run_session_import.py", "session-import-result.json", ("--width", "480", "--height", "640"))
    add_script("qr-ui-zh", "spec/ui/run_qr_login.py", "qr-login-verification.json")
    add_script("qr-ui-en", "spec/ui/run_qr_login.py", "qr-login-verification.json", ("--language", "C"))
    add_script("client", "spec/protocol/run_remote.py", "summary.json")
    destination = output / "workers"
    suites.append(("workers", [python, str(source / "spec/jobs/run_remote.py"), "--runtime", str(runtime),
                  "--source", str(source), "--output", str(destination), "--suites", "runner,budget,extensions"],
                   destination / "results.json", False))

    def execute(suite):
        name, command, result_file, direct = suite
        if direct:
            result_file.parent.mkdir()
        environment = os.environ.copy()
        profile = output / (name + "-profile")
        for variable in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            directory = profile / variable.lower()
            directory.mkdir(parents=True)
            environment[variable] = str(directory)
        environment.update({"KO_MULTIUSER": "1", "SDL_AUDIODRIVER": "dummy"})
        process = subprocess.Popen(["unshare", "--net", *command], cwd=runtime, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   encoding="utf-8", errors="replace", start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=150)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        (output / (name + ".log")).write_text(stdout + stderr, encoding="utf-8")
        result = json.loads(result_file.read_text()) if result_file.exists() else None
        passed = process.returncode == 0 and not timed_out
        print(json.dumps({"suite": name, "passed": passed}), flush=True)
        return {"suite": name, "passed": passed, "returncode": process.returncode, "timed_out": timed_out,
                "result": result, "error": (stdout + stderr)[-5000:] if not passed else None}

    with ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(execute, suites))
    unchanged = all(hashlib.sha256((source / path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
    report = {"passed": unchanged and all(item["passed"] for item in results), "source_unchanged": unchanged,
              "host": "test-env", "runtime_version": (runtime / "git-rev").read_text().strip(),
              "completed_at": datetime.now(timezone.utc).isoformat(), "network_namespace_isolated": True,
              "synthetic_credentials_only": True, "real_account_login_verified": False,
              "real_refresh_verified": False, "source_sha256": hashes, "suites": results}
    (output / "authentication-regression.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "suites": len(results)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
