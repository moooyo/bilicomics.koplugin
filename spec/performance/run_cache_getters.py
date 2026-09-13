"""Run the bounded cache getter measurement on the remote test host only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import zlib


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if os.name == "nt":
        raise SystemExit("Run this measurement through ssh test-env; local verification is not authorized.")
    args.output.mkdir(parents=True, exist_ok=False)
    width, height = 2048, 512
    fixtures = []
    for index in range(8):
        pixels = random.Random(20260912 + index).randbytes(width * height * 3)
        raw = b"".join(b"\x00" + pixels[row * width * 3:(row + 1) * width * 3] for row in range(height))
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw, level=1)) + chunk(b"IEND", b"")
        name = "fixture-%d.png" % (index + 1)
        (args.output / name).write_bytes(png)
        fixtures.append({"path": name, "width": width, "height": height,
                         "bytes": len(png), "checksum": hashlib.sha256(png).hexdigest()})
    assert sum(item["bytes"] for item in fixtures) <= 64 * 1024 * 1024
    (args.output / "fixtures.json").write_text(json.dumps(fixtures, indent=2) + "\n")
    environment = os.environ.copy()
    for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
        directory = args.output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    completed = subprocess.run(
        ["xvfb-run", "-a", str(args.runtime / "luajit"), str(args.plugin / "spec/performance/cache_getters.lua"),
         str(args.plugin), str(args.output)], cwd=args.runtime, env=environment,
        text=True, capture_output=True, timeout=240,
    )
    (args.output / "measurement.log").write_text(completed.stdout + completed.stderr)
    if completed.returncode != 0:
        print(completed.stdout + completed.stderr)
    else:
        result = json.loads((args.output / "results.json").read_text())
        result["runtime_git_rev"] = (args.runtime / "git-rev").read_text().strip()
        result["source_sha256"] = {
            name: hashlib.sha256((args.plugin / name).read_bytes()).hexdigest()
            for name in ["bilicomics/catalog/init.lua", "bilicomics/controller.lua", "bilicomics/storage/page_store.lua",
                         "bilicomics/storage/files.lua", "bilicomics/ui/screens.lua"]
        }
        (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
