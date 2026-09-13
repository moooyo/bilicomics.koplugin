# Bookshelf experience proposal

Status: design proposal, not implemented. Date: 2026-09-13.

The user requested a considered redesign after finding the permanent Refresh
bookshelf and All controls confusing. Earlier changes replaced rows with covers
and removed the second lower pagination bar. This proposal addresses the
remaining information hierarchy and behavior together.

## Primary task and stable navigation

The normal bookshelf task is to recognize a comic, see the current reading
position, and resume it. Default entry remains Bookshelf. Preserve the approved
Bookshelf, History, Search and Downloads destinations in that order.

Use one quiet header and one bottom navigation band. The header has a return
action, a clear screen title and a More menu. The return action leaves the plugin
view rather than suggesting that it exits the entire application. Multiple-page
navigation stays compact within the header area and disappears for one page.
Remove permanent refresh/filter toolbars and the permanent gesture-instruction
line. A collection with two titles should retain natural empty space.

The bottom band uses a separator and a clear selected text/underline state,
instead of four separately framed command buttons. Keep adequate touch targets
and native key focus. Grayscale and e-ink readability remain requirements.

## Synchronization before hiding refresh

Hiding manual refresh is justified only after normal synchronization becomes
automatic and dependable. Display cached data immediately. On entering the
bookshelf, refresh missing or stale account data through the existing workers.
A provisional freshness interval of 15 minutes is a client policy, not a service
session lifetime. Do not wake periodically while the user is reading a chapter.

Keep a manual refresh action and the last successful synchronization time in
More. Until automatic synchronization is implemented, keep a small labeled
refresh action in the header as a transitional design.

Offline mode and synchronization failures retain cached cards. Distinguish a
first-use empty cache, an empty account bookshelf and an empty filter result.
Provide an explicit retry when no content can be shown. Avoid full-page loading
states over existing data, repeated modal failures and animated spinners.
Batch visible updates, preserve focus and do not reorder cards during a tap or
while the user is browsing the current page.

## Filters, ordering and return position

The menu can group refresh, filter and sort separately from account/settings
and help. All is the default state, not a permanent command label. A non-default
filter must produce an explicit visible condition with a one-tap clear action.
An empty filter result must offer that clear action instead of pretending the
whole bookshelf is empty.

Preserve each account's selected filter, ordering and grid position when moving
between destinations or returning from the reader. If recent reading is the
default sort, apply it on a deliberate entry/order action, not on every cover
arrival. Titles with no known reading time retain a stable source order.

## Card information budget

Use an aspect-preserving portrait cover, at most two title lines and one concise
reading-position line. Preserve title alignment without allocating permanent
blank rows for every possible metadata field. Show exact chapter/page information
only when it is known for that content revision. Server-only progress is chapter
level; no local history is not proof that the user has never read the comic.

Remove the unconditional latest-chapter subtitle. A small update marker may be
shown when an update is actually known; full latest-chapter details belong in
the catalog. Publication completion is distinct from reading completion. Avoid
adding multiple simultaneous status badges to every cover.

Keep the accepted tap-to-read and hold-for-chapters behavior. Teach it once,
then keep help available in the menu. Key-based devices need an accessible
selected-card action; chapter access cannot depend solely on a touch long press.
Keep the native reader and the existing explicit purchase boundary.

## Review and implementation order

The conversation companion demonstrates the quiet default page, the More menu,
visible active filters and retained-content connection states using cover crops
from the user's reference and illustrative progress. It is not a native runtime
or account verification. Its optional alternatives compare automatic versus
manual refresh, two versus three columns, connection state and always-visible
update subtitles.

Implement synchronization and view-state preservation before removing their
manual affordances. Then implement the header/menu and visible filter state,
followed by compact card captions and lighter navigation. Verify default,
filtered, offline, empty and returning-from-reader states in the remote native
runtime before replacing the current candidate. No production module or package
was changed for this proposal.
