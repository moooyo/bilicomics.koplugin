# Original bookshelf finishing evidence

This directory preserves the original 986-assertion native matrix before the
authenticated-offline UI correction. It is historical evidence of the source
hashes recorded in `bookshelf-finishing-verification.json`, not the current UI.

- `bookshelf-finishing.md`: original execution notes and scope.
- `bookshelf-finishing-verification.json`: original eight-case receipt.
- `bookshelf-finishing-results/`: original per-case assertions.
- `bookshelf-finishing/`: original native screenshots grouped by locale and size.
- `bookshelf_finishing_spec.lua` and `run_bookshelf_finishing.py`: original harness.

Current results are in [the current report](../../bookshelf-finishing.md).
Both matrices ran only through `ssh test-env` with synthetic account state and
no real network or credentials. Neither is fresh QR or real-account acceptance.
