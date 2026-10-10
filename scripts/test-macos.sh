#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_COMPILER="$(xcrun --find swiftc)"
TOOLCHAIN_USR="$(dirname "$(dirname "$SWIFT_COMPILER")")"
TESTING_PLUGINS="$TOOLCHAIN_USR/lib/swift/host/plugins/testing"
PROJECT_ID="$(printf '%s' "$PROJECT_ROOT" | shasum -a 256 | cut -c 1-12)"
TEST_SCRATCH="${LUMA_TEST_SCRATCH:-${TMPDIR:-/tmp}/luma-tests-$PROJECT_ID}"
TEST_FLAGS=(--disable-xctest)

# CLT-only Swift installations may omit this plugin search path. Full Xcode
# also accepts it. Discover the active toolchain rather than hardcoding paths.
if [[ -f "$TESTING_PLUGINS/libTestingMacros.dylib" ]]; then
    TEST_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

# Recent CLT releases ship Swift Testing as a framework, outside the native
# SwiftPM engine's default search paths. Full Xcode uses its platform's
# Developer directory; older toolchains keep their built-in module paths.
TEST_FRAMEWORK_CANDIDATES=("$TOOLCHAIN_USR/../Library/Developer/Frameworks")
TEST_PLATFORM="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
if [[ -n "$TEST_PLATFORM" ]]; then
    TEST_FRAMEWORK_CANDIDATES+=("$TEST_PLATFORM/Developer/Library/Frameworks")
fi
for TEST_FRAMEWORKS in "${TEST_FRAMEWORK_CANDIDATES[@]}"; do
    if [[ -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
        TEST_FRAMEWORKS="$(cd "$TEST_FRAMEWORKS" && pwd)"
        TEST_FLAGS+=(-Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS")
        for TEST_RUNTIME in "$(dirname "$TEST_FRAMEWORKS")/usr/lib" "$(dirname "$(dirname "$TEST_FRAMEWORKS")")/usr/lib"; do
            if [[ -f "$TEST_RUNTIME/lib_TestingInterop.dylib" ]]; then
                TEST_FLAGS+=(-Xswiftc -L -Xswiftc "$TEST_RUNTIME" -Xlinker -rpath -Xlinker "$TEST_RUNTIME")
                break
            fi
        done
        break
    fi
done

# Test bundles are ad-hoc signed. Build outside iCloud/FileProvider folders so
# Finder metadata cannot cause codesign's "resource fork" failure.
exec xcrun --sdk macosx swift test --build-system native --sdk "$(xcrun --sdk macosx --show-sdk-path)" --package-path "$PROJECT_ROOT/macos" \
    --scratch-path "$TEST_SCRATCH" "${TEST_FLAGS[@]}" "$@"
