# Real interactive online reading

Date: 2026-09-13. The user explicitly requested actual online reading with their
account, authorizing this local KOReader run under Debian WSLg.

The run used the unchanged canonical development archive
`45385c6ff3cc99d2639f92575fb6db0ac363ab20aa76800aa7bbdbdbe93f5342`
and the existing private renewable session. Actual Windows window input opened
the native following list, chapter catalog and ReaderUI, then advanced pages.
No response, catalog or image was supplied by a fixture.

## Observed result

The followed comic `【我推的孩子】`, chapter 1, opened online with 45 pages.
The catalog marked that chapter free. Actual images rendered on pages 1 through
4 in native page-fit mode. At page 2, five real JPEG files were ready; at page 4,
pages 1 through 7 were ready, matching the configured three-page prefetch.

The profile had zero pages and zero reading anchors before the run. The final
sample contained seven ready pages, 18,621,249 image bytes, zero failed pages and
a persisted page-4 anchor. It had no durable chapter download job and no remaining
child worker. The other 38 pages were still missing: this was an interactive
online sample, not a repeat of the earlier complete-chapter acceptance.

The temporary request-observation patch was then removed. A normal new KOReader
process restored the chapter at page 4 through the visible Continue reading
action and was left open for the user.

A reading-region screenshot is retained locally under the ignored
`build/live-ui-reading/online-page-02.png` for the user's preview. Account
identifiers, credentials and acquired source images are not part of this record.

## Newly exposed QR session gap

Initially, both followed comics failed to load their catalogs. The production
Client received HTTP 200 and business code `99` from `ComicDetail`. Login and
following requests succeeded. The QR session contained the authentication
cookies but lacked `buvid3`.

A bounded production-Client comparison added only an existing, server-issued
`buvid3` from the same account's browser export to an in-memory QR session. The
selected catalog then returned 171 chapters; this comparison saved no credentials.

The current [official page script](https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/chunks/chunk-A-ZFq6o-.js)
initializes a missing `buvid3` through `GET https://manga.bilibili.com/ductape/buvid`.
That official endpoint issued the device cookie. A one-time initialization used
the existing production Transport and Session cookie parser, verified the selected
catalog and saved the session with the production atomic save. The authentication
and renewal credentials remained unchanged. After restarting, the ordinary UI
loaded the catalog and performed the online reading described above.

The production QR flow still needs automatic site initialization. This run
repaired the current private session only; it did not fix or replace the packaged
plugin. Earlier QR acceptance covered login, restart and following requests,
whereas the complete reading acceptance used a browser-imported session in a
separate profile. Those earlier results did not cover this failing combination.

An incidental cover request also hit the existing response-size limit, leaving
the library cover placeholder. Actual chapter images were acquired successfully.
No purchase, coupon consumption, recharge or following mutation was requested.
