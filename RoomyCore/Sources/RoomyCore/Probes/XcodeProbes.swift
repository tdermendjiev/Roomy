//
//  XcodeProbes.swift
//  RoomyCore
//
//  macOS only. DerivedData, DeviceSupport and simulator caches are catalog rules;
//  these two need recursion (archives) or `simctl` (simulators).
//

import Foundation

public struct XcodeArchivesProbe: SystemArtifactProbe {
    public let categoryKey = "xcode"
    public var supportedPlatforms: Set<RoomyPlatform> { [.macOS] }

    public init() {}

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        let archivesRoot = context.home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
        guard SystemProbeHelpers.pathExists(archivesRoot.path) else { return [] }
        if context.exclusionFilter.shouldExcludeDirectory(url: archivesRoot) { return [] }

        var xcarchives: [URL] = []
        collectXCArchives(under: archivesRoot, into: &xcarchives, shouldCancel: context.shouldCancel)
        if xcarchives.isEmpty { return [] }

        let sizes = await RoomyDirectorySizeReader.bytesConcurrently(urls: xcarchives, shouldCancel: context.shouldCancel)
        return xcarchives.compactMap { url in
            guard let size = sizes[url] else { return nil }
            return SystemProbeHelpers.finding(
                path: url.path, label: "Archive: \(url.deletingPathExtension().lastPathComponent)", sizeBytes: size,
                ecosystemTag: "swift", groupRoot: RoomySystemGroupRoot.xcode, safetyTier: .warning,
                restoreHint: "Cannot be restored — re-archive from Xcode if needed",
                lastActivityDate: RoomyDirectorySizeReader.modificationDate(at: url), ruleID: "xcode-archive"
            )
        }
    }

    private func collectXCArchives(under url: URL, into result: inout [URL], shouldCancel: () -> Bool) {
        if shouldCancel() { return }
        if url.pathExtension == "xcarchive" { result.append(url); return }
        for entry in SystemProbeHelpers.childDirectories(of: url) {
            if shouldCancel() { return }
            collectXCArchives(under: entry, into: &result, shouldCancel: shouldCancel)
        }
    }
}

public struct CoreSimulatorProbe: SystemArtifactProbe {
    public let categoryKey = "xcode"
    public var supportedPlatforms: Set<RoomyPlatform> { [.macOS] }

    public init() {}

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        guard let json = ProcessRunner.output(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "-j"], timeout: 10),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }

        let devicesRoot = context.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        var findings: [ScanArtifactFinding] = []
        for (_, devices) in devicesByRuntime {
            if context.shouldCancel() { break }
            for device in devices {
                if context.shouldCancel() { break }
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                let availability = (device["availability"] as? String) ?? (device["isAvailable"] as? Bool == true ? "available" : "unavailable")
                let isUnavailable = availability.lowercased().contains("unavailable")
                let deviceURL = devicesRoot.appendingPathComponent(udid, isDirectory: true)
                guard SystemProbeHelpers.pathExists(deviceURL.path) else { continue }
                if context.exclusionFilter.shouldExcludeDirectory(url: deviceURL) { continue }
                let size = await Task.detached { RoomyDirectorySizeReader.bytes(at: deviceURL) }.value
                guard let size, size >= SystemProbeHelpers.minBytes else { continue }
                var lastBooted: Date?
                if let bootedStr = device["lastBootedAt"] as? String { lastBooted = ISO8601DateFormatter().date(from: bootedStr) }
                findings.append(SystemProbeHelpers.finding(
                    path: deviceURL.path, label: "Simulator: \(name)", sizeBytes: size, ecosystemTag: "swift",
                    groupRoot: RoomySystemGroupRoot.xcode, safetyTier: isUnavailable ? .safe : .caution,
                    restoreHint: "Create new simulator in Xcode → Devices & Simulators",
                    lastActivityDate: lastBooted ?? RoomyDirectorySizeReader.modificationDate(at: deviceURL), ruleID: "xcode-simulator"
                ))
            }
        }
        return findings
    }
}
