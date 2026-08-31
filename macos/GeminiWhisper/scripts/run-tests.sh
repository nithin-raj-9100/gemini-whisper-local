#!/usr/bin/env bash
# Compile TestingInteropStub.c into lib_TestingInterop.dylib (Command Line Tools
# Testing.framework loads it by @rpath), then run GeminiWhisperCoreTests.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STUB_SRC="$PACKAGE_DIR/Tests/GeminiWhisperCoreTests/Vendor/TestingInteropStub.c"
STUB_INCLUDE="$PACKAGE_DIR/Tests/GeminiWhisperCoreTests/Vendor/include"
STUB_DIR="$PACKAGE_DIR/.build/testing-interop"
STUB_DYLIB="$STUB_DIR/lib_TestingInterop.dylib"

mkdir -p "$STUB_DIR"
clang -dynamiclib \
  -o "$STUB_DYLIB" \
  -install_name "@rpath/lib_TestingInterop.dylib" \
  -I "$STUB_INCLUDE" \
  "$STUB_SRC"

cd "$PACKAGE_DIR"
swift build --product GeminiWhisperCoreTests "$@"
BIN_DIR="$(swift build --product GeminiWhisperCoreTests --show-bin-path)"
cp "$STUB_DYLIB" "$BIN_DIR/lib_TestingInterop.dylib"

exec "$BIN_DIR/GeminiWhisperCoreTests" --testing-library swift-testing
