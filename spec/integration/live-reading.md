# Authorized Single-Chapter Live Reading Probe

The authorized live workflow now passes on the official KOReader v2026.07.1
Linux x86_64 runtime through `ssh test-env`. A complete free chapter retained
all 45 pages (92,022,101 bytes). Online opening, real prefetch, continued download
after reader closure and cross-process offline reopening passed 51 online and
30 offline checks. The offline phase had no session, no network routes and zero
worker starts. The descriptor and source anchor remained stable. No payment,
quote, wallet or account-mutating test was run.

See [the complete source-bound result](live-reading-results.json),
[online observations](live-reading-online-results.json),
[offline observations](live-reading-offline-results.json), and
[the compact archive comparison](live-reading-summary.json). All 87 packaged
files match the passing live source snapshot; the 99 omitted snapshot files
are native build sources. These results do not establish physical Scribe
acceptance or page-by-page visual inspection of the full chapter.

The preceding remote preparation run compiled 57 Lua
files, including the driver and supplied guard, and checked Python syntax.
live-reading-preparation.json records the result and code hashes. No selection
or session was supplied to that preparation run, and no application phase or
network request was executed. Preparation is not evidence of live success.

## Execution boundary

live_reading.lua uses the actual production main, Runtime, Controller, native
ReaderUI, Runner, default Worker, Store and PageStore. There are no synthetic
responses, injected workers, substituted connectivity results or fabricated
chapter pages. Transparent observers count Runner activity and observe native
image drawing; they delegate to the original implementations.

The operator supplies a private selection containing comic_id, episode_id,
approved_source_paths and approved_cover_url. The preflight source list must
describe the entire approved chapter and contain 6 through 64 unique paths.
Comic identity, chapter identity and the full page count remain fixed. The
driver verifies real free access and observes the selected image-index worker's
actual result before passing it to the production callback. It validates the
episode identity, complete count and ordered unique paths, then refreshes only
the path authorization through guard:updateIndex. The real result and error are
forwarded unchanged. The descriptor must match that current complete index;
the driver never truncates it. Exactly one chapter download is submitted.

The default Runner worker remains unchanged. Its submission observer permits
only session validation, the selected comic's detail, the selected chapter's
index, approved chapter images and the selected comic's cover path through the
transport guard. Quote, purchase, wallet, following, history-write and unrelated
chapter tasks are rejected before submission. Library reads are not exercised.
The normal empty local purchase-service lifecycle may be initialized by the
production Controller; no purchase scenario or payment request is run.

Global prefetch remains enabled for three pages. The next-chapter image count
is zero and the reader stays near the start of the selected chapter. The task
guard also rejects any unrelated image-index request: the current production
next-chapter helper may prepare an index even when its image count is zero.

Opening observations contain only booleans and counts: callback receipt, native
reader/integration presence, matching opened generation, document/service
liveness, pending and queued tasks, first-page availability, connectivity,
session validity and suspension state. Image-submission observations report
only whether the source was approved and its index matched the approved order.
An out-of-scope submission fails promptly even if the provider catches its hint
exception. After a successful reading callback, an empty task/queue state with
no image gate for 15 seconds is an explicit research failure, not a reason to
wait for the full network deadline or treat the opening as successful.

The first live attempt did not finish: all 45 source paths in its real index
differed from the same chapter's preflight paths, including after query removal.
The original static whitelist rejected acquisition hints, which the production
provider correctly caught. No image task started. That failed run and its
successful cleanup remain separate evidence. Current approval follows the
fixed chapter's real index result instead of assuming source-path stability.

The second attempt reached native online reading and prefetch, but stopped
after three acquired pages: the fourth image returned HTTP 400. The resulting
production fixes follow the official complete-URL marker and HTTP `image/*`
response branch. A flagged image can arrive as an ordinary JPEG; it still
undergoes the existing container, digest and geometry checks. The third attempt
completed using those production fixes without request overrides or skipped
pages. Earlier failed attempts were not rewritten as successes.

## Guard contract

The private guard file returns a factory:

    function(selection, context) -> guard

context contains phase, work, private_root and parent_pid. All actual protocol
assets, image temporaries, cached images and native data are below
work/private. The factory supplies these methods:

- guard:before(request) returns true and metadata, page_image or cover_image;
  otherwise it returns nil and a nonretryable error.
- guard:after(request, response, error) returns true on acceptance, or nil and
  an error. It must not replace or modify production responses.
