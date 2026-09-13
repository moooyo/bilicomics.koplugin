"""Bounded local-image rendering on authorized remote test-env; no acquisition."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on authorized remote test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--image", type=Path, action="append", required=True)
    args = parser.parse_args()
    if not 1 <= len(args.image) <= 2:
        raise RuntimeError("Supply only one or two explicitly authorized images")
    if args.work.exists():
        raise RuntimeError("Use a fresh work directory")
    if (args.runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("The expected official runtime is unavailable")
    for image in args.image:
        if image.is_symlink() or not image.is_file():
            raise RuntimeError("Each authorized image must be a regular file")
    args.work.mkdir(mode=0o700, parents=True)
    source_hashes = {str(p.relative_to(args.source)): digest(p)
                     for p in sorted((args.source / "bilicomics").rglob("*.lua")) if p.is_file()}
    runtime_hashes = {name: digest(args.runtime / name) for name in
                      ("luajit", "frontend/apps/reader/readerui.lua", "frontend/document/document.lua", "ffi/mupdf.lua")}
    script = Path(__file__).with_name("real_image_local.lua")
    report = {"source_sha256": source_hashes, "runtime_sha256": runtime_hashes,
              "test_sha256": {script.name: digest(script), Path(__file__).name: digest(Path(__file__))},
              "samples": [], "passed": False}
    for index, image in enumerate(args.image, 1):
        case = args.work / ("sample-" + str(index))
        case.mkdir(mode=0o700)
        sample = {}
        for phase in ("open", "reopen"):
            home = case / ("ui-" + phase)
            home.mkdir(mode=0o700)
            (home / "settings.reader.lua").write_text("return {quickstart_shown_version=9999999999,color_rendering=false}")
            env = os.environ.copy()
            env.update(KO_HOME=str(home), EMULATE_READER_W="600", EMULATE_READER_H="800",
                       SDL_AUDIODRIVER="dummy", BILI_PARENT_NETNS=os.readlink("/proc/self/ns/net"))
            command = ["unshare", "-n", "--", "xvfb-run", "-a", str(args.runtime / "luajit"),
                       str(script), str(args.source), str(case), phase]
            if phase == "open":
                command.append(str(image))
            process = subprocess.Popen(command, cwd=args.runtime, env=env, text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       close_fds=True, start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=25)
                # Private logs stay remote and are never included in published evidence.
                (case / (phase + ".log")).write_text(stdout + stderr)
                path = case / (phase + "-result.json")
                outcome = json.loads(path.read_text()) if path.exists() else {"passed": False}
                outcome["process_completed"] = process.returncode == 0
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                outcome = {"passed": False, "process_completed": False}
            sample[phase] = outcome
            if not outcome.get("passed") or not outcome["process_completed"]:
                break
        report["samples"].append(sample)
        if len(sample) != 2 or not all(item.get("passed") for item in sample.values()):
            break
    report["passed"] = len(report["samples"]) == len(args.image) and all(
        len(sample) == 2 and all(item.get("passed") and item.get("process_completed")
                                 for item in sample.values()) for sample in report["samples"])
    report["source_unchanged"] = all(digest(args.source / name) == value for name, value in source_hashes.items())
    report["runtime_unchanged"] = all(digest(args.runtime / name) == value for name, value in runtime_hashes.items())
    report["passed"] = report["passed"] and report["source_unchanged"] and report["runtime_unchanged"]
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"]}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
