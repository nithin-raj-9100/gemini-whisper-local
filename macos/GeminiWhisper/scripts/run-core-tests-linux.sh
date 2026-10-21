#!/usr/bin/env bash
# Build and test GeminiWhisperCore with a Linux Swift toolchain (for example in a
# cloud container). The app target needs AppKit and only builds on macOS; this
# wraps Core and its tests in a throwaway package. AppKit-only tests (clipboard)
# are skipped here and still run on macOS CI.
#
#   ./scripts/run-core-tests-linux.sh                 # all Core tests
#   ./scripts/run-core-tests-linux.sh --sanitize=thread --filter GeminiLiveTests
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${GEMINI_WHISPER_LINUX_BUILD_DIR:-$PACKAGE_DIR/.build/linux-core}"

mkdir -p "$WORK_DIR/Sources" "$WORK_DIR/Tests"
ln -sfn "$PACKAGE_DIR/Sources/GeminiWhisperCore" "$WORK_DIR/Sources/GeminiWhisperCore"
ln -sfn "$PACKAGE_DIR/Tests/GeminiWhisperCoreTests" "$WORK_DIR/Tests/GeminiWhisperCoreTests"
cat > "$WORK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeminiWhisperCoreLinux",
    targets: [
        .target(
            name: "GeminiWhisperCore",
            path: "Sources/GeminiWhisperCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GeminiWhisperCoreTests",
            dependencies: ["GeminiWhisperCore"],
            path: "Tests/GeminiWhisperCoreTests",
            exclude: ["Vendor", "RunnerMain.swift", "ClipboardTests.swift"]
        ),
    ]
)
SWIFT

cd "$WORK_DIR"
exec swift test "$@"
