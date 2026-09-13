"""Remove only this probe's private captures after all readers have exited."""
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
if root.parent != Path("/tmp") or not root.name.startswith("bilicomics-auth-") or root.is_symlink() or root.resolve() != root:
    raise SystemExit("Unexpected private probe root")
groups = {name: [] for name in ("catalogs", "indexes", "images", "logs")}
for name in ("metadata", "images-initial", "images-final", "next-pages"):
    directory = root / name
    if directory.is_symlink() or directory.resolve() != directory or not directory.is_dir():
        raise SystemExit("Unexpected probe phase directory")
    for path in directory.iterdir():
        category = (
            "catalogs" if path.name.startswith("comic_") and path.name.endswith("-private-detail.json")
            else "indexes" if path.name.startswith("index-") and path.name.endswith("-private.json")
            else "images" if path.name.startswith("image-") and path.name.endswith(".part")
            else "logs" if path.name in ("stdout.log", "stderr.log")
            else None
        )
        if category:
            if path.is_symlink() or not path.is_file() or path.resolve().parent != directory:
                raise SystemExit("Unexpected capture entry")
            groups[category].append(path)
for paths in groups.values():
    for path in paths:
        path.unlink()
report = {"scope": "Owned remote probe captures only",
          "removed": {category: len(paths) for category, paths in groups.items()},
          "remote_session_input_absent": not (root / "session.txt").exists(),
          "all_selected_captures_absent": all(not path.exists() for paths in groups.values() for path in paths),
          "local_user_input_untouched": True}
(root / "cleanup-result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
