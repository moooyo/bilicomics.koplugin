"""Inspect private live-test job states without returning identifiers or content."""
import json
from pathlib import Path
import re
import sqlite3
import sys

results = []
for database in Path(sys.argv[1]).glob("private/data/bilicomics/accounts/*/state.sqlite3"):
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        jobs = connection.execute("SELECT data FROM jobs").fetchall()
        pages = connection.execute("SELECT data FROM pages").fetchall()
    for row in jobs:
        job = json.loads(row[0])
        raw = job.get("error") or {}
        safe = {}
        for key in ("kind", "code", "status", "retryable"):
            value = raw.get(key)
            if isinstance(value, (bool, int, float)) or isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9_]{1,64}", value):
                safe[key] = value
        states = {}
        for page_row in pages:
            page = json.loads(page_row[0])
            state = page.get("state", "unknown")
            states[state] = states.get(state, 0) + 1
        results.append({"state": job.get("state"), "completed": job.get("completed"), "total": job.get("total"),
                        "encrypted_image_branch": raw.get("message") == "The encrypted image service rejected the resource.",
                        "error": safe, "page_states": states})
print(json.dumps({"jobs": results}))
