//
//  Metrics.swift
//  RoomyFleet
//
//  Prometheus text exposition. Written to a node_exporter textfile after every run and
//  served over HTTP by `roomy fleet serve`.
//

import Foundation
import RoomyCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FleetMetricsSnapshot: Sendable, Equatable {
    public var host: String
    public var edition: String
    public var org: String?
    public var version: String
    public var catalogVersion: String
    public var policyName: String
    public var reclaimableBytesByTier: [String: Int64]
    public var reclaimableBytesByCategory: [String: Int64]
    public var reclaimableItems: Int
    public var plannedBytes: Int64
    public var plannedItems: Int
    public var disposedBytesThisRun: Int64
    public var disposedItemsThisRun: Int
    public var failuresThisRun: Int
    public var disposedBytesTotal: Int64
    public var disposedItemsTotal: Int
    public var failuresTotal: Int
    public var purgedBytesTotal: Int64
    public var runsTotal: Int
    public var lastRunStart: Date
    public var lastRunDurationSeconds: Double
    public var lastRunSucceeded: Bool
    public var dryRun: Bool
    public var quarantineBytes: Int64
    public var quarantineItems: Int
    public var volumeTotalBytes: Int64?
    public var volumeAvailableBytes: Int64?
    public var licenseExpiresAt: Date?

    public init(host: String, edition: String, org: String?, version: String, catalogVersion: String, policyName: String,
                reclaimableBytesByTier: [String: Int64], reclaimableBytesByCategory: [String: Int64], reclaimableItems: Int,
                plannedBytes: Int64, plannedItems: Int, disposedBytesThisRun: Int64, disposedItemsThisRun: Int, failuresThisRun: Int,
                disposedBytesTotal: Int64, disposedItemsTotal: Int, failuresTotal: Int, purgedBytesTotal: Int64, runsTotal: Int,
                lastRunStart: Date, lastRunDurationSeconds: Double, lastRunSucceeded: Bool, dryRun: Bool,
                quarantineBytes: Int64, quarantineItems: Int, volumeTotalBytes: Int64?, volumeAvailableBytes: Int64?, licenseExpiresAt: Date?) {
        self.host = host; self.edition = edition; self.org = org; self.version = version; self.catalogVersion = catalogVersion; self.policyName = policyName
        self.reclaimableBytesByTier = reclaimableBytesByTier; self.reclaimableBytesByCategory = reclaimableBytesByCategory; self.reclaimableItems = reclaimableItems
        self.plannedBytes = plannedBytes; self.plannedItems = plannedItems; self.disposedBytesThisRun = disposedBytesThisRun
        self.disposedItemsThisRun = disposedItemsThisRun; self.failuresThisRun = failuresThisRun; self.disposedBytesTotal = disposedBytesTotal
        self.disposedItemsTotal = disposedItemsTotal; self.failuresTotal = failuresTotal; self.purgedBytesTotal = purgedBytesTotal; self.runsTotal = runsTotal
        self.lastRunStart = lastRunStart; self.lastRunDurationSeconds = lastRunDurationSeconds; self.lastRunSucceeded = lastRunSucceeded; self.dryRun = dryRun
        self.quarantineBytes = quarantineBytes; self.quarantineItems = quarantineItems; self.volumeTotalBytes = volumeTotalBytes
        self.volumeAvailableBytes = volumeAvailableBytes; self.licenseExpiresAt = licenseExpiresAt
    }
}

