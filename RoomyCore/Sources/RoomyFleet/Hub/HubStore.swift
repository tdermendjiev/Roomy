//
//  HubStore.swift
//  RoomyFleet
//
//  The hub's state: one JSON file per host (latest report + a capped history), policies as
//  JSON files, and an append-only event log. Plain files on purpose: back it up with rsync,
//  inspect it with jq, no database to operate.
//

import Foundation
import RoomyCore

public enum HubHostStatus: String, Codable, Sendable, CaseIterable {
    /// Reported recently, last run succeeded, disk headroom fine.
    case healthy
    /// Reported recently but something needs a look: failures, low disk, over the license allowance.
    case attention
    /// No report within the expected window.
    case stale
}

public struct HubHistoryPoint: Codable, Equatable, Sendable {
    public var time: Date
    public var reclaimableBytes: Int64
    public var disposedBytes: Int64
    public var failures: Int
    public var volumeAvailableBytes: Int64?
    public var dryRun: Bool

    public init(time: Date, reclaimableBytes: Int64, disposedBytes: Int64, failures: Int, volumeAvailableBytes: Int64?, dryRun: Bool) {
        self.time = time; self.reclaimableBytes = reclaimableBytes; self.disposedBytes = disposedBytes; self.failures = failures
        self.volumeAvailableBytes = volumeAvailableBytes; self.dryRun = dryRun
    }
}

/// What the hub keeps for one host.
public struct HubHostFile: Codable, Equatable, Sendable {
    public var host: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var reports: Int
    public var latest: HubHostReport
    public var history: [HubHistoryPoint]
    /// Set by an operator; shown on the dashboard.
    public var note: String?
}

/// An inventory row: the host file plus the status the hub computed now.
public struct HubHostRecord: Codable, Equatable, Sendable {
    public var host: String
    public var status: HubHostStatus
    public var statusReasons: [String]
    public var overLicenseLimit: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    public var reports: Int
    public var note: String?
    public var latest: HubHostReport
    public var history: [HubHistoryPoint]
}

public struct HubEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case reportReceived, reportRejected, hostRemoved, policyUpdated, policyRemoved, noteUpdated, hubStarted
    }
    public var time: Date
    public var kind: Kind
    public var host: String?
    public var message: String
    public var bytes: Int64?
}

public struct HubLicenseInfo: Codable, Equatable, Sendable {
    public var edition: String
    public var org: String?
    public var maxHosts: Int
    public var expiresAt: Date?
    public var problem: String?
    public var hostsKnown: Int
    public var hostsOverLimit: [String]
}

public struct HubSummary: Codable, Equatable, Sendable {
    public struct HostBytes: Codable, Equatable, Sendable { public var host: String; public var bytes: Int64 }
    public struct HostDisk: Codable, Equatable, Sendable { public var host: String; public var availableBytes: Int64; public var totalBytes: Int64; public var freeFraction: Double }
    public struct RuleBytes: Codable, Equatable, Sendable { public var label: String; public var tier: ArtifactSafetyTier; public var category: String; public var bytes: Int64; public var hosts: Int }
    public struct RecentRun: Codable, Equatable, Sendable {
        public var host: String; public var startedAt: Date; public var disposedBytes: Int64; public var disposedItems: Int
        public var failures: Int; public var succeeded: Bool; public var dryRun: Bool; public var reclaimableBytes: Int64
    }
    public struct DayPoint: Codable, Equatable, Sendable { public var day: String; public var disposedBytes: Int64; public var runs: Int; public var failures: Int }

