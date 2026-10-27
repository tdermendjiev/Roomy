//
//  SystemArtifactProbe.swift
//  RoomyCore
//

import Foundation

/// A probe knows how to find one tool's disk usage. Fixed paths come from the catalog
/// (`CatalogPathProbe`); probes written in code handle anything that needs a CLI or a symlink check.
public protocol SystemArtifactProbe: Sendable {
    var categoryKey: String { get }
    var supportedPlatforms: Set<RoomyPlatform> { get }
    func scan(context: SystemProbeContext) async -> [ScanArtifactFinding]
}

public extension SystemArtifactProbe {
    var supportedPlatforms: Set<RoomyPlatform> { [.macOS, .linux] }
}

public struct SystemProbeContext: Sendable {
    public let home: URL
    public let exclusionFilter: RoomyScanExclusionFilter
    public let catalog: RuleCatalog
    public let platform: RoomyPlatform
    public let shouldCancel: @Sendable () -> Bool

    public init(
        home: URL,
        exclusionFilter: RoomyScanExclusionFilter = .empty,
        catalog: RuleCatalog = .builtin,
        platform: RoomyPlatform = .current,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) {
        self.home = home
        self.exclusionFilter = exclusionFilter
        self.catalog = catalog
        self.platform = platform
        self.shouldCancel = shouldCancel
    }

    public var resolver: RoomyPathResolver { RoomyPathResolver(home: home) }

    /// Base directory for Electron / VS Code family app data on this platform.
    public func appDataDirectory(appName: String) -> URL {
        switch platform {
        case .macOS: return home.appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true)
        case .linux: return home.appendingPathComponent(".config/\(appName)", isDirectory: true)
        }
    }
}

public enum SystemProbeHelpers {
    public static let minBytes = RoomyDirectorySizeReader.minimumBytes

    public static func finding(
        path: String,
        label: String,
        sizeBytes: Int64,
        ecosystemTag: String,
        groupRoot: String,
        source: ArtifactSource = .systemProbe,
        safetyTier: ArtifactSafetyTier = .safe,
        restoreHint: String? = nil,
        lastActivityDate: Date? = nil,
        ruleID: String? = nil
    ) -> ScanArtifactFinding {
        ScanArtifactFinding(
            path: path, label: label, sizeBytes: sizeBytes, ecosystemTag: ecosystemTag,
            groupRoot: groupRoot, source: source, safetyTier: safetyTier,
            restoreHint: restoreHint, lastActivityDate: lastActivityDate, ruleID: ruleID
        )
    }

    public static func pathExists(_ path: String, isDirectory: Bool = true) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDirectory ? isDir.boolValue : true
    }

    public static func runCommand(executable: String, arguments: [String], timeout: TimeInterval = 8) -> String? {
        ProcessRunner.output(executable: executable, arguments: arguments, timeout: timeout)
    }

    public static func which(_ name: String) -> String? {
        ProcessRunner.which(name)
    }

    public static func parseSizeFromCondaDryRun(_ output: String) -> Int64? {
        let lower = output.lowercased()
        if lower.contains("there are no") || lower.contains("nothing to") { return 0 }
        if let mbRange = lower.range(of: #"(\d+(?:\.\d+)?)\s*mb"#, options: .regularExpression) {
            let digits = String(lower[mbRange]).filter { $0.isNumber || $0 == "." }
            if let mb = Double(digits) { return Int64(mb * 1_048_576) }
        }
        if let gbRange = lower.range(of: #"(\d+(?:\.\d+)?)\s*gb"#, options: .regularExpression) {
            let digits = String(lower[gbRange]).filter { $0.isNumber || $0 == "." }
            if let gb = Double(digits) { return Int64(gb * 1_073_741_824) }
        }
        return nil
    }

    /// Immediate subdirectories, excluding hidden ones.
    public static func childDirectories(of url: URL, includeHidden: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: options
        ) else { return [] }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }
}
