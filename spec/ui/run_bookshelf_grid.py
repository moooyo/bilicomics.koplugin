"""Render synthetic native bookshelf cases only in the remote Linux test environment."""
import argparse
import hashlib
from run_ui_sources import ui_source_names
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys


def synthetic_covers(directory):
    """Draw original monochrome storybook landscapes with a visible synthetic label."""
    from PIL import Image, ImageDraw, ImageFont

    directory.mkdir()
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    label_font = ImageFont.truetype(font_path, 22)
    title_font = ImageFont.truetype(font_path, 36)
    names = ("MOONLIT\nOBSERVATORY", "THE LAST\nPAPER CRANE", "LIGHTHOUSE\nIN THE CLOUDS", "GARDEN OF\nQUIET STARS", "SILVER\nMOUNTAIN")
    for index, name in enumerate(names, 1):
        image = Image.new("L", (480, 640), 243)
        draw = ImageDraw.Draw(image)
        draw.rectangle((16, 16, 464, 624), outline=35, width=3)
        draw.rectangle((26, 27, 454, 64), fill=35)
        draw.text((240, 45), "SYNTHETIC ORIGINAL ART", fill=255, font=label_font, anchor="mm")
        draw.ellipse((230 - index * 15, 105, 408 - index * 15, 283), fill=213 if index % 2 else 40)
        for layer in range(4):
            points = [(25, 490)]
            for x in range(25, 456, 12):
                y = 300 + layer * 47 + math.sin(x / (49 + index * 4) + layer * 1.7) * (48 - layer * 8)
                points.append((x, y))
            points += [(455, 538), (25, 538)]
            draw.polygon(points, fill=201 - layer * 41)
        for star in range(18):
            x = 44 + ((star * 73 + index * 29) % 388)
            y = 86 + ((star * 43 + index * 13) % 178)
            draw.line((x - 3, y, x + 3, y), fill=80, width=1)
            draw.line((x, y - 3, x, y + 3), fill=80, width=1)
        if index in (1, 3):
            x = 135 if index == 1 else 320
            draw.polygon(((x - 42, 444), (x - 23, 283), (x + 23, 283), (x + 42, 444)), fill=237, outline=30)
            draw.rectangle((x - 29, 267, x + 29, 299), fill=30)
            draw.polygon(((x - 45, 267), (x, 229), (x + 45, 267)), fill=30)
            for y in (323, 366, 409):
                draw.rectangle((x - 8, y, x + 8, y + 19), fill=30)
            draw.line((x - 110, 308, x - 29, 279), fill=160, width=3)
            draw.line((x + 29, 279, x + 112, 310), fill=160, width=3)
        elif index == 2:
            draw.polygon(((71, 315), (217, 261), (318, 344), (430, 245), (314, 408), (211, 339)), fill=249, outline=25)
            draw.line(((71, 315), (211, 339), (217, 261), (314, 408), (318, 344)), fill=25, width=3)
        elif index == 4:
            for x, y in ((95, 359), (185, 311), (287, 365), (384, 329)):
                draw.line((x, 476, x, y), fill=235, width=3)
                for angle in range(0, 360, 60):
                    dx, dy = math.cos(math.radians(angle)) * 20, math.sin(math.radians(angle)) * 20
                    draw.ellipse((x + dx - 14, y + dy - 14, x + dx + 14, y + dy + 14), fill=238, outline=35)
                draw.ellipse((x - 10, y - 10, x + 10, y + 10), fill=35)
        else:
            draw.polygon(((61, 477), (235, 222), (421, 477)), fill=44)
            draw.polygon(((174, 311), (235, 222), (305, 318), (257, 287), (235, 323), (214, 291)), fill=245)
            draw.line(((235, 323), (180, 438), (207, 418), (172, 477)), fill=165, width=3)
        draw.rectangle((27, 536, 453, 614), fill=244)
        draw.multiline_text((240, 574), name, fill=25, font=title_font, anchor="mm", align="center", spacing=0)
        image.save(directory / f"synthetic-cover-{index}.png")


def main():
    if sys.platform != "linux":
        raise SystemExit("Execute only through ssh test-env.")
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {"scope": "Synthetic native bookshelf UI only; no real account; isolated network namespace", "cases": []}
    summary["sources"] = {name: hashlib.sha256((args.plugin / name).read_bytes()).hexdigest()
                          for name in ui_source_names(args.plugin) + ("main.lua", "bilicomics/ui/screens.lua", "bilicomics/ui/widgets.lua",
                                       "bilicomics/ui/model.lua", "l10n/bilicomics_zh_CN.lua")}
    for language in ("zh_CN", "C"):
        for width, height in ((480, 640), (600, 800), (720, 960), (960, 720)):
            output = args.output / f"{language}-{width}x{height}"
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
                 str(args.plugin / "spec/ui/bookshelf_grid_spec.lua"), str(args.plugin), str(output), language],
                cwd=args.runtime, env=environment, text=True, encoding="utf-8", errors="replace",
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
                stderr += "\nThe isolated bookshelf check exceeded its time limit.\n"
            (output / "bookshelf-grid.log").write_text(stdout + stderr, encoding="utf-8")
            result_path = output / "bookshelf-grid-result.json"
            result = json.loads(result_path.read_text()) if result_path.is_file() else {}
            case = {"width": width, "height": height, "language": language, "returncode": process.returncode,
                    "passed": process.returncode == 0 and result.get("passed") is True,
                    "assertions": len(result.get("assertions", [])),
                    "failures": [item for item in result.get("assertions", []) if not item["passed"]]}
            summary["cases"].append(case)
            print(json.dumps(case))
            if not result:
                print(stdout + stderr)
    summary["passed"] = all(case["passed"] for case in summary["cases"])
    (args.output / "bookshelf-grid-verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