    public var generatedAt: Date
    public var title: String
    public var hosts: Int
    public var hostsByStatus: [String: Int]
    public var hostsByPlatform: [String: Int]
    public var hostsByPolicy: [String: Int]
    public var hostsByVersion: [String: Int]
    public var hostsDryRun: Int
    public var reclaimableBytes: Int64
    public var bytesByTier: [String: Int64]
    public var bytesByCategory: [String: Int64]
    public var plannedBytes: Int64
    public var disposedBytesTotal: Int64
    public var disposedItemsTotal: Int64
    public var disposedBytesLast24h: Int64
    public var disposedBytesLast7d: Int64
    public var runsTotal: Int
    public var failuresTotal: Int
    public var failuresLast24h: Int
    public var quarantineBytes: Int64
    public var volumeTotalBytes: Int64
    public var volumeAvailableBytes: Int64
    public var hostsLowDisk: Int
    public var license: HubLicenseInfo
    public var topReclaimable: [HostBytes]
    public var topFreed: [HostBytes]
    public var lowestDisk: [HostDisk]
    public var topRules: [RuleBytes]
    public var recentRuns: [RecentRun]
    public var trend: [DayPoint]
    public var staleAfterSeconds: Int
}

public final class HubStore: @unchecked Sendable {
    public let dataDir: URL
    public var staleAfter: TimeInterval
    public var title: String
    private let lock = NSLock()
    private var hosts: [String: HubHostFile] = [:]
    public static let historyCap = 1_000
    public static let lowDiskFraction = 0.10

