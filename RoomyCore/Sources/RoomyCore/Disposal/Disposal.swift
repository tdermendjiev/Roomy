//
//  Disposal.swift
//  RoomyCore
//
//  How a finding leaves the disk. Trash on macOS, freedesktop Trash or a quarantine
//  directory on Linux, or a permanent delete. CLI-managed targets (docker:, conda:, pip:)
//  go through their tool regardless of method.
//

import Foundation

public enum DisposalMethod: String, Codable, Sendable, CaseIterable, Equatable {
    /// Finder Trash (macOS) or freedesktop Trash (Linux). Reversible by the user, not reclaimed until emptied.
    case trash
    /// Move into a Roomy-managed quarantine directory on the same volume; purged after a retention period.
    case quarantine
    /// `rm -rf` equivalent. Reclaims space immediately.
    case delete

    public var displayLabel: String {
        switch self {
        case .trash: return "Move to Trash"
        case .quarantine: return "Quarantine"
        case .delete: return "Delete permanently"
        }
    }
}

public struct RoomyDeletionFailure: Error, Equatable, Identifiable, Sendable, Codable {
    public var id: String { path }
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// What happened to one item.
public struct DisposalReceipt: Equatable, Sendable, Codable {
    public let path: String
    public let method: DisposalMethod
    /// Where the item went (trash or quarantine location), when applicable.
    public let destination: String?
    public let bytes: Int64?
    public let at: Date

    public init(path: String, method: DisposalMethod, destination: String?, bytes: Int64?, at: Date = Date()) {
        self.path = path
        self.method = method
        self.destination = destination
        self.bytes = bytes
        self.at = at
    }
}

public struct DisposalOutcome: Sendable, Equatable {
    public var receipts: [DisposalReceipt] = []
    public var failures: [RoomyDeletionFailure] = []

    public init(receipts: [DisposalReceipt] = [], failures: [RoomyDeletionFailure] = []) {
        self.receipts = receipts
        self.failures = failures
    }
}

public struct QuarantineConfig: Codable, Sendable, Equatable {
    /// Where quarantined items live. Default: `~/.roomy/quarantine` (or `$ROOMY_QUARANTINE_DIR`).
    public var directory: URL
    public var retentionDays: Int

    public init(directory: URL, retentionDays: Int = 7) {
        self.directory = directory
        self.retentionDays = retentionDays
    }

    public static func `default`(home: URL = RoomyHost.homeDirectory) -> QuarantineConfig {
        if let env = ProcessInfo.processInfo.environment["ROOMY_QUARANTINE_DIR"], !env.isEmpty {
            return QuarantineConfig(directory: URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true))
        }
        return QuarantineConfig(directory: home.appendingPathComponent(".roomy/quarantine", isDirectory: true))
    }
}

public enum RoomyDeletionService {
    // MARK: App-facing API (unchanged semantics)

    /// Deletes a single item — filesystem folder or CLI-managed target.
    public static func deleteItem(path: String, moveToTrash: Bool) async -> [RoomyDeletionFailure] {
        await dispose(paths: [path], method: moveToTrash ? .trash : .delete).failures
    }

    /// Deletes each path in order on a background thread; reports per-path failures.
    public static func delete(folderPaths: [String], moveToTrash: Bool) async -> [RoomyDeletionFailure] {
        await dispose(paths: folderPaths, method: moveToTrash ? .trash : .delete).failures
    }

    // MARK: Full API

    public static func dispose(
        paths: [String],
        method: DisposalMethod,
        quarantine: QuarantineConfig? = nil,
        dryRun: Bool = false
    ) async -> DisposalOutcome {
        await Task.detached(priority: .userInitiated) {
            disposeSync(paths: paths, method: method, quarantine: quarantine, dryRun: dryRun)
        }.value
    }

    public static func disposeSync(
        paths: [String],
        method: DisposalMethod,
        quarantine: QuarantineConfig? = nil,
        dryRun: Bool = false
    ) -> DisposalOutcome {
        var outcome = DisposalOutcome()
        for path in paths {
            let result = disposeOne(path: path, method: method, quarantine: quarantine ?? .default(), dryRun: dryRun)
            switch result {
            case .success(let receipt): outcome.receipts.append(receipt)
            case .failure(let failure): outcome.failures.append(failure)
            }
        }
        return outcome
    }

