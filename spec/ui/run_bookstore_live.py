"""Capture the production anonymous bookstore only on the remote Linux test host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def source_identity(plugin):
    files = [plugin / "main.lua", plugin / "_meta.lua", plugin / "spec/local/readonly_guard.lua",
             plugin / "spec/ui/bookstore_live.lua", plugin / "spec/ui/run_bookstore_live.py"]
    for directory in ("bilicomics", "l10n", "patches"):
        files.extend((plugin / directory).rglob("*.lua"))
    return {str(path.relative_to(plugin)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(set(files))}


def main():
    if sys.platform != "linux":
        raise SystemExit("Run only through ssh test-env.")
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    args = parser.parse_args()
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    before = source_identity(plugin)
    profile = output / "profile"
    profile.mkdir(mode=0o700)
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = profile / name.lower()
        path.mkdir(mode=0o700)
        environment[name] = str(path)
    home = profile / "koreader"
    home.mkdir(mode=0o700)
    environment.update({"KO_HOME": str(home), "KO_MULTIUSER": "1", "EMULATE_READER_W": str(args.width),
                        "EMULATE_READER_H": str(args.height), "SDL_AUDIODRIVER": "dummy"})
    for name in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
        environment.pop(name, None)
    process = subprocess.Popen(
        ["xvfb-run", "-a", str(runtime / "luajit"), str(plugin / "spec/ui/bookstore_live.lua"), str(plugin), str(output)],
        cwd=runtime, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", start_new_session=True,
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
    (output / "bookstore-live.log").write_text(stdout + stderr, encoding="utf-8")
    result_file = output / "bookstore-live-result.json"
    result = json.loads(result_file.read_text()) if result_file.exists() else {}
    events_file = output / "requests.jsonl"
    events = [json.loads(line) for line in events_file.read_text().splitlines()] if events_file.exists() else []
    requests = [event for event in events if event["event"] == "request"]
    responses = [event for event in events if event["event"] == "response"]
    blocked = [event for event in events if event["event"] in ("blocked", "probe_error")]
    visible_urls = {item["cached_cover_url"] for item in result.get("visible_cards", []) if item.get("cached_cover_url")}
    public_requests = all(event["method"] == "GET" and event["body_absent"] and event["credentials_absent"]
                          and (event["url"] == "https://manga.bilibili.com/index.pageContext.json"
                               or event["url"] in visible_urls) for event in requests)
    complete_responses = len(requests) == len(responses) and all(event.get("status") == 200 for event in responses)
    no_sessions = not any(profile.rglob("session.dat"))
    after = source_identity(plugin)
    screenshot = output / "bookstore-live.png"
    report = {
        "environment": "ssh test-env", "runtime": str(runtime),
        "runtime_version": (runtime / "git-rev").read_text().strip(),
        "runtime_luajit_sha256": hashlib.sha256((runtime / "luajit").read_bytes()).hexdigest(),
        "source_sha256": before, "source_unchanged": before == after,
        "returncode": process.returncode, "timed_out": timed_out, "native_result": result,
        "requests": requests, "responses": responses, "boundary_failures": blocked,
        "all_requests_public_and_read_only": public_requests, "all_responses_successful": complete_responses,
        "isolated_profile_contains_no_session_file": no_sessions,
        "screenshot_sha256": hashlib.sha256(screenshot.read_bytes()).hexdigest() if screenshot.exists() else None,
    }
    report["passed"] = process.returncode == 0 and result.get("passed") is True and before == after
    report["passed"] = report["passed"] and bool(requests) and public_requests and complete_responses and no_sessions and not blocked
    (output / "bookstore-live-verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "returncode": process.returncode, "output": str(output),
                      "reason": result.get("reason"), "recommendations": len(result.get("recommendations", [])),
                      "visible_cards": len(result.get("visible_cards", [])), "requests": len(requests),
                      "boundary_failures": len(blocked), "source_unchanged": before == after}))
    if not report["passed"]:
        print((stdout + stderr)[-10000:])
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
