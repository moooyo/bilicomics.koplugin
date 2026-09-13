# Expanded official homepage sections

On 2026-09-13, a fresh anonymous request to
`https://manga.bilibili.com/index.pageContext.json` returned HTTP 200 with
`application/json`, 156649 bytes, and `pageId = "/pages/index"`. The same request
already contains these direct-comic sections:

| Official section | Observed arrays | Raw comics | New distinct comics in page order |
| --- | --- | ---: | ---: |
| Recommendations | `recommendation.comics` | 7 | 7 |
| Best sellers | `hotSeller.firstGroup`, `hotSeller.secondGroup` | 10 | 10 |
| Widely discussed | `internetHot.firstGroup`, `internetHot.secondGroup` | 10 | 8 |
| Completed works | `completedComic.firstGroup`, `completedComic.secondGroup` | 10 | 9 |
| Total selected | Four sections | 37 | 34 |

The fresh homepage still loads
`https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/entries/pages_index.B7vjAQej.js`,
whose SHA-256 is
`f3dec7912ae8d6357166ce3681d4b409f795485088f607e170e852269f2b136a`.
Its three section components render `firstGroup` before `secondGroup` and preserve
each array's order. Both groups are already present; their arrows only scroll
the local carousel. Their shared card component constructs `/detail/mc<ID>`
links from `comic_id`, rather than following an arbitrary supplied link.

All 37 selected rows had numeric comic identities, titles and official CDN
vertical covers. The original section uses `id` and `evaluate`; the three added
sections use `comic_id` and `comic_introduction`. All use a string `tags` array.
The added rows' observed `home_block_jump_value` values were
`bilicomic://reader_progress/<ID>`, but the plugin does not store or follow those
links. It continues opening its existing chapter catalog from the canonical ID.

The page also contains `ranking.JP`, `ranking.CN`, and `ranking.KO`, each with 50
comics. The homepage itself displays only the first six of the selected ranking.
Those rankings are outside this minimal four-section expansion. The separate
`banner` contains six card entries and eighteen comic entries and is excluded.
No distinct new-release section was present, so no such field or label is
invented. These observations describe the captured response; titles and counts
may change on later anonymous requests.

The protocol makes the same single anonymous GET with the same 4 MiB response
bound. It appends the four selected sections in page order, keeps the first valid
occurrence of each comic ID, and limits the output to 96 valid distinct comics.
The limit is defensive and does not pad the observed 34-item result. The result
envelope remains `source = "official_homepage"`, `personalized = false`, and
`has_more = false`, with no new endpoint or server-pagination claim.

Each item now includes one fixed `extra.recommendation_section` value:
`recommendation`, `hot_seller`, `internet_hot`, or `completed`. This records its
editorial source; it does not assign favorite, reading, completion or purchase
state. Both observed description fields become the existing
`extra.recommendation` / `extra.evaluate` display fields. Contexts containing only
the original recommendation section remain supported. Missing or malformed
optional groups are ignored while the valid original feed remains available.

The focused remote run passed 13 groups and 153 assertions inside `unshare --net`
on `test-env`, with no real transport in the contract process. It covers original
anonymous-session isolation, exact request count, four-section order, cross-group
deduplication, first valid occurrence, source labels, optional-section fallback,
excluded banner/ranking data, the 96-item limit and the freshly captured official
response. `recommendations-expanded-result.json` and
`recommendations-expanded-verification.json` retain this run separately from the
earlier recommendation-only evidence and bind it to the current source digests.