- guard:updateIndex(result) accepts only the fixed chapter and complete page
  count, then updates its source authorization. It runs in the parent before
  the production image-index callback, so future real workers inherit it.
- guard:approveTokens(paths, tokens) approves the actual CDN destination only
  for a currently approved source path. A transparent Client:imageTokens
  observer invokes it after the real method returns and then returns the same
  tokens/error to the same child. Token failures are forwarded unchanged.

Every online Transport request must originate in a real child and pass before
the original Transport.request is called. after observes the original result.
The supplied guard limits API routes and identities, anonymous CDN paths,
private output paths and the shared cross-process request count. Pinned WASM
URLs must be classified as metadata before testing output_path.
Index source strings are not assumed to be CDN URL paths. Each real token result
must establish that association before any corresponding image GET is allowed.
Guard or observation failures set a persistent failure marker before raising,
so a callback's protected call cannot hide a rejected scope indefinitely.

Approved page-image requests initially wait at a local gate before the real
HTTP call. The main process must open and paint the native missing-image state
while the first child waits, process at least five heartbeats, and then release
the gate. No response or image is fabricated. A guard rejection fails the run;
the optional approved_cover_omitted error code can represent an explicitly
omitted cover without transmitting its request.

## Required observations

- The same Reader instance and generation emit opened before the first image
  arrives, and UI events continue while the real image worker waits.
- A real native draw replaces the placeholder; the next image arrives through
  production prefetch without navigating from page one.
- A single explicit download preserves the original full descriptor. Native
  scrolling saves a source anchor, then the reader closes before completion.
- Additional real image workers start after reader closure. Every approved
  chapter page becomes ready, the full chapter validates complete and pinned,
  and descriptor bytes remain unchanged.
- The copied test session is deleted. A separate native process in a new
  network namespace opens the same descriptor, restores the anchor and renders
  real cached content while submitting zero workers.

Native cache is cleared between the two processes so the offline observation
requires a new MuPDF draw. PageStore files and document settings are preserved.
The existing 4 MP lossless, 32 MP JPEG, 16 MiB tile and 2 MP intermediate limits
are checked without overrides. Full download completion does not claim that
every image was visibly inspected or rendered.

## Launcher, privacy and cleanup

run_live_reading.py runs only on the authorized Linux host and defaults to
preparation. The --execute-live-read flag explicitly starts the live phase.
An execution-started marker prevents an accidental second online run in the
same directory. A prepared work directory can be used for its one live run
only while production, launcher, driver and supplied guard hashes remain equal.

Use a new private work directory outside the code snapshot and outside all
input files. The operator retains responsibility for selecting the chapter,
supplying the guard/session and authorizing the actual run. Example remote
commands, with operator-owned paths substituted:

    python3 run_live_reading.py --runtime /path/to/koreader --source /path/to/frozen/source --work /tmp/new-live-work --guard /path/to/guard.lua --syntax-only
    python3 run_live_reading.py --runtime /path/to/koreader --source /path/to/frozen/source --work /tmp/new-live-work --guard /path/to/guard.lua --selection /path/to/private-selection.json --session /path/to/private-session.txt --execute-live-read

KO_HOME is work/private/data. Session, account data, catalog records, images,
native settings, private progress and raw process logs stay inside this isolated
namespace. The offline driver reads its saved private state rather than the
external session or selection files. The launcher never deletes the supplied
original inputs. Saved offline state contains a copied selection with this
run's current index paths; the original selection file is never modified.

Each phase has a default 900-second deadline, bounded to at most 1800 seconds.
The launcher uses a startup gate, stable PID handles, a child subreaper, session
membership and start-time records to observe and clean up actual native
descendants, including Runner children with separate process groups. Timeout
first requests normal shutdown and then terminates remaining owned processes.
Session cleanup runs on success and failure, including strict known temporary
session filenames, and checks that no test session remains. Remaining private
images and catalog data are retained for operator review and subsequent cleanup.

Public results accept only boolean outcomes, counts, dimensions and code hashes.
String-valued phase results or identity/path/token fields are rejected and moved
to private evidence. No Cookie, title, account/comic/chapter ID, source URL,
descriptor, screenshot, image or raw error is copied into the repository.

The final [cleanup record](live-reading-cleanup.json) confirms removal of the
external remote session copy and all known private captures/profiles after
terminal-process checks. It removed 551 files and 313 directories, left zero
sensitive targets, and preserved code, packages and sanitized reports. The
original local session input was not touched. The fixed-root helper is
`cleanup_live_reading.py`; it is specific to this completed research workspace.
