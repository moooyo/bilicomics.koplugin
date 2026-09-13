"""Bind sanitized remote live-reading evidence to the tested development ZIP."""

import hashlib
import json
from collections import Counter
from pathlib import Path
import sys


def main():
    assert sys.platform == "linux", "Run through ssh test-env only"
    root = Path("/tmp/bilicomics-live-chapter-8g1JFqtw")
    assert root.is_dir() and not root.is_symlink()

    def read(relative):
        path = root / relative
        assert path.resolve().is_relative_to(root) and not path.is_symlink()
        return json.loads(path.read_bytes())

    live = read("run3/results.json")
    package = read("package-final/result.json")
    manifest = read("package-final/bilicomics-0.1.0-dev.manifest.json")
    assert live["passed"] and package["passed"]
    tested = live["code_sha256"]["production"]
    packaged = {item["path"]: item["sha256"] for item in manifest["files"]}
    assert all(tested.get(path) == value for path, value in packaged.items()), \
        "Every packaged file must match the live-tested source bytes"
    source_only = sorted(tested.keys() - packaged.keys())
    assert all(path.startswith("bilicomics/protocol/native/")
               and Path(path).suffix in {".c", ".h", ".sh", ".map", ".list", ".py", ".patch"}
               for path in source_only), "Only native build sources may be omitted from the package"
    starts, finishes = Counter(), Counter()
    statuses = Counter()
    for path in sorted((root / "run3").glob("transport-*.jsonl")):
        assert not path.is_symlink()
        for line in path.read_text().splitlines():
            event = json.loads(line)
            if "status" in event:
                statuses[str(event["status"])] += 1
            if event.get("event") == "start":
                starts[event["category"]] += 1
            elif event.get("event") == "finish":
                finishes[event["category"]] += 1
    phases = {}
    for name in ("online", "offline"):
        phase = read("run3/" + name + "-results.json")
        assert phase["passed"] and all(phase["checks"].values())
        phases[name] = {"passed": True, "checks": len(phase["checks"]),
                        "counts": phase["counts"], "launcher": phase["launcher"]}
    report = {
        "date": "2026-09-12", "environment": "ssh test-env",
        "runtime": "Official KOReader v2026.07.1 Linux x86_64",
        "purchase_testing": False, "quote_testing": False, "wallet_testing": False,
        "account_mutation_testing": False,
        "full_chapter_access": "free", "protocol_responses": "real, unmodified",
        "phases": phases, "response_status_counts": dict(statuses),
        "guarded_request_starts_by_category": dict(starts),
        "completed_responses_by_category": dict(finishes),
        "package_files_match_live_tested_source": True,
        "live_snapshot_files": len(tested), "packaged_files": len(packaged),
        "omitted_native_build_source_files": len(source_only),
        "archive": {key: package["archive"][key] for key in ("file", "sha256", "bytes", "files")},
        "reports_sha256": {},
        "limits": ["No physical Scribe execution", "No live encrypted-container wire observed",
                   "No purchase, quote, wallet or batch acceptance", "No full-chapter page-by-page visual inspection"],
    }
    for relative in ("run3/results.json", "run3/online-results.json", "run3/offline-results.json",
                     "package-final/result.json", "page4-fixed/authenticated-readonly-result.json"):
        report["reports_sha256"][relative] = hashlib.sha256((root / relative).read_bytes()).hexdigest()
    (root / "live-reading-summary.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
