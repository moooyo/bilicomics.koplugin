"""Stage and bind the bounded reading revision on test-env without publishing it.

All commands require an SSH-connected Linux environment. The stage command writes
only a new temporary tree; syntax compiles Lua without executing application
modules; bind records provenance for separately produced package results. This
script never builds an archive, changes dist, or contacts an application API.

The built-in recipe is the reviewed reading-only UI migration. An optional recipe
file must match it exactly. No payment UI functions or locale keys are migrated.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import socket
import subprocess
import sys
import zipfile


BASELINES = {
    "reading": {"sha256": "b7b27290dda31834d593bd0e4234079602f807e7093be5b396d78d18a35691b4", "files": 91},
    "preview": {"sha256": "37127a655a2da25417cb29a8a6871a0ea8de78a97e328f1a2807bc5d8e8a537e", "files": 95},
}
CONTROLLER = "bilicomics/controller.lua"
MODEL = "bilicomics/ui/model.lua"
SCREENS = "bilicomics/ui/screens.lua"
LOCALE = "l10n/bilicomics_zh_CN.lua"
WHOLE_FILES = ("bilicomics/jobs/download_service.lua", "bilicomics/jobs/runner.lua")
CHANGED_PATHS = {CONTROLLER, MODEL, SCREENS, LOCALE, *WHOLE_FILES}
CONTROLLER_SYMBOLS = ("Controller:_openAccount", "Controller:prepareEpisode")
READING_RECIPE = {
    "model_replacements": [],
    "screen_replacements": ["Screens:_chapterRow", "Screens:_comic"],
    "helper_insertions": [{"path": MODEL, "symbol": "Model.entitlementExpiry", "before_symbol": "Model.storage"}],
    "locale_keys": ["Temporary access expiry is unknown.", "Temporary access expires: %s (UTC)"],
}
PREVIEW_ONLY = {
    "bilicomics/purchase/candidate.lua", "bilicomics/purchase/quote_fetch.lua",
    "bilicomics/purchase/selection-contract.md", "bilicomics/purchase/selection.lua",
}
PREFIX = "bilicomics.koplugin/"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
READING_SYMBOL = re.compile(r"(?:purchase|quote|coupon|payment|wallet|discount|balance)", re.I)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    assert isinstance(value, dict), f"An object is required: {path}"
    return value


def write_new_json(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def relative_name(name: str) -> str:
    assert isinstance(name, str) and name and "\\" not in name
    path = PurePosixPath(name)
    assert not path.is_absolute() and all(part not in {"", ".", ".."} for part in path.parts), name
    assert path.as_posix() == name, name
    return name


def remote_only() -> None:
    if not __debug__ or sys.flags.optimize:
        raise RuntimeError("Optimization must remain disabled so provenance assertions cannot be removed")
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Run only through ssh test-env")


def new_temporary_directory(path: Path) -> Path:
    resolved = path.resolve()
    assert resolved.is_relative_to(Path("/tmp")) and resolved != Path("/tmp"), "Use a new /tmp child directory"
    assert "dist" not in resolved.parts, "Publishing directories are outside this script's scope"
    assert not resolved.exists(), "Existing staging and evidence directories must remain untouched"
    return resolved


def regular_source(root: Path, name: str) -> bytes:
    name = relative_name(name)
    path = root / name
    assert path.is_file() and path.resolve().is_relative_to(root), f"Missing or escaping source: {name}"
    assert not any(parent.is_symlink() for parent in (path, *path.parents) if parent != root.parent), name
    return path.read_bytes()


def package_sources(root: Path) -> dict[str, bytes]:
    """Mirror tools/package.py's production allowlist without building an archive."""
    candidates = [root / "main.lua", root / "_meta.lua"]
    for directory in ("bilicomics", "l10n", "patches"):
        candidates.extend(path for path in (root / directory).rglob("*") if path.is_file())
    result = {}
    for candidate in sorted(candidates):
        name = candidate.relative_to(root).as_posix()
        parts = PurePosixPath(name).parts
        if any(part in {".secrets", "node_modules", "build", "test", "tests", "accounts", "temporary", "documents", "covers"}
               for part in parts):
            continue
        assert candidate.name not in {"session.dat", "session.json", "cookies.json", "cookies.txt", "state.sqlite3"}, name
        if candidate.suffix not in {".lua", ".so", ".json", ".md"} and "licenses" not in parts \
                and candidate.name not in {"LICENSE", "NOTICE", "COPYING"}:
            continue
        assert name not in result, name
        result[name] = regular_source(root, name)
    return result


