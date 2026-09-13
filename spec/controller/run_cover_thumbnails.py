"""Verify cover thumbnails only in the isolated Linux test-env runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import urllib.request
import zlib


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run verification only through ssh test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--live-public", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = (b"\0" + bytes([64, 64, 64]) * 20) * 40
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 20, 40, 8, 2, 0, 0, 0))
    (args.output / "fixture.png").write_bytes(png + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    env = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = args.output / name.lower()
        directory.mkdir()
        env[name] = str(directory)
    env.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    summary = {"host": "test-env", "runtime_version": (args.runtime / "git-rev").read_text().strip(),
               "scope": "Synthetic controller state and optional anonymous public CDN thumbnails; no account files or original cover downloads",
               "source_sha256": {}, "passed": True}
    for relative in ("bilicomics/controller.lua", "bilicomics/cover_source.lua", "bilicomics/jobs/worker.lua",
                     "bilicomics/protocol/client.lua", "bilicomics/image_policy.lua",
                     "spec/controller/cover_thumbnail_spec.lua", "spec/controller/run_cover_thumbnails.py",
                     "spec/jobs/cover_thumbnail_live_spec.lua"):
        summary["source_sha256"][relative] = hashlib.sha256((args.source / relative).read_bytes()).hexdigest()
    commands = [("controller", ["xvfb-run", "-a", str(args.runtime / "luajit"),
                                str(args.source / "spec/controller/cover_thumbnail_spec.lua"),
                                str(args.source), str(args.output)])]
    if args.live_public:
        source_url = "https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/chunks/chunk-BTk2--tq.js"
        request = urllib.request.Request(source_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read(1024 * 1024 + 1)
            assert len(body) <= 1024 * 1024
        source = body.decode("utf-8")
        evidence = re.search(r"const Xv=.{0,1200}", source).group(0)
        assert '`${d}@${_?`${_}w`:""}.${C}`' in evidence and '"jpg":"png"' in evidence
        summary["official_image_component"] = {"url": source_url, "sha256": hashlib.sha256(body).hexdigest(),
                                                "verified_width_format": "<url>@<width>w.<format>",
                                                "jpeg_fallback": "jpg", "other_fallback": "png"}
        commands.append(("live", [str(args.runtime / "luajit"), str(args.source / "spec/jobs/cover_thumbnail_live_spec.lua"),
                                   str(args.source), str(args.output)]))
    summary["suites"] = []
    for name, command in commands:
        result = subprocess.run(command, cwd=args.runtime, env=env, text=True, capture_output=True, timeout=55)
        log = result.stdout + result.stderr
        (args.output / (name + ".log")).write_text(log)
        filename = "cover-thumbnail-controller-result.json" if name == "controller" else "cover-thumbnail-live-result.json"
        path = args.output / filename
        summary["suites"].append({"suite": name, "returncode": result.returncode,
                                 "result": json.loads(path.read_text()) if path.exists() else None})
        summary["passed"] = summary["passed"] and result.returncode == 0
        print(name, result.returncode, flush=True)
        if result.returncode:
            print(log[-12000:], flush=True)
    (args.output / "cover-thumbnail-results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
