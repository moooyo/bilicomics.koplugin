# Private live-reading preparation

`prepare_live_reading.py` runs only in the authorized Linux `test-env` environment.
Its default mode parses the supplied private session with the production parser
and calls the production `Client:validateSession` once. `--select` additionally
reads the first favorite, falling back to the first history item only when the
favorite list is empty, reads that comic's catalog, and selects its first episode
whose normalized access is exactly `free`. It requests one complete image index
and requires 6 through 64 ordered unique source paths. If that first free chapter
is outside the limit, preparation stops; it does not search additional chapters.

No chapter image, cover, image token, wallet, quote, purchase, favorite mutation,
history mutation or session renewal request is permitted. The strict transport
boundary allows at most one call per metadata route, bounded first-page library
reads and pinned protocol assets; all other requests are rejected before the
production transport. Protocol responses remain unchanged.

Example commands on `test-env`, using a frozen source and private input paths:

```sh
umask 077
python3 /path/to/source/spec/integration/prepare_live_reading.py \
  --runtime /path/to/koreader --source /path/to/source \
  --work /tmp/new-private-validation --session /path/to/private-session.txt
python3 /path/to/source/spec/integration/prepare_live_reading.py \
  --runtime /path/to/koreader --source /path/to/source \
  --work /tmp/new-private-selection --session /path/to/private-session.txt --select
```

The work directory must be new, outside source and runtime, and separate from
the credential input. The credential file must be regular, not a symlink, and
have no group or other permissions. The process uses a private umask. The
original credential input is never changed. The private work directory retains
raw process logs, protocol assets, `selection.json`, and sanitized observations.

`preflight-results.json` contains only booleans, counts and source/test/runtime
hashes; it may be exported. The source binding covers the production roots used
by the full reading launcher. The public result never includes account, comic
or episode identities, source paths, URLs, credential fields or raw errors.
Successful preparation proves current session validity and a bounded selection,
not online reading, retained images, session renewal or physical-device behavior.

Pass the resulting private `selection.json`, the same credential input, a guard
and the final frozen production source to `run_live_reading.py` for the separately
authorized complete online/offline chapter workflow described in
[live-reading.md](live-reading.md). If preparation used an earlier source
snapshot, preserve its report as preflight evidence and bind the actual full
reading result to the final snapshot. Never substitute preflight success for
the final full-reading evidence.
