"""Exercise real KOReader SQLite and page commits inside a remote isolated runtime."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def png(path, shade):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\0" + bytes([shade, shade, shade]) * 40 for _ in range(80))
    content = b"\x89PNG\r\n\x1a\n"
    content += chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 2, 0, 0, 0))
    content += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
    path.write_bytes(content)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pillow-root", type=Path, required=True,
                        help="Existing isolated Pillow installation used only to generate test fixtures")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    fixtures = args.output / "fixtures"
    fixtures.mkdir()
    png(fixtures / "page-a.png", 70)
    png(fixtures / "page-b.png", 180)
    sys.path.insert(0, str(args.pillow_root))
    from PIL import Image
    source = Image.new("RGB", (40, 80), (70, 70, 70))
    source.save(fixtures / "page.jpg")
    source.save(fixtures / "page-lossy.webp")
    source.save(fixtures / "page-lossless.webp", lossless=True)
    source.convert("RGBA").save(fixtures / "page-extended.webp", icc_profile=b"Synthetic test profile")
    for orientation in range(1, 9):
        exif = Image.Exif()
        exif[274] = orientation
        source.save(fixtures / ("page-exif-" + str(orientation) + ".jpg"), exif=exif)
    exif = Image.Exif()
    exif[274] = 6
    source.save(fixtures / "page-exif.png", exif=exif)
    source.save(fixtures / "page-exif.webp", exif=exif)
    environment = os.environ.copy()
    environment["KO_MULTIUSER"] = "1"
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = args.output / key.lower()
        path.mkdir()
        environment[key] = str(path)
    summary = {"runtime": str(args.runtime), "suites": [], "passed": True}
    modes = ["core", "integration-safety"]
    for stage in ("after_journal", "after_rename", "after_database"):
        modes += ["crash-" + stage, "recover-" + stage]
    modes += ["crash-invalid-commit", "recover-invalid-commit"]
    modes += ["crash-retry-commit", "recover-retry-commit"]
    for mode in modes:
        completed = subprocess.run([
            str(args.runtime / "luajit"), str(args.source / "spec/storage/storage_spec.lua"),
            str(args.source), str(args.output), mode,
        ], cwd=args.runtime, env=environment, capture_output=True, text=True, timeout=45)
        (args.output / (mode + ".log")).write_text(completed.stdout + completed.stderr)
        expected = 73 if mode.startswith("crash-") else 0
        result_file = args.output / (mode + "-result.json")
        item = {"mode": mode, "returncode": completed.returncode, "expected_returncode": expected,
                "result": json.loads(result_file.read_text()) if result_file.exists() else None}
        summary["suites"].append(item)
        if completed.returncode != expected:
            summary["passed"] = False
            item["error"] = (completed.stdout + completed.stderr)[-6000:]
            break
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
