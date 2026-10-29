// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.
import PackageDescription

let package = Package(
    name: "Simless",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .executable(name: "simless", targets: ["simless"]),
        .library(name: "SimlessKit", targets: ["SimlessKit"]),
    ],
    targets: [
        .target(
            name: "SimlessKit",
            path: "Templates",
            exclude: ["SimlessFixtures.swift", "SKILL.md", "XCUI"],
            sources: ["SimlessKit.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "simless",
            path: "Sources/simless",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SimlessTests",
            dependencies: ["simless"],
            path: "Tests/SimlessTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
