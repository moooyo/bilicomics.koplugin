# Local WSL complete-chapter reading acceptance

The user must explicitly authorize local verification for the current task.
`run_live_reading.py` then runs as the ordinary WSL desktop user in a new private
directory below that user's Linux home. It stays separate from the visible UI
acceptance profile and uses the official KOReader runtime without root access.

The wrapper verifies the supplied candidate ZIP digest and every manifest entry
against the current production source. It extracts that exact ZIP, stages the
existing integration drivers and strict complete-chapter guard, and binds all
results to the extracted candidate. The report distinguishes packaged files
from the full production map, whose additional native build sources are not
runtime package entries.

The existing preparation driver validates a private copy of the supplied session.
With `--execute-live-read`, it then selects the first explicitly free episode of
the first favorite comic (or first history comic only if favorites are empty),
requires the complete ordered index to contain 6 through 64 pages, and runs the
existing real online/download/offline workflow. The original session input is
never changed. The wrapper deletes its copied input on success or failure.
Cancellation is forwarded to the managed launcher, and the wrapper waits for
that launcher to finish its own native-process cleanup before deleting the
copied input. Optimized Python execution is rejected because the preflight and
candidate checks must remain enabled.

The shared drivers have an explicit `--execution-host local-wsl` mode, which
requires a detected WSL kernel and a non-root caller. The default `test-env`
mode retains its root requirement and existing network namespace command.
The local offline process uses `unshare --user --map-current-user --net`, and
the Lua driver still proves a different network namespace, no routes, no
session and zero worker starts. No weaker offline fallback is available.

The transport guard, real production responses, complete-chapter requirement,
native rendering observations, memory limits, process tracking, session cleanup
and no-spending boundary are unchanged. Requests for payment, quotes, wallets,
account mutations or unrelated chapter images remain outside this workflow.
The supplied cookie input should not include automatic-renewal credentials;
authentication maintenance is covered by its separate acceptance workflow.

Example inside the authorized WSL distribution:

```sh
python3 /path/to/repo/spec/local/run_live_reading.py \
  --repo /path/to/repo --runtime /path/to/koreader \
  --archive /path/to/bilicomics-0.1.0-dev.zip \
  --manifest /path/to/bilicomics-0.1.0-dev.manifest.json \
  --expected-archive-sha256 APPROVED_CANDIDATE_SHA256 \
  --work "$HOME/.local/share/bilicomics-acceptance/new-private-reading-run" \
  --session-input /path/to/original-private-cookie-export --execute-live-read
```

`local-live-reading-results.json`, the nested preflight results, and the live
`results.json`, `online-results.json` and `offline-results.json` contain public
booleans, counts and code hashes. They may be exported under new local evidence
names. Private logs, selection paths, account data and chapter images must stay
in the private work directory until scoped cleanup. Complete download acceptance
does not claim page-by-page visual inspection.

## Accepted candidate and evidence

The 2026-09-13 ordinary-user WSL run accepted the exact canonical archive
`45385c6ff3cc99d2639f92575fb6db0ac363ab20aa76800aa7bbdbdbe93f5342`.
Its 101 packaged files match the 201-file production map, with 100 native build
source files excluded from the ZIP. The extracted candidate, source, staged
drivers and runtime remained unchanged throughout the run.

The real workflow passed 51 online checks and 30 independent offline checks.
It retained all 45 free-chapter pages, totaling 92,022,101 bytes; 43 pages
completed after the reader closed. Offline execution used separate user and
network namespaces, had no session or network routes, started zero workers and
rendered actual cached content at the restored source anchor. Both launchers
cleaned their children normally without forced cleanup, and the wrapper removed
its private copy of the original input.

See `live-reading-candidate-results.json` for exact ZIP/source binding,
`live-reading-results.json` for the full source-bound workflow, and
`live-reading-online-results.json` / `live-reading-offline-results.json` for the
individual native phases. These reports preserve the test hashes actually used
for that completed run.

After that successful real run, cancellation forwarding and optimized-Python
rejection were strengthened in the acceptance helpers. The separate
`live-reading-wrapper-results.json` binds four network-isolated cases to those
updated helpers: SIGTERM, SIGINT, explicit `-O`, and `PYTHONOPTIMIZE`. The signal
cases require a supervisor to complete delayed cleanup of a child in another
session before the outer wrapper removes its synthetic input. This separate
helper evidence does not rewrite the earlier real-run hashes or fabricate an
additional chapter download.
