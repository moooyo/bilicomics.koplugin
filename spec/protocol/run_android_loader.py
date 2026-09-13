"""Verify Android staging defenses using real remote filesystem operations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env["KO_MULTIUSER"] = "1"
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = args.output / name.lower()
        path.mkdir()
        env[name] = str(path)
    command = [str(args.runtime / "luajit"), str(args.source / "spec/protocol/android_loader_spec.lua"),
               str(args.source), str(args.output)]
    completed = subprocess.run(command, cwd=args.runtime, env=env, capture_output=True, text=True, timeout=60)
    (args.output / "staging.log").write_text(completed.stdout + completed.stderr)
    if completed.returncode:
        print(completed.stdout + completed.stderr)
        raise SystemExit(completed.returncode)
    # Use the verified Linux binary to exercise a real dlopen in each process.
    # Android's actual linker and namespace are tested in the APK, not emulated.
    source = args.source / "bilicomics/protocol/native/bin/linux-x86_64/libbiliwasm.so"
    module = args.output / "race/protocol"
    binary = module / "native/bin/android-x86_64/libbiliwasm.so"
    binary.parent.mkdir(parents=True)
    shutil.copyfile(source, binary)
    content = binary.read_bytes()
    manifest = {"libraries": {"android-x86_64": {
        "path": "bin/android-x86_64/libbiliwasm.so", "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }}}
    (module / "native/manifest.json").write_text(json.dumps(manifest))
    private = args.output / "race/private"
    private.mkdir(mode=0o700)
    race = args.output / "race"
    workers = []
    logs = []
    try:
        for index in (1, 2):
            log = open(race / f"worker-{index}.log", "w")
            logs.append(log)
            workers.append(subprocess.Popen([
                str(args.runtime / "luajit"), str(args.source / "spec/protocol/android_loader_race.lua"),
                str(args.source), str(module), str(private), str(race), str(index),
            ], cwd=args.runtime, env=env, stdout=log, stderr=subprocess.STDOUT))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if all((race / f"ready-{index}").exists() for index in (1, 2)):
                break
            if any(worker.poll() is not None for worker in workers):
                raise RuntimeError("A race worker exited before the start barrier")
            time.sleep(0.01)
        else:
            raise RuntimeError("The concurrent source-open barrier timed out")
        (race / "start").write_text("start")
        codes = [worker.wait(timeout=20) for worker in workers]
        assert codes == [0, 0], f"Concurrent workers failed: {codes}"
        results = [json.loads((race / f"worker-{index}.json").read_text()) for index in (1, 2)]
        assert all(result["loaded"] for result in results)
        assert len(list(race.glob("published-*"))) == 1, "Both workers published instead of reusing the winner"
        assert not list(private.rglob(".part-*")), "Concurrent initialization left staging files"
        assert results[0]["detail"]["path"] == results[1]["detail"]["path"]
        assert hashlib.sha256(Path(results[0]["detail"]["path"]).read_bytes()).hexdigest() == manifest["libraries"]["android-x86_64"]["sha256"]
        summary = {
            "staging": json.loads((args.output / "android-loader-result.json").read_text()),
            "concurrency": {"processes": 2, "post_rename_delay_ms": 700, "both_loaded": True,
                            "published_files": 1, "temporary_files": 0},
        }
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.terminate()
                worker.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == "__main__":
    main()
