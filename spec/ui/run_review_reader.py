"""Capture synthetic native reader screens only through ssh test-env."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.platform != "linux":
        raise SystemExit("Execute only through ssh test-env.")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pillow", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.pillow))
    from PIL import Image, ImageDraw, ImageFont
    args.output.mkdir(parents=True, exist_ok=False)
    runs = []
    for width, height in ((600, 800), (480, 640)):
        output = args.output / f"{width}x{height}"
        fixtures = output / "fixtures"
        fixtures.mkdir(parents=True)
        records = []
        for index, page_height in enumerate((900, 2100, 900), 1):
            page = Image.new("RGB", (600, page_height), "white")
            draw = ImageDraw.Draw(page)
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 20)
            draw.text((28, 18), "SYNTHETIC REVIEW PAGE / ORIGINAL PANELS", fill="black", font=font)
            panels = 3 if page_height == 900 else 7
            for panel in range(panels):
                top = 66 + panel * 285
                draw.rectangle((25, top, 575, top + 262), fill=245 - panel % 3 * 15, outline="black", width=4)
                draw.ellipse((465, top + 20, 515, top + 70), fill="white", outline="black", width=3)
                draw.polygon([(30, top + 240), (180, top + 85), (320, top + 238)], fill=170, outline="black", width=3)
                draw.polygon([(205, top + 246), (385, top + 100), (570, top + 246)], fill=208, outline="black", width=3)
                draw.text((43, top + 24), f"PAGE {index} / PANEL {panel + 1}", fill="black", font=font)
            path = fixtures / f"page-{index}.png"
            page.save(path)
            records.append({"key": f"episode/review/{index}", "id": f"page-{index}", "index": index,
                            "episode_id": "episode", "revision": "review", "state": "ready" if index < 3 else "missing",
                            "path": str(path) if index < 3 else None, "width": 600, "height": page_height,
                            "format": "png", "content_generation": 1, "geometry_generation": 1,
                            "geometry": {"source_width": 600, "source_height": page_height, "exif_orientation": 1}})
        descriptor = {"schema_version": 1, "account_key": "review", "comic_id": "comic", "episode_id": "episode",
                      "revision": "review", "pages": [{key: page[key] for key in ("id", "index", "width", "height")} for page in records]}
        (output / "pages.json").write_text(json.dumps(records))
        (output / "chapter.bcomic").write_text(json.dumps(descriptor))
        environment = os.environ.copy()
        for kind in ("DATA", "CONFIG", "CACHE"):
            directory = output / f"xdg-{kind.lower()}"
            directory.mkdir()
            environment[f"XDG_{kind}_HOME"] = str(directory)
        environment.update(KO_MULTIUSER="1", EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), SDL_AUDIODRIVER="dummy")
        completed = subprocess.run(["unshare", "-n", "--", "xvfb-run", "-a", str(args.runtime / "luajit"),
                                    str(args.plugin / "spec/ui/review_reader.lua"), str(args.plugin), str(output)],
                                   cwd=args.runtime, env=environment, capture_output=True, text=True, timeout=45)
        (output / "review-reader.log").write_text(completed.stdout + completed.stderr)
        runs.append({"width": width, "height": height, "returncode": completed.returncode,
                     "screens": len(list(output.glob("reader-*.png")))})
        print(json.dumps(runs[-1]), flush=True)
        if completed.returncode:
            print((completed.stdout + completed.stderr)[-5000:])
    summary = {"runs": runs, "passed": all(run["returncode"] == 0 for run in runs)}
    (args.output / "review-reader-verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    return int(not summary["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
