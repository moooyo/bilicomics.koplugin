"""Extract a separate Debian ARM runtime for limited ABI evidence, never installation."""

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")
DESTINATION = ROOT / "debian"
DESTINATION.mkdir(mode=0o700, exist_ok=True)
report = {"scope": "Debian ARM sysroot, not a Kindle firmware or Kindle glibc baseline", "packages": []}
for package in ("libc6-armhf-cross=2.41-11cross1", "libgcc-s1-armhf-cross=14.2.0-19cross1",
                "libstdc++6-armhf-cross=14.2.0-19cross1"):
    metadata = subprocess.check_output(["apt-cache", "show", package], text=True)
    fields = dict(line.split(": ", 1) for line in metadata.splitlines() if ": " in line and not line.startswith(" "))
    (DESTINATION / (fields["Package"] + "-metadata.txt")).write_text(metadata)
    subprocess.check_call(["apt-get", "download", package], cwd=DESTINATION)
    archives = list(DESTINATION.glob(fields["Package"] + "_*.deb"))
    assert len(archives) == 1
    archive = archives[0]
    assert archive.stat().st_size == int(fields["Size"])
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == fields["SHA256"]
    producer = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", str(archive)], stdout=subprocess.PIPE)
    try:
        subprocess.check_call(["tar", "-xf", "-", "-C", str(DESTINATION), "./usr/arm-linux-gnueabihf/lib"],
                              stdin=producer.stdout)
    finally:
        producer.stdout.close()
    assert producer.wait() == 0
    report["packages"].append({"package": package, "filename": fields["Filename"],
                               "bytes": int(fields["Size"]), "sha256": fields["SHA256"]})
(ROOT / "debian-preparation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
