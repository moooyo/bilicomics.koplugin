# Protocol adapter

All network methods are synchronous worker operations. The main KOReader UI,
document provider, drawing paths, and database writer must not invoke them
directly. Public methods return `value, error`; protocol errors contain `kind`,
`message`, and `retryable`, with status/capability fields where relevant.

## Components

- `session.lua` imports cookie headers, JSON browser exports, or Netscape exports.
  Only Bilibili session/anti-CSRF/device cookies are retained. An account ID from
  cookies is not trusted until the current official navigation endpoint confirms
  it. `serialize()` contains credentials and is restricted to private persistence
  or bounded worker IPC; `summary()` is the safe UI result. Linux/Android saves
  create a new private file with mode `0600` and atomically replace the previous
  file after writing and syncing it.
  The controller uses `bilicomics/session_storage.lua` to select and verify
  Android app-private storage; shared-storage permission flags alone do not
  establish private credential ownership.
- `transport.lua` uses bundled LuaSocket/LuaSec with certificate-chain **and**
  hostname verification, a bundled CA file, time limits, response-size limits,
  and no automatic redirects. It never logs request headers, signed URLs, or
  response bodies. CDN acquisitions do not receive account cookies.
- `client.lua` constructs current PC API requests, validates input, normalizes
  catalog/access state, and keeps the image key exchange private to one worker.
- `native_backend.lua` calls the local `biliwasm` shared library through FFI. The
  C host executes the pinned official signing WASM over wasm3; there is no Node,
  browser, companion service, or command-line credential dependency.
- `native_library.lua` stages Android libraries in `android.dir`, the official
  app's `Context.getFilesDir()`, because its linker namespace rejects shared
  storage. Both native providers use the same manifest digest/size checks,
  app-owned `0700` directories and `0600` files, content-addressed paths,
  descriptor-relative operations that reject symlinks, synchronized atomic
  publication, and a per-content directory lock. The verified file descriptor
  pins the loaded inode against pathname replacement. Successful descriptors
  remain with their handles so Android API 21/22 cannot reuse an old
  `/proc/self/fd/N` dlopen name for a different library; repeated cache hits do
  not allocate more descriptors. Linux retains its original direct load path.
- `assets.lua` installs public signing resources on first worker use and checks
  their pinned SHA-256 before every selection. Assets are stored outside account
  state under `bilicomics/protocol-assets`. Offline downloaded reading does not
  load or acquire these resources.
- `response_crypto.lua` implements the independently verified current
  AES-192-CBC response algorithm using KOReader's existing AES-ECB binding.
- `ecdh.lua` creates the current P-256 `m1` and private JWK exchange format and
  derives the image shared secret. It uses bundled LibreSSL when its symbols are
  available and the plugin's portable MbedTLS library otherwise. Native buffers
  are cleared before release.
- `portable_crypto.lua` loads the plugin's ABI-specific MbedTLS crypto library
  for P-256, AES block operations, PBKDF2-SHA512, and authenticated GCM. Linux and
  Android artifacts have separate targets and manifests; a built artifact is
  not by itself a successful target-device test.
- `image_crypto.lua` implements current image-container versions 3, 5, 6, 7, and
  8 using the verified native primitives. It preserves version-specific metadata
  layouts, prefix lengths, CBC padding, GCM authentication, and CTR counter width.
  It performs no networking or telemetry. Synthetic results have been compared
  byte-for-byte with unchanged official JavaScript and WASM.
- `image.lua` checks image signatures, dimensions, container boundaries, and
  content SHA-256 without decoding an entire long image into memory. Its result
  says `verification="container"`; it does not claim all pixels were decoded.

## API

```lua
local client = Client.new{
    session = imported_session, -- Session instance or serialized fields
    transport = worker_transport, -- optional injected HTTP transport
    crypto = crypto_adapter, -- optional verified adapter
    asset_root = public_asset_directory, -- optional persistent asset directory
}
```

