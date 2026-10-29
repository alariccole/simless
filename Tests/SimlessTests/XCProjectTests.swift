// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

final class XCProjectTests: XCTestCase {
    var root: String!
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-xcproj-" + UUID().uuidString
        try mkdirp(root + "/App.xcodeproj/xcshareddata/xcschemes")
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    func write(_ path: String, _ text: String) throws {
        try mkdirp((root + "/" + path as NSString).deletingLastPathComponent)
        try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
    }
    func config(mode: String = "native") throws {
        let value = Config(project: "App.xcodeproj", scheme: "App", appTarget: "App", testTarget: "AppTests",
                           kitDir: "App/Simless", sourceDirs: ["App"], mode: mode)
        try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: root + "/.simless.json"))
    }
    let project = #"""
    {
      // Xcode writes JSON5 comments and trailing commas.
      "targets": [
        {"name": "App", "product-type": "application"},
        {"name": "AppTests", "product-type": "bundle.unit-test"},
        {"name": "Journey", "product-type": "bundle.ui-testing"},
        {"name": "WatchTests", "product-type": "bundle.unit-test", "build-settings": {"SDKROOT": ["watchos"]}},
      ],
      "packages": [{"kind": "local", "path": "Packages/Widgets"}, {"kind": "remote", "repository": "https://example.invalid/widgets"}],
      "files": [
        {"kind": "folder", "path": "App", "target-membership": ["App"]},
        {"kind": "group", "name": "Display name", "path": "Tests", "children": [
          {"kind": "folder", "path": "UI", "target-membership": ["Journey"], "membership-exceptions": [{"target": "Journey", "exclusions": ["Excluded.swift"]}]},
          {"kind": "group", "name": "Virtual", "children": [
            {"path": "<PROJECT>/Shared/Extra.swift", "target-membership": ["Journey/compile-sources"]},
          ]},
        ]},
        {"kind": "group", "name": "Products", "children": [{"path": "<PRODUCTS>/App.app"}]},
      ],
    }
    """#

    func prepare() throws {
        try write("App.xcodeproj/project.xcproj", project)
        try write("Tests/UI/Included.swift", "import XCTest\nfinal class Journey: XCTestCase {\n func testWorks() {}\n}")
        try write("Tests/UI/Excluded.swift", "import XCTest\nfinal class Excluded: XCTestCase {\n func testMustNotRun() {}\n}")
        try write("Shared/Extra.swift", "")
        try write("Packages/Widgets/Package.swift", "")
        try config()
    }

    func testJSON5DiscoveryKeepsMembershipAndPackagePaths() throws {
        try prepare()
        let ws = try Workspace.load(at: root)
        XCTAssertEqual(ws.packages, ["Packages/Widgets"])
        XCTAssertEqual(ws.xcproject?.folders["Journey"], [root + "/Tests/UI"])
        let targets = UITestEngine.targets(ws, includingUnbuilt: true)
        XCTAssertEqual(targets.map(\.name), ["Journey"])
        XCTAssertEqual(targets.first?.sources, [root + "/Shared/Extra.swift", root + "/Tests/UI/Included.swift"])
        XCTAssertEqual(UITestEngine.tests(in: targets[0]).map(\.method), ["testWorks"])
        XCTAssertEqual(SimulatorLane.platform("WatchTests", ws: ws), "watchOS")
        XCTAssertEqual(try ws.buildProject(), root + "/App.xcodeproj")
    }

    func testExpectedUnitTargetsExcludeUIAndOtherPlatforms() throws {
        try prepare()
        try write("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", """
        <Scheme><TestAction><TestableReference BlueprintName = "AppTests" />
        <TestableReference BlueprintName = "Journey" /><TestableReference BlueprintName = "WatchTests" />
        <TestableReference BlueprintName = "DeletedTests" /></TestAction></Scheme>
        """)
        let ws = try Workspace.load(at: root)
        XCTAssertEqual(TestEngine.expectedTargets(ws, packageTargets: ["WidgetsTests"]), ["AppTests", "WidgetsTests"])
    }

    func testMalformedJSONDoesNotBecomeEmptyDiscovery() throws {
        try config()
        try write("App.xcodeproj/project.xcproj", "{broken")
        XCTAssertThrowsError(try Workspace.load(at: root))
    }

    func testUnsupportedUITestExceptionsFailClosed() throws {
        try prepare()
        try write("App.xcodeproj/project.xcproj", project.replacingOccurrences(of: #""exclusions": ["Excluded.swift"]"#, with: #""platforms": {"Included.swift": ["ios"]}"#))
        XCTAssertThrowsError(try Workspace.load(at: root))
    }

    func testDFIModeGivesExplicitError() throws {
        let previous = ProcessInfo.processInfo.environment["SIMLESS_MODE"]
        setenv("SIMLESS_MODE", "dfi", 1)
        defer {
            if let previous { setenv("SIMLESS_MODE", previous, 1) } else { unsetenv("SIMLESS_MODE") }
        }
        try prepare()
        try config(mode: "dfi")
        XCTAssertThrowsError(try Workspace.load(at: root).buildProject()) { error in
            XCTAssertTrue(String(describing: error).contains("requires native mode"))
        }
    }

    func testBuildPhaseExceptionCannotHideAnAdditionalUITarget() throws {
        try prepare()
        let changed = project.replacingOccurrences(of: #""target-membership": ["Journey"], "membership-exceptions": [{"target": "Journey", "exclusions": ["Excluded.swift"]}]"#,
                                                  with: #""target-membership": ["App"], "membership-exceptions": [{"build-phase": "Journey/compile-sources", "inclusions": ["Included.swift"]}]"#)
        XCTAssertNotEqual(changed, project)
        try write("App.xcodeproj/project.xcproj", changed)
        XCTAssertThrowsError(try Workspace.load(at: root))
    }

    func testEmptyExpectedUITargetCannotHideBehindAnotherTarget() throws {
        try prepare()
        let populated = UITestEngine.UITarget(name: "Journey", sources: [root + "/Tests/UI/Included.swift"])
        let empty = UITestEngine.UITarget(name: "OtherJourney", sources: [])
        XCTAssertThrowsError(try UITestEngine.validateDiscovery([populated, empty], inScheme: [], filters: []))
        XCTAssertNoThrow(try UITestEngine.validateDiscovery([populated, empty], inScheme: [], filters: ["Journey"]))
    }

    func testMalformedMembershipFailsInsteadOfOmittingSources() throws {
        try prepare()
        try write("App.xcodeproj/project.xcproj", project.replacingOccurrences(of: #"["Journey/compile-sources"]"#, with: #"{"invalid": true}"#))
        XCTAssertThrowsError(try Workspace.load(at: root))
    }

    func testMissingExplicitUITestSourceFails() throws {
        try prepare()
        try write("App.xcodeproj/project.xcproj", project.replacingOccurrences(of: "Shared/Extra.swift", with: "Shared/Missing.swift"))
        XCTAssertThrowsError(try Workspace.load(at: root))
    }

    func testLegacyProjectStillLoadsWithoutJSON() throws {
        try config()
        try write("App.xcodeproj/project.pbxproj", "{}")
        let ws = try Workspace.load(at: root)
        XCTAssertNil(ws.xcproject)
        XCTAssertEqual(try ws.buildProject(), root + "/App.xcodeproj")
    }

    func testTargetXcconfigCannotSilentlyExcludeAnIOSTest() throws {
        let json: [String: Any] = [
            "build-settings": ["SDKROOT": "watchos"],
            "targets": [["name": "Tests", "product-type": "bundle.unit-test",
                         "specialized-configurations": [["name": "Debug", "file": "Debug.xcconfig"]]]]
        ]
        XCTAssertThrowsError(try XCProject(json: json, directory: root))
    }

    func testLiteralTargetSDKDoesNotDependOnProjectXcconfig() throws {
        let json: [String: Any] = [
            "configurations": [["name": "Debug", "file": "Debug.xcconfig"]],
            "targets": [["name": "Tests", "product-type": "bundle.unit-test", "build-settings": ["SDKROOT": "iphoneos"]]]
        ]
        XCTAssertEqual(try XCProject(json: json, directory: root).platforms["Tests"], "iOS")
    }

    func testConditionalSDKCannotSilentlyExcludeAnIOSTest() throws {
        let json: [String: Any] = [
            "build-settings": ["SDKROOT": "watchos"],
            "targets": [["name": "Tests", "product-type": "bundle.unit-test",
                         "build-settings": ["SDKROOT[config=Debug][arch=arm64]": "iphoneos"]]]
        ]
        XCTAssertThrowsError(try XCProject(json: json, directory: root))
    }

    func testReleaseSDKDoesNotChangeDebugClassification() throws {
        let json: [String: Any] = ["targets": [["name": "Tests", "product-type": "bundle.unit-test",
            "build-settings": ["SDKROOT": "iphoneos", "SDKROOT[config=Release]": "watchos"]]]]
        XCTAssertEqual(try XCProject(json: json, directory: root).platforms["Tests"], "iOS")
    }

    func testConfiguredUISourcesArePreservedAlongsideJSONMembership() throws {
        try prepare()
        try write("ExtraUI/Extra.swift", "import XCTest\nfinal class Extra: XCTestCase {\n func testExtra() {}\n}")
        let path = root + "/.simless.json"
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        config.tests = Config.Tests(uiSources: ["Journey": "ExtraUI"])
        try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: path))
        let targets = UITestEngine.targets(try Workspace.load(at: root), includingUnbuilt: true)
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(Set(UITestEngine.tests(in: target).map(\.method)), ["testWorks", "testExtra"])
    }

    func testPackagesOutsideRepositoryRemainRelative() {
        XCTAssertEqual(Workspace.relativePackages(["/repo/shared/Widgets"], root: "/repo/app"), ["../shared/Widgets"])
    }
}
