// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

enum KitSetup {
    /// Package users keep only their fixtures in the app, sharing the package's
    /// registry and host rather than compiling a second implementation.
    static func install(root: String, config: Config) throws -> Bool {
        let kit = "\(root)/\(config.kitFile)"
        let fixtures = "\(root)/\(config.fixturesFile)"
        if config.kitPackage == true, exists(kit) {
            throw SimlessError("package kit mode found a copied \(config.kitFile); remove the old copy from the app target before migrating")
        }
        try mkdirp("\(root)/\(config.kitDir)")
        if config.kitPackage != true {
            try? FileManager.default.removeItem(atPath: kit)
            try FileManager.default.copyItem(atPath: "\(Paths.toolRoot)/Templates/SimlessKit.swift", toPath: kit)
        }
        guard !exists(fixtures) else { return false }
        var text = try String(contentsOfFile: "\(Paths.toolRoot)/Templates/SimlessFixtures.swift", encoding: .utf8)
        if config.kitPackage == true { text = text.replacingOccurrences(of: "import SwiftUI", with: "import SwiftUI\nimport SimlessKit") }
        try text.write(toFile: fixtures, atomically: true, encoding: .utf8)
        return true
    }

    static func hookCall(package: Bool) -> String {
        package ? "SimlessHost.startIfRequested(configure: simlessFixtures)" : "SimlessHost.startIfRequested()"
    }
}
