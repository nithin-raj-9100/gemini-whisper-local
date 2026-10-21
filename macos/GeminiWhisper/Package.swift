// swift-tools-version: 6.0

import Foundation
import PackageDescription

/// Testing.framework from the toolchain that compiles the tests. Its macros come
/// from that toolchain; a framework from another install (Command Line Tools
/// next to a newer Xcode) has a different macro ABI and the tests do not build.
let testingFrameworkPath: String? = {
    var developerDirectories: [String] = []
    if let explicit = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !explicit.isEmpty {
        developerDirectories.append(explicit)
    }
    if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
        developerDirectories.append(selected)
    }
    developerDirectories += [
        "/Library/Developer/CommandLineTools",
        "/Applications/Xcode.app/Contents/Developer",
    ]
    let candidates = developerDirectories.flatMap { directory in
        [
            directory + "/Library/Developer/Frameworks",
            directory + "/Platforms/MacOSX.platform/Developer/Library/Frameworks",
            directory + "/Library/Frameworks",
        ]
    }
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
        // Swift 6 language mode: Core owns the concurrent session/transport logic,
        // so the compiler checks its data-race safety.
        .target(
            name: "GeminiWhisperCore",
            path: "Sources/GeminiWhisperCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
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
