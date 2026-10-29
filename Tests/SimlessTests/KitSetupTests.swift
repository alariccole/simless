// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

final class KitSetupTests: XCTestCase {
    var root: String!
    var config: Config!
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-kit-" + UUID().uuidString
        try mkdirp(root)
        config = Config(project: "App.xcodeproj", scheme: "App", appTarget: "App", testTarget: "",
                        kitDir: "App/Simless", sourceDirs: ["App"], kitPackage: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    func testPackageModeKeepsUserFixturesAndNeverCopiesKit() throws {
        XCTAssertTrue(try KitSetup.install(root: root, config: config))
        XCTAssertFalse(exists(root + "/" + config.kitFile))
        let path = root + "/" + config.fixturesFile
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("import SimlessKit"))
        try "// user fixtures".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(try KitSetup.install(root: root, config: config))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "// user fixtures")
    }

    func testMigrationRefusesDuplicateHostInsteadOfDeletingSource() throws {
        config.kitPackage = nil
        _ = try KitSetup.install(root: root, config: config)
        let before = try Data(contentsOf: URL(fileURLWithPath: root + "/" + config.kitFile))
        config.kitPackage = true
        XCTAssertThrowsError(try KitSetup.install(root: root, config: config))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/" + config.kitFile)), before)
    }

    func testPackageHookImportsKitAndPassesFixturesOnlyOnce() throws {
        let path = root + "/App.swift"
        try "import SwiftUI\n@main struct Demo: App {\n var body: some Scene { WindowGroup { Text(\"Demo\") } }\n}".write(toFile: path, atomically: true, encoding: .utf8)
        _ = try insertHook(in: root, packageKit: true)
        let first = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(first.contains("import SimlessKit"))
        XCTAssertTrue(first.contains("SimlessHost.startIfRequested(configure: simlessFixtures)"))
        _ = try insertHook(in: root, packageKit: true)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), first)
    }
}
