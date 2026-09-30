"""Exercise shared widgets in an isolated, authorized native KOReader runtime."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=1860)
    parser.add_argument("--height", type=int, default=2480)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = args.output / f"xdg-{kind.lower()}"
        directory.mkdir(exist_ok=True)
        environment[f"XDG_{kind}_HOME"] = str(directory)
    environment.update(KO_MULTIUSER="1", EMULATE_READER_W=str(args.width),
                       EMULATE_READER_H=str(args.height), SDL_AUDIODRIVER="dummy")
    completed = subprocess.run(
        ["xvfb-run", "-a", str(args.runtime / "luajit"),
         str(args.plugin / "spec/ui/widget_layout_spec.lua"), str(args.plugin), str(args.output)],
        cwd=args.runtime, env=environment, text=True, capture_output=True, timeout=60,
    )
    (args.output / "native.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode:
        print((completed.stdout + completed.stderr)[-8000:])
        return completed.returncode
    result_path = args.output / "widget-layout-results.json"
    if not result_path.is_file():
        raise RuntimeError("The native run did not produce its verification report")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    assertions = result.get("assertions", [])
    failures = [item["name"] for item in assertions if not item["passed"]]
    print(json.dumps({"assertions": len(assertions), "failures": failures,
                      "output": str(args.output)}, ensure_ascii=False))
    if failures or not assertions:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
