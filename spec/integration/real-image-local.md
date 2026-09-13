# Local Rendering of Acquired Image Samples

The authorized remote run passed all 54 boolean checks: 14 on first open and 13
on a separate-process reopen for each of two JPEG samples. The measured oriented
dimensions are 2001 by 2900 and 2000 by 2855. The official Linux KOReader runtime
is v2026.07.1. Source, test and native-runtime hashes are recorded in
real-image-local-results.json; production and runtime files were unchanged.

This probe covers local rendering of two images already acquired by the caller.
The caller identified the samples as a free-page image and an already-owned-page
image. Acquisition, real entitlement decisions, encrypted image responses,
complete chapter downloads, online prefetch and payments are outside this run.
The probe never receives credentials, original catalog records or image tokens.
It must not be described as a complete authenticated online-reading test.

## Exercised path

For each explicitly supplied image, the driver creates a fresh synthetic account
and one-page descriptor using real Store and PageStore modules. It reads only
the supplied image header, copies the file into the isolated temporary image
directory and commits it through PageStore. Synthetic local authorization checks
the immutable stored descriptor; no Controller, session or protocol service is
loaded. The synthetic owned state does not claim to verify the original rights.

The real ComicDocument, Integration and ReaderUI render the committed image.
Transparent observers retain every production draw and decode result. A check
passes only when a native backend draw returns successfully inside a ReaderUI
draw, the same draw does not use a placeholder, the document has no recorded
decode errors and native ownership has been released. No pixel value, buffer,
screenshot, image checksum or image content is exported.

After the matching Reader instance/generation emits opened, the test explicitly
selects native page-width continuous mode. A native onGotoViewRel call advances
inside the same source image. Closing the reader synchronously saves the anchor
to real SQLite storage and releases the document. A separate KOReader process
with a fresh UI/cache namespace opens the same descriptor and verifies another
real decode, restored continuous mode and source anchor within 0.005 tolerance.
This is not a test of new-document mode defaults.

The existing policy is checked without overrides: 4,000,000 lossless pixels,
32,000,000 JPEG pixels, 16 MiB tiles and 2,000,000 intermediate pixels.

## Network and privacy boundary

Every native process runs under unshare -n. The driver verifies that its network
namespace differs from the launcher and has no routes. Protocol, session,
worker and payment-service imports are forbidden; socket connection and DNS
entry points are also guarded. All four processes completed with no forbidden
attempt. No purchase test or existing mixed integration suite is invoked.

Inputs are limited to one or two explicit regular image files. The launcher
does not enumerate their parent directories. Each run uses a fresh mode-0700
remote directory and synthetic account identifiers. Images, derived local cache
and private debugging logs are never copied to the repository. Published JSON contains only image
format/dimensions, boolean outcomes and source hashes, without original paths,
titles, account identifiers or image contents.

Two initial driver adaptations were necessary: an empty route file in a fresh
network namespace must be accepted as empty, and ReaderUI creation must be
awaited before attaching Integration. All rendering checks still wait for the
matching opened event. No production fix was made for either driver issue.

## Reproduction

Run only through ssh test-env after receiving explicit image paths and read-only
authorization. Use the standalone driver, not a broader suite:

    python3 run_real_image_local.py --runtime /path/to/official/koreader --source /path/to/frozen/source --work /tmp/new-private-local-render-run --image /path/to/authorized-image-1 --image /path/to/authorized-image-2

The launcher requires a fresh work directory, Linux network namespaces and
xvfb-run. It bounds each phase and terminates the phase process group on timeout.
The recorded passing private run is /tmp/bili-local-real-m1UmIeye/run-4.
All native processes have exited. After verification, the operator removed every
synthetic Store and UI profile under this probe's validated private work root,
including real-image copies, thumbnails, caches and debugging logs. Only scripts
and sanitized boolean results remain. real-image-local-cleanup.json records this
successful cleanup. Original acquired input files were left untouched and
released to the caller for its own cleanup.
