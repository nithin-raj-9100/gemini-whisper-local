#!/usr/bin/env bash
# Build and ad-hoc sign macos/GeminiWhisper.app (no sandbox).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PACKAGE_DIR/../.." && pwd)"
APP_OUT="${APP_OUT:-$REPO_DIR/macos/GeminiWhisper.app}"
CONFIG="${CONFIG:-release}"

cd "$PACKAGE_DIR"

echo "Building GeminiWhisperApp ($CONFIG)…"
swift build -c "$CONFIG" --product GeminiWhisperApp

BIN_DIR="$(swift build -c "$CONFIG" --product GeminiWhisperApp --show-bin-path)"
BIN="$BIN_DIR/GeminiWhisperApp"
if [[ ! -x "$BIN" ]]; then
  echo "error: expected executable at $BIN" >&2
  exit 1
fi

echo "Bundling $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS"
mkdir -p "$APP_OUT/Contents/Resources"

cp "$PACKAGE_DIR/Resources/Info.plist" "$APP_OUT/Contents/Info.plist"
cp "$BIN" "$APP_OUT/Contents/MacOS/GeminiWhisper"
chmod +x "$APP_OUT/Contents/MacOS/GeminiWhisper"
echo -n "APPL????" > "$APP_OUT/Contents/PkgInfo"

# Ad-hoc sign. Do not enable App Sandbox — event tap + paste need Accessibility.
# Designated requirement is the bundle id, not the per-build CDHash. Otherwise
# TCC Accessibility stays visually ON while AXIsProcessTrusted() is false after
# every rebuild (Settings grant is bound to the old hash).
codesign --force --sign - \
  --identifier com.nithin.gemini-whisper \
  --requirements '=designated => identifier "com.nithin.gemini-whisper"' \
  --timestamp=none \
  "$APP_OUT"

echo "Signed $APP_OUT"
echo "Run with: open -g $APP_OUT"
echo "Or from the package: swift run --product GeminiWhisperApp"
