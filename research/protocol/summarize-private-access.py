"""Summarize entitlement field shapes without titles, account IDs or image URLs.

Run only on test-env against the private read-only probe output.
"""
import collections
import json
import pathlib
import sys


def expiry_shape(value):
    if value is None:
        return "absent"
    if value == "":
        return "empty"
    try:
        number = float(value)
        return "zero" if number == 0 else "negative" if number < 0 else "positive"
    except (TypeError, ValueError):
        text = str(value)
        if text.startswith("0001-01-01"):
            return "zero_datetime"
        if text.startswith("1970-01-01"):
            return "epoch_datetime"
        return "datetime" if len(text) >= 10 and text[4:5] == "-" and text[7:8] == "-" else "other"


def safe_flag(value):
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and -1 <= value <= 10:
        return value
    if isinstance(value, str) and value in ("", "0", "1", "2", "3", "4"):
        return value
    return "[other]"


for path in sorted(pathlib.Path(sys.argv[1]).glob("comic_*-private-detail.json")):
    data = json.loads(path.read_text())
    groups = collections.Counter()
    for episode in data.get("episodes", []):
        raw = episode.get("extra", {})
        fields = {"access": episode.get("access"),
                  **{key: safe_flag(raw.get(key)) for key in
                     ("pay_mode", "unlock_type", "is_purchased", "is_locked", "is_in_free", "status")},
                  "unlock_expire_at": expiry_shape(raw.get("unlock_expire_at")),
                  "expires_at": expiry_shape(raw.get("expires_at"))}
        groups[json.dumps(fields, sort_keys=True)] += 1
    print(json.dumps({"alias": path.name.split("-private")[0],
                      "groups": [{"count": count, **json.loads(fields)} for fields, count in groups.items()]}))