def manifest_archive(path: Path, expected: dict | None = None) -> tuple[dict, dict[str, bytes]]:
    manifest = read_json(path)
    assert manifest["archive"] == Path(manifest["archive"]).name
    archive_path = path.with_name(manifest["archive"])
    assert digest(archive_path.read_bytes()) == manifest["sha256"], "Archive does not match its manifest"
    if expected:
        assert manifest["sha256"] == expected["sha256"] and len(manifest["files"]) == expected["files"], "Baseline changed"
    entries = {relative_name(item["path"]): item for item in manifest["files"]}
    assert len(entries) == len(manifest["files"]), "Duplicate manifest paths"
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), "Duplicate archive paths"
        assert set(names) == {PREFIX + name for name in entries}, "Unexpected archive members"
        result = {}
        for name, item in entries.items():
            data = archive.read(PREFIX + name)
            mode = archive.getinfo(PREFIX + name).external_attr >> 16
            assert mode & 0o170000 in {0, 0o100000}, "Only regular packaged files are allowed"
            assert digest(data) == item["sha256"] and len(data) == item["bytes"], name
            result[name] = data
    return manifest, result


@dataclass(frozen=True)
class Token:
    value: bytes
    start: int
    end: int


def lua_tokens(data: bytes) -> list[Token]:
    """Tokenize enough Lua syntax to locate blocks without executing Lua."""
    result, offset, length = [], 0, len(data)
    while offset < length:
        start, byte = offset, data[offset]
        if byte in b" \t\r\n\v\f":
            offset += 1
            continue
        comment = data.startswith(b"--", offset)
        if comment:
            offset += 2
        long_string = re.match(rb"\[(=*)\[", data[offset:])
        if long_string:
            closing = b"]" + long_string[1] + b"]"
            end = data.find(closing, offset + long_string.end())
            assert end >= 0, "Unterminated Lua long string or comment"
            offset = end + len(closing)
            continue
        if comment:
            end = data.find(b"\n", offset)
            offset = length if end < 0 else end + 1
            continue
        if byte in (34, 39):
            offset += 1
            while offset < length:
                if data[offset] == 92:
                    offset += 2
                elif data[offset] == byte:
                    offset += 1
                    break
                else:
                    offset += 1
            else:
                raise AssertionError("Unterminated Lua quoted string")
            continue
        word = re.match(rb"[A-Za-z_][A-Za-z_0-9]*", data[offset:])
        if word:
            offset += word.end()
            result.append(Token(word[0], start, offset))
        else:
            offset += 1
            result.append(Token(data[start:offset], start, offset))
    return result


def block_depths(tokens: list[Token]) -> list[int]:
    stack, depths = [], []
    for token in tokens:
        depths.append(len(stack))
        value = token.value
        if value in {b"function", b"if", b"repeat"}:
            stack.append(value)
        elif value in {b"for", b"while"}:
            stack.append(b"pending_loop")
        elif value == b"do":
            if stack and stack[-1] == b"pending_loop":
                stack[-1] = b"loop"
            else:
                stack.append(b"do")
        elif value in {b"end", b"until"}:
            assert stack, "Unbalanced top-level Lua block"
            previous = stack.pop()
            assert (value == b"until") == (previous == b"repeat"), "Unbalanced Lua block terminator"
    assert not stack, "Unterminated top-level Lua block"
    return depths


