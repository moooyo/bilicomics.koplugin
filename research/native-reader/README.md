# Native Reader Research Probes

These are research harnesses, not production plugin modules. They were executed only on `ssh test-env`, using official KOReader v2026.07.1 for Linux x86_64. Follow the project's verification policy; do not run locally without explicit local verification authorization.

See [the detailed report](../../docs/native-reader-integration-research.md) for interpretation, source links, and unverified behavior.

## Files

- `provider_probe.lua`: minimal composite Document provider, native rendering, core ReaderUI, continuous-mode resume, event interception, and simulated file completion.
- `run_provider_probe.py`: creates synthetic PNG fixtures and runs each provider scenario in a separate Lua process under Xvfb.
- `provider-probe-results.json`: 21 passing assertions from the recorded run.
- `backend_probe.py` and `backend_probe.lua`: generate JPG/PNG/WebP fixtures and exercise native image, directory and CBZ rendering, DPI and memory behavior.
- `backend-probe-results.json`: recorded per-case backend results and isolated dependency digest.
- `ui-waiting.png` and `ui-online.png`: native framebuffers containing synthetic grayscale bands before and after file completion.

## Remote reproduction

Use an isolated extraction of the official release, not a user's installed runtime. The verified asset is `koreader-linux-x86_64-v2026.07.1.tar.xz`, SHA256 `299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`.

The recorded runtime was `/tmp/bilicomics-native-_duimwe7/lib/koreader`. That temporary path is evidence of the run, not a guaranteed permanent installation. Replace paths below with an existing isolated remote extraction and uploaded probe scripts. Use a fresh output directory for each provider run; the scenarios intentionally change file availability and native settings.

PowerShell commands invoking the remote Linux environment:

```powershell
ssh test-env 'python3 /tmp/research/run_provider_probe.py /tmp/runtime/lib/koreader /tmp/research/provider-run-new /tmp/research/provider_probe.lua'
ssh test-env 'python3 /tmp/research/backend_probe.py --runtime /tmp/runtime/lib/koreader --work /tmp/research/backend-run-new'
```

Upload both backend files to the same remote directory. The backend harness uses an isolated, digest-verified Pillow wheel to generate images; it does not install dependencies globally. The provider harness uses Python's standard library for its PNG fixtures. The provider runtime needs Xvfb and uses private XDG settings directories.

## Deliberate limitations

The provider harness uses 72 DPI grayscale PNGs, fixed geometry, no HTTP, no real workers, no entitlement checks, no purchase, and no background download service. Bundled plugins are disabled. Its missing-state guard covers the exercised ordinary draw path; it is not a complete implementation of inverted drawing, fragments, thumbnails or page-browser behavior. The native backend harness separately verifies 300 DPI geometry; that normalization is not implemented in the provider prototype.

Success demonstrates feasibility of the exercised native integration. It does not establish a finished plugin, compatibility with every KOReader module or plugin, current-master execution, Bilibili authentication, arbitrary image sizes, or real e-ink device performance.
