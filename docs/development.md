# Development

Luma is a SwiftPM executable using AppKit, AVKit, and libmpv. Start with the [requirements and build instructions](../README.md#build).

## Build and run

```sh
./scripts/run-macos.sh

# Build without launching
./scripts/build-macos.sh

# Build and launch with debug symbols
LUMA_BUILD_CONFIGURATION=debug ./scripts/run-macos.sh
```

The default configuration is `release`. The app is assembled at `build/macos/Luma.app` with its icon, demo artwork, localization resources, and dynamic libraries.

The build script uses SwiftPM's native build engine and verifies that the executable records the selected SDK. It then bundles libmpv's non-system dynamic-library dependencies, rewrites their load paths, calculates the required minimum macOS version, and signs the result locally. A packaged app does not load these libraries from Homebrew at runtime.

## Tests

```sh
./scripts/test-macos.sh

# Forward Swift Testing filters to swift test
./scripts/test-macos.sh --filter BackendTests
```

Tests use Swift Testing and synthetic network responses and media. FFmpeg generates local playback fixtures. The script locates the active toolchain's Testing framework and uses a temporary build directory to avoid FileProvider metadata interfering with code signing. Set `LUMA_TEST_SCRATCH` to use a different scratch directory.

Check the final Swift Testing summary as well as the exit code. Some tests create AppKit windows and exercise the playback engine, so full local validation needs a Mac with a graphical session.

`MPVPlaybackTests` probes for an accelerated OpenGL 3.2 context before running rendering integration tests. A hosted macOS runner without that capability skips those tests explicitly. Other tests and application packaging still run. A failure to initialize Luma's player on a capable Mac is a test failure, not a reason to skip.

For interface changes, check English and Simplified Chinese, light and dark appearances, keyboard navigation, and the relevant window sizes. For playback changes, check both engines where applicable, including pause, seek, track selection, resume position, and closing the player.

## Local Emby fixture

The optional integration fixture requires Node.js 22 or later. It has no npm dependencies and is not part of the application.

```sh
node scripts/mock-emby.mjs
```

Connect Luma to `http://127.0.0.1:8097` with username `demo` and password `demo`. The fixture binds only to loopback and provides fictional movies, a series, pagination, favorites, and playback progress endpoints. State is kept in memory and cleared on exit. Request and playback state is available at `http://127.0.0.1:8097/__qa/state`.

By default, playback uses the online Sintel trailer described in [asset credits](assets.md). To generate a local MKV sample instead:

```sh
LUMA_QA_SYNTHETIC_MKV=1 node scripts/mock-emby.mjs
```

Useful environment variables:

| Variable | Purpose |
| --- | --- |
| `LUMA_QA_PORT` | Change the listening port. |
| `LUMA_QA_FFMPEG` | Select an FFmpeg executable for synthetic samples. |
| `LUMA_QA_VIDEO_CODEC` | Choose `h264` or `hevc` for a synthetic sample. |
| `LUMA_QA_SAMPLE_FILE` | Serve a local sample file, up to 30 MiB. |
| `LUMA_QA_MULTITRACK=1` | Describe a matching local multi-track MKV fixture; requires `LUMA_QA_SYNTHETIC_MKV=1` and `LUMA_QA_SAMPLE_FILE`. |

The fixture exercises client behavior; real Emby servers, reverse proxies, and different media still need integration testing. Stop it with Ctrl+C.

## Localization

Application translations are SwiftPM resources under `macos/Sources/Luma/Resources/`. English is the development language; `zh-Hans` supplies Simplified Chinese. App bundle metadata translations live under `macos/Resources/`.

Use macOS **Language & Region → Applications** to test a language override and relaunch Luma. The app should translate controls and application messages while preserving server-provided media metadata. Translation guidelines are in [CONTRIBUTING.md](../CONTRIBUTING.md#translations).

## Packaging

```sh
./scripts/build-macos.sh
./scripts/archive-macos.sh
```

The archive is written to `build/macos/Luma-macOS.zip`. The archive script extracts a temporary copy and verifies its code signature. GitHub Actions runs tests, builds the app, and checks the archive; it does not publish binaries.

Local builds and the initial public preview are ad-hoc signed, without Apple notarization. Release notes must state the signature status, supported architectures, and actual minimum macOS version. The generated dependency manifest is at `Luma.app/Contents/Resources/ThirdParty/manifest.json`. See [third-party notices](../macos/ThirdPartyNotices.md).

For a release, run `./scripts/prepare-release.sh <commit-or-tag>`. This builds a committed snapshot in a clean temporary directory, removes debug path records, verifies the extracted app signature, and writes the application ZIP, Luma source archive and dependency manifest to `build/release/`. It rejects application bundles containing personal build paths. Collect the matching dependency sources with `scripts/collect-dependency-sources.py` before publishing a binary. Publish all source archives and SHA-256 checksums on the same release page; retain the source assets for as long as their binary is available.

For the 0.4.0 Apple Silicon preview:

```sh
ditto -x -k build/release/Luma-0.4.0-macos-arm64.zip build/release/verify
python3 scripts/collect-dependency-sources.py build/release/verify/Luma.app \
  --version 0.4.0 --supplement scripts/release-sources-0.4.0.json
```

Run source collection before upgrading Homebrew dependencies. The collector checks the app's recipes against the installed versions and validates each download using its pinned checksum or Git commit. The versioned supplement supplies external build inputs that the installed recipes do not fully describe; review it for each new dependency set.