    private static func disposeOne(path: String, method: DisposalMethod, quarantine: QuarantineConfig, dryRun: Bool) -> Result<DisposalReceipt, RoomyDeletionFailure> {
        if path.hasPrefix("docker:") { return CLITargetDisposer.docker(path: path, dryRun: dryRun) }
        if path.hasPrefix("conda:") { return CLITargetDisposer.conda(path: path, dryRun: dryRun) }
        if path.hasPrefix("pip:orphan:") { return CLITargetDisposer.pipOrphan(path: path, dryRun: dryRun) }

        let expanded = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return .failure(RoomyDeletionFailure(path: path, message: "Path not found"))
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: isDir.boolValue)
        let bytes: Int64? = isDir.boolValue ? RoomyDirectorySizeReader.bytes(at: url, timeout: 30) : RoomyDirectorySizeReader.fileBytes(at: url)

        if dryRun {
            return .success(DisposalReceipt(path: expanded, method: method, destination: nil, bytes: bytes))
        }

        do {
            switch method {
            case .trash:
                let dest = try TrashDisposer.trash(url: url)
                return .success(DisposalReceipt(path: expanded, method: .trash, destination: dest?.path, bytes: bytes))
            case .quarantine:
                let dest = try QuarantineDisposer(config: quarantine).quarantine(url: url, originalPath: expanded)
                return .success(DisposalReceipt(path: expanded, method: .quarantine, destination: dest.path, bytes: bytes))
            case .delete:
                try fm.removeItem(at: url)
                return .success(DisposalReceipt(path: expanded, method: .delete, destination: nil, bytes: bytes))
            }
        } catch {
            return .failure(RoomyDeletionFailure(path: path, message: error.localizedDescription))
        }
    }

    /// Empties the user Trash via Finder (macOS only; may prompt for permissions on some macOS versions).
    public static func emptyTrashViaFinder() async -> Bool {
        #if os(macOS)
        return await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(executable: "/usr/bin/osascript",
                              arguments: ["-e", #"tell application "Finder" to empty trash"#], timeout: 60)?.succeeded ?? false
        }.value
        #else
        return false
        #endif
    }
}

// MARK: - Trash

public enum TrashDisposer {
    /// Moves to the platform trash. Returns the trashed location when known.
    public static func trash(url: URL) throws -> URL? {
        #if os(macOS)
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
        return trashURL?.absoluteURL
        #else
        return try FreedesktopTrash.trash(url: url)
        #endif
    }
}

/// freedesktop.org Trash specification, enough for a headless host:
/// `$XDG_DATA_HOME/Trash/{files,info}` for the home volume, `<mount>/.Trash-<uid>/{files,info}` for others.
public enum FreedesktopTrash {
    public struct Location: Equatable {
        public let files: URL
        public let info: URL
    }

    public static func location(for url: URL, home: URL = RoomyHost.homeDirectory) throws -> Location {
        let fm = FileManager.default
        let homeDev = deviceID(of: home)
        let itemDev = deviceID(of: url.deletingLastPathComponent())
        let base: URL
        if homeDev == nil || itemDev == nil || homeDev == itemDev {
            let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".local/share", isDirectory: true)
            base = xdg.appendingPathComponent("Trash", isDirectory: true)
        } else {
            let mount = mountPoint(of: url)
            base = mount.appendingPathComponent(".Trash-\(getuid())", isDirectory: true)
        }
        let files = base.appendingPathComponent("files", isDirectory: true)
        let info = base.appendingPathComponent("info", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: info, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return Location(files: files, info: info)
    }

