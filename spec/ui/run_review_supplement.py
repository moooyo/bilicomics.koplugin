"""Capture supplementary production UI widgets only on the remote Linux test host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

from run_bookshelf_grid import synthetic_covers


def main():
    if sys.platform != "linux":
        raise SystemExit("Execute only through ssh test-env.")
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {"scope": "Supplementary native screenshots with synthetic data and network isolation", "cases": []}
    source_names = ("main.lua", "bilicomics/runtime.lua", "bilicomics/ui/screens.lua", "bilicomics/ui/widgets.lua", "bilicomics/ui/model.lua",
                    "l10n/bilicomics_zh_CN.lua", "spec/ui/review_supplement.lua", "spec/ui/run_review_supplement.py")
    summary["sources"] = {name: hashlib.sha256((args.plugin / name).read_bytes()).hexdigest() for name in source_names}
    for width, height in ((600, 800), (480, 640)):
        output = args.output / f"zh_CN-{width}x{height}"
        output.mkdir()
        synthetic_covers(output / "fixtures")
        environment = os.environ.copy()
        for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            directory = output / name.lower()
            directory.mkdir()
            environment[name] = str(directory)
        environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": str(width), "EMULATE_READER_H": str(height),
                            "SDL_AUDIODRIVER": "dummy"})
        process = subprocess.Popen(
            ["unshare", "--net", "xvfb-run", "-a", str(args.runtime / "luajit"),
             str(args.plugin / "spec/ui/review_supplement.lua"), str(args.plugin), str(output), "zh_CN"],
            cwd=args.runtime, env=environment, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            stderr += "\nThe supplementary capture exceeded its time limit.\n"
        (output / "review-supplement.log").write_text(stdout + stderr, encoding="utf-8")
        result_path = output / "review-supplement-result.json"
        result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.is_file() else {}
        case = {"width": width, "height": height, "language": "zh_CN", "returncode": process.returncode,
                "passed": process.returncode == 0 and result.get("passed") is True,
                "screenshots": len(result.get("screenshots", [])), "error": result.get("error"),
                "layout_flags": [frame for frame in result.get("frames", [])
                                 if not frame.get("content_fits", True) or not frame.get("dialog_fits", True)]}
        summary["cases"].append(case)
        print(json.dumps(case))
        if not result:
            print(stdout + stderr)
    summary["passed"] = all(case["passed"] for case in summary["cases"])
    (args.output / "review-supplement-verification.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
