#!/bin/bash
set -euo pipefail

LUMA_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LUMA_ROOT="$(CDPATH= cd -- "$LUMA_SCRIPT_DIR/.." && pwd)"
"$LUMA_SCRIPT_DIR/build-macos.sh"
open "$LUMA_ROOT/build/macos/Luma.app" --args "$@"
