#!/bin/bash
set -euo pipefail

# Build only committed files, away from local sessions, caches and private data.
LUMA_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LUMA_REF="${1:-HEAD}"
LUMA_COMMIT="$(git -C "$LUMA_ROOT" rev-parse --verify "${LUMA_REF}^{commit}")"
LUMA_OUTPUT="$LUMA_ROOT/build/release"
LUMA_STAGE="$(mktemp -d /tmp/luma-release.XXXXXX)"
trap 'rm -rf "$LUMA_STAGE"' EXIT
mkdir -p "$LUMA_STAGE/source" "$LUMA_OUTPUT"
git -C "$LUMA_ROOT" archive "$LUMA_COMMIT" | tar -x -C "$LUMA_STAGE/source"
LUMA_BUILD_CONFIGURATION=release "$LUMA_STAGE/source/scripts/build-macos.sh"
LUMA_APP="$LUMA_STAGE/source/build/macos/Luma.app"

# Remove object-file debug map records, then re-sign the changed executable.
# The clean build path also keeps SwiftPM's generated fallback free of user data.
strip -S "$LUMA_APP/Contents/MacOS/Luma"
codesign --force --sign - "$LUMA_APP"
codesign --verify --deep --strict "$LUMA_APP"
python3 - "$LUMA_APP" <<'PY'
import sys
from pathlib import Path
app = Path(sys.argv[1])
for path in app.rglob('*'):
    if path.is_file() and not path.is_symlink():
        data = path.read_bytes()
        if b'/Users/' in data:
            raise SystemExit(f'Personal build path in {path.relative_to(app)}')
PY

"$LUMA_STAGE/source/scripts/archive-macos.sh"
LUMA_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$LUMA_APP/Contents/Info.plist")"
LUMA_ARCH="$(lipo -archs "$LUMA_APP/Contents/MacOS/Luma" | tr ' ' '-')"
LUMA_NAME="Luma-$LUMA_VERSION"
cp "$LUMA_STAGE/source/build/macos/Luma-macOS.zip" "$LUMA_OUTPUT/$LUMA_NAME-macos-$LUMA_ARCH.zip"
cp "$LUMA_APP/Contents/Resources/ThirdParty/manifest.json" "$LUMA_OUTPUT/$LUMA_NAME-dependencies.json"
git -C "$LUMA_ROOT" archive --format=tar --prefix="$LUMA_NAME/" "$LUMA_COMMIT" | gzip -n > "$LUMA_OUTPUT/$LUMA_NAME-source.tar.gz"
printf 'Prepared %s from %s in %s\n' "$LUMA_NAME" "$LUMA_COMMIT" "$LUMA_OUTPUT"
