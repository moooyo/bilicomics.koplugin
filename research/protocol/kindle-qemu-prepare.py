"""Prepare an isolated remote Kindle ABI probe without installing packages."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")
ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(ROOT, 0o700)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True)


with urllib.request.urlopen(
    "https://api.github.com/repos/koreader/koxtoolchain/releases/tags/2026.08"
) as response:
    release = json.load(response)
asset = next(item for item in release["assets"] if item["name"] == "kindlehf.tar.zst")
expected = asset["digest"].removeprefix("sha256:")
assert re.fullmatch("[a-f0-9]{64}", expected)
archive = ROOT / asset["name"]
if not archive.exists():
    print("Downloading the official Kindle hard-float toolchain archive", flush=True)
    urllib.request.urlretrieve(asset["browser_download_url"], archive)
assert archive.stat().st_size == asset["size"] and digest(archive) == expected

package = "qemu-user=1:10.0.11+ds-0+deb13u1"
metadata = run("apt-cache", "show", package)
fields = dict(line.split(": ", 1) for line in metadata.splitlines() if ": " in line and not line.startswith(" "))
(ROOT / "qemu-package-metadata.txt").write_text(metadata)
package_path = ROOT / "qemu-user_1%3a10.0.11+ds-0+deb13u1_amd64.deb"
archives = list(ROOT.glob("qemu-user*.deb"))
if not archives:
    print("Downloading QEMU from the configured Debian package repository", flush=True)
    subprocess.check_call(["apt-get", "download", package], cwd=ROOT)
    archives = list(ROOT.glob("qemu-user*.deb"))
assert len(archives) == 1
package_path = archives[0]
assert package_path.stat().st_size == int(fields["Size"])
assert digest(package_path) == fields["SHA256"]

listing = run("tar", "--zstd", "-tf", str(archive))
(ROOT / "toolchain-archive-files.txt").write_text(listing)
report = {
    "scope": "Remote preparation only; no target program has been executed",
    "toolchain": {"url": asset["browser_download_url"], "bytes": asset["size"], "sha256": expected},
    "qemu_package": {"package": package, "filename": fields["Filename"],
                     "bytes": package_path.stat().st_size, "sha256": fields["SHA256"]},
    "global_installation": False,
    "binfmt_registration": False,
    "kindle_firmware_image": False,
}
(ROOT / "preparation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
print("Relevant sysroot entries:")
print("\n".join(line for line in listing.splitlines() if "sysroot/lib/" in line and
                any(name in line for name in ("ld-", "libc.", "libc-", "libm.", "libpthread.", "libdl.", "librt."))))
