# Contributing to Luma

Contributions are welcome through [GitHub issues](https://github.com/carelessty/lumo/issues) and [pull requests](https://github.com/carelessty/lumo/pulls). English and Chinese are both welcome.

## Report a problem

Search existing issues first. A useful report includes:

- The Luma version or commit, macOS version, and Mac model or chip.
- Steps to reproduce, expected behavior, and actual behavior.
- For playback issues: container, video/audio codecs, selected player, and whether the same file works in another player.
- For scrolling issues: mouse or trackpad, whether a remote desktop is involved, and the scroll wheel speed setting.

Use synthetic media or a shareable sample when possible. Remove server credentials, access tokens, authenticated URLs, and personal library details from logs and screenshots.

## Submit a change

For a small fix, open a pull request directly. For a new feature or a substantial interface or architecture change, open an issue first to discuss the scope.

1. Fork the repository and create a branch from `main`.
2. Follow the [build instructions](README.md#build) and the [development guide](docs/development.md).
3. Keep each pull request focused on one change. Follow the surrounding Swift style and prefer standard AppKit controls and macOS behavior.
4. Add regression coverage for behavior changes where practical, and run the relevant tests. Test interface and playback changes in the app as well.
5. Explain the problem, the resulting behavior, and what you tested. Include screenshots for visible interface changes and link any related issue.

The [architecture guide](docs/native-architecture.md) describes the main components. UI work belongs on the main actor; network, image decoding, and player teardown should not block it. Performance changes should include measurements, the test setup, and enough information to repeat the comparison.

Do not commit generated app bundles, dependencies, signing credentials, or private integration records.

## Translations

Luma currently supports English and Simplified Chinese. The app follows macOS language preferences, including the per-app language setting.

Strings live in `macos/Sources/Luma/Resources/en.lproj/` and `zh-Hans.lproj/`, split into `Interface.strings`, `Playback.strings`, and `Service.strings`. Bundle metadata lives in `macos/Resources/en.lproj/InfoPlist.strings` and `zh-Hans.lproj/InfoPlist.strings`.

Use the `L10n` helpers for user-facing text. Keep keys and format placeholders consistent across languages, translate complete sentences, and check both languages in the app for clipping and unclear labels. Server-provided titles and metadata are not application translations.

When changing documented behavior, update both `README.md` and `README.zh-CN.md`. For a new language, open an issue to coordinate coverage before sending the translation.

## License

Contributions are accepted under the project's [GPL-3.0-or-later license](LICENSE). Include attribution and license information when adding third-party material.
