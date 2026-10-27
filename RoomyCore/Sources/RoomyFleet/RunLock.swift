//
//  RunLock.swift
//  RoomyFleet
//
//  One policy run per host at a time. The lock file holds the pid; a lock whose pid is gone is stale.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class RunLock {
    public let url: URL
    private var held = false

    public init(url: URL) { self.url = url }

    public enum LockError: Error, LocalizedError {
        case busy(pid: Int32)
        public var errorDescription: String? {
            switch self { case .busy(let pid): return "another roomy run (pid \(pid)) holds the lock" }
        }
    }

    public func acquire() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(existing) {
            if pid != getpid() && (kill(pid, 0) == 0 || errno == EPERM) { throw LockError.busy(pid: pid) }
            try? fm.removeItem(at: url) // stale
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if let s = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                throw LockError.busy(pid: pid)
            }
            throw LockError.busy(pid: -1)
        }
        let text = "\(getpid())\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        held = true
    }

    public func release() {
        guard held else { return }
        try? FileManager.default.removeItem(at: url)
        held = false
    }

    deinit { release() }
}
