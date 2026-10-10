#!/bin/bash
set -euo pipefail

LUMA_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LUMA_ROOT="$(CDPATH= cd -- "$LUMA_SCRIPT_DIR/.." && pwd)"
LUMA_CONFIGURATION="${LUMA_BUILD_CONFIGURATION:-release}"
LUMA_OUTPUT="$LUMA_ROOT/build/macos"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Luma AppKit 必须在 macOS 上构建。" >&2
    exit 1
fi
case "$LUMA_CONFIGURATION" in
    debug|release) ;;
    *) echo "LUMA_BUILD_CONFIGURATION 必须为 debug 或 release。" >&2; exit 1 ;;
esac

LUMA_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
LUMA_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if ! command -v pkg-config >/dev/null || ! pkg-config --exists mpv; then
    echo "缺少 libmpv 开发依赖，请先运行 brew install mpv pkgconf。" >&2
    exit 1
fi
LUMA_SWIFT_ARGS=(--build-system native --package-path "$LUMA_ROOT/macos" --configuration "$LUMA_CONFIGURATION" --sdk "$LUMA_SDK_PATH")

# On the local CLT Swift 6.4 toolchain, SwiftBuild records the linked SDK as
# 13.0 even with xcrun and an explicit --sdk. The native build engine records
# the selected SDK correctly, allowing AppKit to use its current appearance.
# Keep the metadata check below until this toolchain issue is resolved.
xcrun --sdk macosx swift build "${LUMA_SWIFT_ARGS[@]}"
LUMA_BIN_DIR="$(xcrun --sdk macosx swift build "${LUMA_SWIFT_ARGS[@]}" --show-bin-path)"

mkdir -p "$LUMA_OUTPUT"
LUMA_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/luma-build.XXXXXX")"
trap 'rm -rf "$LUMA_STAGE"' EXIT
LUMA_APP="$LUMA_STAGE/Luma.app"
mkdir -p "$LUMA_APP/Contents/MacOS" "$LUMA_APP/Contents/Resources/Media"
cp "$LUMA_BIN_DIR/Luma" "$LUMA_APP/Contents/MacOS/Luma"
cp "$LUMA_ROOT/macos/Info.plist" "$LUMA_APP/Contents/Info.plist"
cp "$LUMA_ROOT/macos/Resources/AppIcon.icns" "$LUMA_APP/Contents/Resources/Luma.icns"
cp "$LUMA_ROOT/LICENSE" "$LUMA_APP/Contents/Resources/LICENSE"
cp "$LUMA_ROOT/docs/assets.md" "$LUMA_APP/Contents/Resources/AssetNotices.md"
ditto "$LUMA_ROOT/macos/Resources/Media" "$LUMA_APP/Contents/Resources/Media"
ditto "$LUMA_BIN_DIR/Luma_Luma.bundle" "$LUMA_APP/Contents/Resources/Luma_Luma.bundle"
for LUMA_LANGUAGE in en zh-Hans; do
    ditto "$LUMA_ROOT/macos/Resources/$LUMA_LANGUAGE.lproj" "$LUMA_APP/Contents/Resources/$LUMA_LANGUAGE.lproj"
done
chmod 755 "$LUMA_APP/Contents/MacOS/Luma"
plutil -lint "$LUMA_APP/Contents/Info.plist"

# Verify every architecture's linked SDK before signing. Keep the macOS 13
# deployment target; the build SDK determines adoption of the current design.
LUMA_LINKED_SDKS="$(xcrun vtool -show-build "$LUMA_APP/Contents/MacOS/Luma" | awk '$1 == "sdk" { print $2 }')"
if ! printf '%s\n' "$LUMA_LINKED_SDKS" | awk -v expected="$LUMA_SDK_VERSION" '
    function version(value, parts) {
        split(value, parts, ".")
        return sprintf("%d.%d.%d", parts[1], parts[2], parts[3])
    }
    NF { found++; if (version($1) != version(expected)) mismatch = 1 }
    END { exit (!found || mismatch) }
'; then
    printf '构建 SDK 不匹配：预期 %s，二进制记录为 %s。请清理构建缓存后重试。\n' "$LUMA_SDK_VERSION" "${LUMA_LINKED_SDKS:-未知}" >&2
    exit 1
fi

# Copy libmpv's actual non-system dylib closure, relocate all load commands,
# derive the minimum supported OS from those binaries, and sign each library.
# The resulting app has no runtime dependency on Homebrew's install location.
python3 "$LUMA_SCRIPT_DIR/bundle-mpv.py" "$LUMA_APP"

# Local development signature only. Distribution signing/notarization is separate.
codesign --deep --force --sign - "$LUMA_APP"
codesign --verify --deep --strict "$LUMA_APP"

# This directory is exclusively the generated application bundle.
if [[ -e "$LUMA_OUTPUT/Luma.app" ]]; then
    rm -rf "$LUMA_OUTPUT/Luma.app"
fi
mv "$LUMA_APP" "$LUMA_OUTPUT/Luma.app"
echo "已构建：$LUMA_OUTPUT/Luma.app"
