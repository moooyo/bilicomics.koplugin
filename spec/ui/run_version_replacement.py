"""Run fake-controller version replacement specs in the remote KOReader runtime."""
import argparse
import os
from pathlib import Path
import signal
import subprocess


def screen_size(value):
    try:
        width, height = (int(part) for part in value.lower().split("x"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use WIDTHxHEIGHT, such as 600x800.") from error
    if width < 1 or height < 1:
        raise argparse.ArgumentTypeError("Screen dimensions must be positive.")
    return width, height


def positive_seconds(value):
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("The timeout must be an integer.") from error
    if seconds < 1:
        raise argparse.ArgumentTypeError("The timeout must be positive.")
    return seconds


def stop_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run_spec(runtime, plugin, output, size, timeout):
    width, height = size
    output.mkdir()
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update({
        "KO_MULTIUSER": "1",
        "EMULATE_READER_W": str(width),
        "EMULATE_READER_H": str(height),
        "SDL_AUDIODRIVER": "dummy",
    })
    command = [
        "xvfb-run", "-a", str(runtime / "luajit"),
        str(plugin / "spec/ui/version_replacement_spec.lua"), str(output), str(plugin),
    ]
    interrupted = False
    try:
        process = subprocess.Popen(
            command, cwd=runtime, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", start_new_session=True,
        )
    except OSError as error:
        stdout, stderr, returncode = "", "The native UI spec could not start: " + str(error) + "\n", 127
    else:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            returncode = process.returncode
        except subprocess.TimeoutExpired:
            stop_process_group(process)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated version replacement spec exceeded its time limit.\n"
            returncode = 124
        except KeyboardInterrupt:
            stop_process_group(process)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated version replacement spec was interrupted.\n"
            returncode, interrupted = 130, True
    log = stdout + stderr
    (output / "version-replacement.log").write_text(log, encoding="utf-8")
    print(log, end="" if log.endswith("\n") else "\n")
    print(f"Version replacement {width}x{height}: exit {returncode}; output: {output}")
    return returncode, interrupted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path, help="A new directory for isolated per-size results.")
    parser.add_argument("--sizes", nargs="+", type=screen_size,
                        default=[(600, 800), (480, 640)], metavar="WIDTHxHEIGHT")
    parser.add_argument("--timeout", type=positive_seconds, default=60,
                        help="Maximum seconds for each screen size (default: 60).")
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("Run this harness through ssh test-env in the isolated Linux runtime.")
    if len(set(args.sizes)) != len(args.sizes):
        parser.error("Each screen size must be unique.")
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    if not (runtime / "luajit").is_file():
        parser.error("The runtime directory must contain the official KOReader luajit executable.")
    if not (plugin / "spec/ui/version_replacement_spec.lua").is_file():
        parser.error("The plugin snapshot must contain spec/ui/version_replacement_spec.lua.")
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error("A fresh output directory is required: " + str(error))
    failed = False
    for size in args.sizes:
        directory = output / f"{size[0]}x{size[1]}"
        returncode, interrupted = run_spec(runtime, plugin, directory, size, args.timeout)
        if interrupted:
            raise SystemExit(130)
        failed = failed or returncode != 0
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
