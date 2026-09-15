"""Index captured recharge PNG filenames for an offline preview without copying images."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re


SIZES = ("600x800", "480x640")
SCENE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def build(screens, output):
    records = {}
    for size in SIZES:
        directory = screens / size
        if not directory.is_dir():
            continue
        for image in sorted(directory.glob("*.png")):
            if not SCENE_ID.fullmatch(image.stem):
                raise ValueError("Unexpected screenshot filename: " + image.name)
            record = records.setdefault(image.stem, {"id": image.stem, "sizes": []})
            record["sizes"].append(size)
    data = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "captureCount": sum(len(record["sizes"]) for record in records.values()),
        "scenes": [records[key] for key in sorted(records)],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("window.RECHARGE_PREVIEW_MANIFEST = " + json.dumps(data, ensure_ascii=False, indent=2) + ";\n", encoding="utf-8")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screens", type=Path, required=True, help="Directory containing 600x800 and 480x640 PNG capture folders.")
    parser.add_argument("--output", type=Path, required=True, help="Destination manifest.js path inside the preview folder.")
    args = parser.parse_args()
    data = build(args.screens, args.output)
    print(json.dumps({"scenes": len(data["scenes"]), "captures": data["captureCount"], "output": str(args.output)}))


if __name__ == "__main__":
    main()
