"""Run synthetic native QR sign-in checks only on the remote Linux test host."""
import argparse
import hashlib
from run_ui_sources import ui_source_names
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def main():
    if sys.platform != "linux":
        raise SystemExit("Execute only through ssh test-env.")
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--language", choices=("zh_CN", "C"), default="zh_CN")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {"scope": "Synthetic native QR UI only; no real session or HTTP", "language": args.language, "cases": []}
    summary["sources"] = {
        name: hashlib.sha256((args.plugin / name).read_bytes()).hexdigest()
        for name in ui_source_names(args.plugin)
    }
    for width, height in ((480, 640), (600, 800)):
        output = args.output / f"{width}x{height}"
        output.mkdir()
        environment = os.environ.copy()
        for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            directory = output / name.lower()
            directory.mkdir()
            environment[name] = str(directory)
        environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": str(width),
                            "EMULATE_READER_H": str(height), "SDL_AUDIODRIVER": "dummy"})
        process = subprocess.Popen(
            ["unshare", "--net", "xvfb-run", "-a", str(args.runtime / "luajit"),
             str(args.plugin / "spec/ui/qr_login_spec.lua"), str(args.plugin), str(output), args.language],
            cwd=args.runtime, env=environment, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated QR login check exceeded its time limit.\n"
        (output / "qr-login.log").write_text(stdout + stderr, encoding="utf-8")
        print(stdout + stderr)
        result_path = output / "qr-login-result.json"
        result = json.loads(result_path.read_text()) if result_path.is_file() else {}
        summary["cases"].append({"width": width, "height": height, "returncode": process.returncode,
                                  "passed": process.returncode == 0 and result.get("passed") is True,
                                  "assertions": len(result.get("assertions", []))})
    summary["passed"] = all(case["passed"] for case in summary["cases"])
    (args.output / "qr-login-verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