def function_span(data: bytes, symbol: str, required: bool = True) -> tuple[int, int] | None:
    assert re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*(?:[.:][A-Za-z_][A-Za-z_0-9]*)*", symbol), symbol
    tokens = lua_tokens(data)
    depths = block_depths(tokens)
    wanted = re.findall(rb"[A-Za-z_][A-Za-z_0-9]*|[.:]", symbol.encode("ascii"))
    matches = []
    for index, token in enumerate(tokens):
        if token.value != b"function":
            continue
        if [item.value for item in tokens[index + 1:index + 1 + len(wanted)]] != wanted:
            continue
        if index + 1 + len(wanted) >= len(tokens) or tokens[index + 1 + len(wanted)].value != b"(":
            continue
        line_start = data.rfind(b"\n", 0, token.start) + 1
        prefix = data[line_start:token.start]
        assert prefix in {b"", b"local "}, f"Only top-level declarations may be migrated: {symbol}"
        assert depths[index] == 0, f"A nested or conditional declaration cannot be migrated: {symbol}"
        stack = [b"function"]
        for current in tokens[index + 1:]:
            value = current.value
            if value in {b"function", b"if", b"repeat"}:
                stack.append(value)
            elif value in {b"for", b"while"}:
                stack.append(b"pending_loop")
            elif value == b"do":
                if stack[-1] == b"pending_loop":
                    stack[-1] = b"loop"
                else:
                    stack.append(b"do")
            elif value in {b"end", b"until"}:
                assert stack, symbol
                previous = stack.pop()
                assert (value == b"until") == (previous == b"repeat"), f"Unbalanced Lua block: {symbol}"
                if not stack:
                    matches.append((line_start, current.end))
                    break
        else:
            raise AssertionError(f"Unterminated Lua function: {symbol}")
    assert len(matches) <= 1, f"Duplicate function: {symbol}"
    if required:
        assert matches, f"Missing function: {symbol}"
    return matches[0] if matches else None


def function_bytes(data: bytes, symbol: str) -> bytes:
    start, end = function_span(data, symbol)
    return data[start:end]


def replace_functions(reading: bytes, preview: bytes, current: bytes, symbols: list[str]) -> tuple[bytes, list[dict]]:
    changes, evidence = [], []
    for symbol in symbols:
        start, end = function_span(reading, symbol)
        original = reading[start:end]
        assert original == function_bytes(preview, symbol), f"The old baselines disagree on {symbol}"
        replacement = function_bytes(current, symbol)
        assert replacement != original, f"The selected function has no current change: {symbol}"
        changes.append((start, end, replacement))
        evidence.append({"symbol": symbol, "baseline_function_sha256": digest(original),
                         "source_function_sha256": digest(replacement), "baseline_functions_identical": True})
    assert len(symbols) == len(set(symbols)), "Duplicate migration symbols"
    for start, end, replacement in sorted(changes, reverse=True):
        reading = reading[:start] + replacement + reading[end:]
    for item in evidence:
        assert digest(function_bytes(reading, item["symbol"])) == item["source_function_sha256"]
    return reading, evidence


def locale_entries(data: bytes) -> dict[str, bytes]:
    result = {}
    for match in re.finditer(rb'^([ \t]*\[((?:"(?:\\.|[^"\\])*"))\][ \t]*=[^\r\n]*,)[ \t]*\r?$', data, re.M):
        key = json.loads(match[2].decode("utf-8"))
        assert key not in result, f"Duplicate locale key: {key}"
        result[key] = match[1]
    return result


