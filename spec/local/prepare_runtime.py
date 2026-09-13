"""Prepare an isolated official KOReader runtime for requested local acceptance."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import urllib.request


VERSION = "v2026.07.1"
ARCHIVE = "koreader-linux-x86_64-" + VERSION + ".tar.xz"
URL = "https://github.com/koreader/koreader/releases/download/" + VERSION + "/" + ARCHIVE
SHA256 = "299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0"
SIZE = 30144476


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main():
    assert sys.platform == "linux", "Run inside the requested local WSL environment"
    os.umask(0o077)
    root = Path.home() / ".local/share/bilicomics-acceptance"
    assert not root.is_symlink()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    assert root.stat().st_uid == os.geteuid()
    root.chmod(0o700)
    downloads = root / "downloads"
    downloads.mkdir(mode=0o700, exist_ok=True)
    assert not downloads.is_symlink()
    archive = downloads / ARCHIVE
    assert not archive.is_symlink()
    if not archive.exists():
        partial = downloads / (ARCHIVE + ".part")
        assert not partial.is_symlink()
        request = urllib.request.Request(URL, headers={"User-Agent": "BiliComics-local-acceptance"})
        with urllib.request.urlopen(request, timeout=60) as source, partial.open("wb") as target:
            shutil.copyfileobj(source, target)
        assert partial.stat().st_size == SIZE and digest(partial) == SHA256
        partial.replace(archive)
    assert archive.stat().st_size == SIZE and digest(archive) == SHA256
    installation = root / ("runtime-" + VERSION)
    assert not installation.is_symlink()
    if not installation.exists():
        staging = Path(tempfile.mkdtemp(prefix=".runtime-staging-", dir=root))
        with tarfile.open(archive, "r:xz") as bundle:
            bundle.extractall(staging, filter="data")
        assert (staging / "lib/koreader/git-rev").read_text().strip() == VERSION
        staging.rename(installation)
    runtime = installation / "lib/koreader"
    assert (runtime / "git-rev").read_text().strip() == VERSION
    report = {"runtime": str(runtime), "version": VERSION, "archive_url": URL,
              "archive_sha256": SHA256, "archive_bytes": SIZE,
              "source": "Official GitHub release asset and its published digest",
              "local_verification_requested": True, "global_installation": False}
    (root / "runtime-preparation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
