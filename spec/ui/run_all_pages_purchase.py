"""Run every purchase handoff state using the shared isolated native harness.

Accept the same runtime, plugin, output, size and language arguments as
run_scribe_handoff.py. The wrapper selects the purchase domain and adds the
purchase state module; outputs must remain outside the repository.
"""
import sys

from run_scribe_handoff import main


if __name__ == "__main__":
    sys.argv.extend(["--domains", "purchase", "--extra-modules", "all_pages_purchase_spec"])
    main()
