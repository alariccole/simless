// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
import AppKit
import CryptoKit
@testable import simless

/// Opt-in acceptance test for Ink#296. This runs the existing Proof app and its
/// existing TextInput preview through production simless APIs, under managed XCTest.
/// It accepts source paths/revisions, never an arbitrary command to execute.
final class InkIntegrationTests: XCTestCase {
    /// A read-only check against the actual project's complete JSON5 structure,
    /// useful before its host hookup has reached the committed acceptance tree.
    func testActualInkProjectMetadata() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIMLESS_RUN_INK_METADATA"] == "1" else { throw XCTSkip("opt-in real-project metadata check") }
        let repository = try XCTUnwrap(env["SIMLESS_INK_REPOSITORY"])
        let project = try XCTUnwrap(XCProject.loadIfPresent(repository + "/Proof.xcodeproj"))
        XCTAssertEqual(project.targets, ["Proof", "ProofUITests", "ProofDepthTests"])
        XCTAssertEqual(project.uiTargets, ["ProofUITests"])
        XCTAssertEqual(project.folders["Proof"], [repository + "/Proof"])
        XCTAssertTrue(project.packages.contains(repository + "/Packages/Presentable"))
        XCTAssertFalse(project.uiSources["ProofUITests", default: []].isEmpty)
        XCTAssertEqual(project.platforms["Proof"], "iOS")
    }

    func testProofPreviewAndFixtureReload() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIMLESS_RUN_INK"] == "1" else { throw XCTSkip("Set SIMLESS_RUN_INK=1 for the explicit Ink acceptance run") }
        let oldVerbose = Log.verbose
        Log.verbose = true
        defer { Log.verbose = oldVerbose }
        let job = try XCTUnwrap(env["INKLINGS_BUILD_SCRATCH_ROOT"])
        _ = try XCTUnwrap(env["INKLINGS_JOB_ID"])
        let source = try XCTUnwrap(env["SIMLESS_INK_SNAPSHOT"])
        let repository = try XCTUnwrap(env["SIMLESS_INK_REPOSITORY"])
        let revision = try XCTUnwrap(env["SIMLESS_INK_REVISION"])
        guard revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw SimlessError("expected a full committed revision")
        }
        let root = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        let jobRoot = URL(fileURLWithPath: job).resolvingSymlinksInPath().path
        let state = try XCTUnwrap(Paths.stateRoot)
        guard state.hasPrefix(jobRoot + "/") else { throw SimlessError("integration state must belong to the managed job") }
        guard env["SIMLESS_MODE"] == "native" else { throw SimlessError("integration requires SIMLESS_MODE=native") }
        let results = try XCTUnwrap(env["INKLINGS_JOB_RESULTS"])
        guard URL(fileURLWithPath: results).resolvingSymlinksInPath().path.hasPrefix(jobRoot + "/") else {
            throw SimlessError("results must belong to the managed job")
        }
        var inputs = try committedInputs(repository: repository, revision: revision)
        var overlay: [String: String] = [:]
        if let manifest = env["SIMLESS_REVIEWED_OVERLAY"] {
            guard env["SIMLESS_ALLOW_REVIEWED_OVERLAY"] == "1" else { throw SimlessError("reviewed overlay needs explicit opt-in") }
            let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard receipt["baseCommit"] as? String == revision else { throw SimlessError("overlay base commit differs") }
            overlay = try XCTUnwrap(receipt["blobs"] as? [String: String])
            guard Set(overlay.keys) == [".simless.json", "Proof/ProofApp.swift", "Proof/Simless/SimlessFixtures.swift", "Proof.xcodeproj/project.xcproj"],
                  overlay.values.allSatisfy({ $0.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil }) else {
                throw SimlessError("overlay must contain exactly the four reviewed hookup files")
            }
            inputs.removeAll { overlay[$0.0] != nil }
            inputs += overlay.map { ($0.key, $0.value, "100644") }
        }
        guard inputs.contains(where: { $0.0 == ".simless.json" }) else { throw SimlessError("no verified simless configuration") }
        // Xcode regenerates this derived lock after adding the pinned host.
        // Validate every dependency revision instead of demanding the old lock blob.
        let resolverPath = "Proof.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        inputs.removeAll { $0.0 == resolverPath }
        _ = try verifyResolver(root: root, repository: repository, revision: revision, requireKit: false)
        try verify(inputs, at: root)
        let previousDirectory = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(root) else { throw SimlessError("cannot enter Proof snapshot") }
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory) }
        let ws = try Workspace.load()
        guard ws.config.appTarget == "Proof", ws.config.project == "Proof.xcodeproj",
              ws.config.kitPackage == true, ws.xcproject != nil, ws.config.buildJobs == 4 else {
            throw SimlessError("expected the committed JSON Proof app with package kit and four build jobs")
        }
        for path in ws.config.sourceDirs + ws.packages + [ws.config.project, ws.config.fixturesFile] {
            guard !path.hasPrefix("/"), URL(fileURLWithPath: root + "/" + path).resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
                throw SimlessError("configured source path escapes verified snapshot: \(path)")
            }
        }

        for path in (ws.xcproject?.folders.values.flatMap { $0 } ?? []) + (ws.xcproject?.uiSources.values.flatMap { $0 } ?? []) {
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
                throw SimlessError("project source path escapes verified snapshot: \(path)")
            }
        }

        // Nested xcodebuild inherits the managed job but not its direct-tool
        // xcconfig setup. Preserve existing settings and confine its CAS here.
        let oldConfig = env["XCODE_XCCONFIG_FILE"]
        let configPath = jobRoot + "/proof-cache.xcconfig"
        let include = oldConfig.map { "#include? \"\($0)\"\n" } ?? ""
        try (include + "COMPILATION_CACHE_ENABLE_CACHING = YES\nCOMPILATION_CACHE_CAS_PATH = \(Paths.cache)/CompilationCache\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        setenv("XCODE_XCCONFIG_FILE", configPath, 1)
        defer {
            if let oldConfig { setenv("XCODE_XCCONFIG_FILE", oldConfig, 1) } else { unsetenv("XCODE_XCCONFIG_FILE") }
        }
        var ownedSlot: SlotRecord?
        defer {
            if let slot = ownedSlot ?? (try? currentSlot(ws)), slot.namespace == shortHash(state) {
                Slots.stop(slot)
                XCTAssertTrue(Native.pids(slot).isEmpty, "the integration host must stop")
            }
        }
        let setupStart = now()
        try cmdUp(Args(["--no-tests"]))
        let setupSeconds = now() - setupStart
        let slot = try currentSlot(ws)
        ownedSlot = slot
        XCTAssertEqual(slot.namespace, shortHash(state))
        XCTAssertEqual(slot.sources, ws.currentSourcesID())
        Slots.stop(slot)
        try Slots.launch(slot, idleMinutes: ws.idleMinutes, locale: "en")
        let fixture = "Ink.TextInput"
        var evidence: [[String: Any]] = []
        for device in ["iphone-small", "iphone", "ipad"] {
            for dark in [false, true] {
                let name = device + (dark ? "-dark" : "-light")
                evidence.append(try render(slot, fixture: fixture, device: device, dark: dark,
                                           output: results + "/" + name))
            }
        }
        if env["SIMLESS_COMPARE_WARM"] == "1" {
            for index in 1...3 {
                evidence.append(try render(slot, fixture: fixture, device: "iphone", dark: false,
                                           output: results + "/warm-iphone-\(index)", idiom: "phone"))
            }
        }
        // Recompile/re-register the unchanged fixture: this proves the package's
        // registry is shared with generated patches, without editing app source.
        let beforePatch = try XCTUnwrap(slot.stats()?["patch"] as? Int)
        let reloadStart = now()
        let dylib = try Patch.compile(ws: ws, slot: slot, settings: ws.settings(), files: [root + "/" + ws.config.fixturesFile])
        XCTAssertNil(try Patch.live(dylib: dylib, slot: slot))
        let reloadSeconds = now() - reloadStart
        XCTAssertGreaterThan(try XCTUnwrap(slot.stats()?["patch"] as? Int), beforePatch)
        evidence.append(try render(slot, fixture: fixture, device: "iphone", dark: false, output: results + "/reloaded-iphone"))
        XCTAssertEqual(slot.sources, ws.currentSourcesID())
        try verify(inputs, at: root)
        let resolvedPins = try verifyResolver(root: root, repository: repository, revision: revision, requireKit: true)
        let receipt: [String: Any] = ["baseInkCommit": revision, "overlayBlobs": overlay, "fixture": fixture, "renders": evidence,
                                       "sourceID": ws.currentSourcesID(), "slotID": slot.slotID,
                                       "setupSeconds": setupSeconds, "unchangedFixtureReloadSeconds": reloadSeconds,
                                       "resolvedPins": resolvedPins, "venue": "mac-native-host", "modelBehaviorTested": false]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: results + "/ink-proof.json"))
    }

    private func render(_ slot: SlotRecord, fixture: String, device: String, dark: Bool, output: String, idiom: String? = nil) throws -> [String: Any] {
        let canvas = try Render.canvas(device)
        let start = now()
        let result = try Render.run(slot: slot, fixture: fixture,
                                    options: Render.Options(dark: dark, device: device, pngPath: output + ".png", json: true, idiom: idiom))
        try result.text.write(toFile: output + ".json", atomically: true, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        XCTAssertEqual(json["fixture"] as? String, fixture)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        XCTAssertTrue(nodes.contains { $0["id"] as? String == "textInput.draft" }, "expected the real TextInput preview field")
        XCTAssertTrue(nodes.contains {
            (($0["value"] as? String ?? "") + ($0["label"] as? String ?? "")).contains("Write a note.")
        }, "expected TextInput.Preview's existing sample text")
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: output + ".png"))))
        XCTAssertEqual(image.pixelsWide, Int(canvas.width * 2))
        XCTAssertEqual(image.pixelsHigh, Int(canvas.height * 2))
        return ["device": device, "dark": dark, "png": (output as NSString).lastPathComponent + ".png",
                "nodes": nodes.count, "reportedIssues": result.issues, "wallSeconds": now() - start,
                "requestedIdiom": idiom ?? "default", "measurement": "request to validated image and accessibility report"]
    }

    private func verifyResolver(root: String, repository: String, revision: String, requireKit: Bool) throws -> [[String: Any]] {
        let path = "Proof.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        let original = try Shell.check(["git", "-C", repository, "show", revision + ":" + path])
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/" + path))) as? [String: Any])
        let basePins = try XCTUnwrap(base["pins"] as? [[String: Any]])
        let pins = try XCTUnwrap(current["pins"] as? [[String: Any]])
        let baseIDs = Set(basePins.compactMap { $0["identity"] as? String })
        for pin in basePins {
            guard let match = pins.first(where: { $0["identity"] as? String == pin["identity"] as? String }),
                  NSDictionary(dictionary: match).isEqual(to: pin) else { throw SimlessError("resolver changed an existing dependency") }
        }
        let added = pins.filter { !baseIDs.contains($0["identity"] as? String ?? "") }
        guard added.count <= 1, pins.count == basePins.count + added.count else { throw SimlessError("unexpected resolver additions") }
        if let kit = added.first {
            guard kit["identity"] as? String == "simless", kit["location"] as? String == "https://github.com/alariccole/simless.git",
                  (kit["state"] as? [String: String])?["revision"] == "4bd33b4d99a54790c3217b986dc8cc9262d25e99" else {
                throw SimlessError("resolver did not use the reviewed fork revision")
            }
        } else if requireKit { throw SimlessError("resolver has no SimlessKit dependency") }
        return pins
    }

    private func committedInputs(repository: String, revision: String) throws -> [(String, String, String)] {
        let tree = try Shell.check(["git", "-C", repository, "ls-tree", "-rz", revision, "--",
                                    ".simless.json", "Proof", "ProofUITests", "Proof.xcodeproj", "Packages", "Config"])
        let entries = try tree.split(separator: "\0").map { entry -> (String, String, String) in
            let pair = entry.split(separator: "\t", maxSplits: 1)
            guard pair.count == 2 else { throw SimlessError("invalid source tree entry") }
            let fields = pair[0].split(separator: " ")
            guard fields.count == 3, fields[1] == "blob" else { throw SimlessError("unverified submodule in Proof input") }
            return (String(pair[1]), String(fields[2]), String(fields[0]))
        }
        guard entries.contains(where: { $0.0 == "Proof.xcodeproj/project.xcproj" }) else {
            throw SimlessError("commit does not contain the JSON Proof project")
        }
        return entries
    }

    private func verify(_ entries: [(String, String, String)], at root: String) throws {
        let expectedPaths = Set(entries.map { $0.0 })
        for directory in ["Proof", "ProofUITests", "Proof.xcodeproj", "Packages", "Config"] {
            guard let enumerator = FileManager.default.enumerator(atPath: root + "/" + directory) else { continue }
            while let relative = enumerator.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                if [".git", ".swiftpm", ".build", "xcuserdata"].contains(name) { enumerator.skipDescendants(); continue }
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
                let path = directory + "/" + relative
                // Xcode may create its resolver lock; every compiled input must
                // still be an exact blob from the recorded commit.
                if name == ".DS_Store" || name == "Package.resolved" { continue }
                guard expectedPaths.contains(path) else { throw SimlessError("uncommitted file in snapshot: \(path)") }
            }
        }
        for (relative, expected, mode) in entries {
            let path = root + "/" + relative
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
                throw SimlessError("source escapes snapshot: \(relative)")
            }
            let contents = mode == "120000"
                ? Data(try FileManager.default.destinationOfSymbolicLink(atPath: path).utf8)
                : try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            var sha = Insecure.SHA1()
            sha.update(data: Data("blob \(contents.count)\0".utf8))
            sha.update(data: contents)
            let actual = sha.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw SimlessError("snapshot differs from committed input: \(relative)") }
        }
    }
}
