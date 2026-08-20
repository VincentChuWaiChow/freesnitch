// swift-tools-version:5.10
// The repo pins SWIFT_VERSION: "5.10" in project.yml to match macOS Sequoia's default.
// The build container ships Swift 6.0.3; both versions are compatible with this manifest.
// See .specs/design/02-build-system.md § D1 for rationale.

import PackageDescription

let package = Package(
    name: "FreeSnitch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FreeSnitchCore", targets: ["FreeSnitchCore"])
    ],
    dependencies: [
        // No third-party dependencies. See CONTRIBUTING.md for the no-deps policy.
    ],
    targets: [
        // System library for zlib, providing the CZlib module.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [
                .apt(["zlib1g-dev"]),
                .brew(["zlib"])
            ]
        ),
        // System library for SQLite3, providing the SQLite3 module.
        // Note: module name is SQLite3 (not CSQLite3) to match import statements.
        .systemLibrary(
            name: "CSQLite3",
            path: "Sources/CSQLite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite"])
            ]
        ),
        // Portable core: rule matching, profile management, wire protocols.
        // These 29 files compile clean on Linux without Apple frameworks (R2.4).
        // Source layout in place per D1; no relocations permitted (R1.5).
        .target(
            name: "FreeSnitchCore",
            dependencies: ["CZlib", "CSQLite3"],
            path: "Sources/Shared",
            swiftSettings: [
                .define("PORTABLE_CORE")
            ]
        )
    ]
)
