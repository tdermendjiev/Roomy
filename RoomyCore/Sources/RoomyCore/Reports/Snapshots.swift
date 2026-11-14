//
//  Snapshots.swift
//  RoomyCore
//
//  What is filling the disk, over time. A snapshot is a compact copy of a scan report (every
//  finding with its size) plus, optionally, the sizes of the directories under a few roots.
//  Snapshots are saved on a schedule (`roomy scan --snapshot`); `GrowthReport` compares two of
//  them and says what grew, what shrank, what is new and what is gone.
//
//  Both shapes leave the process (`roomy growth --json`, snapshot files on disk), so changes
//  are additive only.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum RoomySnapshotSchema {
    public static let version = 1
}

public struct DiskSnapshot: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var label: String
        public var bytes: Int64
        public var tier: ArtifactSafetyTier
        public var category: String
        public var ruleID: String?

        public init(id: String, path: String, label: String, bytes: Int64, tier: ArtifactSafetyTier, category: String, ruleID: String?) {
            self.id = id; self.path = path; self.label = label; self.bytes = bytes; self.tier = tier
            self.category = category; self.ruleID = ruleID
        }

        public init(_ r: ScanReportItem) {
            self.init(id: r.id, path: r.path, label: r.label, bytes: r.bytes, tier: r.tier, category: r.category, ruleID: r.ruleID)
        }
    }

    /// The recursive size of one directory. `depth` 0 is a surveyed root.
    public struct Dir: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: Int64
        public var depth: Int

        public init(path: String, bytes: Int64, depth: Int) {
            self.path = path; self.bytes = bytes; self.depth = depth
        }
    }

    public var schemaVersion: Int
    public var roomyVersion: String
    public var takenAt: Date
    public var host: String
    public var platform: RoomyPlatform
    public var home: String
    public var scanRoot: String
    public var volume: RoomyVolumeSpaceReader.Space?
    /// Reclaimable bytes: the sum of `items`.
    public var totalBytes: Int64
    public var bytesByTier: [String: Int64]
    public var bytesByCategory: [String: Int64]
    public var items: [Item]
    /// Directory sizes, when the snapshot was taken with a directory survey. Nil otherwise.
    public var dirs: [Dir]?
    /// Directories smaller than this were left out of `dirs`.
    public var dirMinBytes: Int64?

    public init(report: ScanReport, dirs: [Dir]? = nil, dirMinBytes: Int64? = nil) {
        schemaVersion = RoomySnapshotSchema.version
        roomyVersion = report.roomyVersion
        takenAt = report.generatedAt
        host = report.host
        platform = report.platform
        home = report.home
        scanRoot = report.scanRoot
        volume = report.volume
        totalBytes = report.totalBytes
        bytesByTier = report.bytesByTier
        bytesByCategory = report.bytesByCategory
        items = report.items.map(Item.init)
        self.dirs = dirs
        self.dirMinBytes = dirs == nil ? nil : dirMinBytes
    }

    public init(takenAt: Date, host: String, platform: RoomyPlatform = .current, home: String, scanRoot: String,
                volume: RoomyVolumeSpaceReader.Space?, items: [Item], dirs: [Dir]? = nil, dirMinBytes: Int64? = nil,
                roomyVersion: String = RoomyCoreInfo.version) {
        schemaVersion = RoomySnapshotSchema.version
        self.roomyVersion = roomyVersion
        self.takenAt = takenAt
        self.host = host
        self.platform = platform
        self.home = home
        self.scanRoot = scanRoot
        self.volume = volume
        self.items = items
        totalBytes = items.reduce(0) { $0 + $1.bytes }
        var byTier: [String: Int64] = [:], byCategory: [String: Int64] = [:]
        for i in items {
            byTier[i.tier.rawValue, default: 0] += i.bytes
            byCategory[i.category, default: 0] += i.bytes
        }
        bytesByTier = byTier
        bytesByCategory = byCategory
        self.dirs = dirs
        self.dirMinBytes = dirs == nil ? nil : dirMinBytes
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // compact: these files accumulate
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    public static func load(from url: URL) throws -> DiskSnapshot {
        try ScanReport.decoder.decode(DiskSnapshot.self, from: Data(contentsOf: url))
    }
}

// MARK: - Directory survey

