#!/bin/bash
set -euo pipefail

LUMA_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LUMA_OUTPUT="$LUMA_ROOT/build/macos"
LUMA_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/luma-archive.XXXXXX")"
trap 'rm -rf "$LUMA_STAGE"' EXIT

# FileProvider can attach FinderInfo after a bundle enters Documents. Copy only
# the signed files to a clean staging directory; the bundle needs no resource forks.
ditto --norsrc --noextattr "$LUMA_OUTPUT/Luma.app" "$LUMA_STAGE/Luma.app"
codesign --verify --deep --strict "$LUMA_STAGE/Luma.app"
ditto -c -k --norsrc --noextattr --keepParent "$LUMA_STAGE/Luma.app" "$LUMA_STAGE/Luma-macOS.zip"
mkdir "$LUMA_STAGE/verify"
ditto -x -k "$LUMA_STAGE/Luma-macOS.zip" "$LUMA_STAGE/verify"
codesign --verify --deep --strict "$LUMA_STAGE/verify/Luma.app"
mv -f "$LUMA_STAGE/Luma-macOS.zip" "$LUMA_OUTPUT/Luma-macOS.zip"
echo "已验证归档：$LUMA_OUTPUT/Luma-macOS.zip"