public enum PrometheusRenderer {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func labels(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: ",") + "}"
    }

    public static func render(_ m: FleetMetricsSnapshot) -> String {
        var out: [String] = []
        let base = [("host", m.host), ("policy", m.policyName)]
        func gauge(_ name: String, _ help: String, _ rows: [([(String, String)], String)]) {
            out.append("# HELP \(name) \(help)")
            out.append("# TYPE \(name) gauge")
            for (l, v) in rows { out.append("\(name)\(labels(base + l)) \(v)") }
        }
        func counter(_ name: String, _ help: String, _ rows: [([(String, String)], String)]) {
            out.append("# HELP \(name) \(help)")
            out.append("# TYPE \(name) counter")
            for (l, v) in rows { out.append("\(name)\(labels(base + l)) \(v)") }
        }

        gauge("roomy_build_info", "Roomy version and rule catalog. Always 1.",
              [([("version", m.version), ("catalog", m.catalogVersion), ("edition", m.edition), ("org", m.org ?? "")], "1")])
        gauge("roomy_reclaimable_bytes", "Bytes Roomy could reclaim on this host, by safety tier.",
              ArtifactSafetyTier.allCases.map { ([("tier", $0.rawValue)], "\(m.reclaimableBytesByTier[$0.rawValue] ?? 0)") })
        gauge("roomy_reclaimable_bytes_by_category", "Bytes Roomy could reclaim on this host, by category.",
              m.reclaimableBytesByCategory.keys.sorted().map { ([("category", $0)], "\(m.reclaimableBytesByCategory[$0] ?? 0)") })
        gauge("roomy_reclaimable_items", "Findings in the last scan.", [([], "\(m.reclaimableItems)")])
        gauge("roomy_planned_bytes", "Bytes the policy selected for removal in the last run.", [([], "\(m.plannedBytes)")])
        gauge("roomy_planned_items", "Items the policy selected for removal in the last run.", [([], "\(m.plannedItems)")])
        gauge("roomy_last_run_disposed_bytes", "Bytes removed in the last run.", [([], "\(m.disposedBytesThisRun)")])
        gauge("roomy_last_run_failures", "Disposal failures in the last run.", [([], "\(m.failuresThisRun)")])
        counter("roomy_disposed_bytes_total", "Bytes removed by Roomy on this host since the audit log began.", [([], "\(m.disposedBytesTotal)")])
        counter("roomy_disposed_items_total", "Items removed by Roomy on this host since the audit log began.", [([], "\(m.disposedItemsTotal)")])
        counter("roomy_dispose_failures_total", "Disposal failures since the audit log began.", [([], "\(m.failuresTotal)")])
        counter("roomy_purged_bytes_total", "Bytes permanently freed from quarantine or trash since the audit log began.", [([], "\(m.purgedBytesTotal)")])
        counter("roomy_runs_total", "Completed policy runs since the audit log began.", [([], "\(m.runsTotal)")])
        gauge("roomy_last_run_timestamp_seconds", "Start time of the last run.", [([], String(format: "%.0f", m.lastRunStart.timeIntervalSince1970))])
        gauge("roomy_last_run_duration_seconds", "Wall time of the last run.", [([], String(format: "%.3f", m.lastRunDurationSeconds))])
        gauge("roomy_last_run_success", "1 if the last run completed without disposal failures.", [([], m.lastRunSucceeded ? "1" : "0")])
        gauge("roomy_dry_run", "1 if the policy runs in dry-run mode.", [([], m.dryRun ? "1" : "0")])
        gauge("roomy_quarantine_bytes", "Bytes currently held in Roomy's quarantine.", [([], "\(m.quarantineBytes)")])
        gauge("roomy_quarantine_items", "Items currently held in Roomy's quarantine.", [([], "\(m.quarantineItems)")])
        if let t = m.volumeTotalBytes { gauge("roomy_volume_total_bytes", "Size of the volume holding the scan root.", [([], "\(t)")]) }
        if let a = m.volumeAvailableBytes { gauge("roomy_volume_available_bytes", "Free space on the volume holding the scan root.", [([], "\(a)")]) }
        if let e = m.licenseExpiresAt {
            gauge("roomy_license_expiry_timestamp_seconds", "When the fleet license expires.", [([], String(format: "%.0f", e.timeIntervalSince1970))])
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Atomic write for the node_exporter textfile collector: write a sibling temp file, then rename(2) over the target.
    public static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))])
        }
    }
}
