"""Generate synthetic assets and exercise the provider in an authorized runtime."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run inside the authorized Linux verification runtime")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pillow", type=Path, required=True)
    parser.add_argument("--modes", default="render,ui,ui-reopen,page,page-reopen,pan,pan-reopen,ui-online,thumbnail")
    args = parser.parse_args()
    sys.path.insert(0, str(args.pillow))
    from PIL import Image, ImageDraw

    args.output.mkdir(parents=True, exist_ok=True)
    fixture_dir = args.output / "fixtures"
    fixture_dir.mkdir(exist_ok=True)
    records = []

    def asset(name, width, height, fmt="png", dpi=(72, 72), orientation=1, quadrants=False):
        image = Image.new("RGB", (width, height))
        draw = ImageDraw.Draw(image)
        for index, value in enumerate([40, 100, 160, 220]):
            if quadrants:
                x, y = index % 2, index // 2
                box = (x * width // 2, y * height // 2, (x + 1) * width // 2 - 1, (y + 1) * height // 2 - 1)
            else:
                box = (0, index * height // 4, width - 1, (index + 1) * height // 4 - 1)
            draw.rectangle(box, fill=(value, value, value))
        path = fixture_dir / f"{name}.{fmt}"
        opts = {"dpi": dpi}
        exif = Image.Exif()
        exif[274] = orientation
        if fmt == "jpg":
            opts.update(quality=98, subsampling=0, exif=exif)
        elif orientation != 1:
            opts["exif"] = exif
        if fmt == "webp":
            opts = {"lossless": True, "exif": exif}
        image.save(path, **opts)
        logical_w, logical_h = (height, width) if orientation >= 5 else (width, height)
        index = len(records) + 1
        records.append({"key": f"episode/r1/{index}", "id": name, "index": index,
                        "episode_id": "episode", "revision": "r1", "state": "ready", "path": str(path),
                        "width": logical_w, "height": logical_h, "format": fmt,
                        "content_generation": 1, "geometry_generation": 1,
                        "geometry": {"source_width": width, "source_height": height,
                                     "exif_orientation": orientation}})

    asset("page-1", 600, 2400)
    asset("page-2", 600, 1600)
    image = Image.new("RGB", (600, 1600), (60, 60, 60))
    ImageDraw.Draw(image).rectangle((0, 800, 599, 1599), fill=(180, 180, 180))
    image.save(fixture_dir / "page-2.png")
    records[1]["state"] = "missing"
    records[1]["path"] = None
    asset("jpeg-300", 360, 1200, "jpg", (300, 300))
    asset("png-300", 360, 1200, "png", (300, 300))
    asset("png-anisotropic", 360, 1200, "png", (72, 144))
    asset("jpeg-anisotropic", 360, 1200, "jpg", (72, 144))
    asset("webp", 360, 1200, "webp")
    for orientation in range(1, 9):
        asset(f"exif-{orientation}", 120, 240, "jpg", orientation=orientation, quadrants=True)
    asset("oversized", 120, 240)
    records[-1].update(width=1200, height=16000, geometry={"source_width": 1200, "source_height": 16000})
    asset("corrupt", 600, 1600)
    Path(records[-1]["path"]).write_bytes(b"invalid synthetic image")
    for fmt in ("png", "webp"):
        for orientation in range(1, 9):
            asset(f"{fmt}-exif-{orientation}", 120, 240, fmt, orientation=orientation, quadrants=True)
    descriptor = {"schema_version": 1, "account_key": "test", "comic_id": "comic",
                  "episode_id": "episode", "revision": "r1",
                  "pages": [{key: page[key] for key in ("id", "index", "width", "height")} for page in records]}
    (args.output / "chapter.bcomic").write_text(json.dumps(descriptor))
    (args.output / "pages.json").write_text(json.dumps(records))
    env = os.environ.copy()
    for kind in ("DATA", "CONFIG", "CACHE"):
        path = args.output / f"xdg-{kind.lower()}"
        path.mkdir(exist_ok=True)
        env[f"XDG_{kind}_HOME"] = str(path)
    env.update(KO_MULTIUSER="1", EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
    summary = {"runtime": str(args.runtime), "version": (args.runtime / "git-rev").read_text().strip(),
               "scope": "Synthetic local provider tests, no Bilibili network, no physical device", "runs": []}
    for mode in args.modes.split(","):
        if mode in ("ui", "page", "pan", "ui-online", "thumbnail"):
            anchor = args.output / "anchor.json"
            if anchor.exists():
                anchor.unlink()
        completed = subprocess.run(["xvfb-run", "-a", str(args.runtime / "luajit"),
                                    str(args.plugin / "spec/reader/native_spec.lua"),
                                    str(args.plugin), str(args.output), mode],
                                   cwd=args.runtime, env=env, text=True, capture_output=True, timeout=25)
        (args.output / f"{mode}.log").write_text(completed.stdout + completed.stderr)
        path = args.output / f"{mode}-results.json"
        result = json.loads(path.read_text()) if path.exists() else {}
        summary["runs"].append({"mode": mode, "returncode": completed.returncode, "result": result})
        print(mode, completed.returncode, len(result.get("assertions", [])), flush=True)
        if completed.returncode:
            print((completed.stdout + completed.stderr)[-8000:])
            break
    (args.output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return int(any(run["returncode"] for run in summary["runs"]))


if __name__ == "__main__":
    raise SystemExit(main())
