# Authenticated Reading-Only Test Report

Date: 2026-09-12. Runtime: unmodified official KOReader v2026.07.1, Linux x86_64,
on `test-env` through SSH. The authenticated workflow and package verification
in this report ran remotely. The subsequently requested local native UI
acceptance uses a separate Windows WSLg profile; see
[the local acceptance record](../spec/local/README.md).

The user's supplied browser session passed validation. A complete free chapter
now passes the actual plugin's online reading, prefetch, retained download and
independent-process offline reopening workflow. This is a development result;
the user's physical Kindle Scribe has not been tested.

The user explicitly prohibited purchase testing. No purchase, rental, recharge,
quote, wallet, automatic-purchase-setting, favorite-mutation or history-write
test was run. Both live probes and targeted regression suites obeyed that
restriction. Transport guards restricted API routes, methods, query/body keys,
chapter identities and anonymous CDN resources before transmission.

## Complete chapter result

| Boundary | Observation |
| --- | --- |
| Session, library and catalog | Session validated; existing favorites/history and signed catalogs read successfully |
| Native online opening | Actual ReaderUI opened before the first image arrived and remained responsive |
| Prefetch | The next real image arrived without navigating away from the first image |
| Explicit retained download | All 45 original chapter pages acquired, validated and pinned; 92,022,101 image bytes |
| Reader closure | 43 pages finished after closing the reader; new image workers continued the explicit download |
| Persistent identity | One descriptor retained the same path and bytes throughout the workflow |
| Offline reopen | A separate process with no session and no network routes reopened the same chapter, restored its source anchor and rendered cached pixels |
| Offline network activity | Zero transport requests and zero worker starts/submissions |
| Image budgets | Existing JPEG, lossless, tile and intermediate limits unchanged; all acquired pages within limits |
| Lifecycle | All tracked children exited; both phases completed without forced cleanup |

The online phase passed 51 checks and the offline phase passed 30 checks.
The test used actual main/Runtime/Controller/Runner/default Worker/Store/PageStore
and native ReaderUI. Protocol responses, chapter page count, connectivity and
image data were not replaced with synthetic results. A short local gate before
the first actual image HTTP request made UI responsiveness observable.

The 45 page-image requests completed with HTTP 200. The online guard counted
138 request starts, including lower-priority cover work, and 94 HTTP 200
responses. A started or interrupted cover transfer is not counted as a completed
image. Every chapter page received its own real, approved ImageToken result.

## Defects found and fixed

1. The catalog's exact unset expiry value `0000-00-00 00:00:00` previously
   produced unknown access for already-owned chapters. The normalizer now maps
   this sentinel to no expiry while retaining explicit locked-state precedence
   and conservative handling of other unknown dates.
2. The official reader appends the fixed `code=DanmakuInfo` marker to current
   complete image URLs. A same-token comparison changed the fourth image's
   response from HTTP 400 to HTTP 200. Production URL construction now follows
   the observed official branch without re-encoding signed parameters. Direct
   cover URLs continue through the ordinary URL path without this marker.
3. A token marked `hit_encrpyt=true` can return an ordinary JPEG. The observed
   fourth image was HTTP 200, `Content-Type: image/jpeg`, 2000 by 2850 pixels,
   and 4,640,394 bytes. Following the official response handler, the backend now
   recognizes `image/*` before container conversion and retains full image
   inspection, digest, size limits and failure cleanup. The corrected page and
   the whole chapter passed without diagnostic request overrides.

The related regression evidence contains seven entitlement groups, 12 catalog
cases, 24 image-protocol groups and eight cover-policy groups. Existing real
encrypted-container fixtures still pass; no decryption algorithm was changed.

## Additional account and device evidence

The earlier read-only probe retrieved three free and three already-owned JPEG
pages. Two acquired first images separately passed 54 native local
render/scroll/reopen checks. Those smaller checks remain distinct from the
later complete free-chapter workflow.

The native session file picker passed 42 focused checks at each of 600 by 800,
480 by 640 and 1860 by 2480. These used synthetic import inputs and a controlled
session-validation response. The Scribe-size layout is emulation, not a physical
screen test. [Session import instructions](session-import.md) describe copying
the text file by USB and selecting it through KOReader's file picker.

