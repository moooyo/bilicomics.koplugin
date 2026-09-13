"""Capture multiple production bookstore pages on the remote Linux test host."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


PREFIX = "bookstore-expanded-live"
FEED_URL = "https://manga.bilibili.com/index.pageContext.json"
ALLOWED_HEADERS = {"user-agent", "accept", "referer"}
PAGE_TIMEOUT_SECONDS = 75
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


def positive_integer(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("The value must be a positive integer.") from error
    if number < 1:
        raise argparse.ArgumentTypeError("The value must be a positive integer.")
    return number


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_identity(plugin):
    files = [plugin / "main.lua", plugin / "_meta.lua", plugin / "spec/local/readonly_guard.lua",
             plugin / "spec/ui/bookstore_expanded_live.lua", plugin / "spec/ui/run_bookstore_expanded_live.py"]
    for directory in ("bilicomics", "l10n", "patches"):
        files.extend((plugin / directory).rglob("*.lua"))
    return {path.relative_to(plugin).as_posix(): digest(path) for path in sorted(set(files))}


def read_result(path, errors):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError("The native result must be a JSON object.")
        return value
    except (OSError, ValueError) as error:
        errors.append("Cannot read native result: " + str(error))
        return {}


def read_events(path, errors):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        errors.append("Cannot read request audit: " + str(error))
        return []
    events = []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError("The audit event must be a JSON object.")
            events.append(value)
        except ValueError as error:
            errors.append("Invalid request audit line {}: {}".format(number, error))
    return events


def comic_id(item):
    if not isinstance(item, dict):
        return None
    value = item.get("id")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return None
    value = str(value)
    if not value.isascii() or not value.isdigit() or not value.strip("0"):
        return None
    return value.lstrip("0")


def screenshot_identity(output, page, index, errors):
    expected = "{}-page-{:02d}.png".format(PREFIX, index)
    name = page.get("screenshot")
    record = {"page": index, "screenshot": name, "sha256": None, "path_within_output": False}
    if name != expected:
        errors.append("Page {} has an unexpected screenshot name.".format(index))
        return record
    try:
        path = output / name
        resolved = path.resolve()
        if path.is_symlink() or resolved.parent != output or resolved.name != expected:
            raise ValueError("The screenshot path must remain inside the output directory.")
        record["path_within_output"] = True
        if not path.is_file():
            raise ValueError("The screenshot file is missing.")
        record["sha256"] = digest(path)
    except (OSError, RuntimeError, ValueError) as error:
        errors.append("Page {} screenshot: {}".format(index, error))
    return record


def inspect_samples(result, args, output, errors):
    recommendations = result.get("recommendations")
    if not isinstance(recommendations, list):
        errors.append("The recommendation snapshot is missing or invalid.")
        recommendations = []
    recommendation_ids = [comic_id(item) for item in recommendations]
    if len(recommendations) < args.min_recommendations:
        errors.append("The recommendation snapshot has fewer than the requested minimum items.")
    if None in recommendation_ids or len(set(recommendation_ids)) != len(recommendation_ids):
        errors.append("Recommendation IDs must be valid and unique.")

    pages = result.get("captured_pages")
    if not isinstance(pages, list):
        errors.append("Captured pages are missing or invalid.")
        pages = []
    if len(pages) != args.pages:
        errors.append("The captured page count differs from the requested page count.")

    screenshots, visible_urls, captured_ids = [], set(), []
    for index, page in enumerate(pages, 1):
        if not isinstance(page, dict):
            errors.append("Captured page {} must be an object.".format(index))
            continue
        if type(page.get("page")) is not int or page["page"] != index:
            errors.append("Captured page numbers must begin at one and remain consecutive.")
        if page.get("source") != "official_homepage" or page.get("personalized") is not False:
            errors.append("Page {} must contain anonymous official homepage data.".format(index))
        if page.get("runner_idle") is not True or page.get("all_covers_loaded") is not True:
            errors.append("Page {} was captured before its visible covers completed.".format(index))
        screenshots.append(screenshot_identity(output, page, index, errors))
        cards = page.get("cards")
        if not isinstance(cards, list):
            errors.append("Page {} cards are missing or invalid.".format(index))
            cards = []
        if len(cards) < args.min_visible_cards:
            errors.append("Page {} has fewer than the requested minimum visible cards.".format(index))
        for card in cards:
            position = len(captured_ids)
            identifier = comic_id(card)
            captured_ids.append(identifier)
            if not isinstance(card, dict):
                errors.append("Page {} contains an invalid card.".format(index))
                continue
            if position >= len(recommendation_ids) or identifier != recommendation_ids[position]:
                errors.append("Captured cards must follow the recommendation snapshot from its first item.")
            if type(card.get("source_index")) is not int or card["source_index"] != position + 1:
                errors.append("Captured card source indexes must match the recommendation snapshot.")
            url = card.get("cached_cover_url")
            if card.get("cover_loaded") is not True or not isinstance(url, str) or not url.startswith("https://"):
                errors.append("Every captured card must have a loaded public cover URL.")
            else:
                visible_urls.add(url)
    if None in captured_ids or len(set(captured_ids)) != len(captured_ids):
        errors.append("Captured card IDs must be valid and unique within and across pages.")
    return screenshots, visible_urls, len(recommendations), len(captured_ids)


def inspect_identity(result, args, plugin, errors):
    expected = {
        "requested_pages": args.pages, "min_visible_cards": args.min_visible_cards,
        "min_recommendations": args.min_recommendations, "page_timeout_seconds": PAGE_TIMEOUT_SECONDS,
        "width": args.width, "height": args.height, "account_key": "anonymous",
        "session_present": False, "synthetic_data": False, "isolated_profile": True,
        "request_boundary_installed": True, "feed_source": "official_homepage", "personalized": False,
        "route": "bookstore", "runtime_closed": True, "runner_idle": True,
        "recommendations_unique": True, "visible_ids_unique_and_ordered": True,
        "first_screen_covers_loaded": True, "favorite_count": 0, "history_count": 0, "download_count": 0,
    }
    valid = True
    for key, value in expected.items():
        actual = result.get(key)
        if type(actual) is not type(value) or actual != value:
            errors.append("The native identity or capture boundary is invalid: " + key)
            valid = False
    lookups = result.get("session_lookups")
    if not isinstance(lookups, list) or not lookups or any(key != "anonymous" for key in lookups):
        errors.append("Only anonymous session lookups may be recorded.")
        valid = False
    loaded = result.get("loaded_sources")
    if not isinstance(loaded, dict):
        loaded = {}
    for name, relative in {
        "probe": "spec/ui/bookstore_expanded_live.lua",
        "runtime": "bilicomics/runtime.lua", "controller": "bilicomics/controller.lua",
        "screens": "bilicomics/ui/screens.lua", "runner": "bilicomics/jobs/runner.lua",
        "recommendations": "bilicomics/protocol/recommendations.lua",
    }.items():
        if loaded.get(name) != "@" + (plugin / relative).as_posix():
            errors.append("The loaded production source differs from the selected checkout: " + name)
            valid = False
    return valid


def inspect_requests(events, visible_urls, errors):
    requests = [event for event in events if event.get("event") == "request"]
    responses = [event for event in events if event.get("event") == "response"]
    blocked = [event for event in events if event.get("event") in ("blocked", "probe_error")]
    if any(event.get("event") not in ("request", "response", "blocked", "probe_error") for event in events):
        errors.append("The request audit contains an unknown event type.")
    public = bool(requests)
    for request in requests:
        headers = request.get("header_names")
        valid_headers = isinstance(headers, list) and all(isinstance(name, str) for name in headers)
        if valid_headers:
            names = [name.lower() for name in headers]
            valid_headers = len(names) == len(set(names)) and set(names).issubset(ALLOWED_HEADERS)
        url = request.get("url")
        permitted = (url == FEED_URL and request.get("category") == "official_recommendations")
        permitted = permitted or (isinstance(url, str) and url in visible_urls
                                  and request.get("category") == "visible_official_cover")
        public = public and request.get("method") == "GET" and request.get("body_absent") is True
        public = public and request.get("credentials_absent") is True and valid_headers and permitted
        public = public and request.get("max_bytes") == MAX_RESPONSE_BYTES
    if not any(request.get("url") == FEED_URL for request in requests):
        public = False
    if not public:
        errors.append("Every request must be an anonymous bounded GET for the feed or a captured cover.")

    def request_key(event):
        values = (event.get("pid"), event.get("category"), event.get("url"))
        if type(values[0]) is not int or values[0] < 1 or not all(isinstance(value, str) for value in values[1:]):
            return None
        return values

    request_keys = [request_key(event) for event in requests]
    response_keys = [request_key(event) for event in responses]
    complete = bool(requests) and None not in request_keys and None not in response_keys
    complete = complete and Counter(request_keys) == Counter(response_keys)
    complete = complete and all(type(event.get("status")) is int and event["status"] == 200 for event in responses)
    if not complete:
        errors.append("Each audited request must have a matching HTTP 200 response.")
    if blocked:
        errors.append("The live boundary recorded blocked operations or probe errors.")
    return requests, responses, blocked, bool(public), bool(complete)


def main():
    if sys.platform != "linux":
        raise SystemExit("Run only through ssh test-env.")
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--width", type=positive_integer, default=600)
    parser.add_argument("--height", type=positive_integer, default=800)
    parser.add_argument("--pages", type=positive_integer, default=2)
    parser.add_argument("--min-visible-cards", type=positive_integer, default=6)
    parser.add_argument("--min-recommendations", type=positive_integer, default=12)
    args = parser.parse_args()
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    try:
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
    except OSError as error:
        raise SystemExit("A new output directory is required: " + str(error)) from error

    profile = output / "profile"
    timeout = args.pages * 90 + 15
    errors, stdout, stderr = [], "", ""
    process = None
    log_file = output / (PREFIX + ".log")
    report_file = output / (PREFIX + "-verification.json")
    report = {
        "environment": "ssh test-env", "runtime": str(runtime), "plugin": str(plugin), "output": str(output),
        "parameters": {"width": args.width, "height": args.height, "pages": args.pages,
                       "min_visible_cards": args.min_visible_cards, "min_recommendations": args.min_recommendations,
                       "page_timeout_seconds": PAGE_TIMEOUT_SECONDS, "process_timeout_seconds": timeout},
        "runtime_version": None, "runtime_luajit_sha256": None,
        "source_sha256": {}, "source_after_sha256": {}, "source_unchanged": False,
        "returncode": None, "timed_out": False, "passed": False, "verification_errors": errors,
    }
    log_file.write_text("", encoding="utf-8")
    report_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    try:
        report["source_sha256"] = source_identity(plugin)
        report["runtime_version"] = (runtime / "git-rev").read_text(encoding="utf-8").strip()
        report["runtime_luajit_sha256"] = digest(runtime / "luajit")
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
            ["xvfb-run", "-a", str(runtime / "luajit"), str(plugin / "spec/ui/bookstore_expanded_live.lua"),
             str(plugin), str(output), str(args.pages), str(args.min_visible_cards), str(args.min_recommendations)],
            cwd=runtime, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            report["timed_out"] = True
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            errors.append("The expanded live capture exceeded its process timeout.")
        report["returncode"] = process.returncode
    except (Exception, KeyboardInterrupt) as error:
        errors.append("Capture setup or execution failed: {}: {}".format(type(error).__name__, error))
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
            except OSError as error:
                errors.append("Cannot finish capture process cleanup: " + str(error))
        if process is not None:
            report["returncode"] = process.returncode

    try:
        report["source_after_sha256"] = source_identity(plugin)
        report["source_unchanged"] = bool(report["source_sha256"]) and report["source_sha256"] == report["source_after_sha256"]
    except (OSError, ValueError) as error:
        errors.append("Cannot read final production source identity: " + str(error))
    if not report["source_unchanged"]:
        errors.append("The production source identity was unavailable or changed during capture.")

    try:
        result = read_result(output / (PREFIX + "-result.json"), errors)
        report["native_result"] = result
        screenshots, visible_urls, recommendation_count, card_count = inspect_samples(result, args, output, errors)
        report["screenshots"] = screenshots
        report["native_identity_verified"] = inspect_identity(result, args, plugin, errors)
        events = read_events(output / (PREFIX + "-requests.jsonl"), errors)
        requests, responses, blocked, public, complete = inspect_requests(events, visible_urls, errors)
        report.update({"requests": requests, "responses": responses, "boundary_failures": blocked,
                       "all_requests_public_and_read_only": public, "all_responses_successful": complete,
                       "captured_card_count": card_count, "recommendation_count": recommendation_count})
        report["isolated_profile_contains_no_session_file"] = profile.is_dir() and not any(profile.rglob("session.dat"))
        if not report["isolated_profile_contains_no_session_file"]:
            errors.append("The isolated profile is missing or contains a session file.")
        report["passed"] = report["returncode"] == 0 and not report["timed_out"] and result.get("passed") is True and not errors
    except (Exception, KeyboardInterrupt) as error:
        errors.append("Capture verification failed: {}: {}".format(type(error).__name__, error))
        report["passed"] = False

    log = stdout + stderr
    if errors:
        log += "\nWrapper verification errors:\n" + "\n".join(errors) + "\n"
    log_file.write_text(log, encoding="utf-8")
    report_file.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    result = report.get("native_result", {})
    visible = result.get("visible_cards", [])
    print(json.dumps({"passed": report["passed"], "returncode": report["returncode"], "output": str(output),
                      "reason": result.get("reason"), "recommendations": report.get("recommendation_count", 0),
                      "captured_pages": len(report.get("screenshots", [])), "captured_cards": report.get("captured_card_count", 0),
                      "visible_cards": len(visible) if isinstance(visible, list) else 0,
                      "requests": len(report.get("requests", [])), "boundary_failures": len(report.get("boundary_failures", [])),
                      "source_unchanged": report["source_unchanged"], "verification_errors": errors}))
    if not report["passed"]:
        print(log[-10000:])
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
