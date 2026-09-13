"""Run the native UI probe only in the isolated test-env KOReader runtime."""
import argparse
import os
from pathlib import Path
import subprocess
import struct
import zlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", default="600")
    parser.add_argument("--height", default="800")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    compressor = zlib.compressobj()
    compressed = bytearray()
    for _ in range(2000):
        compressed.extend(compressor.compress(b"\0" + b"\x7f\x7f\x7f" * 3000))
    compressed.extend(compressor.flush())
    content = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 3000, 2000, 8, 2, 0, 0, 0))
    content += chunk(b"IDAT", bytes(compressed)) + chunk(b"IEND", b"")
    (args.output / "oversized-cover.png").write_bytes(content)
    environment = os.environ.copy()
    for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
        directory = args.output / name.lower()
        directory.mkdir(exist_ok=True)
        environment[name] = str(directory)
    environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": args.width, "EMULATE_READER_H": args.height, "SDL_AUDIODRIVER": "dummy"})
    completed = subprocess.run(
        ["xvfb-run", "-a", str(args.runtime / "luajit"), str(args.plugin / "spec/ui/native_probe.lua"),
         str(args.output), str(args.plugin)], cwd=args.runtime, env=environment, text=True, capture_output=True, timeout=60,
    )
    (args.output / "native.log").write_text(completed.stdout + completed.stderr)
    print(completed.stdout + completed.stderr)
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