def add_locale_entries(reading: bytes, preview: bytes, current: bytes, keys: list[str]) -> tuple[bytes, list[dict]]:
    old, previous, source = (locale_entries(data) for data in (reading, preview, current))
    assert keys and len(keys) == len(set(keys)), "Provide each new reading locale key exactly once"
    position = reading.rfind(b"}")
    assert position >= 0 and not reading[position + 1:].strip(), "Expected one returned locale table"
    newline = b"\r\n" if b"\r\n" in reading else b"\n"
    entries = []
    for key in keys:
        assert key not in old and key not in previous, f"Only new reading locale keys may be added: {key}"
        assert key in source, f"Missing source locale entry: {key}"
        entries.append(source[key])
    changed = reading[:position] + newline.join(entries) + newline + reading[position:]
    output = locale_entries(changed)
    assert {key: value for key, value in output.items() if key not in keys} == old
    assert set(output) == set(old) | set(keys)
    return changed, [{"key": key, "source_entry_sha256": digest(source[key])} for key in keys]


def file_hashes(files: dict[str, bytes]) -> dict[str, str]:
    return {name: digest(data) for name, data in sorted(files.items())}


def load_stage(path: Path) -> dict:
    receipt = read_json(path)
    assert receipt["schema_version"] == 1 and receipt["staged"] is True
    assert set(receipt["packages"]) == {"reading", "preview"}
    working = Path(receipt["working_source"])
    manifests, reading, preview, provenance = derive_sources(working,
        Path(receipt["packages"]["reading"]["baseline_manifest"]),
        Path(receipt["packages"]["preview"]["baseline_manifest"]), receipt["recipe"])
    assert receipt["reading_provenance"] == provenance
    assert receipt["recipe_sha256"] == digest(json.dumps(READING_RECIPE, sort_keys=True).encode("utf-8"))
    assert receipt["working_source_sha256"] == file_hashes(preview), "The frozen working source changed"
    expected_packages = {"reading": reading, "preview": preview}
    package_tool_digest = digest(regular_source(working, "tools/package.py"))
    for kind, package in receipt["packages"].items():
        expected = file_hashes(expected_packages[kind])
        assert file_hashes(package_sources(Path(package["source_root"]))) == package["source_sha256"] == expected, f"Stage changed: {kind}"
        assert package["files"] == BASELINES[kind]["files"] and package["changed_paths"] == sorted(CHANGED_PATHS)
        assert package["unchanged_files"] == BASELINES[kind]["files"] - len(CHANGED_PATHS)
        assert package["baseline_archive_sha256"] == manifests[kind]["sha256"]
        assert digest(regular_source(Path(package["source_root"]), "tools/package.py")) == package["packaging_tool_sha256"] == package_tool_digest
    return receipt


