"""Accept the Scribe handoff with real KOReader widgets and synthetic records.

The caller must authorize verification on the selected host. Each case has its
own KOReader profile and a network namespace with no external routes. Outputs
must stay outside the repository and never contain a real account or session.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

from run_ui_sources import ui_source_names
from run_bookshelf_grid import synthetic_covers


REQUIRED_SIZES = ((1860, 2480), (480, 640), (600, 800), (960, 720))


def screen_size(value):
    try:
        width, height = (int(item) for item in value.lower().split("x"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use WIDTHxHEIGHT.") from error
    if min(width, height) < 320 or max(width, height) > 4096:
        raise argparse.ArgumentTypeError("Use dimensions from 320 through 4096.")
    return width, height


def source_hashes(plugin):
    names = set(ui_source_names(plugin))
    names.update(("spec/ui/scribe_handoff_spec.lua", "spec/ui/fidelity_geometry.lua", "spec/ui/run_scribe_handoff.py",
                  "spec/ui/run_bookshelf_grid.py", "spec/ui/run_ui_sources.py"))
    return {name: hashlib.sha256((plugin / name).read_bytes()).hexdigest()
            for name in sorted(names)}


def isolation_prefix():
    probe = subprocess.run(["unshare", "--net", "--", "true"],
                           capture_output=True, timeout=5, check=False)
    if probe.returncode == 0:
        return ["unshare", "--net", "--"]
    probe = subprocess.run(["unshare", "--user", "--map-root-user", "--net", "--", "true"],
                           capture_output=True, timeout=5, check=False)
    if probe.returncode == 0:
        return ["unshare", "--user", "--map-root-user", "--net", "--"]
    raise RuntimeError("The host cannot provide the required isolated network namespace.")


def run_case(runtime, plugin, output, size, language, prefix, timeout):
    width, height = size
    output.mkdir(mode=0o700)
    synthetic_covers(output / "fixtures")
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME", "HOME"):
        directory = output / name.lower()
        directory.mkdir(mode=0o700)
        environment[name] = str(directory)
    for name in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
        environment.pop(name, None)
    environment.update(KO_MULTIUSER="1", EMULATE_READER_W=str(width),
                       EMULATE_READER_H=str(height), SDL_AUDIODRIVER="dummy",
                       BILI_SCRIBE_PARENT_NETNS=os.readlink("/proc/self/ns/net"))
    command = [*prefix, "xvfb-run", "-a", "-s", f"-screen 0 {width}x{height}x24",
               str(runtime / "luajit"), str(plugin / "spec/ui/scribe_handoff_spec.lua"),
               str(plugin), str(output), language]
    process = subprocess.Popen(command, cwd=runtime, env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8", errors="replace", start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        stderr += "\nThe native Scribe handoff case exceeded its time limit.\n"
    (output / "scribe-handoff.log").write_text(stdout + stderr, encoding="utf-8")
    result_path = output / "scribe-handoff-result.json"
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        result = {}
    failures = [item for item in result.get("assertions", []) if item.get("passed") is not True]
    case = {"width": width, "height": height, "language": language, "returncode": process.returncode,
            "passed": process.returncode == 0 and result.get("passed") is True,
            "assertion_count": len(result.get("assertions", [])), "failures": failures,
            "screenshot_count": len(result.get("screenshots", [])),
            "result": f"{output.name}/scribe-handoff-result.json",
            "log": f"{output.name}/scribe-handoff.log"}
    if not result:
        case["error"] = "The native spec did not write a result."
        print((stdout + stderr)[-6000:], flush=True)
    print(json.dumps(case), flush=True)
    return case


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--sizes", nargs="+", type=screen_size, default=list(REQUIRED_SIZES))
    parser.add_argument("--languages", nargs="+", choices=("zh_CN", "C"), default=["zh_CN"])
    parser.add_argument("--pillow", type=Path,
                        default=Path.home() / ".local/share/bilicomics-acceptance/python-deps-pillow-11.3.0")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Use the authorized Linux or WSL KOReader runtime.")
    runtime, plugin, output = (path.resolve() for path in (args.runtime, args.plugin, args.output))
    if output.is_relative_to(plugin):
        parser.error("Acceptance output must stay outside the repository.")
    if len(set(args.sizes)) != len(args.sizes) or len(set(args.languages)) != len(args.languages):
        parser.error("Sizes and languages must be unique.")
    if args.timeout < 1:
        parser.error("The per-case timeout must be positive.")
    if not (runtime / "luajit").is_file() or not (runtime / "reader.lua").is_file():
        parser.error("The official KOReader runtime was not found.")
    if args.pillow.is_dir():
        sys.path.insert(0, str(args.pillow.resolve()))
    before = source_hashes(plugin)
    prefix = isolation_prefix()
    os.umask(0o077)
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    report = {"spec": "native-scribe-handoff", "scope": "Actual KOReader widgets and framebuffer; synthetic controller and original art only",
              "environment": "User-authorized local WSL or designated Linux verification host",
              "runtime_version": (runtime / "git-rev").read_text().strip(),
              "runtime_luajit_sha256": hashlib.sha256((runtime / "luajit").read_bytes()).hexdigest(),
              "network_isolation": prefix, "real_account_used": False, "actual_purchase_executed": False,
              "actual_recharge_created": False, "source_sha256": before, "cases": [], "passed": False,
              "started_at": datetime.now(timezone.utc).isoformat(),
              "density_scope": "Independent Scribe handoff expectations; historical UI density assertions are not rewritten"}
    report_path = output / "scribe-handoff-verification.json"
    for language in args.languages:
        for size in args.sizes:
            case_output = output / f"{language}-{size[0]}x{size[1]}"
            report["cases"].append(run_case(runtime, plugin, case_output, size, language, prefix, args.timeout))
            report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    report["source_sha256_after"] = source_hashes(plugin)
    report["source_unchanged"] = before == report["source_sha256_after"]
    report["all_required_sizes_covered"] = set(REQUIRED_SIZES).issubset(args.sizes)
    report["passed"] = report["source_unchanged"] and all(case["passed"] for case in report["cases"])
    report["completed_at"] = datetime.now(timezone.utc).isoformat()
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "all_required_sizes_covered": report["all_required_sizes_covered"],
                      "report": str(report_path)}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
