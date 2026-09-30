# UI preparation data

The Scribe handoff's A6 and D2 counters use local observations from the existing
library and image workers. They introduce no service endpoint and never substitute
fictional counts, chapter sizes, prices, or balances for unavailable data.

## First bookshelf presentation

`Controller:getBookshelfSyncState()` exposes `phase`, `first_sync`, `comics_count`,
`covers_ready`, `covers_settled`, `covers_total`, and `progress`.

- `library` collects favorites and history under the existing single-flight,
  account-generation, and favorite-revision guards. `comics_count` is the received
  favorites count before ingestion, then the resulting local favorites count.
- `covers` prepares only the cover IDs returned by
  `Screens:getInitialBookshelfCoverIDs(items)`. This reuses the actual persisted
  filter, ordering, page, responsive grid capacity, and local-anchor resume block.
  A visible resume cover is included once and excluded from the grid. Before
  publication, the controller repeats this selection against fresh catalog items
  and the current persisted view. A changed filter, sort, local resume anchor,
  favorite, or source prepares the newly visible selection before showing a grid.
- `ready` publishes the complete presentation after every selected cover reaches
  a terminal outcome. A missing or failed cover uses the existing placeholder.

`covers_ready` counts an existing strategy-matched regular cache file or an image
worker result that was successfully persisted. `covers_settled` also counts
missing URLs, rejected sources, backoff, offline rejection, transfer or persistence
failure, and cancellation. None of those outcomes increment `covers_ready`.
Progress is `covers_settled / covers_total`, so it describes completion of cover
preparation rather than invented image download success.

The first library transaction writes `presentation_ready = false`. `has_cache`
remains false during cover preparation, even though catalog records already exist.
The final publication sets the flag to true. An interrupted persisted first stage
does not certify a ready cache after restart; it is stale and can be synchronized
again. Existing and legacy ready caches remain usable during background refresh.

Cover observers share the existing worker for the same visible request and settle
once. The current source is followed if its URL changes while a worker runs. The
original observer still has a finite deadline. Suspension retires visible cover
preparation, and incomplete library collection is canceled without publishing a
partial collection. Account changes retire cover observers while the existing
generation guard suppresses obsolete bookshelf UI callbacks and writes. Transfer
failures retain the established five-minute source-specific retry backoff.

The first preparation also has one overall `worker_timeout + 5` second deadline.
It is not reset when the visible selection changes. On expiry, outstanding visible
requests retire, the fresh selection is checked once more, and uncached covers
settle as timed-out placeholders. Existing verified cache hits still count as
ready. This prevents changing navigation or source data from keeping A6 pending
indefinitely, without pretending a timed-out cover was downloaded.

## Selection size and stored copy bytes

`Controller:getDownloadEstimate(comic_id, episode_ids)` returns:

| Field | Meaning |
| --- | --- |
| `bytes` | Total only when every selected chapter can be calculated; otherwise absent |
| `known_bytes` | Subtotal for the chapters that can be calculated |
| `estimated` | At least one extrapolation or unknown chapter |
| `known_chapters` | Number of calculable chapters |
| `total_chapters` | Unique selected identities plus invalid selections |
| `descriptors` | Selected validated current revisions, each with `revision`, `total_pages`, optional `bytes`, and `estimated` |

The estimate uses the current authoritative descriptor and matching ready image
records. Files must be regular files within the account's pages namespace, and
their measured byte size must equal the persisted byte size. Removed, stale,
foreign, mismatched, corrupt, empty, and symbolic-link observations are excluded.
A fully observed chapter uses its actual total. A partial chapter uses its own
observed average page size and authoritative page count. A zero-sample chapter can
use the same comic's observed current-page average only when its current descriptor
or saved `image_count` / `total_pages` declares a valid count. A missing count or
missing usable sample leaves that chapter unknown. Retired revisions supply no
estimate samples. No constant MB-per-chapter value is used.

Recovery cards use `descriptors[episode_id]` to distinguish a saved new revision
from the paused older copy. The page count comes only from a complete, validated,
current stored descriptor. A declared count can support an estimated size without
creating a trusted descriptor entry. Unknown descriptors, replacement-marker
conflicts, and retired revisions leave the entry absent. Thus an older 24-page
job cannot stand in for the current 32-page document or an unknown future document.

`Controller:getDownloads()` adds `job.bytes` from that job's exact stored revision,
including retained older copies. It never substitutes the current revision's size
for an older copy. A valid descriptor with no observed ready files has zero stored
bytes; an unavailable descriptor leaves the size unknown. These getters neither
repair image metadata nor write jobs, fetch image indices, or dispatch workers.

## Native verification

The user-authorized local Debian WSL KOReader runtime `v2026.07.1` ran all cases
with separate synthetic profiles and an isolated network namespace. The production
controller, catalog, SQLite store, page store, and filesystem were used; worker
responses were controlled and contained no real account data.

| Suite | Checks | Result |
| --- | ---: | --- |
| UI preparation and controller size integration | 47 | Passed |
| Download estimate and revision boundaries | 21 | Passed |
| Existing bookshelf synchronization regression | 31 | Passed |
| Existing official cover thumbnail regression | 33 | Passed |

The recorded source hashes and case results are in
[`ui-preparation-verification.json`](../spec/controller/ui-preparation-verification.json).
The focused runner is `spec/controller/run_ui_preparation.py`. Raw logs and
synthetic profiles remain outside the repository in the local acceptance directory.
