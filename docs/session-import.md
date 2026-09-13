# Browser session import

The authentication development build also supports native **Sign in with QR code** from Account and settings. QR sign-in captures the independent renewal credential; copying only a browser Cookie header does not. See [renewable session behavior](session-renewal.md) for automatic maintenance and its verification boundaries. Existing imports remain supported as described below.

The plugin accepts a plain UTF-8 text file containing a browser request's complete `Cookie` header value. The native file importer supports `.txt`, `.json` and `.cookies` extensions, including uppercase variants, and a maximum size of 128 KiB. It also accepts a leading UTF-8 BOM, supported browser JSON exports and Netscape cookie exports. A custom plugin session file does not need to be generated manually.

## Create the private input file

1. Open `https://manga.bilibili.com/` in Chrome or Edge and sign in to the intended account.
2. Open Developer Tools with F12 and select Network. Refresh the page so the request list is populated.
3. Select an existing library request to `manga.bilibili.com/twirp/`.
4. In Headers, find Request Headers and copy the complete `Cookie` value. Use the request cookie header, not a response `Set-Cookie` header or an entire HAR export.
5. Paste the value into a text editor as one line and save it as `bilibili.txt` in a private location you choose. For development in this repository, input files belong inside `.secrets/`, which is excluded from Git and packaging. Do not paste the contents into a conversation or issue.

Example shape, with placeholders only:

```text
SESSDATA=REDACTED; bili_jct=REDACTED; DedeUserID=REDACTED; buvid3=REDACTED
```

Copy the actual complete header from the logged-in request; do not reconstruct credentials from this example. If the request does not contain `SESSDATA`, check that it belongs to the logged-in Bilibili session.

## Import on Kindle Scribe

1. Connect the Kindle Scribe to the computer over USB. Copy `bilibili.txt` into an accessible folder on the Kindle that you choose, and remember that folder. This instruction does not assume that a particular destination or an existing file is already present.
2. Safely disconnect USB and open KOReader and the BiliComics plugin on the Kindle. Enable the connection needed to validate the session.
3. Open **Account and settings**, then choose **Import from file**. These are the English message IDs for the localized controls in [the translation table](../l10n/bilicomics_zh_CN.lua). The existing **Import session** or **Replace session** paste dialog also contains **Import from file**.
4. In **Choose a session file**, browse with KOReader's native FileChooser to the folder selected in step 1 and tap `bilibili.txt`. Folder taps navigate; the file tap selects the file for import. The plugin does not auto-detect a filename or scan for an exported session.
5. Wait for **Session imported** and **The selected session was validated and saved.** The previous account remains selected if validation or saving fails. Closing the file chooser before selection cancels the operation. Closing the validation status suppresses feedback but does not undo an import already dispatched.

The masked paste workflow remains available. A selected file must be a readable regular file; directories, final symbolic links, empty or binary input and files larger than 128 KiB are rejected. Errors show fixed guidance without echoing the file contents or cookie value.

Successful import validates the account identity online and writes the plugin-managed, structured `session.dat` under the verified account namespace. Linux, including Kindle, uses the normal account directory. Android uses `android.dir/bilicomics/accounts/<account_key>/session.dat` in the app's private files directory; a shared-storage Android session requires a fresh validated import rather than automatic reuse. The browser export and this plugin-managed file have different roles and formats. Treat both as credentials. The importer leaves the selected export untouched; after successful import, you may remove that exported copy from the Kindle if it is no longer needed.

## Verification boundaries

The original file-import verification excluded purchase, quote and wallet tests. The user subsequently authorized non-purchase operations on 2026-09-13; current quote/wallet observations and synthetic transaction checks are recorded in [the non-purchase report](nonpurchase-integration-report.md), while actual purchasing remains prohibited. The focused file-import harness, `spec/ui/run_session_import.py`, uses synthetic files, actual native widgets and the real Controller/Session/SQLite path with controlled `validateSession` results. It performs no Bilibili network traffic and does not call purchase, quote or wallet operations. It passed 42 assertions at each of 600x800, 480x640 and 1860x2480; see [the focused result](../spec/ui/session-import-result.json) and [the Scribe-size result](../spec/ui/session-import-result-scribe-size.json). The largest resolution verifies layout in a Linux emulator, not physical Scribe or firmware 5.19.3 compatibility. The broader native UI probe was not rerun for that import change.

For separately authorized authenticated development checks, run `research/protocol/authenticated-readonly.lua` only in the authorized remote test environment. Transfer the input privately over SSH, store it in a private directory, and never include credentials in command arguments, logs, screenshots or test reports. The script excludes quote and wallet endpoints as well as purchase, rental, recharge, history writes, favorites mutations and account-setting endpoints. It permits only session validation, existing-library/history reads, chapter metadata/index/token acquisition and anonymous CDN retrieval.

The `metadata` mode first inspects fresh entitlement fields. The `images` mode permits image-index requests only for explicitly approved free or already-owned episodes with no temporary-access flags or contradictory locked state. Reports contain counts, field-presence flags and acquisition results, not account identity, titles, signed URLs or credentials. Any private response captures stay in the restricted remote workspace and do not enter the repository.

An expired or rejected nonrenewable session pauses dependent acquisitions. Sign in with QR code or import a newly validated session to restore account networking. Renewable sessions receive bounded maintenance before an authentication failure becomes an account failure; uncertain credential rotation requires sign-in again. Restarting alone is not evidence that an invalid session is valid. Locally retained chapters with valid offline rights remain available.
