// swift-tools-version:6.0
import PackageDescription

// Strict-concurrency / Swift 6 language mode applied uniformly to every target.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Alembic",
    platforms: [
        // Deployment target: macOS 26. The app commits fully to macOS 26+ APIs
        // (SpeechAnalyzer / SpeechTranscriber, ScreenCaptureKit per-app audio),
        // so we set the platform here and avoid scattering @available annotations.
        .macOS("26.0")
    ],
    targets: [
        // ---------------------------------------------------------------------
        // AlembicKit — the platform-agnostic core plus all deterministically
        // testable logic (models, protocols, and — in later phases — the
        // transcript writer, orchestrator/state machine, and platform adapters).
        // Lives in a library so it can be imported by BOTH the app executable
        // and the AlembicCheck test runner.
        // ---------------------------------------------------------------------
        .target(
            name: "AlembicKit",
            path: "Sources/AlembicKit",
            swiftSettings: strict
        ),

        // ---------------------------------------------------------------------
        // Alembic — the thin SwiftUI menu-bar app shell (@main). Depends on
        // AlembicKit for all logic; keep this target free of testable business
        // logic so AlembicCheck can cover everything that matters.
        // ---------------------------------------------------------------------
        .executableTarget(
            name: "Alembic",
            dependencies: ["AlembicKit"],
            path: "Sources/Alembic",
            swiftSettings: strict
        ),

        // ---------------------------------------------------------------------
        // AlembicCheck — the AUTHORITATIVE test runner under Command Line Tools.
        //
        // `swift test` (swift-testing/XCTest) BUILDS but does NOT EXECUTE tests
        // when only Xcode Command Line Tools are installed (no Xcode.app / no
        // xctest host) — a deliberately failing test still exits 0. So the real
        // acceptance command for this repo is:
        //
        //     swift run AlembicCheck
        //
        // AlembicCheck is a plain executable (no test host needed) that runs a
        // hand-rolled assertion harness over AlembicKit and exits NONZERO on any
        // failure. It uses `async @main` so it can exercise actors/@MainActor.
        // ---------------------------------------------------------------------
        .executableTarget(
            name: "AlembicCheck",
            dependencies: ["AlembicKit"],
            path: "Sources/AlembicCheck",
            swiftSettings: strict
        ),

        // ---------------------------------------------------------------------
        // AlembicTests — swift-testing suite kept for a future full Xcode / CI
        // host. NOT authoritative under CLT-only (does not execute there). The
        // unsafeFlags locate the swift-testing framework under CLT so the target
        // at least builds; on full Xcode they are redundant/harmless.
        // ---------------------------------------------------------------------
        .testTarget(
            name: "AlembicTests",
            dependencies: ["Alembic", "AlembicKit"],
            path: "Tests/AlembicTests",
            swiftSettings: strict + [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
