# Download connectivity

The download service checks current connectivity before preparing or acquiring
missing content. Controller supplies a callback that also checks its active
account, generation, closed state and suspend state. A failed connectivity check
or an exception from that callback is treated as unavailable.

An explicit download or resume attempted while unavailable remains a durable
paused job with a connection error. It does not start an index request or an
image worker. Resume remains an explicit user action for these jobs; this change
does not add network polling or resume every paused job when connectivity returns.
The existing suspend/resume flow retains its narrower list of previously active
jobs.

Ready pages are returned before the network check. A fully cached chapter can
still be retained and marked complete without a connection or a valid session,
subject to its existing confirmed offline rights. Partial chapters keep their
cached pages and positions when paused.

An optional parent-side `Runner.before_start` callback repeats the check before
each actual subprocess start. Image tasks and chapter-index acquisition use this
hook. It covers tasks waiting for a slot, retry backoff and preemption replay;
rejecting the hook invokes the normal completion callback without starting a
worker or automatically retrying that rejection. Tasks without the hook retain
their existing behavior. No payment task receives a new hook.

Preparation or image completion with an authentication, storage-space, network
or timeout error pauses the download. Other failures retain their existing
failed state. Job and service generations continue rejecting stale completions
after cancellation, account changes and shutdown.

The check is a dispatch policy, not an operating-system network sandbox. It does
not continuously cancel an already running transfer on every link change. Its
normal completion, timeout or lifecycle cancellation still settles that work;
the next dispatch must pass the current check.

The [focused result](../spec/jobs/download-connectivity-results.json) passed 25
cases and 135 assertions: 16 DownloadService/Controller cases with real SQLite
and controlled worker results, plus nine real Runner cases. All seven forked
children were reaped and standby holds/releases balanced at seven each. The
initial Runner harness incorrectly required a nil error on successful returns
where existing code returns false; that first result is retained separately.
Correcting the assertion required no production change, and the final source
hashes match the initial run.

Verification is limited to independent reading scenarios on `test-env`. It does
not read the user's session file or make live account calls, quote or wallet
reads, purchases, or physical Kindle runs. Source hashes in the focused result identify the
tested revision; previous live reading evidence keeps its original scope.
