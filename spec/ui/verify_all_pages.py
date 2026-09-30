"""Require current-source, rendered evidence for every selected handoff page."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct

SIZES = {(1860, 2480), (480, 640), (600, 800), (960, 720)}
LANGUAGES = {"zh_CN", "C"}
PRIMARY_STATES = {"D4": ("number-match", "jump-results"), "J5": ("connection-failed",)}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def png_size(path):
    with path.open("rb") as image:
        header = image.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"A native capture is not a PNG: {path}")
    return struct.unpack(">II", header[16:24])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--handoff", type=Path, required=True)
    parser.add_argument("--reports", nargs="+", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    plugin, handoff = args.plugin.resolve(), args.handoff.resolve()
    source = (handoff / "BiliComics 设计稿.dc.html").read_text(encoding="utf-8")
    required = dict(re.findall(r'data-screen-label="([A-J][1-6]) ([^"]+)"', source))
    if len(required) != 43:
        raise ValueError("The complete chosen handoff must contain 43 page IDs.")
    evidence = {page: {} for page in required}
    suites, verified_sources = [], {}
    for report_path in args.reports:
        report_path = report_path.resolve()
        report = json.loads(report_path.read_text(encoding="utf-8"))
        if report.get("passed") is not True or report.get("source_unchanged") is not True:
            raise ValueError(f"A suite is not accepted against stable sources: {report_path}")
        hashes = report.get("source_sha256", {})
        if not hashes:
            raise ValueError(f"A suite has no source provenance: {report_path}")
        for name, expected in hashes.items():
            if digest(plugin / name) != expected:
                raise ValueError(f"A verified source has since changed: {name}")
            if name in verified_sources and verified_sources[name] != expected:
                raise ValueError(f"Suites cover different source versions: {name}")
            verified_sources[name] = expected
        seen_cases, assertions, screenshots = set(), 0, 0
        for case in report["cases"]:
            if case.get("passed") is not True or case.get("returncode", 0) != 0:
                raise ValueError(f"A native case failed: {report_path}: {case}")
            width, height, language = case["width"], case["height"], case["language"]
            seen_cases.add((width, height, language))
            result_path = report_path.parent / case["result"]
            result = json.loads(result_path.read_text(encoding="utf-8"))
            checks = result.get("assertions", [])
            if not checks or any(check.get("passed") is not True for check in checks):
                raise ValueError(f"A native result lacks passing requirements: {result_path}")
            assertions += len(checks)
            for capture in result.get("screenshots", []):
                if isinstance(capture, str):
                    name, filename, page = capture, capture, None
                else:
                    name, filename, page = capture["name"], capture["file"], capture.get("design_id")
                image_path = result_path.parent / filename
                actual_size = png_size(image_path)
                screenshots += 1
                if not page:
                    match = re.search(r"(?:^|[-_])([A-J][1-6])(?:[-_.]|$)", name)
                    page = match.group(1) if match else None
                primary = page not in PRIMARY_STATES or any(state in name for state in PRIMARY_STATES[page])
                if page in required and actual_size == (width, height) and primary:
                    key = f"{language}-{width}x{height}"
                    evidence[page].setdefault(key, []).append({
                        "suite": str(report_path), "result": str(result_path),
                        "capture": str(image_path), "sha256": digest(image_path),
                        "assertion_count": len(checks)})
        expected_cases = {(w, h, lang) for w, h in SIZES for lang in LANGUAGES}
        if not expected_cases.issubset(seen_cases):
            raise ValueError(f"A suite omits a required size/language: {report_path}")
        suites.append({"report": str(report_path), "sha256": digest(report_path),
                       "cases": len(seen_cases), "assertions": assertions, "screenshots": screenshots})
    required_keys = {f"{lang}-{w}x{h}" for w, h in SIZES for lang in LANGUAGES}
    missing = {page: sorted(required_keys - captures.keys()) for page, captures in evidence.items()
               if required_keys - captures.keys()}
    acceptance = {"scope": "All 43 selected handoff pages plus supplemental native states",
        "reference_readme_sha256": digest(handoff / "README.md"),
        "reference_html_sha256": digest(handoff / "BiliComics 设计稿.dc.html"),
        "selected_directions": ["1b", "1d", "1h"], "source_sha256": verified_sources,
        "suites": suites, "required_pages": required, "evidence": evidence,
        "missing": missing, "passed": not missing,
        "created_at": datetime.now(timezone.utc).isoformat()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(acceptance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": not missing, "pages": len(required), "missing": missing,
                      "assertions": sum(s["assertions"] for s in suites),
                      "screenshots": sum(s["screenshots"] for s in suites),
                      "report": str(args.output)}, ensure_ascii=False))
    return 1 if missing else 0

if __name__ == "__main__":
    raise SystemExit(main())
