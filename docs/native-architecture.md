# Architecture

Luma is a SwiftPM executable. AppKit owns the application, windows, menus, navigation, and collection views. AVKit provides system playback; libmpv handles additional media formats through its public C API.

## Source layout

| Component | Responsibility |
| --- | --- |
| `App.swift`, `MainWindowController.swift` | Application lifecycle, menus, shortcuts, navigation, and request coordination. |
| `NativeUI.swift`, `SidebarController.swift`, `Sheets.swift` | Reusable views, media grids, the sidebar, connection and detail sheets, and settings. |
| `Models.swift`, `Backend.swift` | Typed application data, actor-isolated session state, Emby requests, and playback negotiation. |
| `SessionStore.swift` | Keychain persistence and session restoration. |
| `ImagePipeline.swift` | Image downsampling, shared requests, cancellation, and a bounded memory cache. |
| `PlayerWindowController.swift`, `SubtitleParser.swift` | Playback controls, engine selection, subtitles, Now Playing, progress reports, and cleanup. |
| `MPVPlayback.swift`, `Sources/CMPV/` | libmpv events, commands, decoding, and OpenGL rendering. |
| `SmoothScrollView.swift` | Wheel input interpolation and scroll speed preferences. |
| `DemoCatalog.swift` | Fictional library metadata and demo playback. |
| `LocalPlaybackBridge.swift` | Retained FFmpeg-based compatibility implementation; not selected by current automatic playback negotiation. |
| `Resources/*.lproj/` | English and Simplified Chinese application strings. |

Swift sources above are under `macos/Sources/Luma/`; the C bridge is under `macos/Sources/CMPV/`. Bundled artwork and icons live in `macos/Resources/`.

## Interface

The window uses `NSSplitViewController`, `NSToolbar`, and `NSCollectionView`. Standard AppKit controls provide keyboard focus, selection, accessibility, and system appearance. On macOS 26 and later, glass buttons and `NSGlassEffectContainerView` use the system's Liquid Glass rendering. Older systems retain standard controls.

Mouse wheel events without gesture phases are interpolated. Trackpad gestures and native momentum stay with AppKit. Scroll speed can be reduced for remote desktop input that arrives as large pixel deltas. The animation runs only while scrolling and respects Reduce Motion.

`L10n` resolves application strings from the SwiftPM resource bundle. English is the fallback language; macOS language preferences, including an application-specific override, select the localization at launch. Text supplied by an Emby server is displayed as received.

## Sessions and network requests

Authentication uses Emby's `Users/AuthenticateByName`. Server normalization adds `/emby/` to root addresses while preserving explicit reverse-proxy prefixes. An address without a scheme is treated as HTTP.

API requests carry `X-Emby-Authorization` and `X-Emby-Token`. API redirects are not followed automatically. Artwork has a separate redirect policy: it permits image/CDN redirects, removes Emby credentials on cross-origin redirects, and rejects HTTPS downgrades. HTTPS uses system certificate validation; explicitly entered HTTP servers are supported.

A single Keychain item stores the saved connection and access token. Passwords are not retained. Launch restores and validates the session. Temporary network failures preserve it; an authentication failure invalidates the token. A successful server switch replaces the old session, and an explicit disconnect removes it. Persistence errors are shown to the user.

UserDefaults stores the device identifier, last entered server and username, application preferences, and demo favorites. Session generations prevent late responses from an old account from updating the current interface or invalidating a newer connection.

## Browsing and artwork

Home sections load concurrently. A non-authentication failure in one section leaves other sections available. Lists request pages as needed, and search is debounced by 280 ms. Query snapshots and request generations keep stale search or pagination responses out of the current result set. Favorites update their existing cells without resetting scroll position or selection.

Artwork is downsampled with ImageIO to the requested display size. The pipeline coalesces matching requests, limits downloads to six at a time, and keeps an in-memory cache bounded by 96 MiB and 160 images. A request is canceled when no visible subscriber needs it. Images are not persisted to disk.

## Playback negotiation

The client sends a combined AVPlayer/libmpv capability profile to `Items/{id}/PlaybackInfo`, then selects a source in this order:

1. A system-compatible direct source for AVPlayer.
2. A supported original source for libmpv.
3. Server-provided H.264/AAC HLS when transcoding is allowed.

The AVPlayer path covers supported video and audio combinations in MP4, M4V, MOV, and HLS. The libmpv path covers additional supported combinations such as MKV, WebM, and TS with audio including DTS, TrueHD, FLAC, and Opus. Selection uses explicit container and codec checks; an unknown or unavailable route produces an error.

When Emby omits `DirectStreamUrl`, the client can form its standard `Videos/{id}/stream.{container}` URL. Server filesystem paths are never treated as network URLs. Only direct play uses `Static=true`; direct stream preserves any server-side remuxing requirements.

Initial media and subtitle URLs must share the server's origin before receiving credentials. Deployments returning an initial playback URL on another CDN origin are not currently supported.

## Player engines

`MPVPlayback` owns the libmpv core and render context. Events and commands use a dedicated queue; interface updates return to the main thread. The engine disables user configuration, scripts, external URL resolvers, and disk caching.

The renderer uses the OpenGL render API. `hwdec=videotoolbox` requests hardware decoding, and the displayed status comes from `hwdec-current`; unsupported codecs may fall back to software decoding. The direct playback path does not launch FFmpeg, re-encode media, or write intermediate conversion files.

The demuxer cache is configured for up to 64 MiB forward, 32 MiB backward, and a target of 30 seconds. These limits do not include decoded frames, renderer allocations, or the rest of the application.

Both engines support playback controls, seeking, resume positions, audio/subtitle selection, macOS media keys, and Now Playing. AVKit supplies system Picture in Picture. The libmpv path uses AppKit controls and does not currently support Picture in Picture or a chapter menu. External AVPlayer WebVTT subtitles use an application overlay and do not appear in the system Picture in Picture window.

The retained `LocalPlaybackBridge` can copy video, convert audio to AAC, and serve local HLS through an FFmpeg subprocess. Current automatic negotiation does not select that route for MKV playback.

## Progress and lifecycle

Emby positions use ticks, with 10,000,000 ticks per second. AVPlayer seeks to a saved position after becoming ready; libmpv receives the starting position when loading the media.

Both engines share ordered start, progress, and stop reporting, associated with the device and playback session. Switching media or closing the window detaches rendering and callbacks before releasing libmpv resources in the background. Switching accounts waits for playback cleanup. App termination waits up to three seconds for final reporting before exiting.

## Build boundaries

The Swift package declares macOS 13 as its deployment target and compiles with a macOS 26 or newer SDK. The actual application minimum is derived from its executable and bundled libraries. The currently verified Apple Silicon dependency set requires macOS 27; a lower source deployment target does not lower those binary requirements.

`scripts/bundle-mpv.py` follows non-system Mach-O dependencies, copies them into `Contents/Frameworks`, rewrites load commands, checks architectures, and signs the libraries. It records exact versions, origins, hashes, and license material under `Contents/Resources/ThirdParty/`.

Tests cover network/session behavior, images, navigation, scrolling, subtitles, negotiation, progress reporting, and synthetic libmpv playback. Hardware-dependent rendering tests require a graphical Mac. Real media, HDR output, subtitle styles, and audio-device compatibility still require device testing. See the [development guide](development.md) for commands and [third-party notices](../macos/ThirdPartyNotices.md) for distribution requirements.
