//
//  AuditLog.swift
//  RoomyFleet
//
//  Append-only JSON Lines. Every record carries the SHA-256 of the previous record, so a
//  truncated or edited log fails `verify`. Shippable as-is to a SIEM.
//

import Foundation
import Crypto
import RoomyCore

public struct AuditRecord: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case runStarted, scanCompleted, planned, disposed, disposeFailed, skipped, purged, runFinished, error, licenseChecked, hubReported
    }

    public var seq: Int
    public var time: Date
    public var host: String
    public var runID: String
    public var event: Event
    public var actor: String
    public var edition: String
    public var policy: String?
    public var path: String?
    public var bytes: Int64?
    public var tier: ArtifactSafetyTier?
    public var category: String?
    public var ruleID: String?
    public var method: DisposalMethod?
    public var destination: String?
    public var reason: String?
    public var message: String?
    /// True for records written by a dry run: `disposed` events then describe what would have been removed.
    public var dryRun: Bool?
    public var prevHash: String
    public var hash: String?

    public init(seq: Int, time: Date = Date(), host: String = RoomyHost.name, runID: String, event: Event, actor: String,
                edition: String, policy: String? = nil, path: String? = nil, bytes: Int64? = nil, tier: ArtifactSafetyTier? = nil,
                category: String? = nil, ruleID: String? = nil, method: DisposalMethod? = nil, destination: String? = nil,
                reason: String? = nil, message: String? = nil, dryRun: Bool? = nil, prevHash: String) {
        self.seq = seq; self.time = time; self.host = host; self.runID = runID; self.event = event; self.actor = actor
        self.edition = edition; self.policy = policy; self.path = path; self.bytes = bytes; self.tier = tier; self.category = category
        self.ruleID = ruleID; self.method = method; self.destination = destination; self.reason = reason; self.message = message
        self.dryRun = dryRun; self.prevHash = prevHash; self.hash = nil
    }

    /// Logs written before 1.3.0 carried only the message.
    public var isDryRun: Bool { dryRun == true || message == "dry run" }
}

public final class AuditLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var seq: Int
    private var lastHash: String

    public static let genesisHash = String(repeating: "0", count: 64)

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let last = try Self.lastRecord(in: url) {
            seq = last.seq
            lastHash = last.hash ?? Self.genesisHash
        } else {
            seq = 0
            lastHash = Self.genesisHash
        }
    }

    /// Appends a record, filling in `seq`, `prevHash` and `hash`. Returns the stored record.
    @discardableResult
    public func append(_ make: (_ seq: Int, _ prevHash: String) -> AuditRecord) throws -> AuditRecord {
        lock.lock(); defer { lock.unlock() }
        var record = make(seq + 1, lastHash)
        record.seq = seq + 1
        record.prevHash = lastHash
        record.hash = nil
        let body = try Self.encoder.encode(record)
        record.hash = Self.hash(prev: lastHash, body: body)
        let line = try Self.encoder.encode(record) + Data("\n".utf8)
        try Self.appendData(line, to: url)
        seq = record.seq
        lastHash = record.hash!
        return record
    }

    public static func hash(prev: String, body: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prev.utf8))
        hasher.update(data: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func readAll(from url: URL) throws -> [AuditRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.isEmpty }.map { try decoder.decode(AuditRecord.self, from: Data($0.utf8)) }
    }

    public struct VerifyResult: Equatable, Sendable {
        public let records: Int
        public let ok: Bool
        /// Sequence number of the first bad record, when not ok.
        public let firstBadSeq: Int?
        public let message: String
    }

    /// Recomputes the hash chain. O(n) in the log size.
    public static func verify(url: URL) -> VerifyResult {
        let records: [AuditRecord]
        do { records = try readAll(from: url) } catch {
            return VerifyResult(records: 0, ok: false, firstBadSeq: nil, message: "Cannot read log: \(error.localizedDescription)")
        }
        var prev = genesisHash
        var expectedSeq = 1
        for r in records {
            if r.seq != expectedSeq {
                return VerifyResult(records: records.count, ok: false, firstBadSeq: r.seq, message: "Sequence gap: expected \(expectedSeq), found \(r.seq)")
            }
            if r.prevHash != prev {
                return VerifyResult(records: records.count, ok: false, firstBadSeq: r.seq, message: "Broken chain at seq \(r.seq)")
            }
            var copy = r
            copy.hash = nil
            guard let body = try? encoder.encode(copy), hash(prev: prev, body: body) == r.hash else {
                return VerifyResult(records: records.count, ok: false, firstBadSeq: r.seq, message: "Hash mismatch at seq \(r.seq)")
            }
            prev = r.hash ?? ""
            expectedSeq += 1
        }
        return VerifyResult(records: records.count, ok: true, firstBadSeq: nil, message: "OK (\(records.count) records)")
    }

    /// Bytes disposed so far according to the log (for monotonic counters). Dry runs are not counted.
    public static func totals(from url: URL) -> (disposedBytes: Int64, disposedItems: Int, failures: Int, purgedBytes: Int64, runs: Int) {
        guard let records = try? readAll(from: url) else { return (0, 0, 0, 0, 0) }
        var bytes: Int64 = 0, items = 0, failures = 0, purged: Int64 = 0, runs = 0
        for r in records {
            switch r.event {
            case .disposed where r.isDryRun: break
            case .disposed: bytes += r.bytes ?? 0; items += 1
            case .disposeFailed: failures += 1
            case .purged: purged += r.bytes ?? 0
            case .runFinished: runs += 1
            default: break
            }
        }
        return (bytes, items, failures, purged, runs)
    }

    /// Sequence number and hash of the newest record, for reporting the chain head to a hub.
    public static func head(url: URL) -> (seq: Int, hash: String)? {
        guard let last = try? lastRecord(in: url) else { return nil }
        return (last.seq, last.hash ?? genesisHash)
    }

    private static func lastRecord(in url: URL) throws -> AuditRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size > 0 else { return nil }
        let window = min(size, 65_536)
        try handle.seek(toOffset: UInt64(size - window))
        let tail = handle.readDataToEndOfFile()
        guard let text = String(data: tail, encoding: .utf8) else { return nil }
        guard let lastLine = text.split(separator: "\n").last(where: { !$0.isEmpty }) else { return nil }
        return try decoder.decode(AuditRecord.self, from: Data(lastLine.utf8))
    }

    private static func appendData(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
