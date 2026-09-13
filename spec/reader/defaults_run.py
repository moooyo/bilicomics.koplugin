"""Run chapter default contracts only on the authorized remote Linux host."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on the authorized remote verification host")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pillow", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.pillow))
    from PIL import Image

    cases = [
        ("auto_strip", 2400, ["open", "reopen"]),
        ("auto_page", 800, ["open"]),
        ("forced_page", 2400, ["open"]),
        ("forced_strip", 800, ["open"]),
        ("saved_native", 2400, ["open"]),
        ("legacy_anchor", 2400, ["open", "reopen"]),
        ("anchor_only", 2400, ["open"]),
        ("stale_free_anchor", 2400, ["open"]),
        ("changed_native", 2400, ["open", "reopen"]),
        ("rtl_mirrored", 2400, ["open"]),
        ("ltr_mirrored", 2400, ["open"]),
        ("rtl_pan", 800, ["open", "reopen"]),
        ("free_pan", 2400, ["open", "reopen"]),
    ]
    args.output.mkdir(parents=True, exist_ok=True)
    summary = {"version": (args.runtime / "git-rev").read_text().strip(),
               "scope": "Official Linux ReaderUI with production main hooks and synthetic account services", "runs": []}
    for case, height, phases in cases:
        folder = args.output / case
        folder.mkdir(exist_ok=True)
        pages = []
        for index in range(1, 4):
            path = folder / f"page-{index}.png"
            width = 1800 if case == "rtl_pan" else 600
            Image.new("RGB", (width, height), (index * 60,) * 3).save(path)
            pages.append({"id": f"p{index}", "index": index, "width": width, "height": height,
                          "episode_id": "episode", "revision": "r1", "state": "ready", "path": str(path),
                          "content_generation": 1, "geometry_generation": 1})
        (folder / "pages.json").write_text(json.dumps(pages))
        descriptor = {"schema_version": 1, "account_key": "test", "comic_id": "comic",
                      "episode_id": "episode", "revision": "r1",
                      "pages": [{key: page[key] for key in ("id", "index", "width", "height")} for page in pages]}
        (folder / "chapter.bcomic").write_text(json.dumps(descriptor))
        env = os.environ.copy()
        for kind in ("DATA", "CONFIG", "CACHE"):
            path = folder / f"xdg-{kind.lower()}"
            path.mkdir(exist_ok=True)
            env[f"XDG_{kind}_HOME"] = str(path)
        env.update(KO_MULTIUSER="1", EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
        for phase in phases:
            completed = subprocess.run(["xvfb-run", "-a", str(args.runtime / "luajit"),
                                        str(args.plugin / "spec/reader/defaults_spec.lua"),
                                        str(args.plugin), str(folder), case, phase],
                                       cwd=args.runtime, env=env, capture_output=True, text=True, timeout=25)
            (folder / f"{phase}.log").write_text(completed.stdout + completed.stderr)
            result_path = folder / f"{phase}-results.json"
            result = json.loads(result_path.read_text()) if result_path.exists() else {}
            summary["runs"].append({"case": case, "phase": phase, "returncode": completed.returncode, "result": result})
            print(case, phase, completed.returncode, len(result.get("assertions", [])), flush=True)
            if completed.returncode:
                print((completed.stdout + completed.stderr)[-7000:])
                (args.output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
                return 1
    (args.output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
