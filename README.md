<p align="center">
  <img src="macos/Resources/AppIcon.svg" width="96" alt="Luma icon">
</p>

# Luma

A native Emby client for macOS, written in Swift and AppKit.

[![Native macOS checks](https://github.com/carelessty/lumo/actions/workflows/macos-native.yml/badge.svg)](https://github.com/carelessty/lumo/actions/workflows/macos-native.yml)
[English](README.md) · [简体中文](README.zh-CN.md)

Luma brings your Emby library to the Mac with native navigation, system playback controls, and support for formats such as MKV through libmpv. The project is under active development.

## Download

Get the [latest preview release](https://github.com/carelessty/lumo/releases). The first prebuilt version, **0.4.0**, requires **Apple Silicon and macOS 27 or later**. Download the application ZIP, extract it, and drag `Luma.app` to Applications. Homebrew is not required to run this build.

Preview builds are ad-hoc signed and **not notarized by Apple**. macOS may block the first launch; see [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445). The release includes checksums and the corresponding dependency sources. Intel and older macOS builds are not provided yet.

## Features

- Browse movies and shows, search your library, manage favorites, and continue watching.
- Play system-supported media with AVKit and additional formats with libmpv, including hardware decoding through VideoToolbox when available.
- Switch audio and subtitle tracks, adjust playback speed, and sync progress with Emby.
- Use macOS media keys, Now Playing, full screen, and Picture in Picture with AVKit.
- Keep your connection in Keychain, with automatic session restoration on launch.
- Follow the system appearance and language, with Liquid Glass on macOS 26 and later. English and Simplified Chinese are included.

Offline downloads, Emby Connect, automatic updates, and Picture in Picture for libmpv are not implemented.

## Build

Requirements:

- macOS with Xcode or Command Line Tools providing **Swift 6+ and the macOS 26+ SDK**.
- [Homebrew](https://brew.sh/) and Python 3.10+.
- `mpv` and `pkgconf`. The test suite also requires `ffmpeg`.

```sh
git clone https://github.com/carelessty/lumo.git
cd lumo
brew install mpv pkgconf ffmpeg
./scripts/test-macos.sh
./scripts/run-macos.sh
```

The app is built at `build/macos/Luma.app`. Copy it to `/Applications` to install it. Build scripts bundle the required libraries and apply an ad-hoc signature; Developer ID signing and notarization are not configured.

The source deployment target is macOS 13, but **a built app requires the highest minimum macOS version of its bundled dependencies**. The packaging script calculates this automatically. The currently verified local build is Apple Silicon on macOS 27; older macOS versions and Intel builds require compatible libraries and further testing.

See the [development guide](docs/development.md) for debug builds, packaging, and a local test server.

## Use

Connect with your Emby server address and account, for example `https://media.example.com` or `http://192.168.1.10:8096`. Keep any reverse-proxy path prefix; do not use the server's `/web/index.html` address.

For HTTPS playback with libmpv, use a certificate trusted by macOS's public CA bundle. Self-signed certificates and private CAs installed only in Keychain are not supported by that engine.

Luma restores the last session on launch. Use **Manage Connection…** in the sidebar to switch servers, or **Disconnect & Forget** to remove the saved session. Access tokens are stored in Keychain; passwords are not saved.

The app follows your preferred macOS language. To choose a language just for Luma, open **System Settings → General → Language & Region → Applications**, add Luma, and select English or Simplified Chinese. Relaunch the app after changing its language. Server-provided titles and descriptions remain in the language supplied by Emby.

| Action | Shortcut |
| --- | --- |
| Connect to a server | ⌘K |
| Search | ⌘F |
| Refresh | ⌘R |
| Switch library sections | ⌘1–4 |
| Settings | ⌘, |
| Open details | Return or double-click |
| Play / pause | Space |
| Seek backward / forward | ← / → |

For large scroll steps over a remote desktop connection, lower **Settings → Wheel Speed**. Trackpad gestures retain the system's scrolling behavior.

## Contribute

Bug reports, fixes, and translations are welcome. Search [existing issues](https://github.com/carelessty/lumo/issues) before opening a new one, and include the steps needed to reproduce a problem. English and Chinese reports are both welcome.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow and [the architecture guide](docs/native-architecture.md) for the source layout.

## License

Luma is licensed under [GPL-3.0-or-later](LICENSE). Third-party libraries and demo media retain their own licenses; see [third-party notices](macos/ThirdPartyNotices.md) and [asset credits](docs/assets.md).

Luma is an independent project and is not affiliated with Emby or Apple.
