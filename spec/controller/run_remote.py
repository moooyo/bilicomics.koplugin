"""Run controller integration checks inside the isolated remote KOReader runtime."""
import argparse
import os
from pathlib import Path
import struct
import subprocess
import signal
import zlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--spec", choices=["controller_spec.lua", "authentication_spec.lua", "session_storage_spec.lua", "product_features_spec.lua", "diagnostics_native_spec.lua", "prefetch_spec.lua"], default="controller_spec.lua")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = (b"\0" + bytes([64, 64, 64]) * 20) * 40
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 20, 40, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    (args.output / "fixture.png").write_bytes(png)
    environment = os.environ.copy()
    for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
        directory = args.output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    process = subprocess.Popen(
        ["xvfb-run", "-a", str(args.runtime / "luajit"), str(args.plugin / "spec/controller" / args.spec),
         str(args.plugin), str(args.output)], cwd=args.runtime, env=environment, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        stderr += "\nThe isolated controller verification exceeded its time limit.\n"
    (args.output / "controller.log").write_text(stdout + stderr)
    print(stdout + stderr)
    raise SystemExit(process.returncode)


if __name__ == "__main__":
    main()