    public static func trash(url: URL, home: URL = RoomyHost.homeDirectory, now: Date = Date()) throws -> URL {
        let loc = try location(for: url, home: home)
        let fm = FileManager.default
        var name = url.lastPathComponent
        var attempt = 1
        while fm.fileExists(atPath: loc.files.appendingPathComponent(name).path)
            || fm.fileExists(atPath: loc.info.appendingPathComponent(name + ".trashinfo").path) {
            attempt += 1
            name = "\(url.lastPathComponent).\(attempt)"
        }
        let dest = loc.files.appendingPathComponent(name)
        let infoFile = loc.info.appendingPathComponent(name + ".trashinfo")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let info = "[Trash Info]\nPath=\(encodedPath)\nDeletionDate=\(formatter.string(from: now))\n"
        try info.write(to: infoFile, atomically: true, encoding: .utf8)
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            try? fm.removeItem(at: infoFile)
            throw error
        }
        return dest
    }

    /// Total bytes in a trash `files` directory, for reporting.
    public static func bytes(in location: Location) -> Int64 {
        RoomyDirectorySizeReader.bytes(at: location.files) ?? 0
    }

    /// Removes trashed items older than `days`. Returns receipts.
    public static func purge(location: Location, olderThanDays days: Int, now: Date = Date()) -> DisposalOutcome {
        var outcome = DisposalOutcome()
        let fm = FileManager.default
        guard let infos = try? fm.contentsOfDirectory(at: location.info, includingPropertiesForKeys: nil) else { return outcome }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        for info in infos where info.pathExtension == "trashinfo" {
            guard let text = try? String(contentsOf: info, encoding: .utf8) else { continue }
            var deletionDate: Date? = nil
            for line in text.split(separator: "\n") where line.hasPrefix("DeletionDate=") {
                deletionDate = formatter.date(from: String(line.dropFirst("DeletionDate=".count)))
            }
            guard let deletionDate, deletionDate < cutoff else { continue }
            let name = info.deletingPathExtension().lastPathComponent
            let item = location.files.appendingPathComponent(name)
            let bytes = RoomyDirectorySizeReader.bytes(at: item, timeout: 30)
            do {
                if fm.fileExists(atPath: item.path) { try fm.removeItem(at: item) }
                try fm.removeItem(at: info)
                outcome.receipts.append(DisposalReceipt(path: item.path, method: .delete, destination: nil, bytes: bytes, at: now))
            } catch {
                outcome.failures.append(RoomyDeletionFailure(path: item.path, message: error.localizedDescription))
            }
        }
        return outcome
    }

    static func deviceID(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let dev = attrs[.systemNumber] as? NSNumber else { return nil }
        return dev.uint64Value
    }

    static func mountPoint(of url: URL) -> URL {
        var cursor = url.standardizedFileURL
        let dev = deviceID(of: cursor)
        while cursor.path != "/" {
            let parent = cursor.deletingLastPathComponent()
            if deviceID(of: parent) != dev { return cursor }
            cursor = parent
        }
        return cursor
    }
}

// MARK: - Quarantine

/// A Roomy-managed holding area: items are moved (same volume, instant) and purged after `retentionDays`.
/// Each item has a sidecar `<name>.roomy.json` recording where it came from.
public struct QuarantineDisposer: Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public var originalPath: String
        public var quarantinedAt: Date
        public var bytes: Int64?
        public var host: String
    }

    public let config: QuarantineConfig

    public init(config: QuarantineConfig) {
        self.config = config
    }

    public func quarantine(url: URL, originalPath: String, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        // Keep quarantine on the same volume as the item so the move is a rename, not a copy.
        let dir = quarantineDirectory(for: url)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = Self.stamp(now)
        var name = "\(stamp)-\(url.lastPathComponent)"
        var n = 1
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            n += 1
            name = "\(stamp)-\(url.lastPathComponent).\(n)"
        }
        let dest = dir.appendingPathComponent(name)
        let bytes = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? RoomyDirectorySizeReader.bytes(at: url, timeout: 30)
            : RoomyDirectorySizeReader.fileBytes(at: url)
        let manifest = Manifest(originalPath: originalPath, quarantinedAt: now, bytes: bytes, host: RoomyHost.name)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: dir.appendingPathComponent(name + ".roomy.json"), options: .atomic)
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    /// `~/.roomy/quarantine` for the home volume; `<mount>/.roomy-quarantine` for other volumes.
    public func quarantineDirectory(for url: URL) -> URL {
        let homeDev = FreedesktopTrash.deviceID(of: config.directory.deletingLastPathComponent())
            ?? FreedesktopTrash.deviceID(of: RoomyHost.homeDirectory)
        let itemDev = FreedesktopTrash.deviceID(of: url.deletingLastPathComponent())
        if homeDev == nil || itemDev == nil || homeDev == itemDev { return config.directory }
        return FreedesktopTrash.mountPoint(of: url).appendingPathComponent(".roomy-quarantine", isDirectory: true)
    }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let manifest: Manifest
    }

    /// Items currently held in the main quarantine directory.
    public func entries() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: config.directory.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [Entry] = []
        for name in names.sorted() where name.hasSuffix(".roomy.json") {
            let manifestURL = config.directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: manifestURL), let m = try? dec.decode(Manifest.self, from: data) else { continue }
            let itemURL = config.directory.appendingPathComponent(String(name.dropLast(".roomy.json".count)))
            out.append(Entry(url: itemURL, manifest: m))
        }
        return out
    }

    /// Permanently removes quarantined items older than the retention period (or `olderThanDays` when given).
    public func purge(olderThanDays: Int? = nil, now: Date = Date()) -> DisposalOutcome {
        let days = olderThanDays ?? config.retentionDays
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var outcome = DisposalOutcome()
        let fm = FileManager.default
        for entry in entries() where entry.manifest.quarantinedAt < cutoff {
            do {
                if fm.fileExists(atPath: entry.url.path) { try fm.removeItem(at: entry.url) }
                try fm.removeItem(at: entry.url.appendingPathExtension("roomy").appendingPathExtension("json"))
                outcome.receipts.append(DisposalReceipt(path: entry.manifest.originalPath, method: .delete,
                                                        destination: entry.url.path, bytes: entry.manifest.bytes, at: now))
            } catch {
                outcome.failures.append(RoomyDeletionFailure(path: entry.url.path, message: error.localizedDescription))
            }
        }
        return outcome
    }

    /// Moves an item back to where it came from.
    public func restore(entry: Entry) throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: entry.manifest.originalPath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: entry.url, to: dest)
        try? fm.removeItem(at: entry.url.appendingPathExtension("roomy").appendingPathExtension("json"))
    }

    public var totalBytes: Int64 {
        entries().reduce(0) { $0 + ($1.manifest.bytes ?? 0) }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }
}

