"""Audit every reader handoff state in an authorized isolated native runtime."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from run_scribe_handoff import isolation_prefix, screen_size


def sources(plugin):
    names = ("bilicomics/controller.lua", "bilicomics/reader/document.lua",
             "bilicomics/reader/integration.lua", "bilicomics/ui/widgets.lua",
             "bilicomics/ui/model.lua", "l10n/bilicomics_zh_CN.lua",
             "spec/ui/all_pages_reader_spec.lua", "spec/ui/run_all_pages_reader.py")
    return {name: hashlib.sha256((plugin / name).read_bytes()).hexdigest() for name in names}


def fixtures(output):
    from PIL import Image, ImageDraw
    directory = output / "fixtures"
    directory.mkdir()
    path = directory / "original-page.png"
    page = Image.new("L", (600, 900), 255)
    drawing = ImageDraw.Draw(page)
    for top in (28, 320, 612):
        drawing.rectangle((25, top, 575, top + 260), fill=238, outline=17, width=3)
        drawing.polygon(((35, top + 240), (185, top + 70), (335, top + 240)), fill=153)
        drawing.polygon(((245, top + 240), (395, top + 95), (560, top + 240)), fill=204)
        drawing.ellipse((440, top + 25, 495, top + 80), fill=255, outline=17, width=2)
    page.save(path)
    records = [{"key": f"12/review/{index}", "id": f"image-{index}", "index": index,
                "episode_id": "12", "revision": "review", "state": "missing" if index == 9 else "ready",
                "path": None if index == 9 else str(path), "width": 600, "height": 900,
                "format": "png", "content_generation": 1, "geometry_generation": 1,
                "geometry": {"source_width": 600, "source_height": 900, "exif_orientation": 1}}
               for index in range(1, 25)]
    descriptor = {"schema_version": 1, "account_key": "review", "comic_id": "comic",
                  "episode_id": "12", "revision": "review", "pages": [
                      {key: item[key] for key in ("id", "index", "width", "height")} for item in records]}
    (output / "pages.json").write_text(json.dumps(records), encoding="utf-8")
    (output / "chapter.bcomic").write_text(json.dumps(descriptor), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--sizes", nargs="+", type=screen_size,
                        default=[(1860, 2480), (480, 640), (600, 800), (960, 720)])
    parser.add_argument("--languages", nargs="+", choices=("zh_CN", "C"), default=["zh_CN", "C"])
    parser.add_argument("--pillow", type=Path,
                        default=Path.home() / ".local/share/bilicomics-acceptance/python-deps-pillow-11.3.0")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Use the authorized Linux or WSL native runtime.")
    runtime, plugin, output = (value.resolve() for value in (args.runtime, args.plugin, args.output))
    if output.is_relative_to(plugin):
        parser.error("Keep native artifacts outside the repository.")
    sys.path.insert(0, str(args.pillow))
    prefix = isolation_prefix()
    output.mkdir(parents=True, exist_ok=False)
    before = sources(plugin)
    report = {"scope": "J1-J5 and all existing reader error destinations in native ReaderUI",
              "real_account_used": False, "network_isolation": prefix, "source_sha256": before,
              "runtime_version": (runtime / "git-rev").read_text().strip(),
              "runtime_luajit_sha256": hashlib.sha256((runtime / "luajit").read_bytes()).hexdigest(),
              "environment": "User-authorized local WSL or designated Linux native verification host",
              "started_at": datetime.now(timezone.utc).isoformat(), "cases": []}
    for language in args.languages:
        for width, height in args.sizes:
            case = output / f"{language}-{width}x{height}"
            case.mkdir()
            fixtures(case)
            environment = os.environ.copy()
            for name in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME"):
                directory = case / name.lower()
                directory.mkdir()
                environment[name] = str(directory)
            for name in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
                environment.pop(name, None)
            environment.update(KO_MULTIUSER="1", EMULATE_READER_W=str(width),
                               EMULATE_READER_H=str(height), SDL_AUDIODRIVER="dummy")
            completed = subprocess.run(
                [*prefix, "xvfb-run", "-a", "-s", f"-screen 0 {width}x{height}x24",
                 str(runtime / "luajit"), str(plugin / "spec/ui/all_pages_reader_spec.lua"),
                 str(plugin), str(case), language], cwd=runtime, env=environment,
                text=True, capture_output=True, timeout=60)
            (case / "native.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
            path = case / "all-pages-reader-result.json"
            result = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
            item = {"width": width, "height": height, "language": language,
                    "returncode": completed.returncode, "passed": completed.returncode == 0 and result.get("passed") is True,
                    "assertion_count": len(result.get("assertions", [])),
                    "screenshots": result.get("screenshots", []),
                    "failures": [check for check in result.get("assertions", []) if not check["passed"]],
                    "error": result.get("error"), "result": f"{case.name}/{path.name}"}
            report["cases"].append(item)
            print(json.dumps(item), flush=True)
            if completed.returncode:
                print((completed.stdout + completed.stderr)[-6000:], flush=True)
    report["source_sha256_after"] = sources(plugin)
    report["source_unchanged"] = report["source_sha256_after"] == before
    report["passed"] = report["source_unchanged"] and all(item["passed"] for item in report["cases"])
    report["completed_at"] = datetime.now(timezone.utc).isoformat()
    (output / "all-pages-reader-verification.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
