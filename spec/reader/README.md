# Reader Verification

Run these tests only on the authorized remote `test-env` host. No local validation is authorized by the project instructions.

- `geometry_spec.lua` is a dependency-free assertion function covering EXIF composition, native units, anisotropic mapping, crop precision, source anchors and buffer caps.
- `native_spec.lua` uses the official KOReader runtime to exercise the production provider and ReaderUI, with a test implementation of the documented service interface. It checks PID ownership so a native thumbnail child cannot use the parent store.
- `run_native.py` creates synthetic image fixtures with an isolated Pillow dependency and runs separate native processes with private XDG settings. It never changes the runtime source.
- `native-results.json` records the latest successful complete reader suite.
- `bootstrap_spec.lua` exercises actual user-patch installation ownership, idempotency, disabled/F-Droid capabilities, lazy registration and safe fallback settings.
- `run_startup.py` and `startup_probe.lua` contrast ordinary plugin initialization, plugin top-level registration and the supported late hook by launching official `reader.lua` in separate processes.
- `run_production_startup.py` uses the actual plugin, Runtime, Controller and SQLite data to verify direct cold startup with a cached synthetic free chapter. `seed_startup.lua` prepares that data in a separate process; it does not register a provider in the tested process.
- `run_fallback_startup.py` exercises the actual main ReaderReady/FlushSettings hooks through normal reader close, then launches official `reader.lua` with native patches disabled. Its observer supplies no replacement fallback hooks. It verifies FileManager startup and restored progress when the actual controller reopens the local chapter.

Example command after uploading the plugin and specs into an isolated directory:

```powershell
ssh test-env 'python3 /tmp/reader-test/plugin/spec/reader/run_native.py --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --plugin /tmp/reader-test/plugin --output /tmp/reader-test/output --pillow /tmp/bilicomics-native-_duimwe7/backend-probe/python-deps'
```

Recheck that temporary paths exist before use. The known runtime reports `v2026.07.1`. The isolated Pillow directory comes from the digest-verified research harness; do not install dependencies globally.

Coverage includes JPEG/PNG/WebP with all EXIF directions, 300 DPI and unequal-axis DPI, ready and missing draw variants, selection/cover ownership, corruption and size guards, native document reference counts, same-document completion, geometry correction, continuous/page/free-pan process-restart anchors, one-shot chapter ending, ready-only thumbnails, parent snapshots and stale child rejection before native cache insertion.

The provider suite also requires local authorization at open and verifies that expired permission blocks an already rendered tile. The runtime's real authorization decisions remain a controller-contract concern; startup uses a stored free entitlement and no account credentials or HTTP.

These are synthetic reader-contract tests. Storage persistence, authenticated Bilibili acquisition, scheduler durability, purchased access, physical devices and third-party plugin coexistence require their own integration verification. A passing reader suite must not be described as proof of those separate requirements.