/// Recursive sizes of the directories under a root, down to a fixed depth. One walk per root.
/// Sizes are file sizes, the same measure the scanner uses for findings, so the two compare.
public enum DirectorySizeSurvey {
    public static let defaultDepth = 2
    public static let defaultMinBytes: Int64 = 1_048_576

    /// - Parameters:
    ///   - depth: how many levels below each root get their own entry. Deeper files still count toward their ancestors.
    ///   - minBytes: directories smaller than this are left out. Roots are always kept.
    /// Other filesystems mounted below a root are not entered, and symlinks are not followed.
    public static func survey(roots: [URL], depth: Int = defaultDepth, minBytes: Int64 = defaultMinBytes,
                              shouldCancel: () -> Bool = { false }) -> [DiskSnapshot.Dir] {
        var out: [DiskSnapshot.Dir] = []
        var seen = Set<String>()
        for root in roots {
            let r = canonical(root)
            guard seen.insert(r.path).inserted else { continue }
            out.append(contentsOf: survey(root: r, depth: max(0, depth), minBytes: minBytes, shouldCancel: shouldCancel))
        }
        return out
    }

    /// The real path of a root, symlinks resolved. The enumerator reports real paths for what it finds
    /// (on macOS `/var/…` comes back as `/private/var/…`), and so does the scanner for findings, so the
    /// root has to be in the same form for the three to line up.
    private static func canonical(_ url: URL) -> URL {
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    private static func device(_ path: String, fm: FileManager) -> Int? {
        ((try? fm.attributesOfItem(atPath: path))?[.systemNumber] as? NSNumber)?.intValue
    }

    private static func survey(root: URL, depth: Int, minBytes: Int64, shouldCancel: () -> Bool) -> [DiskSnapshot.Dir] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let rootDevice = device(root.path, fm: fm)
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return [DiskSnapshot.Dir(path: root.path, bytes: 0, depth: 0)]
        }
        var rootBytes: Int64 = 0
        // Open ancestors of the entry being visited, one per level (index 0 is level 1), down to `depth`.
        var open: [Int] = []
        var entries: [DiskSnapshot.Dir] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count % 4096 == 0, shouldCancel() { break }
            let level = enumerator.level
            if open.count > level - 1 { open.removeLast(open.count - (level - 1)) }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if let rootDevice, let d = device(url.path, fm: fm), d != rootDevice {
                    enumerator.skipDescendants()
                    continue
                }
                if level <= depth {
                    entries.append(DiskSnapshot.Dir(path: url.path, bytes: 0, depth: level))
                    open.append(entries.count - 1)
                }
            } else if v.isRegularFile == true {
                let size = Int64(v.fileSize ?? 0)
                rootBytes += size
                for i in open { entries[i].bytes += size }
            }
        }
        return [DiskSnapshot.Dir(path: root.path, bytes: rootBytes, depth: 0)] + entries.filter { $0.bytes >= minBytes }
    }
}

// MARK: - Store

/// A directory of snapshot files, one per scan, named by time.
public struct SnapshotStore: Sendable {
    public struct Entry: Sendable, Equatable {
        public var url: URL
        public var takenAt: Date
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `$ROOMY_SNAPSHOT_DIR`, or `~/.roomy/snapshots`.
    public static func defaultDirectory(home: URL = RoomyHost.homeDirectory) -> URL {
        if let env = ProcessInfo.processInfo.environment["ROOMY_SNAPSHOT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".roomy/snapshots", isDirectory: true)
    }

    private static let prefix = "snapshot-", suffix = ".json"

    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }

    public static func fileName(for date: Date) -> String { prefix + stampFormatter().string(from: date) + suffix }

