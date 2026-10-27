//
//  Platform.swift
//  RoomyCore
//
//  The handful of things that differ between macOS and Linux, behind small types.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RoomyPlatform: String, Codable, Sendable, Equatable, CaseIterable, Hashable {
    case macOS = "macos"
    case linux = "linux"

    public static let current: RoomyPlatform = {
        #if os(macOS)
        return .macOS
        #else
        return .linux
        #endif
    }()

    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        }
    }
}

/// Resolves catalog path specs (`~/.cache/pip`, `$XDG_CACHE_HOME/uv`, `/var/lib/x`) against a home directory.
public struct RoomyPathResolver: Sendable {
    public let home: URL
    public let environment: [String: String]

    public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    /// Expands `~`, `$VAR` and `${VAR}`; falls back to XDG defaults for the XDG_* variables.
    public func resolve(_ spec: String) -> URL? {
        var s = spec
        if s == "~" { return home }
        if s.hasPrefix("~/") {
            s = home.path + "/" + String(s.dropFirst(2))
        }
        if s.contains("$") {
            s = expandVariables(s)
            if s.contains("$") { return nil } // unresolvable variable
        }
        guard s.hasPrefix("/") else {
            // Catalog paths are home-relative unless absolute.
            return home.appendingPathComponent(s, isDirectory: true)
        }
        return URL(fileURLWithPath: s, isDirectory: true).standardizedFileURL
    }

    private func expandVariables(_ s: String) -> String {
        var out = s
        let xdgDefaults: [String: String] = [
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "HOME": home.path,
            "TMPDIR": environment["TMPDIR"] ?? "/tmp",
        ]
        let pattern = try! NSRegularExpression(pattern: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"#)
        let ns = out as NSString
        let matches = pattern.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            let name = ns.substring(with: m.range(at: 1))
            let value = environment[name] ?? xdgDefaults[name]
            guard let value else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: value)
        }
        return out
    }

    /// Tilde-shortened path for display.
    public func display(_ path: String) -> String {
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/"), homePath != "/" {
            return "~/" + String(path.dropFirst(homePath.count + 1))
        }
        return path
    }
}

/// Runs external commands with a timeout. Replaces the ad-hoc Process loops that used to live in each probe.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }
    }

    /// Returns nil when the executable cannot be started or the timeout elapses.
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 8
    ) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        if let environment { p.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return nil
        }
        // Read concurrently so a chatty child cannot block on a full pipe.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            _ = group.wait(timeout: .now() + 1)
            return nil
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return Result(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// stdout of a successful run, or nil.
    public static func output(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 8
    ) -> String? {
        guard let r = run(executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                          environment: environment, timeout: timeout), r.succeeded else { return nil }
        return r.stdout
    }

    /// Locates an executable on PATH, then in the usual extra places on each platform.
    public static func which(_ name: String) -> String? {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        var dirs = path.split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/snap/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static let envExecutable = "/usr/bin/env"
}

/// Total and available bytes on the volume holding a directory.
public enum RoomyVolumeSpaceReader {
    public struct Space: Sendable, Equatable, Codable {
        public let totalBytes: Int64
        public let availableBytes: Int64
        public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    }

    public static func space(forDirectory directory: URL) -> Space? {
        let url = directory.standardizedFileURL
        #if os(macOS)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        if let vals = try? url.resourceValues(forKeys: keys),
           let total = vals.volumeTotalCapacity, total > 0 {
            let legacy = vals.volumeAvailableCapacity.map { Int64($0) } ?? 0
            let available = vals.volumeAvailableCapacityForImportantUsage ?? legacy
            return Space(totalBytes: Int64(total), availableBytes: available)
        }
        #endif
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let total = (attrs[.systemSize] as? NSNumber)?.int64Value, total > 0 else {
            return nil
        }
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return Space(totalBytes: total, availableBytes: free)
    }

    /// GiB pair used by the app's disk charts.
    public static func chartGigabytes(forDirectory directory: URL) -> (used: Double, total: Double)? {
        guard let s = space(forDirectory: directory) else { return nil }
        let div = Double(Int64(1) << 30)
        return (Double(s.usedBytes) / div, Double(s.totalBytes) / div)
    }

    /// When volume queries fail (permissions, network volume, etc.).
    public static let fallbackChartGigabytes: (used: Double, total: Double) = (312, 500)
}

public enum RoomyHost {
    /// Hostname for reports and metrics. Falls back to "unknown-host".
    public static var name: String {
        if let override = ProcessInfo.processInfo.environment["ROOMY_HOSTNAME"], !override.isEmpty {
            return override
        }
        let n = ProcessInfo.processInfo.hostName
        return n.isEmpty ? "unknown-host" : n
    }

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}
