import Foundation
import Testing
@testable import RoomyCore

struct DisposalTests {
    @Test func quarantineMovesWritesManifestPurgesAndRestores() throws {
        let sandbox = try TestFS.makeTempDir("roomy-q")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let victim = sandbox.appendingPathComponent("proj/node_modules")
        try TestFS.writeFile(at: victim.appendingPathComponent("a.js"), bytes: 2048)
        let qdir = sandbox.appendingPathComponent("quarantine")
        let q = QuarantineDisposer(config: QuarantineConfig(directory: qdir, retentionDays: 7))

        let dest = try q.quarantine(url: victim, originalPath: victim.path)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.js").path))
        let entries = q.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.manifest.originalPath == victim.path)

        // Not old enough → nothing purged
        #expect(q.purge().receipts.isEmpty)
        // Old enough → purged
        let later = Date().addingTimeInterval(8 * 86_400)
        let purged = q.purge(now: later)
        #expect(purged.receipts.count == 1)
        #expect(purged.failures.isEmpty)
        #expect(q.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func quarantineRestorePutsItBack() throws {
        let sandbox = try TestFS.makeTempDir("roomy-q")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let victim = sandbox.appendingPathComponent("proj/.venv")
        try TestFS.writeFile(at: victim.appendingPathComponent("bin/python"), bytes: 10)
        let q = QuarantineDisposer(config: QuarantineConfig(directory: sandbox.appendingPathComponent("q")))
        _ = try q.quarantine(url: victim, originalPath: victim.path)
        let entry = try #require(q.entries().first)
        try q.restore(entry: entry)
        #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("bin/python").path))
        #expect(q.entries().isEmpty)
    }

    @Test func deletionServiceDryRunTouchesNothing() async throws {
        let sandbox = try TestFS.makeTempDir("roomy-d")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let victim = sandbox.appendingPathComponent("x/dist")
        try TestFS.writeFile(at: victim.appendingPathComponent("bundle.js"), bytes: 10)
        let outcome = await RoomyDeletionService.dispose(paths: [victim.path, "/definitely/missing"], method: .delete, dryRun: true)
        #expect(outcome.receipts.count == 1)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.message == "Path not found")
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func permanentDeleteRemoves() async throws {
        let sandbox = try TestFS.makeTempDir("roomy-d")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let victim = sandbox.appendingPathComponent("x/dist")
        try TestFS.writeFile(at: victim.appendingPathComponent("bundle.js"), bytes: 10)
        let outcome = await RoomyDeletionService.dispose(paths: [victim.path], method: .delete)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.receipts.first?.method == .delete)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func freedesktopTrashWritesInfoAndPurges() throws {
        let sandbox = try TestFS.makeTempDir("roomy-t")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        // Point XDG_DATA_HOME at the sandbox so we never touch the real trash.
        setenv("XDG_DATA_HOME", sandbox.appendingPathComponent("data").path, 1)
        defer { unsetenv("XDG_DATA_HOME") }
        let victim = sandbox.appendingPathComponent("p/node_modules")
        try TestFS.writeFile(at: victim.appendingPathComponent("a.js"), bytes: 10)
        let dest = try FreedesktopTrash.trash(url: victim, home: sandbox)
        #expect(dest.path.contains("/data/Trash/files/node_modules"))
        let loc = try FreedesktopTrash.location(for: victim, home: sandbox)
        let info = loc.info.appendingPathComponent("node_modules.trashinfo")
        let text = try String(contentsOf: info, encoding: .utf8)
        #expect(text.hasPrefix("[Trash Info]\nPath="))
        #expect(text.contains("DeletionDate="))
        // Collision handling
        try TestFS.writeFile(at: victim.appendingPathComponent("b.js"), bytes: 10)
        let dest2 = try FreedesktopTrash.trash(url: victim, home: sandbox)
        #expect(dest2.lastPathComponent == "node_modules.2")
        // Purge old
        let purged = FreedesktopTrash.purge(location: loc, olderThanDays: 1, now: Date().addingTimeInterval(3 * 86_400))
        #expect(purged.receipts.count == 2)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: loc.files.path))?.isEmpty == true)
    }
}
