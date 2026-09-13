"""Run synthetic QR and private-session checks only on the authorized remote host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if os.name != "posix" or not str(args.source.resolve()).startswith("/tmp/"):
        raise RuntimeError("Run only in an isolated /tmp workspace on authorized test-env")
    args.output.mkdir(parents=True, exist_ok=False)
    suites = [
        ("spec/protocol/session_refresh_spec.lua", "session-refresh-result.json", False),
        ("spec/controller/qr_authentication_spec.lua", "qr-authentication-result.json", True),
    ]
    results = []
    for suite, result_name, display in suites:
        directory = args.output / Path(suite).stem
        directory.mkdir()
        environment = os.environ.copy()
        for variable in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            target = directory / variable.lower()
            target.mkdir()
            environment[variable] = str(target)
        environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
        command = [str(args.runtime / "luajit"), str(args.source / suite), str(args.source), str(directory)]
        if display:
            command = ["xvfb-run", "-a", *command]
        process = subprocess.Popen(command, cwd=args.runtime, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated verification exceeded its time limit.\n"
        (directory / "suite.log").write_text(stdout + stderr)
        result_path = directory / result_name
        result = json.loads(result_path.read_text()) if result_path.exists() else None
        results.append({"suite": suite, "returncode": process.returncode, "result": result,
                        "error": (stdout + stderr)[-5000:] if process.returncode else None})
    source_hashes = {}
    paths = [
        "bilicomics/controller.lua", "bilicomics/protocol/session.lua", "bilicomics/session_storage.lua",
        "bilicomics/protocol/client.lua", "bilicomics/protocol/errors.lua", "bilicomics/util.lua",
        "bilicomics/session_manager.lua", "bilicomics/jobs/session_runner.lua", "bilicomics/jobs/worker.lua",
        "bilicomics/jobs/runner.lua", "bilicomics/storage/codec.lua", "spec/controller/run_session_authentication.py",
        *[suite for suite, _, _ in suites],
    ]
    for relative in paths:
        source_hashes[relative] = hashlib.sha256((args.source / relative).read_bytes()).hexdigest()
    report = {"passed": all(item["returncode"] == 0 and item["result"] and item["result"]["passed"] for item in results),
              "host": socket.gethostname(), "runtime": str(args.runtime), "source_sha256": source_hashes,
              "synthetic_credentials_only": True, "real_network_requests": 0, "results": results}
    (args.output / "session-authentication-summary.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