The default client constructs its transport and native crypto adapter together.
If supplying a separate `Crypto.new`, pass the same worker transport so an absent
pinned signing module can be installed.

`validateSession()` returns a safe summary and updates `client.session`; a worker
can separately return `client.session:serialize()` to its private main-process
account-import continuation. `listFavorites`, `listHistory`, and `search` return
normalized comic arrays. `comicDetail` returns `{comic, episodes, extra}` and
preserves fractional episode ordering. `setFavorite(comic_id, boolean)` is an
explicit account mutation; reading and prefetch never call it implicitly.

`imageIndex` returns `{episode_id, revision, images, pages, extra}`. Each image has
`id`, `index`, `path`, `width`, `height`, `x`, and `y`. A descriptor must omit source
URLs; store `path` only in mutable acquisition state. `imageTokens(paths, opts)`
returns an ordered token array and retains its private key on the client.
`downloadImage(token, temporary_path, opts)` must execute on the same client when
encryption is involved. It returns a temporary file plus dimensions, format,
byte count, SHA-256, and verification level. The main process owns final commit.

`wallet`, `purchaseInfo`, `discountList`, and `discountPrice` expose current
service data. `buyEpisode(payload)` accepts only explicit currency/coupon methods
and verified single/range shapes. It rejects automatic-payment settings and
does not retry. The purchase service must durably journal and confirm the quote
before this method runs. Recognized purchase rejection codes 1–5 are definitive;
unknown business codes, response loss, malformed results, and transport errors
remain uncertain. An omitted `pay_amount` follows the official coupon/zero-price
wrapper shape; the trusted quote service must already have established price.

## Capability status and release gates

Source contracts, synthetic verification, and live authenticated behavior are
different evidence. Consult the native manifest for the exact compiled ABI.
Capabilities describe installed implementation paths, not successful login or
account entitlement.

Native signing, current response decoding, P-256 exchange, ordinary/encrypted
image acquisition, metadata requests, quote construction, and purchase failure
semantics have production modules and remote verification.

The current `m2` browser-environment fingerprint remains separate from successful
local cryptography. The m2 WASM inspects browser
DOM, navigator, canvas/WebGL/native methods, and the official reader environment.
A made-up fingerprint or a historical unsigned request is not a validated device
implementation. The official metadata/index wrapper has an explicit catch
branch: it sends `m2=error:<actual message>_<milliseconds>` even when fingerprint
creation fails. `prepareCatalog` and `prepareIndex` implement that error-report
branch using an honest device capability message. `index_error_reporting=true`
does not imply `index_challenge=true`, and server acceptance of this branch has
not been established. Encrypted conversion is enabled only when the required
local primitive providers are available, and rejects unknown versions. It has a
16 MiB compressed input/preparation limit; larger inputs return an actionable
error instead of allocating an unbounded number of whole-image buffers.

One anonymous signed metadata request through the actual KOReader transport and
native signing bridge returned business code `99`; the anonymous navigation
request returned `-101`. These observations neither establish authenticated
reading nor identify the cause of the metadata rejection. No actual purchase,
coupon consumption, account login, or manga image acquisition has been executed
in this implementation work.

## Verification

Run only on `test-env` unless local execution has been explicitly authorized:

```sh
python3 spec/protocol/run_remote.py \
    /absolute/koreader/runtime /absolute/plugin/source /absolute/new/output \
    --native-assets /absolute/verified/protocol-assets
```

The runner needs Pillow for small synthetic PNG/JPEG/WebP fixtures. It exercises
the real protocol modules, private session persistence, normalized entitlement,
HTTP request construction, purchase boundaries, native signing, current response
decoding, P-256 exchange, and rejection of changed executable assets. Separate
research fixtures cross-check the crypto algorithms with the unchanged official
WASM. Fixture HTTP responses are never evidence of an accepted server purchase.

Evidence is maintained in `research/protocol/`. Complete first-release protocol
acceptance still needs authorized real free/owned images, current quote scope
verification, explicitly authorized purchase verification, and declared devices.
