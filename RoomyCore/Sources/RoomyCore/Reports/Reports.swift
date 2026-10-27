//
//  Reports.swift
//  RoomyCore
//
//  The JSON that leaves the process: a scan report (what `roomy scan --json` prints) and a
//  cleanup plan (what `roomy clean --plan` consumes). Both carry a schema version. Agents and
//  fleet tooling depend on these shapes, so changes are additive only.
//

import Foundation

public enum RoomyReportSchema {
    public static let version = 1
}

public struct ScanReportItem: Codable, Sendable, Equatable, Identifiable {
    /// Stable id derived from the path. Same path → same id across runs.
    public var id: String
    public var path: String
    public var displayPath: String
    public var label: String
    public var bytes: Int64
    public var tier: ArtifactSafetyTier
    public var ecosystem: String
    /// Category key for system findings (`aiTools`, `docker`, …) or `project` for project-walk findings.
    public var category: String
    /// Project root (expanded path) or system group display name.
    public var group: String
    public var source: ArtifactSource
    public var ruleID: String?
    public var restoreHint: String?
    public var lastActivity: Date?
    /// Days since `lastActivity` or since the project folder changed. Nil when unknown.
    public var idleDays: Int?
    public var activity: ProjectActivity?

    public init(finding f: ScanArtifactFinding, group: String, resolver: RoomyPathResolver,
                idleDays: Int?, activity: ProjectActivity?) {
        self.id = StableID.make(f.path)
        self.path = f.path
        self.displayPath = f.isCLITarget ? f.path : resolver.display(f.path)
        self.label = f.label
        self.bytes = f.sizeBytes
        self.tier = f.safetyTier
        self.ecosystem = f.ecosystemTag
        if let g = f.groupRoot, let c = RoomySystemGroupRoot.category(forGroupRoot: g) {
            self.category = c
        } else if f.source == .pipCLI {
            self.category = "python"
        } else {
            self.category = "project"
        }
        self.group = group
        self.source = f.source
        self.ruleID = f.ruleID
        self.restoreHint = f.restoreHint
        self.lastActivity = f.lastActivityDate
        self.idleDays = idleDays
        self.activity = activity
    }
}

public struct ScanReport: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var roomyVersion: String
    public var catalogVersion: String
    public var generatedAt: Date
    public var host: String
    public var platform: RoomyPlatform
    public var scanRoot: String
    public var home: String
    public var durationSeconds: Double
    public var partial: Bool
    public var totalBytes: Int64
    public var bytesByTier: [String: Int64]
    public var bytesByCategory: [String: Int64]
    public var bytesByEcosystem: [String: Int64]
    public var projectCount: Int
    public var volume: RoomyVolumeSpaceReader.Space?
    public var items: [ScanReportItem]

    public init(
        aggregate: ScanAggregate,
        scanRoot: URL,
        home: URL,
        durationSeconds: Double,
        partial: Bool,
        roomyVersion: String,
        catalogVersion: String = RuleCatalog.builtin.catalogVersion,
        dormantMonths: Int = 24,
        inactiveMonths: Int = 6,
        now: Date = Date()
    ) {
        let resolver = RoomyPathResolver(home: home)
        self.schemaVersion = RoomyReportSchema.version
        self.roomyVersion = roomyVersion
        self.catalogVersion = catalogVersion
        self.generatedAt = now
        self.host = RoomyHost.name
        self.platform = .current
        self.scanRoot = scanRoot.path
        self.home = home.path
        self.durationSeconds = durationSeconds
        self.partial = partial
        self.totalBytes = aggregate.totalBytes
        self.bytesByEcosystem = aggregate.bytesByEcosystem
        self.volume = RoomyVolumeSpaceReader.space(forDirectory: scanRoot)

        var items: [ScanReportItem] = []
        var byTier: [String: Int64] = [:]
        var byCategory: [String: Int64] = [:]
        var projectRoots: Set<String> = []
        var mtimeCache: [String: Date?] = [:]

        for (root, findings) in aggregate.artifactsByProjectRoot {
            let isSystem = RoomySystemGroupRoot.isSystemRoot(root)
            let group = isSystem ? RoomySystemGroupRoot.displayName(for: root) : root
            if !isSystem { projectRoots.insert(root) }
            let projectMTime: Date?
            if isSystem {
                projectMTime = nil
            } else if let cached = mtimeCache[root] {
                projectMTime = cached
            } else {
                let d = RoomyDirectorySizeReader.modificationDate(at: URL(fileURLWithPath: root))
                mtimeCache[root] = d
                projectMTime = d
            }
            for f in findings {
                var activityDate = f.lastActivityDate ?? projectMTime
                if activityDate == nil, !f.isCLITarget {
                    activityDate = RoomyDirectorySizeReader.modificationDate(at: URL(fileURLWithPath: f.path))
                }
                let idle = ScanActivityClassification.daysSince(activityDate, now: now)
                let months = activityDate.map { ScanActivityClassification.modificationMonthsAgo(date: $0, now: now) }
                let activity = months.map { ScanActivityClassification.activity(monthsAgo: $0, dormantMonths: dormantMonths, inactiveMonths: inactiveMonths) }
                let item = ScanReportItem(finding: f, group: group, resolver: resolver, idleDays: idle, activity: activity)
                items.append(item)
                byTier[f.safetyTier.rawValue, default: 0] += f.sizeBytes
                byCategory[item.category, default: 0] += f.sizeBytes
            }
        }
        items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        self.items = items
        self.bytesByTier = byTier
        self.bytesByCategory = byCategory
        self.projectCount = projectRoots.count
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    public static func load(from url: URL) throws -> ScanReport { try decoder.decode(ScanReport.self, from: Data(contentsOf: url)) }
}

