# Live anonymous bookstore capture

`bookstore_live.lua` runs the actual `Runtime`, `Controller`, `Screens`, subprocess
`Runner`, protocol client, and verified-TLS transport inside a newly created
anonymous profile. It installs the same read-only guard used by the desktop
acceptance launcher, then adds a narrower live boundary for this capture:

- One exact anonymous recommendation data route is permitted:
  `GET https://manga.bilibili.com/index.pageContext.json`, with no request body.
- Cover requests must match the production CDN thumbnail URL of a comic in the
  current public recommendation snapshot. The production screen requests only
  visible cards. The capture never changes pages or opens a comic.
- Request headers cannot include Cookie, Authorization, or other credentials.
  All unrelated jobs and network routes are rejected before dispatch.
- Session storage is limited to the invalid anonymous identity, which returns
  before resolving a session file. No existing account profile is loaded.

The native UI event loop runs until all visible first-page covers are cached and
the real worker queue is idle. It then writes `bookstore-live.png` and closes the
Runtime. Timeout or incomplete covers produce a failed result rather than a
synthetic replacement.

Run only on the remote test host, with a new output directory:

```sh
python3 SOURCE/spec/ui/run_bookstore_live.py RUNTIME SOURCE /var/tmp/NEW-OUTPUT
```

The recorded 600x800 run on 2026-09-13 loaded seven real official recommendations
and both first-page covers. It made exactly three successful HTTP GET requests:
one recommendation request and two 480x640 CDN thumbnails. There were no boundary
violations, authenticated sessions, favorite records, reading-history records,
or download jobs. The loaded production source remained unchanged during the
run, including Controller digest
`90cdc3210008f10df1e2cb85b70cd0f6429f29d95cef578394e3bfc676597150`.

`bookstore-live-verification.json` records all source digests, native component
identities, request metadata, response statuses, screenshot digest, and profile
isolation. `screens/bookstore-live/600x800.png` is the actual rendered screenshot;
the captured comics and illustrations are neither fabricated nor substituted.
The image was visually checked for loaded covers, legible labels, and bounds.

The companion read-only-guard regression passed 208 cases and 369 assertions in
an isolated network namespace on `test-env`; its evidence is
`spec/local/recommendations-guard-results.json`. Existing mutation rejection cases
remain covered.
