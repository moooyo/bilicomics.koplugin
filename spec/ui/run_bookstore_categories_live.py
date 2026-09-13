"""Capture the real official category picker and one anonymous category page on test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def sources(plugin):
    paths = [plugin / "main.lua", plugin / "_meta.lua", plugin / "spec/local/readonly_guard.lua",
             plugin / "spec/ui/bookstore_categories_live.lua", plugin / "spec/ui/run_bookstore_categories_live.py"]
    for directory in ("bilicomics", "l10n", "patches"):
        paths.extend((plugin / directory).rglob("*.lua"))
    return {path.relative_to(plugin).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(set(paths))}


def main():
    if sys.platform != "linux":
        raise SystemExit("Run only through ssh test-env.")
    parser = argparse.ArgumentParser()
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    profile = output / "profile"
    profile.mkdir(mode=0o700)
    before = sources(plugin)
    env = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME"):
        directory = profile / name.lower()
        directory.mkdir()
        env[name] = str(directory)
    env.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    for name in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
        env.pop(name, None)
    process = subprocess.Popen(["xvfb-run", "-a", str(runtime / "luajit"), str(plugin / "spec/ui/bookstore_categories_live.lua"),
                                str(plugin), str(output)], cwd=runtime, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8", errors="replace", start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
    (output / "bookstore-categories-live.log").write_text(stdout + stderr, encoding="utf-8")
    result_file = output / "bookstore-categories-live-result.json"
    result = json.loads(result_file.read_text()) if result_file.is_file() else {}
    audit_file = output / "bookstore-categories-live-requests.jsonl"
    audit = [json.loads(line) for line in audit_file.read_text().splitlines()] if audit_file.is_file() else []
    counts = {name: sum(item.get("route") == name for item in audit)
              for name in ("AllLabel", "AnonymousDevice", "ClassPage", "VisibleCover", "PinnedSigningAsset")}
    clean = bool(audit) and all(item.get("status") == 200 and item.get("account_credentials_absent") is True for item in audit)
    clean = clean and counts["AllLabel"] == counts["AnonymousDevice"] == counts["ClassPage"] == 1 and counts["VisibleCover"] == 6
    no_sessions = not any(profile.rglob("session.dat"))
    screenshots = [{"name": name, "sha256": hashlib.sha256((output / name).read_bytes()).hexdigest()}
                   for name in result.get("screenshots", [])]
    after = sources(plugin)
    report = {"environment": "ssh test-env", "runtime": str(runtime), "source_sha256": before,
              "source_unchanged": before == after, "returncode": process.returncode, "timed_out": timed_out,
              "native_result": result, "requests": audit, "route_counts": counts, "screenshots": screenshots,
              "all_requests_succeeded_with_existing_readonly_guard": clean, "isolated_profile_contains_no_session_file": no_sessions}
    report["passed"] = process.returncode == 0 and not timed_out and result.get("passed") is True and before == after and clean and no_sessions
    (output / "bookstore-categories-live-verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "reason": result.get("reason"), "categories": len(result.get("categories", [])),
                      "comics": result.get("comic_count"), "covers": len(result.get("visible_cards", [])), "route_counts": counts,
                      "source_unchanged": report["source_unchanged"]}))
    if not report["passed"]:
        print((stdout + stderr)[-6000:])
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