/// A list of things to remove, produced by `roomy scan --plan`, a policy, or an agent filtering a report.
/// `clean` refuses anything that is not in the plan, so a caller never passes raw paths.
public struct CleanupPlan: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var label: String
        public var bytes: Int64
        public var tier: ArtifactSafetyTier
        public var category: String
        public var source: ArtifactSource
        public var ruleID: String?

        public init(_ r: ScanReportItem) {
            id = r.id; path = r.path; label = r.label; bytes = r.bytes; tier = r.tier
            category = r.category; source = r.source; ruleID = r.ruleID
        }

        public init(id: String, path: String, label: String, bytes: Int64, tier: ArtifactSafetyTier,
                    category: String, source: ArtifactSource, ruleID: String?) {
            self.id = id; self.path = path; self.label = label; self.bytes = bytes; self.tier = tier
            self.category = category; self.source = source; self.ruleID = ruleID
        }
    }

    public var schemaVersion: Int
    public var createdAt: Date
    public var host: String
    public var method: DisposalMethod
    /// Free text for the audit log: "policy:default", "agent:claude-code", "user".
    public var reason: String?
    public var items: [Item]

    public init(items: [Item], method: DisposalMethod, reason: String? = nil, now: Date = Date()) {
        schemaVersion = RoomyReportSchema.version
        createdAt = now
        host = RoomyHost.name
        self.method = method
        self.reason = reason
        self.items = items
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var maxTier: ArtifactSafetyTier { items.map(\.tier).max() ?? .safe }

    public func encoded() throws -> Data { try ScanReport.encoder.encode(self) }
    public static func load(from url: URL) throws -> CleanupPlan { try ScanReport.decoder.decode(CleanupPlan.self, from: Data(contentsOf: url)) }

    /// Items whose path is a filesystem path that no longer exists (stale plan).
    public func missingItems() -> [Item] {
        items.filter { item in
            if item.source == .dockerCLI || item.source == .condaCLI || item.source == .pipCLI { return false }
            return !FileManager.default.fileExists(atPath: item.path)
        }
    }
}

/// Short, stable identifiers for findings (FNV-1a 64-bit of the path). Not security-relevant.
public enum StableID {
    public static func make(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16).leftPadded(to: 16)
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
