// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchiveForge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ArchiveForgeKit", targets: ["ArchiveForgeKit"]),
    ],
    dependencies: [
        // Pure-Swift archive formats — no C deps, works inside an iOS sandbox
        // (unlike shelling out to unar/7z, which iOS won't allow at all).
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.6"),
    ],
    targets: [
        // Pure-Swift core: archive engine, batch/sequential decompression, job
        // state. No system deps, so it builds & unit-tests on macOS without
        // Xcode/an iOS toolchain.
        //
        // Deliberately NOT linked against a real emulator core: EmulatorCore's
        // only shipping conformance is StubCore. A working mGBA bridge
        // (Sources/CMGBA, Sources/_UnusedMGBACore/MGBACore.swift) was built
        // and verified compiling/linking, then intentionally pulled back out
        // of the build graph — see that directory's README for why.
        .target(
            name: "ArchiveForgeKit",
            dependencies: [
                .product(name: "SWCompression", package: "SWCompression"),
            ],
            path: "Sources/ArchiveForgeKit"
        ),
        .testTarget(
            name: "ArchiveForgeKitTests",
            dependencies: ["ArchiveForgeKit"],
            path: "Tests/ArchiveForgeKitTests"
        ),
        // Command Line Tools alone (no full Xcode) ships neither XCTest nor
        // Swift Testing — both are Xcode-only here — so `swift test` can't
        // run at all in this environment. This plain executable exercises
        // the same checks as ArchiveForgeKitTests via manual assertions,
        // runnable right now with `swift run SmokeTest`. Once Xcode's
        // installed, ArchiveForgeKitTests is the suite to trust; this one's
        // a stopgap, not a replacement.
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["ArchiveForgeKit"],
            path: "Sources/SmokeTest"
        ),
    ]
)

// NOTE: The SwiftUI app target (Sources/ArchiveForgeApp) is built by the Xcode
// project generated from project.yml — SPM can't host the .app bundle,
// signing, or platform entitlements. See README.md → Building.