def derive_sources(working: Path, reading_manifest: Path, preview_manifest: Path, recipe: dict) -> tuple[dict, dict, dict, dict]:
    assert recipe == READING_RECIPE, "The reading migration must match the reviewed recipe exactly"
    assert set(recipe) == {"model_replacements", "screen_replacements", "helper_insertions", "locale_keys"}
    manifests, baselines = {}, {}
    manifest_paths = {"reading": reading_manifest, "preview": preview_manifest}
    for kind in BASELINES:
        manifests[kind], baselines[kind] = manifest_archive(manifest_paths[kind], BASELINES[kind])
    assert set(baselines["preview"]) - set(baselines["reading"]) == PREVIEW_ONLY
    assert set(baselines["reading"]) <= set(baselines["preview"])
    current = package_sources(working)
    assert set(current) == set(baselines["preview"]), "The full working preview must keep the exact 95-file allowlist"
    changed_preview = {name for name in current if current[name] != baselines["preview"][name]}
    assert changed_preview == CHANGED_PATHS, f"Unexpected or missing current paths: {sorted(changed_preview)}"
    result = dict(baselines["reading"])
    provenance = {}
    for name in WHOLE_FILES:
        assert baselines["reading"][name] == baselines["preview"][name], f"Whole-file old baselines differ: {name}"
        result[name] = current[name]
        provenance[name] = {"mode": "whole_file", "baseline_files_identical": True}
    symbols = {CONTROLLER: list(CONTROLLER_SYMBOLS), MODEL: recipe["model_replacements"], SCREENS: recipe["screen_replacements"]}
    assert symbols[SCREENS], "Supply the reviewed reading Screens function list"
    assert symbols[MODEL] or any(item.get("path") == MODEL for item in recipe["helper_insertions"]), "Supply the reviewed Model change"
    for name, names in symbols.items():
        assert all(isinstance(symbol, str) and not READING_SYMBOL.search(symbol) for symbol in names), "Payment UI symbols cannot enter reading"
        prefix = "Controller:" if name == CONTROLLER else "Model." if name == MODEL else "Screens:"
        assert all(symbol.startswith(prefix) for symbol in names)
        result[name], items = replace_functions(result[name], baselines["preview"][name], current[name], names)
        provenance[name] = {"mode": "selected_functions", "functions": items, "outside_selected_changes_is_baseline": True}
    for insertion in recipe["helper_insertions"]:
        assert set(insertion) == {"path", "symbol", "before_symbol"}
        name, symbol, before = insertion["path"], insertion["symbol"], insertion["before_symbol"]
        assert name in {MODEL, SCREENS} and not READING_SYMBOL.search(symbol)
        assert function_span(baselines["reading"][name], symbol, False) is None
        assert function_span(baselines["preview"][name], symbol, False) is None
        helper = function_bytes(current[name], symbol)
        position, _ = function_span(result[name], before)
        result[name] = result[name][:position] + helper + b"\n\n" + result[name][position:]
        provenance[name].setdefault("inserted_helpers", []).append({"symbol": symbol, "before_symbol": before,
            "source_function_sha256": digest(helper), "absent_from_both_baselines": True})
    result[LOCALE], entries = add_locale_entries(result[LOCALE], baselines["preview"][LOCALE], current[LOCALE], recipe["locale_keys"])
    provenance[LOCALE] = {"mode": "new_reading_locale_entries", "entries": entries, "all_previous_entries_unchanged": True}
    changed_reading = {name for name in result if result[name] != baselines["reading"][name]}
    assert changed_reading == CHANGED_PATHS and len(result) == 91
    assert not (PREVIEW_ONLY & set(result))
    for name in set(result) - CHANGED_PATHS:
        assert result[name] == baselines["reading"][name], f"Unapproved reading change: {name}"
    for name in PREVIEW_ONLY:
        assert current[name] == baselines["preview"][name], f"Existing preview-only files changed: {name}"
    return manifests, result, current, provenance


def stage(args: argparse.Namespace) -> None:
    destination = new_temporary_directory(args.output)
    working = args.working_source.resolve()
    recipe = read_json(args.recipe) if args.recipe else READING_RECIPE
    manifests, result, current, provenance = derive_sources(working, args.reading_baseline.resolve(), args.preview_baseline.resolve(), recipe)
    package_tool = regular_source(working, "tools/package.py")
    destination.mkdir(mode=0o700)
    packages = {}
    for kind, files in (("reading", result), ("preview", current)):
        root = destination / kind
        root.mkdir()
        for name, data in sorted(files.items()):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as output:
                output.write(data)
        (root / "tools").mkdir()
        with (root / "tools/package.py").open("xb") as output:
            output.write(package_tool)
        hashes = file_hashes(files)
        assert file_hashes(package_sources(root)) == hashes
        packages[kind] = {"source_root": str(root), "source_sha256": hashes, "files": len(files),
            "packaging_tool_sha256": digest(package_tool),
            "baseline_archive_sha256": manifests[kind]["sha256"],
            "baseline_manifest": str(getattr(args, kind + "_baseline").resolve()),
            "changed_paths": sorted(CHANGED_PATHS), "unchanged_files": len(files) - len(CHANGED_PATHS)}
    receipt = {"schema_version": 1, "staged": True, "packages": packages, "reading_provenance": provenance,
        "working_source": str(working), "working_source_sha256": file_hashes(current),
        "recipe": recipe, "recipe_sha256": digest(json.dumps(recipe, sort_keys=True).encode("utf-8")),
        "staging_script_sha256": digest(Path(__file__).read_bytes()), "remote_host": socket.gethostname(),
        "reading_excludes_preview_only_files": sorted(PREVIEW_ONLY), "preview_keeps_full_working_allowlist": True,
        "archive_built": False, "dist_modified": False, "modules_executed": False,
        "scope": "Only source staging and exact baseline/source identity; no application acceptance claim"}
    write_new_json(destination / "staging.json", receipt)
    print(json.dumps({"staged": True, "receipt": str(destination / "staging.json"), "reading_files": 91, "preview_files": 95}))


