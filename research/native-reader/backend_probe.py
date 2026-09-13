"""Generate fixtures and probe KOReader's native backend on an authorized Linux host.

Example remote invocation:
  python3 backend_probe.py --runtime /path/to/koreader --work /tmp/backend-probe

The script only writes beneath --work and does not modify the runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
import zipfile


def install_pillow(work: Path) -> dict:
    """Extract a pinned binary wheel into an isolated target without pip."""
    version = "12.0.0"
    python_tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
    with urllib.request.urlopen(f"https://pypi.org/pypi/pillow/{version}/json") as response:
        metadata = json.load(response)
    candidates = [item for item in metadata["urls"]
                  if f"-{python_tag}-{python_tag}-" in item["filename"]
                  and "manylinux_2_28_x86_64" in item["filename"]]
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one compatible Pillow wheel, found {len(candidates)}")
    item = candidates[0]
    wheel = work / item["filename"]
    if not wheel.exists():
        urllib.request.urlretrieve(item["url"], wheel)
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    if digest != item["digests"]["sha256"]:
        raise RuntimeError("Pillow wheel checksum mismatch")
    target = work / "python-deps"
    target.mkdir(exist_ok=True)
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(target)
    sys.path.insert(0, str(target))
    return {"version": version, "wheel": item["filename"], "sha256": digest}


def fixture_color(x: int, y: int, width: int, height: int) -> tuple[int, int, int]:
    palette = [(224, 32, 32), (32, 208, 32), (32, 32, 224), (192, 64, 192)]
    color = palette[min(3, y * 4 // height)]
    if x >= width // 2:
        return tuple(255 - component for component in color)
    return color


def generate_fixtures(work: Path) -> dict:
    from PIL import Image, ImageDraw
    from PIL import features

    if not features.check("webp"):
        raise RuntimeError("The isolated Pillow wheel has no WebP codec")
    fixtures = work / "fixtures"
    fixtures.mkdir(exist_ok=True)
    manifest = {}
    for label, width, height in [("small", 360, 1200), ("long", 1200, 16000)]:
        image = Image.new("RGB", (width, height))
        draw = ImageDraw.Draw(image)
        for band in range(4):
            top, bottom = band * height // 4, (band + 1) * height // 4 - 1
            draw.rectangle((0, top, width // 2 - 1, bottom),
                           fill=fixture_color(0, top, width, height))
            draw.rectangle((width // 2, top, width - 1, bottom),
                           fill=fixture_color(width - 1, top, width, height))
        for extension in ("jpg", "png", "webp"):
            path = fixtures / f"{label}.{extension}"
            options = {"jpg": {"quality": 95, "subsampling": 0, "dpi": (72, 72)},
                       "png": {"dpi": (72, 72)},
                       "webp": {"lossless": True, "method": 1}}[extension]
            image.save(path, **options)
            manifest[str(path)] = {"width": width, "height": height, "format": extension,
                                   "bytes": path.stat().st_size}
        if label == "small":
            for extension in ("jpg", "png"):
                path = fixtures / f"small-300dpi.{extension}"
                options = {"dpi": (300, 300)}
                if extension == "jpg":
                    options.update(quality=95, subsampling=0)
                image.save(path, **options)
                manifest[str(path)] = {"width": width, "height": height,
                                       "format": extension, "dpi": 300,
                                       "bytes": path.stat().st_size}
        image.close()

    archive_dir = fixtures / "image-directory"
    archive_dir.mkdir(exist_ok=True)
    for index, extension in enumerate(("jpg", "png", "webp"), 1):
        (archive_dir / f"{index:04}.{extension}").write_bytes((fixtures / f"small.{extension}").read_bytes())
    archive_path = fixtures / "mixed.cbz"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
        for image_path in sorted(archive_dir.iterdir()):
            archive.write(image_path, image_path.name)
    for path in (archive_dir, archive_path):
        manifest[str(path)] = {"width": 360, "height": 1200, "format": "mixed", "pages": 3}
    return manifest


def main() -> int:
    if sys.platform != "linux":
        raise RuntimeError("Run this verification only on the authorized remote Linux environment")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    dependency = install_pillow(work)
    manifest = generate_fixtures(work)
    lua_path = Path(__file__).with_suffix(".lua").resolve()
    environment = os.environ.copy()
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = work / f"xdg-{kind.lower()}"
        directory.mkdir(exist_ok=True)
        environment[f"XDG_{kind}_HOME"] = str(directory)
    results = []
    for fixture, info in manifest.items():
        width = 600 if info["height"] > 10000 else 180
        start = time.monotonic()
        process = subprocess.run([str(runtime / "luajit"), str(lua_path), fixture,
                                  str(width), "120", "0.5", "draw"],
                                 cwd=runtime, env=environment, text=True, capture_output=True,
                                 timeout=90)
        marker = "BACKEND_PROBE_JSON="
        matching = [line[len(marker):] for line in process.stdout.splitlines()
                    if line.startswith(marker)]
        if len(matching) != 1:
            result = {"path": fixture, "ok": False, "stdout": process.stdout,
                      "stderr": process.stderr, "returncode": process.returncode}
        else:
            result = json.loads(matching[0])
            result["stderr"] = process.stderr
            result["returncode"] = process.returncode
            result["wall_seconds"] = time.monotonic() - start
            result["fixture"] = info
            for page in result.get("page_results", []):
                for sample in page["samples"]:
                    x = int((sample["x"] + 0.5) * info["width"] / width)
                    y = int((sample["y"] + page["offset_y"] + 0.5) * info["width"] / width)
                    expected = fixture_color(x, y, info["width"], info["height"])
                    sample["expected_rgb"] = expected
                    sample["max_error"] = max(abs(a - b) for a, b in zip(sample["rgb"], expected))
                page["crop_matches_fixture"] = all(sample["max_error"] <= 4 for sample in page["samples"])
        results.append(result)
        print(json.dumps({"fixture": Path(fixture).name, "ok": result.get("ok"),
                          "pages": result.get("pages"),
                          "peak_rss_kib": result.get("after_close", {}).get("peak_rss_kib"),
                          "crop_matches": [page.get("crop_matches_fixture") for page in result.get("page_results", [])]}), flush=True)
    report = {"runtime_git_rev": (runtime / "git-rev").read_text().strip(),
              "runtime": str(runtime), "platform": sys.platform,
              "dependency": dependency, "fixtures": manifest, "results": results,
              "scope": "Synthetic solid-band fixtures; native image backend only; no ReaderUI or device performance guarantee."}
    (work / "backend-probe-results.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(item.get("ok") and item.get("returncode") == 0 and
                    all(page.get("crop_matches_fixture") for page in item.get("page_results", []))
                    for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