    @discardableResult
    public func save(_ snapshot: DiskSnapshot) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(for: snapshot.takenAt))
        try snapshot.encoded().write(to: url, options: .atomic)
        return url
    }

    /// Snapshots in the directory, oldest first. Files that are not named like a snapshot are ignored.
    public func list() -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let f = Self.stampFormatter()
        return names.compactMap { name -> Entry? in
            guard name.hasPrefix(Self.prefix), name.hasSuffix(Self.suffix) else { return nil }
            let stamp = String(name.dropFirst(Self.prefix.count).dropLast(Self.suffix.count))
            guard let date = f.date(from: stamp) else { return nil }
            return Entry(url: directory.appendingPathComponent(name), takenAt: date)
        }.sorted { $0.takenAt < $1.takenAt }
    }

    public func latest() -> Entry? { list().last }

    /// The snapshot taken closest to `date`, looking only at ones older than `before`.
    public func closest(to date: Date, before: Date) -> Entry? {
        list().filter { $0.takenAt < before }
            .min { abs($0.takenAt.timeIntervalSince(date)) < abs($1.takenAt.timeIntervalSince(date)) }
    }

    /// Thins old snapshots: everything from the last `keepAllDays` stays, then one per calendar week
    /// (the oldest of that week) up to `keepWeeklyDays`, and anything older goes. Returns what was removed.
    @discardableResult
    public func prune(now: Date = Date(), keepAllDays: Int = 14, keepWeeklyDays: Int = 365) -> [Entry] {
        let day: TimeInterval = 86_400
        var removed: [Entry] = []
        var weeksKept = Set<Int>()
        for e in list() {
            let age = now.timeIntervalSince(e.takenAt)
            if age <= Double(keepAllDays) * day { continue }
            let week = Int((e.takenAt.timeIntervalSince1970 / (7 * day)).rounded(.down))
            if age <= Double(keepWeeklyDays) * day, weeksKept.insert(week).inserted { continue }
            if (try? FileManager.default.removeItem(at: e.url)) != nil { removed.append(e) }
        }
        return removed
    }
}

// MARK: - Growth