// MARK: - CLI-managed targets

enum CLITargetDisposer {
    static func docker(path: String, dryRun: Bool) -> Result<DisposalReceipt, RoomyDeletionFailure> {
        guard let docker = DockerArtifactProbe.resolveDocker() else {
            return .failure(RoomyDeletionFailure(path: path, message: "Docker not found"))
        }
        let args: [String]
        if path == "docker:prune:dangling" { args = ["image", "prune", "-f"] }
        else if path == "docker:prune:buildcache" { args = ["builder", "prune", "-f"] }
        else if path.hasPrefix("docker:volume:") { args = ["volume", "rm", String(path.dropFirst("docker:volume:".count))] }
        else { return .failure(RoomyDeletionFailure(path: path, message: "Unknown Docker target")) }
        return run(executable: docker, args: args, path: path, dryRun: dryRun)
    }

    static func conda(path: String, dryRun: Bool) -> Result<DisposalReceipt, RoomyDeletionFailure> {
        let args: [String]
        switch path {
        case "conda:clean:packages": args = ["conda", "clean", "--packages", "-y"]
        case "conda:clean:tarballs": args = ["conda", "clean", "--tarballs", "-y"]
        case "conda:clean:index-cache": args = ["conda", "clean", "--index-cache", "-y"]
        default:
            guard path.hasPrefix("conda:env:") else { return .failure(RoomyDeletionFailure(path: path, message: "Unknown Conda target")) }
            args = ["conda", "env", "remove", "-n", String(path.dropFirst("conda:env:".count)), "-y"]
        }
        return run(executable: ProcessRunner.envExecutable, args: args, path: path, dryRun: dryRun)
    }

    static func pipOrphan(path: String, dryRun: Bool) -> Result<DisposalReceipt, RoomyDeletionFailure> {
        let venvPath = String(path.dropFirst("pip:orphan:".count))
        let pip = URL(fileURLWithPath: venvPath, isDirectory: true).appendingPathComponent("bin/pip").path
        guard FileManager.default.isExecutableFile(atPath: pip) else {
            return .failure(RoomyDeletionFailure(path: path, message: "pip not found in venv"))
        }
        return run(executable: pip, args: ["cache", "purge"], path: path, dryRun: dryRun)
    }

    private static func run(executable: String, args: [String], path: String, dryRun: Bool) -> Result<DisposalReceipt, RoomyDeletionFailure> {
        if dryRun { return .success(DisposalReceipt(path: path, method: .delete, destination: nil, bytes: nil)) }
        guard let r = ProcessRunner.run(executable: executable, arguments: args, timeout: 600) else {
            return .failure(RoomyDeletionFailure(path: path, message: "Command could not be started or timed out"))
        }
        if r.succeeded { return .success(DisposalReceipt(path: path, method: .delete, destination: nil, bytes: nil)) }
        return .failure(RoomyDeletionFailure(path: path, message: "Command failed (exit \(r.status))"))
    }
}
