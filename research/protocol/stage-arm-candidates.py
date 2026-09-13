"""Stage rebuilt ARM candidates with their exact integrity records for remote probes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser()
    for name in ("source", "build", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    source, build, output = (path.resolve() for path in (args.source, args.build, args.output))
    if output.exists():
        raise RuntimeError("Use a new candidate stage")
    report = json.loads((build / "elf-verification.json").read_text())
    output.mkdir(mode=0o700, parents=True)
    shutil.copytree(source / "bilicomics", output / "bilicomics")
    native = output / "bilicomics/protocol/native"
    for candidate in report["libraries"]:
        name = candidate["name"]
        assert name in ("libbiliwasm.so", "libbilicrypto.so")
        assert candidate["adjacent_dynamic_ranges"] and candidate["effective_bind_now"] and candidate["gnu_relro"]
        compiled = build / "output" / name
        assert hashlib.sha256(compiled.read_bytes()).hexdigest() == candidate["sha256"]
        assert compiled.stat().st_size == candidate["bytes"]
        shutil.copyfile(compiled, native / "bin/linux-armhf" / name)
        manifest_path = native / ("manifest.json" if name == "libbiliwasm.so" else "portable/manifest.json")
        manifest = json.loads(manifest_path.read_text())
        entry = manifest["libraries"]["linux-armhf"]
        entry.update(sha256=candidate["sha256"], bytes=candidate["bytes"],
                     verification="rebuilt-arm-relocation-layout-candidate", device_verified=False,
                     relocation_layout="adjacent REL and JMPREL with BIND_NOW and GNU_RELRO")
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"candidate_stage": str(output), "libraries": len(report["libraries"])}))


if __name__ == "__main__":
    main()
