"""Refresh the pinned subset on test-env or an explicitly authorized host."""

import argparse
import hashlib
import io
import json
import pathlib
import subprocess
import tarfile
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path,
                        help="Use an existing remote archive instead of downloading it")
    parser.add_argument("--check", action="store_true",
                        help="Verify the checked-in subset without downloading or changing it")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    dependency = json.loads((root / "dependency.json").read_text())
    destination = root / "vendor" / "mbedtls"
    if args.check:
        expected = json.loads((root / "vendored-sha256.json").read_text())
        actual = {str(path.relative_to(destination).as_posix()):
                  hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in destination.rglob("*") if path.is_file()}
        if actual != expected:
            raise RuntimeError("The vendored files do not match the maintained manifest")
        print(json.dumps({"status": "pass", "files": len(actual)}, indent=2))
        return
    if args.archive:
        archive = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(dependency["archive_url"], timeout=120) as response:
            archive = response.read()
    actual = hashlib.sha256(archive).hexdigest()
    if actual != dependency["archive_sha256"]:
        raise RuntimeError("The downloaded archive does not match the pinned SHA-256")
    names = (root / "vendor-files.list").read_text().splitlines()
    upstream_hashes = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
        prefix = "mbedtls-" + dependency["commit"] + "/"
        for name in names:
            relative = pathlib.PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Unsafe path in the maintained vendor file list")
            member = package.getmember(prefix + name)
            if not member.isfile():
                raise RuntimeError("The maintained vendor list must contain regular files")
            content = package.extractfile(member).read()
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            upstream_hashes[name] = hashlib.sha256(content).hexdigest()
    for patch in dependency["patches"]:
        subprocess.run(["patch", "-p1", "--batch", "--forward", "--fuzz=0", "-i", str(root / patch)],
                       cwd=destination, check=True)
    vendored_hashes = {
        name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
        for name in names
    }
    for name, manifest in [("upstream-sha256.json", upstream_hashes),
                           ("vendored-sha256.json", vendored_hashes)]:
        (root / name).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"release": dependency["release"], "files": len(names),
                      "archive_sha256": actual, "patches": dependency["patches"]}, indent=2))


if __name__ == "__main__":
    main()
