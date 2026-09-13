"""Create synthetic fixtures and run the native probe in an isolated remote runtime."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import zlib


def png(path, width, height, values):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = bytearray()
    for y in range(height):
        value = values[min(len(values) - 1, y * len(values) // height)]
        rows.extend(b"\x00" + bytes([value, value, value]) * width)
    content = b"\x89PNG\r\n\x1a\n"
    content += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    content += chunk(b"pHYs", struct.pack(">IIB", 2835, 2835, 1))
    content += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
    path.write_bytes(content)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("probe", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixtures = args.output / "fixtures"
    fixtures.mkdir(exist_ok=True)
    png(fixtures / "page-1.png", 600, 2400, [40, 100, 160, 220])
    png(fixtures / "page-2.ready.png", 600, 1600, [60, 180])
    pages = [
        {"path": str(fixtures / "page-1.png"), "width": 600, "height": 2400},
        {"path": str(fixtures / "page-2.png"), "width": 600, "height": 1600},
    ]
    manifest = args.output / "episode.bcomic"
    if not manifest.exists():
        manifest.write_text(json.dumps({"pages": pages}), encoding="utf-8")
    environment = os.environ.copy()
    for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
        directory = args.output / name.lower()
        directory.mkdir(exist_ok=True)
        environment[name] = str(directory)
    environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    summaries = []
    for mode in ["render", "ui", "ui-reopen", "ui-online"]:
        if mode == "ui-online":
            (fixtures / "page-2.png").rename(fixtures / "page-2.pending.png")
        completed = subprocess.run(
            ["xvfb-run", "-a", str(args.runtime / "luajit"), str(args.probe), str(args.output), mode],
            cwd=args.runtime, env=environment, text=True, capture_output=True, timeout=25,
        )
        (args.output / (mode + ".log")).write_text(completed.stdout + completed.stderr)
        result_file = args.output / (mode + "-result.json")
        summaries.append({"mode": mode, "returncode": completed.returncode,
                          "result": json.loads(result_file.read_text()) if result_file.exists() else None,
                          "log_tail": (completed.stdout + completed.stderr)[-6000:] if completed.returncode else None})
        if completed.returncode:
            break
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()