def syntax(args: argparse.Namespace) -> None:
    destination = new_temporary_directory(args.output)
    receipt = load_stage(args.staging.resolve())
    runtime = args.runtime.resolve()
    assert (runtime / "git-rev").read_text().strip() == "v2026.07.1", "Use the official pinned KOReader runtime"
    destination.mkdir(mode=0o700)
    packages = {}
    for kind, package in receipt["packages"].items():
        home = destination / kind / "home"
        home.mkdir(parents=True)
        entries = []
        for index, name in enumerate(package["changed_paths"]):
            assert name.endswith(".lua"), "This revision expects only changed Lua sources"
            source = Path(package["source_root"]) / name
            expected = package["source_sha256"][name]
            assert digest(source.read_bytes()) == expected
            bytecode = destination / kind / f"{index}.luac"
            env = {"PATH": os.defpath, "HOME": str(home), "KO_HOME": str(home), "LANG": "C.UTF-8",
                   "LUA_PATH": str(runtime / "?.lua"), "LUA_CPATH": str(runtime / "libs/?.so")}
            completed = subprocess.run(["unshare", "-n", "--", str(runtime / "luajit"), "-b", str(source), str(bytecode)],
                cwd=runtime, env=env, capture_output=True, text=True, timeout=30)
            entries.append({"path": name, "sha256": expected, "returncode": completed.returncode,
                "source_unchanged": digest(source.read_bytes()) == expected, "bytecode_written": bytecode.is_file(),
                "mode": "LuaJIT -b compile only", "network_namespace_isolated": True,
                "lua_initialization_disabled": True, "lua_search_paths_pinned_to_runtime": True,
                "compiler_output": completed.stdout + completed.stderr})
        packages[kind] = {"files": entries, "passed": all(item["returncode"] == 0 and item["source_unchanged"]
            and item["bytecode_written"] for item in entries)}
    report = {"passed": all(package["passed"] for package in packages.values()), "packages": packages,
        "modules_executed": False, "purchase_tests_executed": False, "remote_host": socket.gethostname(),
        "staging_receipt_sha256": digest(args.staging.read_bytes()), "runtime_version": "v2026.07.1",
        "luajit_sha256": digest((runtime / "luajit").read_bytes()),
        "scope": "Remote syntax compilation of staged changed files only; no application behavior, payment, or visible UI execution"}
    write_new_json(destination / "syntax.json", report)
    print(json.dumps({"passed": report["passed"], "result": str(destination / "syntax.json")}))
    assert report["passed"], "A staged source failed syntax compilation"


