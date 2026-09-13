"""Use the confirmed private session without printing or exporting its contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("phase", choices=("select", "read"))
args = parser.parse_args()
if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
    raise SystemExit("Run through ssh test-env.")
root = Path("/var/tmp/bilicomics-finishing-OHQWOHTS")
source = Path("/tmp/bilicomics-finishing-source-3")
runtime = Path("/var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader")
auth = root / "auth-ready-final"
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def identity(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns]

os.umask(0o077)
pointer = json.loads((auth / "private/session-input-path.json").read_text())
session = Path(pointer["session_path"]).resolve(strict=True)
if not session.is_relative_to((auth / "private").resolve()) or session.stat().st_mode & 0o077:
    raise SystemExit("The confirmed session must remain private.")
selection = root / "selection-ready-final"
report_paths = {"login": auth / "login-results.json", "restart": auth / "restart-results.json"}
report_hashes = {key: digest(path) for key, path in report_paths.items()}
if not all(json.loads(path.read_text())["passed"] for path in report_paths.values()):
    raise SystemExit("Confirmed login and restart are required.")
session_identity = identity(session)
same_input = None
if args.phase == "select":
    command = [sys.executable, str(source / "spec/integration/prepare_live_reading.py"),
               "--runtime", str(runtime), "--source", str(source), "--work", str(selection),
               "--session", str(session), "--select", "--execution-host", "test-env"]
else:
    previous = json.loads((auth / "private/reading-handoff-context.json").read_text())
    same_input = (previous["session_identity"] == session_identity
                  and previous["auth_reports"] == report_hashes
                  and previous["preflight_sha256"] == digest(selection / "preflight-results.json")
                  and previous["selection_sha256"] == digest(selection / "selection.json"))
    if not same_input:
        raise SystemExit("The original confirmed reading input changed.")
    command = [sys.executable, str(source / "spec/integration/run_live_reading.py"),
               "--runtime", str(runtime), "--source", str(source),
               "--work", str(root / "reading-ready-final"),
               "--selection", str(selection / "selection.json"),
               "--guard", str(root / "live-reading-guard.lua"), "--session", str(session),
               "--execute-live-read", "--execution-host", "test-env", "--timeout", "900"]
helper_sha = digest(Path(__file__))
result = subprocess.run(command, stdin=subprocess.DEVNULL)
input_unchanged = identity(session) == session_identity
phase_path = (selection / "preflight-results.json" if args.phase == "select"
              else root / "reading-ready-final/results.json")
phase_result = json.loads(phase_path.read_text()) if phase_path.exists() else {}
public_hashes = {**report_hashes, "preflight": digest(selection / "preflight-results.json")}
if args.phase == "read" and phase_path.exists():
    public_hashes["reading"] = digest(phase_path)
passed = (result.returncode == 0 and phase_result.get("passed") is True and input_unchanged
          and helper_sha == digest(Path(__file__)))
receipt = {"schema": 1, "phase": args.phase, "passed": passed,
           "execution_host": "test-env", "input_from_confirmed_qr": True,
           "same_input_as_selection": same_input, "input_unchanged": input_unchanged,
           "helper_sha256": helper_sha, "public_reports_sha256": public_hashes,
           "private_input_contents_read_by_wrapper": False}
if args.phase == "select" and passed:
    context = {"session_identity": session_identity, "auth_reports": report_hashes,
               "preflight_sha256": public_hashes["preflight"],
               "selection_sha256": digest(selection / "selection.json")}
    (auth / "private/reading-handoff-context.json").write_text(json.dumps(context) + "\n")
(root / ("handoff-" + args.phase + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
raise SystemExit(int(not passed))
