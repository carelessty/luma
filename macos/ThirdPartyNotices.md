# Luma native playback dependencies

Luma's original source code is licensed under GPL-3.0-or-later; see the root
`LICENSE` and `README.md`. Third-party components retain their own licenses.

A locally packaged build embeds libmpv and the non-system dynamic libraries referenced
by its Mach-O load commands. Dependencies come from Homebrew's official formulae
and bottles, not from the IINA application. Luma uses libmpv's public client and
OpenGL render APIs; IINA is an architectural reference, not copied source code.

The installed application contains `Contents/Resources/ThirdParty/manifest.json`
with the exact library list, original file hashes, architectures, minimum macOS
version, package versions, build origins and license declarations for that build.
Per-package directories contain the upstream license and copyright files shipped
in the corresponding Homebrew bottle, plus the Homebrew formula source including
its upstream source URL, checksum, patches and build configuration.
The copied Homebrew formula recipes are covered by `Homebrew-LICENSE.txt`.

The initial integration uses mpv 0.41.0 (Homebrew revision 10, client API 2.5).
The local macOS 27 Homebrew bottle requires macOS 27. The packaging script derives
the generated application's minimum system version from every bundled library;
it does not advertise support for an older macOS than its binary dependencies.

mpv offers GPL/LGPL build configurations, but the Homebrew dependency set used
here includes GPL components. Public binary previews are accompanied by Luma's
source archive and a dependency source archive on the same GitHub release page.
That archive contains the upstream sources, formulae, patches, build resources,
license notices and an inventory with checksums for the packaged versions.
CI verifies packaging without automatically publishing release artifacts.

Keep the corresponding source archives available alongside every binary release.
A manifest, formula or upstream repository link alone does not replace those
materials. Current preview builds are ad-hoc signed and are not notarized by
Apple; Developer ID signing and notarization are separate release tasks.

No mpv executable, FFmpeg executable, Python environment, yt-dlp, user scripts or
Vulkan ICD driver is bundled. The embedded renderer uses OpenGL and VideoToolbox.
Optional features requiring those external programs or runtime resources are not
part of Luma's playback path. System frameworks continue to come from macOS.

Upstream references:

- mpv: https://mpv.io/ and https://github.com/mpv-player/mpv
- Homebrew formula: https://formulae.brew.sh/formula/mpv
- FFmpeg: https://ffmpeg.org/legal.html
- IINA: https://iina.io/ and https://github.com/iina/iina
