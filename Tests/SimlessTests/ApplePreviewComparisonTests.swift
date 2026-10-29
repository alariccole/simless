import XCTest
import AppKit
import CryptoKit
import Darwin

/// Ink#296: the owner requested a comparison with Apple's renderer on the same preview.
/// This opt-in test invokes the real tool, checks its image, and records workflow latency.
final class ApplePreviewComparisonTests: XCTestCase {
    func testExistingInkPreviewThroughApple() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIMLESS_COMPARE_APPLE"] == "1" else { throw XCTSkip("explicit Apple comparison only") }
        let scratch = try XCTUnwrap(env["INKLINGS_BUILD_SCRATCH_ROOT"])
        let results = try XCTUnwrap(env["INKLINGS_JOB_RESULTS"])
        let source = try XCTUnwrap(env["SIMLESS_INK_SNAPSHOT"])
        let repository = try XCTUnwrap(env["SIMLESS_INK_REPOSITORY"])
        _ = try XCTUnwrap(env["INKLINGS_JOB_ID"])
        let canonical: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard canonical(source) == "/Users/alcol/Ink/.lanes/simless-xcproj-01a188d7/ink-acceptance-303ebda",
              canonical(source) != canonical(repository), canonical(results).hasPrefix(canonical(scratch) + "/") else {
            XCTFail("Comparison requires its owned disposable source and managed results"); return
        }
        let revision = "303ebdaca3b128d4ae7a4db07c36fc341494235b"
        let relative = "Packages/Presentable/Sources/Presentable/Previews/TextInput+Preview.swift"
        let data = try Data(contentsOf: URL(fileURLWithPath: source + "/" + relative))
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8)); hash.update(data: data)
        let blob = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let git = Process(); let output = Pipe()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository, "rev-parse", revision + ":" + relative]
        git.standardOutput = output
        try git.run(); git.waitUntilExit()
        guard git.terminationStatus == 0,
              String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == blob else {
            XCTFail("Preview source does not match the committed comparison input"); return
        }
        // Scope Xcode's configurable build output to this managed job. Xcode may
        // still maintain its own service caches, which the report must disclose.
        let settings = URL(fileURLWithPath: source + "/Proof.xcodeproj/project.xcworkspace/xcuserdata/" + NSUserName() + ".xcuserdatad/WorkspaceSettings.xcsettings")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: settings)
        var values = previous.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        values["DerivedDataLocationStyle"] = "CustomLocation"
        values["DerivedDataCustomLocation"] = scratch + "/AppleDerivedData"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: settings)
        let bridge = try ApplePreviewBridge()
        defer { bridge.close() }
        let opened = try bridge.call("XcodeOpenWorkspace", ["path": source + "/Proof.xcodeproj"])
        let workspace = try XCTUnwrap(opened["workspaceIdentifier"] as? String)
        defer { _ = try? bridge.call("XcodeCloseWorkspace", ["workspaceIdentifier": workspace]) }
        guard opened["activeScheme"] as? String == "Proof" else { XCTFail("Unexpected active scheme"); return }
        let switched = try bridge.call("XcodeSwitchRunDestination", ["workspaceIdentifier": workspace, "displayTitle": "iPhone 18 Pro"])
        guard switched["activeDestinationDisplayTitle"] as? String == "iPhone 18 Pro" else { XCTFail("Requested preview device unavailable"); return }
        // Opening a workspace returns before its package graph is ready. Build
        // once outside the warm-render timer, then discover the actual preview path.
        let preparationStart = DispatchTime.now().uptimeNanoseconds
        let preparation: [String: Any]
        do { preparation = try bridge.call("BuildProject", ["workspaceIdentifier": workspace], timeout: 300) }
        catch { preparation = ["errors": [["message": String(describing: error)]]] }
        let initialReport: [String: Any] = ["sourceBlob": blob, "inkRevision": revision, "preparationBuild": preparation,
            "preparationSeconds": Double(DispatchTime.now().uptimeNanoseconds - preparationStart) / 1_000_000_000,
            "cancellationCaveat": "Client timeout does not cancel Xcode's build; inspect actual build activity before releasing its slot."]
        try JSONSerialization.data(withJSONObject: initialReport, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: results + "/apple-preview.json"))
        guard (preparation["errors"] as? [[String: Any]] ?? []).isEmpty else { XCTFail("Apple preparation build failed: \(preparation)"); return }
        let discovery = try bridge.call("XcodeGlob", ["workspaceIdentifier": workspace, "pattern": "**/TextInput+Preview.swift"])
        let matches = try XCTUnwrap(discovery["matches"] as? [String])
        guard matches.count == 1 else { XCTFail("Preview not uniquely discovered: \(discovery)"); return }
        let preparationSeconds = Double(DispatchTime.now().uptimeNanoseconds - preparationStart) / 1_000_000_000
        var records: [[String: Any]] = []
        var arguments: [String: Any] = ["workspaceIdentifier": workspace,
            "sourceFilePath": matches[0], "timeout": 180,
            // Exact supported overrides returned by the initial real RenderPreview call.
            "displayMode": "static", "preferredRenderDestination": ["identifier": "4099B785-D4F4-4584-8CCD-DA13FED692DF"],
            "previewVariantOverrides": ["Color Scheme": "Light Appearance", "Dynamic Type": "Large", "Orientation": "Portrait"]]
        for index in 0..<4 {
            let start = DispatchTime.now().uptimeNanoseconds
            let response: [String: Any]
            do { response = try bridge.call("RenderPreview", arguments, timeout: 210) }
            catch { response = ["errors": [["message": String(describing: error)]]] }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            var record: [String: Any] = ["iteration": index, "requestToResponseSeconds": seconds, "response": response]
            if let path = (response["snapshot"] as? [String: Any])?["path"] as? String {
                let imageData = try Data(contentsOf: URL(fileURLWithPath: path))
                let image = try XCTUnwrap(NSBitmapImageRep(data: imageData))
                record["imageBase64"] = imageData.base64EncodedString()
                record["pixelsWide"] = image.pixelsWide; record["pixelsHigh"] = image.pixelsHigh
                record["requestToUsableImageSeconds"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            }
            records.append(record)
            let report: [String: Any] = ["sourceBlob": blob, "inkRevision": revision, "records": records,
                "preparationSeconds": preparationSeconds, "preparationBuild": preparation,
                "measurement": "Mac-side tool request to usable screenshot, not app or Foundation Models performance",
                "activeRunDestination": "iPhone 18 Pro", "requestedRenderDestination": "iPhone 18 Pro",
                "configuredDerivedData": scratch + "/AppleDerivedData",
                "cacheCaveat": "Xcode service owns additional preview and package caches; no cold-cache or app-performance claim."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: results + "/apple-preview.json"))
            let errors = response["errors"] as? [[String: Any]] ?? []
            guard errors.isEmpty, record["imageBase64"] != nil else {
                XCTFail("RenderPreview did not produce a usable image: \(errors)"); return
            }
            let destination = try XCTUnwrap(response["renderedDestination"] as? [String: Any])
            guard destination["identifier"] as? String == "4099B785-D4F4-4584-8CCD-DA13FED692DF",
                  destination["deviceModelName"] as? String == "iPhone 18 Pro" else {
                XCTFail("Unexpected rendering destination; samples are not matched"); return
            }
            // The owner's clarification: simulator app/model performance is excluded;
            // Mac-side turnaround of the rendering tool is the requested measurement.
            arguments["preferredRenderDestination"] = ["identifier": try XCTUnwrap(destination["identifier"] as? String)]
        }
    }
}

/// Fixed JSON-RPC transport for Apple's integration test; no shell or generic command input.
private final class ApplePreviewBridge {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["mcpbridge"]
        var env = ProcessInfo.processInfo.environment
        env["MCP_XCODE_SESSION_ID"] = "01a188d7-19b3-72a2-8ca4-c320d2e5f52f"
        process.environment = env
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        _ = try request("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "Codex Ink preview comparison", "version": "1.0"]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]])
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func call(_ name: String, _ arguments: [String: Any], timeout: Int = 60) throws -> [String: Any] {
        let result = try request("tools/call", ["name": name, "arguments": arguments], timeout: timeout)
        guard result["isError"] as? Bool != true else { throw failure("\(result)") }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func request(_ method: String, _ params: [String: Any], timeout: Int = 60) throws -> [String: Any] {
        sequence += 1
        try send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(Double(timeout))
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any], message["id"] as? Int == sequence else { continue }
                if let result = message["result"] as? [String: Any] { return result }
                throw failure("\(message)")
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            guard poll(&descriptor, 1, remaining) > 0 else { throw failure("MCP response timed out") }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw failure("MCP bridge closed") }
            buffer.append(chunk)
        }
        throw failure("MCP response timed out")
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "ApplePreviewComparison", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
