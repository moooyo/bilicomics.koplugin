# BiliComics Interactive UI Prototype

Open `index.html` through an HTTP server so the module script can load its localization data. This is a browser design prototype, not an installed KOReader plugin. All comics, balances, quotes and purchases are simulated locally in the page.

The review shell provides page shortcuts, standard/large layouts, online/offline state, reset, and purchase-outcome scenarios. The product itself uses four primary destinations, with account/settings accessible from the header.

Useful entry URLs relative to the server:

```text
/?view=continue
/?view=detail
/?view=purchase
/?view=purchase&scenario=low
/?view=purchase&scenario=unknown
/?view=purchase&scenario=loadfail
/?view=downloads&offline=1
/?view=reader
/overview.html
```

Add `embed=1` to show the product screen without the review shell. Add `size=large` to open the larger layout.

Runtime verification must follow the project policy: use `ssh test-env` unless local verification is explicitly authorized. The recorded preview server is bound to the remote loopback interface and exposed to this workstation through an SSH forward. Its temporary lifetime does not affect the saved source files and screenshots.

See [the design specification](../ui-spec.md) and [recorded browser checks](../screens/verification.json). The final recorded pass includes 30 successful interaction/layout checks, no browser script errors, and no overflow in the checked base-page layouts. The controls simulate presentation and state transitions only; they do not validate native KOReader widgets or Bilibili APIs.
