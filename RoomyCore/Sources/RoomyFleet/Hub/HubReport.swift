//
//  HubReport.swift
//  RoomyFleet
//
//  What one host tells the hub after every run: a compact summary of the scan, the policy
//  decision, what was removed, cumulative totals from the audit log, disk headroom, and the
//  largest findings. Small (a few KB), additive-only, schema-versioned like ScanReport.
//

import Foundation
import RoomyCore

public enum HubSchema {
    public static let version = 1
}

public struct HubTopItem: Codable, Equatable, Sendable {
    public var path: String
    public var label: String
    public var bytes: Int64
    public var tier: ArtifactSafetyTier
    public var category: String
    public var ruleID: String?
    public var idleDays: Int?

    public init(path: String, label: String, bytes: Int64, tier: ArtifactSafetyTier, category: String, ruleID: String? = nil, idleDays: Int? = nil) {
        self.path = path; self.label = label; self.bytes = bytes; self.tier = tier; self.category = category; self.ruleID = ruleID; self.idleDays = idleDays
    }

    public init(_ item: ScanReportItem) {
        self.init(path: item.displayPath, label: item.label, bytes: item.bytes, tier: item.tier, category: item.category, ruleID: item.ruleID, idleDays: item.idleDays)
    }
}

public struct HubHostReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var host: String
    public var platform: RoomyPlatform
    public var roomyVersion: String
    public var catalogVersion: String
    public var policyName: String
    public var edition: String
    public var org: String?
    /// Free-form labels from the policy's `hub.tags` (role, region, team…).
    public var tags: [String: String]
    public var runID: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var dryRun: Bool
    public var succeeded: Bool
    /// How often this host runs, when known. The hub uses it to decide when a host is stale.
    public var intervalSeconds: Int?

    public var findings: Int
    public var reclaimableBytes: Int64
    public var bytesByTier: [String: Int64]
    public var bytesByCategory: [String: Int64]
    public var plannedItems: Int
    public var plannedBytes: Int64
    public var disposedItems: Int
    public var disposedBytes: Int64
    public var failures: Int
    public var purgedItems: Int
    public var purgedBytes: Int64
    public var skippedByReason: [String: Int]

    public var disposedBytesTotal: Int64
    public var disposedItemsTotal: Int
    public var failuresTotal: Int
    public var runsTotal: Int

    public var quarantineBytes: Int64
    public var quarantineItems: Int
    public var volumeTotalBytes: Int64?
    public var volumeAvailableBytes: Int64?

    public var auditSeq: Int
    public var auditHeadHash: String?
    public var licenseExpiresAt: Date?
    public var topItems: [HubTopItem]

    public init(host: String, platform: RoomyPlatform, roomyVersion: String, catalogVersion: String, policyName: String, edition: String,
                org: String? = nil, tags: [String: String] = [:], runID: String, startedAt: Date, durationSeconds: Double, dryRun: Bool,
                succeeded: Bool, intervalSeconds: Int? = nil, findings: Int, reclaimableBytes: Int64, bytesByTier: [String: Int64],
                bytesByCategory: [String: Int64], plannedItems: Int, plannedBytes: Int64, disposedItems: Int, disposedBytes: Int64,
                failures: Int, purgedItems: Int = 0, purgedBytes: Int64 = 0, skippedByReason: [String: Int] = [:],
                disposedBytesTotal: Int64, disposedItemsTotal: Int, failuresTotal: Int, runsTotal: Int,
                quarantineBytes: Int64, quarantineItems: Int, volumeTotalBytes: Int64?, volumeAvailableBytes: Int64?,
                auditSeq: Int, auditHeadHash: String?, licenseExpiresAt: Date? = nil, topItems: [HubTopItem]) {
        self.schemaVersion = HubSchema.version
        self.host = host; self.platform = platform; self.roomyVersion = roomyVersion; self.catalogVersion = catalogVersion
        self.policyName = policyName; self.edition = edition; self.org = org; self.tags = tags; self.runID = runID
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.dryRun = dryRun; self.succeeded = succeeded
        self.intervalSeconds = intervalSeconds; self.findings = findings; self.reclaimableBytes = reclaimableBytes
        self.bytesByTier = bytesByTier; self.bytesByCategory = bytesByCategory; self.plannedItems = plannedItems; self.plannedBytes = plannedBytes
        self.disposedItems = disposedItems; self.disposedBytes = disposedBytes; self.failures = failures; self.purgedItems = purgedItems
        self.purgedBytes = purgedBytes; self.skippedByReason = skippedByReason; self.disposedBytesTotal = disposedBytesTotal
        self.disposedItemsTotal = disposedItemsTotal; self.failuresTotal = failuresTotal; self.runsTotal = runsTotal
        self.quarantineBytes = quarantineBytes; self.quarantineItems = quarantineItems; self.volumeTotalBytes = volumeTotalBytes
        self.volumeAvailableBytes = volumeAvailableBytes; self.auditSeq = auditSeq; self.auditHeadHash = auditHeadHash
        self.licenseExpiresAt = licenseExpiresAt; self.topItems = topItems
    }

    /// Builds the report for a finished run. `topItems` are the largest findings, warning tier included,
    /// so the hub can show what a policy is *not* allowed to remove.
    public init(result: FleetRunResult, policy: FleetPolicy, roomyVersion: String, intervalSeconds: Int?, topItems limit: Int) {
        let totals = AuditLog.totals(from: policy.resolvedAuditPath)
        let head = AuditLog.head(url: policy.resolvedAuditPath)
        let q = QuarantineDisposer(config: policy.resolvedQuarantine)
        var byReason: [String: Int] = [:]
        for s in result.decision.skipped { byReason[s.reason.rawValue, default: 0] += 1 }
        let top = result.report.items.sorted { $0.bytes > $1.bytes }.prefix(max(0, limit)).map(HubTopItem.init)
        self.init(
            host: result.report.host, platform: result.report.platform, roomyVersion: roomyVersion, catalogVersion: result.report.catalogVersion,
            policyName: policy.name, edition: result.license.edition.rawValue, org: result.license.payload?.org, tags: policy.hub.tags,
            runID: result.runID, startedAt: result.startedAt, durationSeconds: result.duration, dryRun: result.dryRun, succeeded: result.succeeded,
            intervalSeconds: intervalSeconds, findings: result.report.items.count, reclaimableBytes: result.report.totalBytes,
            bytesByTier: result.report.bytesByTier, bytesByCategory: result.report.bytesByCategory,
            plannedItems: result.decision.selected.count, plannedBytes: result.decision.selectedBytes,
            disposedItems: result.disposal.receipts.count, disposedBytes: result.disposedBytes, failures: result.disposal.failures.count,
            purgedItems: result.purged.receipts.count, purgedBytes: result.purged.receipts.reduce(0) { $0 + ($1.bytes ?? 0) },
            skippedByReason: byReason, disposedBytesTotal: totals.disposedBytes, disposedItemsTotal: totals.disposedItems,
            failuresTotal: totals.failures, runsTotal: totals.runs, quarantineBytes: q.totalBytes, quarantineItems: q.entries().count,
            volumeTotalBytes: result.report.volume?.totalBytes, volumeAvailableBytes: result.report.volume?.availableBytes,
            auditSeq: head?.seq ?? 0, auditHeadHash: head?.hash, licenseExpiresAt: result.license.payload?.expiresAt, topItems: Array(top)
        )
    }

    // Lenient decoding: a hub must accept reports from older and newer agents.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, host, platform, roomyVersion, catalogVersion, policyName, edition, org, tags, runID, startedAt, durationSeconds, dryRun, succeeded, intervalSeconds
        case findings, reclaimableBytes, bytesByTier, bytesByCategory, plannedItems, plannedBytes, disposedItems, disposedBytes, failures, purgedItems, purgedBytes, skippedByReason
        case disposedBytesTotal, disposedItemsTotal, failuresTotal, runsTotal, quarantineBytes, quarantineItems, volumeTotalBytes, volumeAvailableBytes
        case auditSeq, auditHeadHash, licenseExpiresAt, topItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        host = try c.decode(String.self, forKey: .host)
        platform = try c.decodeIfPresent(RoomyPlatform.self, forKey: .platform) ?? .linux
        roomyVersion = try c.decodeIfPresent(String.self, forKey: .roomyVersion) ?? "?"
        catalogVersion = try c.decodeIfPresent(String.self, forKey: .catalogVersion) ?? "?"
        policyName = try c.decodeIfPresent(String.self, forKey: .policyName) ?? "default"
        edition = try c.decodeIfPresent(String.self, forKey: .edition) ?? "community"
        org = try c.decodeIfPresent(String.self, forKey: .org)
        tags = try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        runID = try c.decodeIfPresent(String.self, forKey: .runID) ?? UUID().uuidString.lowercased()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        succeeded = try c.decodeIfPresent(Bool.self, forKey: .succeeded) ?? true
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        findings = try c.decodeIfPresent(Int.self, forKey: .findings) ?? 0
        reclaimableBytes = try c.decodeIfPresent(Int64.self, forKey: .reclaimableBytes) ?? 0
        bytesByTier = try c.decodeIfPresent([String: Int64].self, forKey: .bytesByTier) ?? [:]
        bytesByCategory = try c.decodeIfPresent([String: Int64].self, forKey: .bytesByCategory) ?? [:]
        plannedItems = try c.decodeIfPresent(Int.self, forKey: .plannedItems) ?? 0
        plannedBytes = try c.decodeIfPresent(Int64.self, forKey: .plannedBytes) ?? 0
        disposedItems = try c.decodeIfPresent(Int.self, forKey: .disposedItems) ?? 0
        disposedBytes = try c.decodeIfPresent(Int64.self, forKey: .disposedBytes) ?? 0
        failures = try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        purgedItems = try c.decodeIfPresent(Int.self, forKey: .purgedItems) ?? 0
        purgedBytes = try c.decodeIfPresent(Int64.self, forKey: .purgedBytes) ?? 0
        skippedByReason = try c.decodeIfPresent([String: Int].self, forKey: .skippedByReason) ?? [:]
        disposedBytesTotal = try c.decodeIfPresent(Int64.self, forKey: .disposedBytesTotal) ?? 0
        disposedItemsTotal = try c.decodeIfPresent(Int.self, forKey: .disposedItemsTotal) ?? 0
        failuresTotal = try c.decodeIfPresent(Int.self, forKey: .failuresTotal) ?? 0
        runsTotal = try c.decodeIfPresent(Int.self, forKey: .runsTotal) ?? 0
        quarantineBytes = try c.decodeIfPresent(Int64.self, forKey: .quarantineBytes) ?? 0
        quarantineItems = try c.decodeIfPresent(Int.self, forKey: .quarantineItems) ?? 0
        volumeTotalBytes = try c.decodeIfPresent(Int64.self, forKey: .volumeTotalBytes)
        volumeAvailableBytes = try c.decodeIfPresent(Int64.self, forKey: .volumeAvailableBytes)
        auditSeq = try c.decodeIfPresent(Int.self, forKey: .auditSeq) ?? 0
        auditHeadHash = try c.decodeIfPresent(String.self, forKey: .auditHeadHash)
        licenseExpiresAt = try c.decodeIfPresent(Date.self, forKey: .licenseExpiresAt)
        topItems = try c.decodeIfPresent([HubTopItem].self, forKey: .topItems) ?? []
    }

    /// Fraction of the volume still free, when the agent reported volume figures.
    public var volumeFreeFraction: Double? {
        guard let t = volumeTotalBytes, t > 0, let a = volumeAvailableBytes else { return nil }
        return Double(a) / Double(t)
    }
}

public enum HubJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
