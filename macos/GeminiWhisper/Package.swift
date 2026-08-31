// swift-tools-version: 6.0

import Foundation
import PackageDescription

let testingFrameworkPath: String? = {
    let candidates = [
        "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
        "/Applications/Xcode.app/Contents/Developer/Library/Frameworks",
    ]
    return candidates.first {
        FileManager.default.fileExists(atPath: $0 + "/Testing.framework")
    }
}()

let testingSwiftSettings: [SwiftSetting] = testingFrameworkPath.map { [.unsafeFlags(["-F", $0])] } ?? []

let testingLinkerSettings: [LinkerSetting] = {
    var settings: [LinkerSetting] = []
    if let testingFrameworkPath {
        settings.append(.unsafeFlags([
            "-F", testingFrameworkPath,
            "-Xlinker", "-rpath",
            "-Xlinker", testingFrameworkPath,
            "-Xlinker", "-rpath",
            "-Xlinker", "@loader_path",
        ]))
        settings.append(.linkedFramework("Testing"))
    }
    return settings
}()

let package = Package(
    name: "GeminiWhisper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GeminiWhisperCore", targets: ["GeminiWhisperCore"]),
        .executable(name: "GeminiWhisperApp", targets: ["GeminiWhisperApp"]),
        .executable(name: "GeminiWhisperCoreTests", targets: ["GeminiWhisperCoreTests"]),
    ],
    targets: [
        .target(
            name: "GeminiWhisperCore",
            path: "Sources/GeminiWhisperCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GeminiWhisperApp",
            dependencies: ["GeminiWhisperCore"],
            path: "Sources/GeminiWhisperApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Compiles TestingInteropStub.c so Command Line Tools can satisfy
        // Testing.framework's lib_TestingInterop.dylib. Never linked into the app.
        .target(
            name: "TestingInteropStub",
            path: "Tests/GeminiWhisperCoreTests/Vendor",
            sources: ["TestingInteropStub.c"],
            publicHeadersPath: "include"
        ),
        // Command Line Tools packages Swift Testing as a bundle and never calls
        // Testing.__swiftPMEntryPoint. Prefer:
        //   ./scripts/run-tests.sh
        // which builds lib_TestingInterop.dylib from the stub .c, copies it next
        // to the test binary, and runs:
        //   swift run GeminiWhisperCoreTests --testing-library swift-testing
        .executableTarget(
            name: "GeminiWhisperCoreTests",
            dependencies: ["GeminiWhisperCore", "TestingInteropStub"],
            path: "Tests/GeminiWhisperCoreTests",
            exclude: ["Vendor"],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        ),
    ]
)
