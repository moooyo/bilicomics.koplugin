"""Run only synthetic session-file import checks in the remote KOReader runtime."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", default="600")
    parser.add_argument("--height", default="800")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    fixtures = args.output / "fixtures"
    fixtures.mkdir()
    cookie = "SESSDATA=synthetic-session-file; DedeUserID=424242"
    (fixtures / "session.txt").write_text(cookie)
    (fixtures / "session-bom.TXT").write_bytes(b"\xef\xbb\xbf" + cookie.encode())
    (fixtures / "session.json").write_text(json.dumps([
        {"domain": ".bilibili.com", "name": "SESSDATA", "value": "synthetic-session-file"},
        {"domain": ".bilibili.com", "name": "DedeUserID", "value": "424242"},
    ]))
    (fixtures / "session.cookies").write_text(
        "# Netscape HTTP Cookie File\n.bilibili.com\tTRUE\t/\tTRUE\t0\tSESSDATA\tsynthetic-session-file\n"
        ".bilibili.com\tTRUE\t/\tTRUE\t0\tDedeUserID\t424242\n"
    )
    (fixtures / "boundary.txt").write_bytes(b"x" * 131072)
    (fixtures / "too-large.txt").write_bytes(b"x" * 131073)
    (fixtures / "empty.txt").touch()
    (fixtures / "binary.txt").write_bytes(b"synthetic\0binary")
    (fixtures / "unsupported.log").write_text(cookie)
    (fixtures / "directory.txt").mkdir()
    (fixtures / "linked.txt").symlink_to(fixtures / "session.txt")
    os.mkfifo(fixtures / "pipe.txt")
    environment = os.environ.copy()
    for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
        directory = args.output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": args.width,
                        "EMULATE_READER_H": args.height, "SDL_AUDIODRIVER": "dummy"})
    process = subprocess.Popen(
        ["xvfb-run", "-a", str(args.runtime / "luajit"), str(args.plugin / "spec/ui/session_import_spec.lua"),
         str(args.plugin), str(args.output)], cwd=args.runtime, env=environment, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        stderr += "\nThe isolated session import check exceeded its time limit.\n"
    (args.output / "session-import.log").write_text(stdout + stderr)
    print(stdout + stderr)
    raise SystemExit(process.returncode)


if __name__ == "__main__":
    main()
