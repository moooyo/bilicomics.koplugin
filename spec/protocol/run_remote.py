"""Run the protocol contract checks within an isolated remote KOReader runtime."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--native-assets", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    for suffix, mode in (("jpg", "RGB"), ("png", "RGB"), ("webp", "RGB")):
        Image.new(mode, (24, 37), color=(45, 120, 90)).save(args.output / ("fixture." + suffix))
    (args.output / "truncated.png").write_bytes((args.output / "fixture.png").read_bytes()[:-8])
    corrupt = bytearray((args.output / "fixture.png").read_bytes())
    corrupt[50] ^= 1
    (args.output / "corrupt.png").write_bytes(corrupt)
    env = os.environ.copy()
    env["KO_MULTIUSER"] = "1"
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        target = args.output / name.lower()
        target.mkdir()
        env[name] = str(target)
    completed = subprocess.run([
        str(args.runtime / "luajit"), str(args.source / "spec/protocol/client_spec.lua"),
        str(args.source), str(args.output),
    ], cwd=args.runtime, env=env, capture_output=True, text=True, timeout=60)
    (args.output / "client.log").write_text(completed.stdout + completed.stderr)
    result_file = args.output / "client-result.json"
    report = {
        "runtime": str(args.runtime), "returncode": completed.returncode,
        "result": json.loads(result_file.read_text()) if result_file.exists() else None,
        "session_mode": oct((args.output / "session.dat").stat().st_mode & 0o777) if (args.output / "session.dat").exists() else None,
    }
    if completed.returncode:
        report["error"] = (completed.stdout + completed.stderr)[-6000:]
    if not completed.returncode and args.native_assets:
        native = subprocess.run([
            str(args.runtime / "luajit"), str(args.source / "spec/protocol/crypto_spec.lua"),
            str(args.source), str(args.output), str(args.native_assets),
        ], cwd=args.runtime, env=env, capture_output=True, text=True, timeout=60)
        (args.output / "crypto.log").write_text(native.stdout + native.stderr)
        crypto_result = args.output / "crypto-result.json"
        report["native_crypto"] = {
            "returncode": native.returncode,
            "result": json.loads(crypto_result.read_text()) if crypto_result.exists() else None,
        }
        if native.returncode:
            report["native_crypto"]["error"] = (native.stdout + native.stderr)[-6000:]
            completed = native
        elif (args.source / "research/protocol/image-legacy-fixtures.json").exists():
            acquisition = subprocess.run([
                str(args.runtime / "luajit"), str(args.source / "spec/protocol/acquisition_spec.lua"),
                str(args.source), str(args.output),
            ], cwd=args.runtime, env=env, capture_output=True, text=True, timeout=120)
            (args.output / "acquisition.log").write_text(acquisition.stdout + acquisition.stderr)
            acquisition_result = args.output / "acquisition-result.json"
            report["acquisition"] = {
                "returncode": acquisition.returncode,
                "result": json.loads(acquisition_result.read_text()) if acquisition_result.exists() else None,
            }
            if acquisition.returncode:
                report["acquisition"]["error"] = (acquisition.stdout + acquisition.stderr)[-6000:]
                completed = acquisition
    (args.output / "summary.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    raise SystemExit(completed.returncode or (0 if report["session_mode"] == "0o600" else 1))


if __name__ == "__main__":
    main()