def focused_sources(path: Path, kind: str) -> tuple[dict, dict[str, str]]:
    report = read_json(path)
    assert report.get("passed") is True and report.get("source_unchanged") is True, f"Focused evidence failed: {path}"
    assert report.get("purchase_tests_executed") is False, "Focused evidence must explicitly exclude purchase tests"
    sources = report.get("source_sha256")
    assert isinstance(sources, dict) and sources, "Focused evidence needs exact source_sha256 mappings"
    result = {}
    for name, value in sources.items():
        relative_name(name)
        assert isinstance(value, str) and SHA256.fullmatch(value), name
        result[name] = value
    if kind == "connectivity":
        assert report.get("runtime_version") == "v2026.07.1" and report.get("network_namespace_isolated") is True
        assert report.get("network_requests") == 0 and report.get("real_session_used") is False
        assert report.get("quote_tests_executed") is False and report.get("wallet_tests_executed") is False
        suites = report.get("suites", [])
        assert len(suites) == 2 and {suite["suite"] for suite in suites} == {"service", "runner"}
        for suite in suites:
            assert suite["passed"] is True and suite["returncode"] == 0 and suite["timed_out"] is False
            observed = suite["result"]
            assert observed["passed"] is True and observed["tests"] and observed["assertions"]
            assert all(item["passed"] is True for item in observed["tests"] + observed["assertions"])
        allowed = {CONTROLLER, *WHOLE_FILES}
    elif kind == "entitlement_display":
        assert report.get("spec") == "native-entitlement-display" and report.get("interrupted") is False
        assert report.get("source_sha256_after") == sources
        assert set(report["required_sizes"]) == set(report["requested_sizes"]) == {"600x800", "480x640"}
        runs = report.get("runs", [])
        assert len(runs) == 2 and {(run["width"], run["height"]) for run in runs} == {(600, 800), (480, 640)}
        for run in runs:
            assert run["passed"] is True and run["result_passed"] is True and run["returncode"] == 0
            result_file = path.parent / relative_name(run["result_file"])
            observed = read_json(result_file)
            assert observed["spec"] == "native-entitlement-display" and observed["passed"] is True
            assert observed["read_only_metadata"] is True and observed["purchase_tests_executed"] is False
            assert observed["width"] == run["width"] and observed["height"] == run["height"]
            assert observed["assertions"] and all(item["passed"] is True for item in observed["assertions"])
        allowed = {MODEL, SCREENS, LOCALE}
    else:
        raise AssertionError("Unknown focused evidence kind")
    assert allowed <= set(result), f"Focused evidence is missing its own component sources: {kind}"
    return report, {name: result[name] for name in sorted(allowed)}


