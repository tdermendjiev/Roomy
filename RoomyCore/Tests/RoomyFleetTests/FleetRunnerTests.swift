import Foundation
import Testing
import RoomyCore
@testable import RoomyFleet

struct FleetRunnerTests {
    @Test func endToEndRunQuarantinesSafeItemsAndWritesAuditAndMetrics() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("home")
        func write(_ rel: String, _ bytes: Int) throws {
            let u = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: u)
        }
        let twoMB = 2 * 1_048_576
        try write("proj/node_modules/a.js", twoMB)              // safe, old → removed
        try write("proj/.crush/db", twoMB)                       // warning → never
        try write(".ollama/models/blob", twoMB)                  // safe → removed
        try write(".claude/projects/-x-proj/a.jsonl", twoMB)     // warning → never
        let old = Date().addingTimeInterval(-40 * 86_400)
        for rel in ["proj", "proj/node_modules", ".ollama/models"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent(rel).path)
        }

        var policy = FleetPolicy(name: "test")
        policy.scan.home = home.path
        policy.scan.roots = [home.appendingPathComponent("proj").path]
        policy.scan.categories = ["aiTools"]
        policy.autoClean.minIdleDays = 7
        policy.disposal = .init(method: .quarantine, quarantineDir: sandbox.appendingPathComponent("q").path, retentionDays: 7, purgeOnRun: true)
        policy.audit.path = sandbox.appendingPathComponent("audit.jsonl").path
        policy.metrics.textfile = sandbox.appendingPathComponent("roomy.prom").path
        policy.lockFile = sandbox.appendingPathComponent("lock").path
        try policy.validate()

        let runner = FleetRunner(policy: policy, roomyVersion: "test")
        let result = try await runner.run()

        #expect(result.report.items.count >= 4)
        #expect(result.decision.selected.count == 2)
        #expect(Set(result.decision.selected.map(\.label)) == ["node_modules", "Ollama models"])
        #expect(result.disposal.failures.isEmpty)
        #expect(result.disposal.receipts.count == 2)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("proj/node_modules").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("proj/.crush").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/projects/-x-proj").path))
        #expect(result.license.edition == .community)

        // Quarantine holds both items with manifests
        let q = QuarantineDisposer(config: policy.resolvedQuarantine)
        #expect(q.entries().count == 2)

        // Audit log is valid and has the expected events
        let verify = AuditLog.verify(url: policy.resolvedAuditPath)
        #expect(verify.ok, "\(verify.message)")
        let records = try AuditLog.readAll(from: policy.resolvedAuditPath)
        #expect(records.filter { $0.event == .disposed }.count == 2)
        #expect(records.contains { $0.event == .runFinished })
        #expect(records.filter { $0.event == .skipped }.allSatisfy { $0.reason != nil })

        // Metrics textfile
        let prom = try String(contentsOf: policy.resolvedMetricsTextfile!, encoding: .utf8)
        #expect(prom.contains("roomy_disposed_items_total{host=\"\(result.report.host)\",policy=\"test\"} 2"))
        #expect(prom.contains("roomy_quarantine_items{host=\"\(result.report.host)\",policy=\"test\"} 2"))
        #expect(prom.contains("edition=\"community\""))

        // Second run: nothing left to remove, counters persist, lock released
        let second = try await runner.run()
        #expect(second.decision.selected.isEmpty)
        #expect(AuditLog.totals(from: policy.resolvedAuditPath).runs == 2)
    }

    @Test func dryRunTouchesNothing() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("home")
        let nm = home.appendingPathComponent("p/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try Data(count: 2 * 1_048_576).write(to: nm.appendingPathComponent("a"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: home.appendingPathComponent("p").path)

        var policy = FleetPolicy(name: "dry")
        policy.scan.home = home.path
        policy.scan.roots = [home.path]
        policy.scan.categories = []
        policy.audit.path = sandbox.appendingPathComponent("audit.jsonl").path
        policy.lockFile = sandbox.appendingPathComponent("lock").path
        policy.disposal.quarantineDir = sandbox.appendingPathComponent("q").path
        let result = try await FleetRunner(policy: policy).run(dryRunOverride: true)
        #expect(result.dryRun)
        #expect(result.decision.selected.count == 1)
        #expect(result.disposal.receipts.count == 1)
        #expect(FileManager.default.fileExists(atPath: nm.path))
        #expect(result.metricsText.contains("roomy_dry_run{host=\"\(result.report.host)\",policy=\"dry\"} 1"))
    }

    @Test func lockPreventsConcurrentRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("l")
        // A live foreign pid (1 is always alive) holds the lock → busy
        try "1\n".write(to: url, atomically: true, encoding: .utf8)
        let lock = RunLock(url: url)
        #expect(throws: RunLock.LockError.self) { try lock.acquire() }
        // A dead pid is stale and reclaimed
        try "999999\n".write(to: url, atomically: true, encoding: .utf8)
        try lock.acquire()
        #expect(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())")
        lock.release()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
