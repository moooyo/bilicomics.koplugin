"""Observe the unchanged official loader's ARM self-relocation instruction states."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    sysroot = ROOT / "x-tools/arm-kindlehf-linux-gnueabihf/arm-kindlehf-linux-gnueabihf/sysroot"
    loader = sysroot / "lib/ld-2.20.so"
    original = loader.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    assert digest == "6f4bbe8b68bf2bf290c6125d4ccee6a44df4451e30866e75beecbcb7f1c4011c"
    assert original[:5] == b"\x7fELF\x01"
    entry = struct.unpack_from("<I", original, 24)[0]
    trace = output / "instructions.log"
    command = ["unshare", "-n", str(ROOT / "qemu/usr/bin/qemu-arm"), "-cpu", "cortex-a15",
               "-L", str(sysroot), "-one-insn-per-tb", "-d", "in_asm,cpu", "-D", str(trace), str(loader)]
    result = subprocess.run(command, env={"PATH": "/usr/bin:/bin", "LANG": "C"},
                            cwd=output, capture_output=True, text=True, timeout=15)
    (output / "stderr.log").write_text(result.stderr)
    states = []
    for block in trace.read_text().split("----------------\n"):
        instruction = re.search(r"^0x([0-9a-f]+):\s+(.*)$", block, re.MULTILINE)
        registers = {"r" + str(int(number)): int(value, 16)
                     for number, value in re.findall(r"R(\d\d)=([0-9a-fA-F]+)", block)}
        if instruction and registers:
            states.append({"pc": int(instruction[1], 16), "instruction": instruction[2], "registers": registers})
    assert states, "The instruction trace is empty"
    base = states[0]["pc"] - entry
    selected = []
    offsets = {0x38e4, 0x38e8, 0x38ee, 0x38f2, 0x38f6, 0x3904, 0x3906, 0x3c64, 0x3c68}
    for state in states:
        offset = state["pc"] - base
        if offset in offsets:
            selected.append({"offset": hex(offset), "pc": hex(state["pc"]), "instruction": state["instruction"],
                             "registers": {name: hex(value) for name, value in state["registers"].items()}})
    report = {"scope": "Unmodified official loader instruction-state observation; no plugin or account code",
              "command": command, "returncode": result.returncode, "stderr": result.stderr,
              "loader_sha256": digest, "loader_unchanged": hashlib.sha256(loader.read_bytes()).hexdigest() == digest,
              "entry": hex(entry), "load_base": hex(base), "trace_bytes": trace.stat().st_size,
              "trace_sha256": hashlib.sha256(trace.read_bytes()).hexdigest(), "instruction_states": selected,
              "device_verified": False, "plugin_loaded": False, "purchase_tests_executed": False}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
