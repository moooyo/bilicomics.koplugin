"""Build a deterministic plugin archive from an explicit production allowlist.

Run packaging and archive verification on test-env under the project policy.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    output = args.output.resolve()
    candidates = [root / "main.lua", root / "_meta.lua"]
    for directory in ("bilicomics", "l10n", "patches"):
        candidates.extend(path for path in (root / directory).rglob("*") if path.is_file())
    allowed_suffixes = {".lua", ".so", ".json", ".md"}
    files = []
    for candidate in sorted(candidates):
        relative = candidate.relative_to(root)
        if candidate.is_symlink() or not candidate.resolve().is_relative_to(root):
            raise RuntimeError("Package inputs must stay inside the project")
        if any(part in {".secrets", "node_modules", "build", "test", "tests", "accounts", "temporary", "documents", "covers"} for part in relative.parts):
            continue
        if candidate.name in {"session.dat", "session.json", "cookies.json", "cookies.txt", "state.sqlite3"}:
            raise RuntimeError("Account data must not enter the plugin archive")
        if candidate.suffix not in allowed_suffixes and "licenses" not in relative.parts and candidate.name not in {"LICENSE", "NOTICE", "COPYING"}:
            continue
        files.append((candidate, relative.as_posix()))
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = []
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for candidate, relative in files:
            content = candidate.read_bytes()
            info = zipfile.ZipInfo("bilicomics.koplugin/" + relative, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content)
            manifest.append({"path": relative, "sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)})
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("The package failed archive integrity verification")
    report = {"archive": output.name, "sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "files": manifest}
    output.with_suffix(".manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"archive": str(output), "files": len(files), "sha256": report["sha256"]}))


if __name__ == "__main__":
    main()