def bind(args: argparse.Namespace) -> None:
    destination = new_temporary_directory(args.output)
    receipt = load_stage(args.staging.resolve())
    working = package_sources(Path(receipt["working_source"]))
    assert file_hashes(working) == receipt["working_source_sha256"], "The frozen working source changed after staging"
    syntax_report = read_json(args.syntax)
    assert syntax_report["passed"] is True and syntax_report["modules_executed"] is False
    assert syntax_report["purchase_tests_executed"] is False and syntax_report["runtime_version"] == "v2026.07.1"
    assert syntax_report["staging_receipt_sha256"] == digest(args.staging.read_bytes()), "Syntax is bound to another staging receipt"
    focused, covered = [], {}
    for kind, path in (("connectivity", args.network_focused), ("entitlement_display", args.ui_focused)):
        evidence, source_map = focused_sources(path, kind)
        relevant = {}
        for name, value in source_map.items():
            if name in working:
                assert digest(working[name]) == value, f"Focused source differs from the frozen working source: {name}"
                assert name not in covered or covered[name] == value
                covered[name] = relevant[name] = value
        focused.append({"kind": kind, "path": str(path.resolve()), "sha256": digest(path.read_bytes()),
            "scope": evidence.get("scope"), "matching_source_sha256": relevant})
    required_focused = CHANGED_PATHS - {LOCALE}
    assert required_focused <= set(covered), f"Changed source lacks focused evidence: {sorted(required_focused - set(covered))}"
    package_reports = {}
    for kind, staged in receipt["packages"].items():
        manifest_path = getattr(args, kind + "_manifest").resolve()
        manifest, files = manifest_archive(manifest_path)
        assert file_hashes(files) == staged["source_sha256"], f"The packaged {kind} differs from its staged source"
        package_result_path = getattr(args, kind + "_package_result").resolve()
        package_result = read_json(package_result_path)
        assert package_result["passed"] is True and package_result["archive"]["sha256"] == manifest["sha256"]
        assert package_result["archive"]["files"] == staged["files"]
        assert package_result["checks"] and all(item["passed"] is True for item in package_result["checks"])
        compiled = syntax_report["packages"][kind]
        assert compiled["passed"] is True
        checked = {relative_name(item["path"]): item for item in compiled["files"]}
        assert set(checked) == set(staged["changed_paths"]), "Syntax must cover exactly this staged revision's changed files"
        for name, entry in checked.items():
            assert entry["sha256"] == staged["source_sha256"][name]
            assert entry["returncode"] == 0 and entry["source_unchanged"] is True and entry["bytecode_written"] is True
            assert entry["network_namespace_isolated"] is True
            assert entry["lua_initialization_disabled"] is True and entry["lua_search_paths_pinned_to_runtime"] is True
        package_reports[kind] = {"archive_file": manifest["archive"], "archive_sha256": manifest["sha256"],
            "archive_bytes": manifest_path.with_name(manifest["archive"]).stat().st_size,
            "packaged_files": staged["files"], "baseline_archive_sha256": staged["baseline_archive_sha256"],
            "changed_paths": staged["changed_paths"], "unchanged_files": staged["unchanged_files"],
            "all_packaged_bytes_match_staging": True, "syntax_checked_files": {name: item["sha256"] for name, item in checked.items()},
            "package_result": str(package_result_path), "package_result_sha256": digest(package_result_path.read_bytes())}
    report = {"schema_version": 1, "bound": True, "packages": package_reports,
        "staging_receipt": str(args.staging.resolve()), "staging_receipt_sha256": digest(args.staging.read_bytes()),
        "syntax_evidence": str(args.syntax.resolve()), "syntax_evidence_sha256": digest(args.syntax.read_bytes()),
        "focused_evidence": focused, "reading_provenance": receipt["reading_provenance"],
        "reading_excludes_preview_only_files": receipt["reading_excludes_preview_only_files"],
        "entrypoints_and_native_libraries_unchanged": True, "preview_keeps_full_working_allowlist": True,
        "focused_components_match_tested_source": True, "whole_archive_runtime_verified": False,
        "live_account_workflow_rerun": False, "live_quote_contract_verified": False,
        "payment_ui_behavior_verified": False, "real_payment_verified": False, "purchase_tests_executed": False,
        "device_verified": False, "local_visible_window_verified": False, "dist_modified": False,
        "remote_host": socket.gethostname(), "binding_script_sha256": digest(Path(__file__).read_bytes()),
        "scope": "Exact baseline, selected-function, focused-source and syntax provenance for the bounded reading revision; prior evidence keeps its original scope and no full live workflow acceptance is claimed"}
    destination.mkdir(mode=0o700)
    write_new_json(destination / "source-binding.json", report)
    print(json.dumps({"bound": True, "result": str(destination / "source-binding.json"),
        "reading_sha256": package_reports["reading"]["archive_sha256"], "preview_sha256": package_reports["preview"]["archive_sha256"]}))


def main() -> None:
    remote_only()
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    staging = commands.add_parser("stage")
    for name in ("working-source", "reading-baseline", "preview-baseline", "output"):
        staging.add_argument("--" + name, type=Path, required=True)
    staging.add_argument("--recipe", type=Path)
    compile_only = commands.add_parser("syntax")
    for name in ("staging", "runtime", "output"):
        compile_only.add_argument("--" + name, type=Path, required=True)
    binding = commands.add_parser("bind")
    for name in ("staging", "syntax", "reading-manifest", "preview-manifest", "reading-package-result", "preview-package-result", "output"):
        binding.add_argument("--" + name, type=Path, required=True)
    binding.add_argument("--network-focused", type=Path, required=True)
    binding.add_argument("--ui-focused", type=Path, required=True)
    args = parser.parse_args()
    {"stage": stage, "syntax": syntax, "bind": bind}[args.command](args)


if __name__ == "__main__":
    main()