    public init(dataDir: URL, staleAfter: TimeInterval = 24 * 3600, title: String = "Roomy Hub") throws {
        self.dataDir = dataDir
        self.staleAfter = staleAfter
        self.title = title
        try FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: policiesDir, withIntermediateDirectories: true)
        try loadAll()
    }

    var hostsDir: URL { dataDir.appendingPathComponent("hosts", isDirectory: true) }
    var policiesDir: URL { dataDir.appendingPathComponent("policies", isDirectory: true) }
    var eventsURL: URL { dataDir.appendingPathComponent("events.jsonl") }

    static func fileName(for host: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let safe = String(host.map { allowed.contains($0) ? $0 : "_" })
        return (safe.isEmpty ? "_" : safe) + ".json"
    }

    private func loadAll() throws {
        let files = try FileManager.default.contentsOfDirectory(at: hostsDir, includingPropertiesForKeys: nil)
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let hf = try? HubJSON.decoder.decode(HubHostFile.self, from: data) {
                hosts[hf.host] = hf
            }
        }
    }

    private func save(_ hf: HubHostFile) throws {
        let data = try HubJSON.encoder.encode(hf)
        try data.write(to: hostsDir.appendingPathComponent(Self.fileName(for: hf.host)), options: .atomic)
    }

    // MARK: Ingest

    public enum IngestError: Error, LocalizedError, Equatable {
        case overHostLimit(limit: Int, known: Int)
        public var errorDescription: String? {
            switch self {
            case .overHostLimit(let limit, let known):
                return "hub already tracks \(known) hosts; the edition in effect allows \(limit). Install a fleet license with a higher host allowance or remove retired hosts."
            }
        }
    }

    /// Records a report. `hostLimit` is the edition's allowance; a report from a *new* host beyond it is refused,
    /// reports from hosts already in the inventory are always accepted.
    @discardableResult
    public func ingest(_ report: HubHostReport, receivedAt now: Date = Date(), hostLimit: Int? = nil) throws -> HubHostFile {
        lock.lock(); defer { lock.unlock() }
        var file: HubHostFile
        if let existing = hosts[report.host] {
            file = existing
            file.latest = report
            file.lastSeen = now
            file.reports += 1
        } else {
            if let limit = hostLimit, hosts.count >= limit {
                appendEventLocked(HubEvent(time: now, kind: .reportRejected, host: report.host,
                                           message: "refused: \(hosts.count) hosts known, allowance is \(limit)", bytes: nil))
                throw IngestError.overHostLimit(limit: limit, known: hosts.count)
            }
            file = HubHostFile(host: report.host, firstSeen: now, lastSeen: now, reports: 1, latest: report, history: [], note: nil)
        }
        file.history.append(HubHistoryPoint(time: report.startedAt, reclaimableBytes: report.reclaimableBytes, disposedBytes: report.disposedBytes,
                                            failures: report.failures, volumeAvailableBytes: report.volumeAvailableBytes, dryRun: report.dryRun))
        if file.history.count > Self.historyCap { file.history.removeFirst(file.history.count - Self.historyCap) }
        try save(file)
        hosts[report.host] = file
        appendEventLocked(HubEvent(time: now, kind: .reportReceived, host: report.host,
                                   message: report.dryRun ? "dry run · \(report.findings) findings" :
                                       "\(report.disposedItems) removed" + (report.failures > 0 ? " · \(report.failures) failed" : ""),
                                   bytes: report.disposedBytes))
        return file
    }

    @discardableResult
    public func remove(host: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard hosts.removeValue(forKey: host) != nil else { return false }
        try? FileManager.default.removeItem(at: hostsDir.appendingPathComponent(Self.fileName(for: host)))
        appendEventLocked(HubEvent(time: now, kind: .hostRemoved, host: host, message: "removed from inventory", bytes: nil))
        return true
    }

    public func setNote(host: String, note: String?, now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var f = hosts[host] else { return false }
        f.note = (note?.isEmpty ?? true) ? nil : note
        try save(f)
        hosts[host] = f
        appendEventLocked(HubEvent(time: now, kind: .noteUpdated, host: host, message: f.note ?? "note cleared", bytes: nil))
        return true
    }

    // MARK: Read

    public var hostCount: Int { lock.lock(); defer { lock.unlock() }; return hosts.count }
    public var hostNames: [String] { lock.lock(); defer { lock.unlock() }; return hosts.keys.sorted() }

    public func file(for host: String) -> HubHostFile? {
        lock.lock(); defer { lock.unlock() }
        return hosts[host]
    }

    func status(of f: HubHostFile, now: Date, overLimit: Bool) -> (HubHostStatus, [String]) {
        var reasons: [String] = []
        let window: TimeInterval
        if let i = f.latest.intervalSeconds, i > 0 { window = max(TimeInterval(i) * 2.5, 15 * 60) } else { window = staleAfter }
        let silence = now.timeIntervalSince(f.lastSeen)
        if silence > window {
            reasons.append("no report for \(Self.humanDuration(silence))")
            return (.stale, reasons)
        }
        if f.latest.failures > 0 { reasons.append("\(f.latest.failures) disposal failure\(f.latest.failures == 1 ? "" : "s") in last run") }
        if !f.latest.succeeded, f.latest.failures == 0 { reasons.append("last run did not succeed") }
        if let free = f.latest.volumeFreeFraction, free < Self.lowDiskFraction { reasons.append("disk \(Int(free * 100))% free") }
        if overLimit { reasons.append("over license host allowance") }
        if let exp = f.latest.licenseExpiresAt, exp < now { reasons.append("fleet license expired") }
        return (reasons.isEmpty ? .healthy : .attention, reasons)
    }

    /// Inventory sorted by host name. `license` decides which hosts are over the allowance (newest first seen are the extras).
    public func inventory(now: Date = Date(), license: HubLicenseInfo? = nil) -> [HubHostRecord] {
        lock.lock(); defer { lock.unlock() }
        let over = Set(license?.hostsOverLimit ?? [])
        return hosts.values.sorted { $0.host < $1.host }.map { f in
            let (status, reasons) = status(of: f, now: now, overLimit: over.contains(f.host))
            return HubHostRecord(host: f.host, status: status, statusReasons: reasons, overLicenseLimit: over.contains(f.host),
                                 firstSeen: f.firstSeen, lastSeen: f.lastSeen, reports: f.reports, note: f.note, latest: f.latest, history: f.history)
        }
    }

    /// Hosts beyond the allowance, oldest hosts keep their place.
    public func hostsOverLimit(_ limit: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let ordered = hosts.values.sorted { ($0.firstSeen, $0.host) < ($1.firstSeen, $1.host) }
        guard ordered.count > limit else { return [] }
        return ordered.dropFirst(limit).map(\.host)
    }

    public func summary(now: Date = Date(), license: HubLicenseInfo) -> HubSummary {
        let inv = inventory(now: now, license: license)
        var byStatus: [String: Int] = [:], byPlatform: [String: Int] = [:], byPolicy: [String: Int] = [:], byVersion: [String: Int] = [:]
        var byTier: [String: Int64] = [:], byCategory: [String: Int64] = [:]
        var reclaimable: Int64 = 0, planned: Int64 = 0, disposedTotal: Int64 = 0, disposedItems: Int64 = 0, quarantine: Int64 = 0
        var volTotal: Int64 = 0, volAvail: Int64 = 0, runs = 0, failures = 0, lowDisk = 0, dry = 0
        var d24: Int64 = 0, d7: Int64 = 0, f24 = 0
        var rules: [String: HubSummary.RuleBytes] = [:]
        var recent: [HubSummary.RecentRun] = []
        var days: [String: HubSummary.DayPoint] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let since14 = now.addingTimeInterval(-14 * 86_400)
        for h in inv {
            let r = h.latest
            byStatus[h.status.rawValue, default: 0] += 1
            byPlatform[r.platform.rawValue, default: 0] += 1
            byPolicy[r.policyName, default: 0] += 1
            byVersion[r.roomyVersion, default: 0] += 1
            if r.dryRun { dry += 1 }
            reclaimable += r.reclaimableBytes
            planned += r.plannedBytes
            disposedTotal += r.disposedBytesTotal
            disposedItems += Int64(r.disposedItemsTotal)
            quarantine += r.quarantineBytes
            runs += r.runsTotal
            failures += r.failuresTotal
            for (k, v) in r.bytesByTier { byTier[k, default: 0] += v }
            for (k, v) in r.bytesByCategory { byCategory[k, default: 0] += v }
            if let t = r.volumeTotalBytes, let a = r.volumeAvailableBytes {
                volTotal += t; volAvail += a
                if t > 0, Double(a) / Double(t) < Self.lowDiskFraction { lowDisk += 1 }
            }
            for item in r.topItems {
                let key = item.label + "|" + item.tier.rawValue
                var e = rules[key] ?? .init(label: item.label, tier: item.tier, category: item.category, bytes: 0, hosts: 0)
                e.bytes += item.bytes
                rules[key] = e
            }
            // one host counts once per rule
            for label in Set(r.topItems.map { $0.label + "|" + $0.tier.rawValue }) { rules[label]?.hosts += 1 }
            for p in h.history where p.time >= since14 {
                let age = now.timeIntervalSince(p.time)
                let freed = p.dryRun ? 0 : p.disposedBytes   // a dry run frees nothing
                if age <= 86_400 { d24 += freed; f24 += p.failures }
                if age <= 7 * 86_400 { d7 += freed }
                let day = dayFormatter.string(from: p.time)
                var dp = days[day] ?? .init(day: day, disposedBytes: 0, runs: 0, failures: 0)
                dp.disposedBytes += freed; dp.runs += 1; dp.failures += p.failures
                days[day] = dp
            }
            recent.append(.init(host: h.host, startedAt: r.startedAt, disposedBytes: r.disposedBytes, disposedItems: r.disposedItems,
                                failures: r.failures, succeeded: r.succeeded, dryRun: r.dryRun, reclaimableBytes: r.reclaimableBytes))
        }
        // Every one of the last 14 days appears, so the trend has a stable x-axis.
        var trend: [HubSummary.DayPoint] = []
        for i in stride(from: 13, through: 0, by: -1) {
            let day = dayFormatter.string(from: now.addingTimeInterval(-Double(i) * 86_400))
            trend.append(days[day] ?? .init(day: day, disposedBytes: 0, runs: 0, failures: 0))
        }
        return HubSummary(
            generatedAt: now, title: title, hosts: inv.count, hostsByStatus: byStatus, hostsByPlatform: byPlatform, hostsByPolicy: byPolicy,
            hostsByVersion: byVersion, hostsDryRun: dry, reclaimableBytes: reclaimable, bytesByTier: byTier, bytesByCategory: byCategory,
            plannedBytes: planned, disposedBytesTotal: disposedTotal, disposedItemsTotal: disposedItems, disposedBytesLast24h: d24,
            disposedBytesLast7d: d7, runsTotal: runs, failuresTotal: failures, failuresLast24h: f24, quarantineBytes: quarantine,
            volumeTotalBytes: volTotal, volumeAvailableBytes: volAvail, hostsLowDisk: lowDisk, license: license,
            topReclaimable: inv.sorted { $0.latest.reclaimableBytes > $1.latest.reclaimableBytes }.prefix(10).map { .init(host: $0.host, bytes: $0.latest.reclaimableBytes) },
            topFreed: inv.sorted { $0.latest.disposedBytesTotal > $1.latest.disposedBytesTotal }.prefix(10).map { .init(host: $0.host, bytes: $0.latest.disposedBytesTotal) },
            lowestDisk: inv.compactMap { h -> HubSummary.HostDisk? in
                guard let t = h.latest.volumeTotalBytes, t > 0, let a = h.latest.volumeAvailableBytes else { return nil }
                return .init(host: h.host, availableBytes: a, totalBytes: t, freeFraction: Double(a) / Double(t))
            }.sorted { $0.freeFraction < $1.freeFraction }.prefix(10).map { $0 },
            topRules: rules.values.sorted { $0.bytes > $1.bytes }.prefix(12).map { $0 },
            recentRuns: recent.sorted { $0.startedAt > $1.startedAt }.prefix(25).map { $0 },
            trend: trend, staleAfterSeconds: Int(staleAfter)
        )
    }

    // MARK: Policies

    public func policyNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: policiesDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public func policy(named name: String) -> FleetPolicy? {
        guard let url = policyURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FleetPolicy.self, from: data)
    }

    public func policyData(named name: String) -> Data? {
        guard let url = policyURL(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func putPolicy(_ policy: FleetPolicy, named name: String, now: Date = Date()) throws {
        guard let url = policyURL(name) else { throw HubStoreError.badName(name) }
        try policy.validate()
        try policy.encoded().write(to: url, options: .atomic)
        lock.lock(); defer { lock.unlock() }
        appendEventLocked(HubEvent(time: now, kind: .policyUpdated, host: nil, message: "policy '\(name)' updated", bytes: nil))
    }

    @discardableResult
    public func removePolicy(named name: String, now: Date = Date()) -> Bool {
        guard let url = policyURL(name), FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        lock.lock(); defer { lock.unlock() }
        appendEventLocked(HubEvent(time: now, kind: .policyRemoved, host: nil, message: "policy '\(name)' removed", bytes: nil))
        return true
    }

    func policyURL(_ name: String) -> URL? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ allowed.contains($0) }), !name.hasPrefix(".") else { return nil }
        return policiesDir.appendingPathComponent(name + ".json")
    }

    // MARK: Events

    private func appendEventLocked(_ e: HubEvent) {
        guard let line = try? HubJSON.encoder.encode(e) else { return }
        if !FileManager.default.fileExists(atPath: eventsURL.path) { try? Data().write(to: eventsURL) }
        if let h = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line + Data("\n".utf8))
        }
    }

    public func appendEvent(_ e: HubEvent) {
        lock.lock(); defer { lock.unlock() }
        appendEventLocked(e)
    }

    public func events(last n: Int = 50) -> [HubEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(n)
        return lines.compactMap { try? HubJSON.decoder.decode(HubEvent.self, from: Data($0.utf8)) }.reversed()
    }

    static func humanDuration(_ t: TimeInterval) -> String {
        if t < 3600 { return "\(Int(t / 60)) min" }
        if t < 86_400 { return "\(Int(t / 3600)) h" }
        return "\(Int(t / 86_400)) d"
    }
}

public enum HubStoreError: Error, LocalizedError {
    case badName(String)
    public var errorDescription: String? {
        switch self {
        case .badName(let n): return "'\(n)' is not a valid policy name (letters, digits, - _ . only)"
        }
    }
}
