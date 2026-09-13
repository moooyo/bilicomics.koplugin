"""Report only boolean/count comparisons for one private live-reader probe."""
import json
from pathlib import Path
import sqlite3
import sys

selection = json.loads(Path(sys.argv[1]).read_text())
databases = list(Path(sys.argv[2]).glob("private/data/bilicomics/accounts/*/state.sqlite3"))
comparisons = []
for database in databases:
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        rows = connection.execute("SELECT data FROM pages ORDER BY page_index").fetchall()
    if not rows:
        continue
    pages = [json.loads(row[0]) for row in rows]
    expected = selection["approved_source_paths"]
    actual = [page.get("extra", {}).get("source_path") for page in pages]
    comparisons.append({
        "page_count": len(pages),
        "expected_page_count": len(expected),
        "exact_path_order_matches": actual == expected,
        "path_mismatch_count": sum(a != b for a, b in zip(actual, expected)),
        "paths_without_query_match": len(actual) == len(expected) and all(
            isinstance(a, str) and a.split("?")[0] == b.split("?")[0] for a, b in zip(actual, expected)),
        "indices_are_numeric": all(isinstance(page.get("index"), (int, float)) for page in pages),
        "indices_match_order": [page.get("index") for page in pages] == list(range(1, len(pages) + 1)),
        "missing_pages": sum(page.get("state") == "missing" for page in pages),
    })
print(json.dumps({"comparisons": comparisons}))