/// What changed between two snapshots.
public struct GrowthReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case grew, shrank
        /// Not in the earlier snapshot.
        case new
        /// Not in the later snapshot: removed, cleaned, or no longer matched by a rule.
        case gone
    }

    public struct Change: Codable, Sendable, Equatable {
        public var fromBytes: Int64
        public var toBytes: Int64
        public var deltaBytes: Int64 { toBytes - fromBytes }

        public init(fromBytes: Int64, toBytes: Int64) { self.fromBytes = fromBytes; self.toBytes = toBytes }

        enum CodingKeys: String, CodingKey { case fromBytes, toBytes, deltaBytes }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fromBytes = try c.decode(Int64.self, forKey: .fromBytes)
            toBytes = try c.decode(Int64.self, forKey: .toBytes)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(fromBytes, forKey: .fromBytes)
            try c.encode(toBytes, forKey: .toBytes)
            try c.encode(deltaBytes, forKey: .deltaBytes)
        }
    }

    public struct VolumeChange: Codable, Sendable, Equatable {
        public var totalBytes: Int64
        public var fromAvailableBytes: Int64
        public var toAvailableBytes: Int64
        /// Positive when the disk got fuller.
        public var usedDeltaBytes: Int64
    }

    public struct CategoryChange: Codable, Sendable, Equatable {
        public var category: String
        public var fromBytes: Int64
        public var toBytes: Int64
        public var deltaBytes: Int64
    }

    public struct ItemChange: Codable, Sendable, Equatable {
        public var path: String
        public var label: String
        public var category: String
        public var tier: ArtifactSafetyTier
        public var ruleID: String?
        public var status: Status
        public var fromBytes: Int64
        public var toBytes: Int64
        public var deltaBytes: Int64
    }

    public struct DirChange: Codable, Sendable, Equatable {
        public var path: String
        public var depth: Int
        public var status: Status
        public var fromBytes: Int64
        public var toBytes: Int64
        public var deltaBytes: Int64
        /// How much of `deltaBytes` comes from findings inside this directory. The rest is not a Roomy target.
        public var reclaimableDeltaBytes: Int64
    }

    public var schemaVersion: Int
    public var host: String
    public var home: String
    public var from: Date
    public var to: Date
    public var seconds: Double
    /// Reasons the two snapshots may not compare cleanly (different host, different scan root).
    public var warnings: [String]
    public var volume: VolumeChange?
    /// Everything Roomy's rules and probes matched.
    public var reclaimable: Change
    /// Growth in used disk space that the findings do not account for. Nil without volume data.
    public var untrackedDeltaBytes: Int64?
    /// Changes smaller than this were left out of `items` and `dirs`.
    public var minDeltaBytes: Int64
    public var categories: [CategoryChange]
    /// Largest growth first, largest shrinkage last.
    public var items: [ItemChange]
    /// Present when both snapshots carry a directory survey.
    public var dirs: [DirChange]?

    public init(from a: DiskSnapshot, to b: DiskSnapshot, minDeltaBytes: Int64 = 1_048_576) {
        schemaVersion = RoomySnapshotSchema.version
        host = b.host
        home = b.home
        from = a.takenAt
        to = b.takenAt
        seconds = b.takenAt.timeIntervalSince(a.takenAt)
        self.minDeltaBytes = minDeltaBytes

        var warnings: [String] = []
        if a.host != b.host { warnings.append("snapshots are from different hosts (\(a.host), \(b.host))") }
        if a.scanRoot != b.scanRoot { warnings.append("snapshots scanned different roots (\(a.scanRoot), \(b.scanRoot))") }
        if (a.dirs == nil) != (b.dirs == nil) { warnings.append("only one snapshot has a directory survey; directories are not compared") }
        self.warnings = warnings

        if let va = a.volume, let vb = b.volume {
            volume = VolumeChange(totalBytes: vb.totalBytes, fromAvailableBytes: va.availableBytes, toAvailableBytes: vb.availableBytes,
                                  usedDeltaBytes: vb.usedBytes - va.usedBytes)
        }
        reclaimable = Change(fromBytes: a.totalBytes, toBytes: b.totalBytes)
        untrackedDeltaBytes = volume.map { $0.usedDeltaBytes - (b.totalBytes - a.totalBytes) }

        categories = Set(a.bytesByCategory.keys).union(b.bytesByCategory.keys).map { k in
            let x = a.bytesByCategory[k] ?? 0, y = b.bytesByCategory[k] ?? 0
            return CategoryChange(category: k, fromBytes: x, toBytes: y, deltaBytes: y - x)
        }.filter { $0.deltaBytes != 0 }.sorted { ($0.deltaBytes, $1.category) > ($1.deltaBytes, $0.category) }

        // Items are matched by path. Two findings can share a path only in theory; sizes are summed if they do.
        var before: [String: DiskSnapshot.Item] = [:], after: [String: DiskSnapshot.Item] = [:]
        for i in a.items { if var e = before[i.path] { e.bytes += i.bytes; before[i.path] = e } else { before[i.path] = i } }
        for i in b.items { if var e = after[i.path] { e.bytes += i.bytes; after[i.path] = e } else { after[i.path] = i } }
        var allItems: [ItemChange] = []
        for path in Set(before.keys).union(after.keys) {
            let x = before[path], y = after[path]
            guard let meta = y ?? x else { continue }
            let fromBytes = x?.bytes ?? 0, toBytes = y?.bytes ?? 0
            let delta = toBytes - fromBytes
            let status: Status = x == nil ? .new : y == nil ? .gone : delta >= 0 ? .grew : .shrank
            allItems.append(ItemChange(path: path, label: meta.label, category: meta.category, tier: meta.tier, ruleID: meta.ruleID,
                                       status: status, fromBytes: fromBytes, toBytes: toBytes, deltaBytes: delta))
        }
        items = allItems.filter { abs($0.deltaBytes) >= minDeltaBytes && $0.deltaBytes != 0 }
            .sorted { ($0.deltaBytes, $1.path) > ($1.deltaBytes, $0.path) }

        if let da = a.dirs, let db = b.dirs {
            let x = Dictionary(da.map { ($0.path, $0) }, uniquingKeysWith: { l, _ in l })
            let y = Dictionary(db.map { ($0.path, $0) }, uniquingKeysWith: { l, _ in l })
            var out: [DirChange] = []
            for path in Set(x.keys).union(y.keys) {
                let p = x[path], q = y[path]
                let fromBytes = p?.bytes ?? 0, toBytes = q?.bytes ?? 0
                let delta = toBytes - fromBytes
                guard delta != 0, abs(delta) >= minDeltaBytes else { continue }
                // Absent means missing or under the survey's size floor; either way it was next to nothing.
                let status: Status = p == nil ? .new : q == nil ? .gone : delta > 0 ? .grew : .shrank
                let prefix = path.hasSuffix("/") ? path : path + "/"
                let inside = allItems.filter { $0.path == path || $0.path.hasPrefix(prefix) }.reduce(Int64(0)) { $0 + $1.deltaBytes }
                out.append(DirChange(path: path, depth: (q ?? p)?.depth ?? 0, status: status, fromBytes: fromBytes, toBytes: toBytes,
                                     deltaBytes: delta, reclaimableDeltaBytes: inside))
            }
            dirs = out.sorted { ($0.deltaBytes, $1.path) > ($1.deltaBytes, $0.path) }
        }
    }

    public func encoded() throws -> Data { try ScanReport.encoder.encode(self) }
}