For the declared first-generation Scribe on firmware 5.19.3, the
[official koxtoolchain target table](https://github.com/koreader/koxtoolchain/blob/2026.08/README.md)
points to `kindlehf`. The later ARM compatibility correction rebuilt the plugin
libraries with adjacent relocation tables. The unchanged official Kindle LuaJIT
then passed nine bounded native checks with each of two QEMU sysroots: Debian
glibc 2.41 and glibc 2.20 with a private diagnostic loader correction. The original
toolchain loader failure remains documented; the corrected loader is not
packaged. These are limited compatibility observations, not proof of execution
on the user's firmware; see [the correction and evidence](kindle-native-compatibility-fix.md).

## Scope limits

The complete live scenario covers one free chapter. Already-owned access has
sample acquisition evidence, not a second complete live chapter scenario.
Although some tokens were marked encrypted, the observed successful wire data
were ordinary JPEGs. Live encrypted-container transformation remains distinct
from the passing synthetic container fixtures. Download integrity does not
establish page-by-page visual inspection of the whole chapter.

Physical Scribe startup, memory pressure, suspend/resume, touch interaction and
e-ink refresh still require device acceptance. Purchase testing remains
prohibited, and the incomplete batch adapter is not established by these results.

## Evidence, cleanup and package

- [Complete live workflow and source hashes](../spec/integration/live-reading-results.json)
- [Compact chapter and archive summary](../spec/integration/live-reading-summary.json)
- [Successful fourth-image response](../research/protocol/image-response-live-result.json)
- [Official image request/response contract](../research/protocol/image-request-contract.md)
- [Image response regression](../spec/protocol/image-response-result.json)
- [Direct cover URL and pixel-budget regression](../spec/jobs/cover-url-result.json)
- [Earlier free/owned samples](../research/protocol/authenticated-readonly-result.json)
- [Earlier native local-image result](../spec/integration/real-image-local-results.json)
- [Native session file picker at Scribe resolution](../spec/ui/session-import-result-scribe-size.json)
- [Development package checks](../spec/package/remote-results.json)
- [Private remote data cleanup](../spec/integration/live-reading-cleanup.json)

The live launcher removed isolated application sessions before offline restart
and verified all child lifetimes. The final cleanup checked 104 child records
across four executed phases and found no live process referencing the workspace.
It removed the remaining remote session input, private catalog/index captures,
image/context/wire files, native profiles and logs: 551 files and 313 directories.
No sensitive cleanup targets remain. Code, packages and sanitized evidence were
preserved unchanged. The user's original local `bilibili.txt` is retained unchanged.

The development archive corresponding exactly to the complete live workflow had 87 files,
2,399,152 bytes, SHA-256
`668d27175642024d78d1da8e379582e57550c490803b6f4a7196c11df8f08c1b`.
All 87 packaged file hashes match the source used by the passing complete live
workflow; native build sources are intentionally excluded. The archive passed
26 remote package checks, including deterministic rebuild and private-data
exclusion. No session or acquired comic content is included.

The subsequent Controller prefetch-policy archive had
87 files, 2,399,221 bytes, SHA-256
`65b38f158e3170dbd028703e62ace39707da21ba08e0c8e7ea773a7ac82f04ae`.
That correction passed 31 focused remote checks and the rebuilt package passed
26 checks. The other 86 packaged files remained identical to the live-tested
snapshot.
The complete live account workflow was not repeated for this policy-only change.

The subsequent source-refresh archive implemented explicit partial-download source
refresh and the basic batch range-information request translation: 89 files,
2,412,242 bytes, SHA-256
`641041ce5df61e82f93374f6560e1be79d2f960862d94afd2d5b6e562b055b0e`.
Source refresh passed 14 network-isolated integration scenarios with 185
assertions and 44 real worker starts, plus focused storage, Worker and native UI
checks. Its historical-content proof and independent replacement boundary are
described in [the recovery report](partial-download-recovery.md).
The batch translation received only static review and remote syntax compilation;
no quote or purchase function was exercised. Twenty-six remote package checks
passed, and 78 files were unchanged from the prefetch archive. The complete live
account workflow was not rerun for that build.

The subsequent independent-version archive added redownload, exact job-version
reading and old/new progress isolation: 91 files, 2,421,925 bytes, SHA-256
`2f337b48d80e5fdae547124851c45f64902fb6e9433c1ca82896218cdcf3fe7d`.
Its [replacement integration](../spec/integration/version-replacement-workflow-results.json)
passed 19 remote network-isolated scenarios, 258 assertions and 58 real worker
starts with synthetic free-chapter responses. Real ReaderUI opened the exact
old/new snapshots; all tracked children terminated. Twenty-six remote archive
checks passed. [The source comparison](../spec/package/source-evidence-before-arm.json)
binds its integrated modules and UI to the focused snapshots, with 80 files
unchanged from the preceding source-refresh archive. The complete live account
workflow was not rerun; its evidence remains bound to the original live-tested
archive. No purchase, quote or wallet scenario was executed for these changes.

The following ARM correction changed only its native libraries, manifests
and native documentation: 91 files, 2,422,729 bytes, SHA-256
`b7b27290dda31834d593bd0e4234079602f807e7093be5b396d78d18a35691b4`.
[The native correction](kindle-native-compatibility-fix.md) passed nine primitive
checks each with Debian glibc 2.41 and toolchain glibc 2.20 using a separately
corrected diagnostic loader. No loader is packaged. All Lua bytes remain those
of the preceding 91-file archive, and 27 package checks passed. These native
checks do not rerun or replace the historical live-account reading evidence.

The current reading archive additionally includes the shared network-dispatch
gate and full temporary-access expiry display. Its 25 connectivity cases and
two sets of 132 native display checks are independent, synthetic reading
evidence. The [current source binding](../spec/package/reading-revision-source-binding.json)
preserves the unchanged ARM bytes and restricts the default archive migration
to the tested reading functions. This update did not rerun the complete live
chapter or replace the local interactive profile.
