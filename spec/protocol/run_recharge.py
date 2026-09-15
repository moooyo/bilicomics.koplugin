"""Run the isolated synthetic recharge protocol specification on test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


SOURCES = (
    "bilicomics/protocol/recharge.lua",
    "bilicomics/protocol/client.lua",
    "bilicomics/protocol/json.lua",
    "spec/protocol/recharge_spec.lua",
)


def source_hashes(plugin):
    return {name: hashlib.sha256((plugin / name).read_bytes()).hexdigest() for name in SOURCES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Run only through ssh test-env; local verification is not authorized.")
    runtime, plugin, output = (path.resolve() for path in (args.runtime, args.plugin, args.output))
    if not (runtime / "luajit").is_file():
        parser.error("The official KOReader LuaJIT runtime is required.")
    output.mkdir(parents=True, exist_ok=False)
    before = source_hashes(plugin)
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update(KO_MULTIUSER="1", SDL_AUDIODRIVER="dummy")
    command = ["unshare", "--net", "--", "xvfb-run", "-a", str(runtime / "luajit"),
        str(plugin / "spec/protocol/recharge_spec.lua"), str(plugin), str(output)]
    process = subprocess.Popen(command, cwd=runtime, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
    (output / "recharge.log").write_text(stdout + stderr, encoding="utf-8")
    result_path = output / "recharge-result.json"
    result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.is_file() else {}
    after = source_hashes(plugin)
    report = {"environment": "ssh test-env, unshare --net", "returncode": process.returncode,
        "timed_out": timed_out, "source_sha256": before, "source_sha256_after": after,
        "source_unchanged": before == after, "result": result}
    report["passed"] = process.returncode == 0 and not timed_out and before == after and result.get("passed") is True
    (output / "recharge-verification.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "count": result.get("count", 0), "output": str(output)}))
    if not report["passed"]:
        print((stdout + stderr)[-8000:])
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
