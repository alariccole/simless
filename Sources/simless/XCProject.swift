// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Native-mode metadata from Apple's JSON5 project format. Xcode builds the
/// original project; simless never converts it. Schema: apple/xcode-project-format.
struct XCProject {
    let packages: [String]
    let targets: Set<String>
    let uiTargets: Set<String>
    let folders: [String: [String]]
    let uiSources: [String: [String]]
    let platforms: [String: String]

    static func loadIfPresent(_ bundle: String) throws -> XCProject? {
        let path = "\(bundle)/project.xcproj"
        guard exists(path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else {
                throw SimlessError("expected a project object")
            }
            return try XCProject(json: json, directory: (bundle as NSString).deletingLastPathComponent)
        } catch {
            throw SimlessError("cannot read \(path): \(error)")
        }
    }

    init(json: [String: Any], directory: String) throws {
        func objects(_ key: String, in object: [String: Any]) throws -> [[String: Any]] {
            guard let value = object[key] else { return [] }
            guard let list = value as? [[String: Any]] else { throw SimlessError("\(key) must be an array of objects") }
            return list
        }
        func strings(_ key: String, in object: [String: Any]) throws -> [String] {
            guard let value = object[key] else { return [] }
            guard let list = value as? [String] else { throw SimlessError("unsupported \(key); expected strings") }
            return list
        }
        func resolve(_ path: String, parent: String) throws -> String {
            let value: String
            if path.hasPrefix("<PROJECT>/") { value = directory + "/" + path.dropFirst(10) }
            else if path.hasPrefix("<") { throw SimlessError("unsupported source path base in \(path)") }
            else if path.hasPrefix("/") { value = path }
            else { value = parent + "/" + path.replacingOccurrences(of: "\\<", with: "<") }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        let descriptions = try objects("targets", in: json)
        var names = Set<String>(), ui = Set<String>(), platform: [String: String] = [:]
        for target in descriptions where (target["kind"] as? String ?? "native") == "native" {
            guard let name = target["name"] as? String, names.insert(name).inserted else {
                throw SimlessError("missing or duplicate target name")
            }
            let type = target["product-type"] as? String ?? target["full-product-type"] as? String ?? ""
            if type == "bundle.ui-testing" || type == "com.apple.product-type.bundle.ui-testing" { ui.insert(name) }
            func setting(_ object: [String: Any], _ key: String) throws -> String? {
                guard let settings = object["build-settings"] as? [String: Any] else { return nil }
                let value = settings[key + "[config=Debug]"] ?? settings[key]
                guard let value else { return nil }
                if let text = value as? String { return text }
                if let array = value as? [String] { return array.joined(separator: " ") }
                throw SimlessError("unsupported \(key) value for \(name)")
            }
            let sdk = try setting(target, "SDKROOT") ?? setting(json, "SDKROOT") ?? "iphoneos"
            switch sdk {
            case "watchos", "watchsimulator": platform[name] = "watchOS"
            case "appletvos", "appletvsimulator": platform[name] = "tvOS"
            case "xros", "xrsimulator": platform[name] = "visionOS"
            case "macosx": platform[name] = "macOS"
            case "iphoneos", "iphonesimulator": platform[name] = "iOS"
            default: throw SimlessError("cannot resolve SDKROOT \(sdk) for \(name)")
            }
        }
        var packagePaths: [String] = []
        for package in try objects("packages", in: json) where package["kind"] as? String == "local" {
            guard let path = package["path"] as? String else { throw SimlessError("local package has no path") }
            packagePaths.append(try resolve(path, parent: directory))
        }
        var synced: [String: [String]] = [:], sources: [String: Set<String>] = [:]
        func walk(_ files: [[String: Any]], parent: String) throws {
            for file in files {
                let kind = file["kind"] as? String ?? "file"
                let rawPath = file["path"] as? String ?? ""
                // Products, assets and other non-source references may use virtual roots.
                guard kind == "group" || kind == "folder" || rawPath.hasSuffix(".swift") else { continue }
                let path = try resolve(rawPath, parent: parent)
                if kind == "group" {
                    try walk(objects("children", in: file), parent: path)
                } else if kind == "folder" {
                    let membership = try strings("target-membership", in: file)
                    for target in membership { synced[target, default: []].append(path) }
                    let exceptions = try objects("membership-exceptions", in: file)
                    let affected = Set(membership).union(exceptions.compactMap { $0["target"] as? String }).intersection(ui)
                    if affected.isEmpty { continue }
                    // Never claim UI coverage for membership forms we cannot resolve.
                    if file["file-types"] != nil || file["opaque-folders"] != nil {
                        throw SimlessError("UI test folder \(path) uses unsupported file-types or opaque-folders")
                    }
                    for item in exceptions {
                        guard item["target"] is String,
                              Set(item.keys).isSubset(of: ["target", "exclusions", "inclusions"]) else {
                            throw SimlessError("unsupported UI test membership exception in \(path)")
                        }
                    }
                    let enumerator = FileManager.default.enumerator(atPath: path)
                    let swift = (enumerator?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".swift") }
                    for target in affected {
                        var selected = Set(membership.contains(target) ? swift : [])
                        for item in exceptions where item["target"] as? String == target {
                            let exclusions = try strings("exclusions", in: item)
                            let inclusions = try strings("inclusions", in: item)
                            func matches(_ file: String, _ entry: String) -> Bool { file == entry || file.hasPrefix(entry + "/") }
                            selected = selected.filter { file in !exclusions.contains { matches(file, $0) } }
                            selected.formUnion(swift.filter { file in inclusions.contains { matches(file, $0) } })
                        }
                        sources[target, default: []].formUnion(selected.map { path + "/" + $0 })
                    }
                } else if kind == "file" {
                    for member in file["target-membership"] as? [Any] ?? [] {
                        guard let ref = member as? String else {
                            throw SimlessError("unsupported Swift file membership at \(path); use simple target/compile-sources references")
                        }
                        let parts = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                        guard parts.count == 2, !ref.hasPrefix("id:") else {
                            throw SimlessError("unsupported Swift file membership \(ref)")
                        }
                        if parts[1] == "compile-sources", ui.contains(parts[0]) {
                            sources[parts[0], default: []].insert(path)
                        }
                    }
                }
            }
        }
        try walk(objects("files", in: json), parent: directory)
        packages = packagePaths
        targets = names
        uiTargets = ui
        folders = synced
        uiSources = sources.mapValues { $0.sorted() }
        platforms = platform
    }
}
