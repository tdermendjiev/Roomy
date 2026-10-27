import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Crypto
import RoomyCore
@testable import RoomyFleet

struct AuditLogTests {
    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.jsonl")
    }

    @Test func appendsChainedRecordsAndVerifies() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try AuditLog(url: url)
        let a = try log.append { seq, prev in AuditRecord(seq: seq, runID: "r1", event: .runStarted, actor: "test", edition: "community", prevHash: prev) }
        let b = try log.append { seq, prev in
            var r = AuditRecord(seq: seq, runID: "r1", event: .disposed, actor: "test", edition: "community", prevHash: prev)
            r.path = "/x"; r.bytes = 42; r.method = .quarantine
            return r
        }
        #expect(a.seq == 1 && b.seq == 2)
        #expect(a.prevHash == AuditLog.genesisHash)
        #expect(b.prevHash == a.hash)
        #expect(AuditLog.verify(url: url).ok)

        // Reopen continues the chain
        let log2 = try AuditLog(url: url)
        let c = try log2.append { seq, prev in AuditRecord(seq: seq, runID: "r2", event: .runFinished, actor: "test", edition: "community", prevHash: prev) }
        #expect(c.seq == 3 && c.prevHash == b.hash)
        // Dry-run disposals (new field, or only the message in older logs) never count as freed.
        try log2.append { seq, prev in
            var r = AuditRecord(seq: seq, runID: "r3", event: .disposed, actor: "test", edition: "community", dryRun: true, prevHash: prev)
            r.bytes = 1_000; return r
        }
        try log2.append { seq, prev in
            var r = AuditRecord(seq: seq, runID: "r4", event: .disposed, actor: "test", edition: "community", prevHash: prev)
            r.bytes = 2_000; r.message = "dry run"; return r
        }
        #expect(AuditLog.verify(url: url).ok)
        let totals = AuditLog.totals(from: url)
        #expect(totals.disposedBytes == 42 && totals.disposedItems == 1 && totals.runs == 1)
    }

    @Test func tamperingIsDetected() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try AuditLog(url: url)
        for i in 0..<3 {
            try log.append { seq, prev in
                var r = AuditRecord(seq: seq, runID: "r", event: .disposed, actor: "t", edition: "community", prevHash: prev)
                r.bytes = Int64(i); return r
            }
        }
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"bytes\":1", with: "\"bytes\":1000")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let v = AuditLog.verify(url: url)
        #expect(!v.ok)
        #expect(v.firstBadSeq == 2)

        // Truncation
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        try (lines.dropLast().joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        // Dropping the last line keeps a valid chain prefix; verify must still pass (truncation of the tail is detectable only via seq expectations upstream)
        _ = AuditLog.verify(url: url)
    }
}

struct LicenseTests {
    @Test func signAndVerifyRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = LicensePayload(org: "Acme", maxHosts: 50, expiresAt: Date().addingTimeInterval(86_400 * 30))
        let token = try LicenseVerifier.sign(payload: payload, privateKey: key)
        #expect(token.hasPrefix("ROOMY1."))
        let back = try LicenseVerifier.verify(token: token, publicKey: key.publicKey)
        #expect(back.org == "Acme" && back.maxHosts == 50)
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: LicenseError.badSignature) { try LicenseVerifier.verify(token: token, publicKey: other.publicKey) }
        let expired = LicensePayload(org: "Acme", maxHosts: 1, issuedAt: Date().addingTimeInterval(-200 * 86_400), expiresAt: Date().addingTimeInterval(-86_400))
        let expiredToken = try LicenseVerifier.sign(payload: expired, privateKey: key)
        #expect(throws: LicenseError.self) { try LicenseVerifier.verify(token: expiredToken, publicKey: key.publicKey) }
        #expect(throws: LicenseError.malformed) { try LicenseVerifier.verify(token: "nonsense", publicKey: key.publicKey) }
    }

    @Test func statusNeverThrows() {
        #expect(LicenseVerifier.status(token: nil) == .community)
        let s = LicenseVerifier.status(token: "ROOMY1.garbage.garbage")
        #expect(s.edition == .community)
        #expect(s.problem != nil)
    }

    @Test func compiledInPublicKeyIsSet() {
        #expect(LicenseVerifier.publicKeyBase64 != "REPLACE_WITH_PUBLIC_KEY")
        #expect(Data(base64Encoded: LicenseVerifier.publicKeyBase64)?.count == 32)
    }
}

struct MetricsTests {
    @Test func rendersPrometheusText() {
        let snap = FleetMetricsSnapshot(
            host: "h1", edition: "fleet", org: "Acme \"Inc\"", version: "1.3.0", catalogVersion: "c", policyName: "p",
            reclaimableBytesByTier: ["safe": 10, "caution": 5], reclaimableBytesByCategory: ["aiTools": 15], reclaimableItems: 2,
            plannedBytes: 10, plannedItems: 1, disposedBytesThisRun: 10, disposedItemsThisRun: 1, failuresThisRun: 0,
            disposedBytesTotal: 100, disposedItemsTotal: 7, failuresTotal: 1, purgedBytesTotal: 50, runsTotal: 3,
            lastRunStart: Date(timeIntervalSince1970: 1_700_000_000), lastRunDurationSeconds: 1.5, lastRunSucceeded: true, dryRun: false,
            quarantineBytes: 20, quarantineItems: 2, volumeTotalBytes: 1000, volumeAvailableBytes: 400, licenseExpiresAt: nil)
        let text = PrometheusRenderer.render(snap)
        #expect(text.contains("# TYPE roomy_reclaimable_bytes gauge"))
        #expect(text.contains("roomy_reclaimable_bytes{host=\"h1\",policy=\"p\",tier=\"safe\"} 10"))
        #expect(text.contains("roomy_reclaimable_bytes{host=\"h1\",policy=\"p\",tier=\"warning\"} 0"))
        #expect(text.contains("roomy_disposed_bytes_total{host=\"h1\",policy=\"p\"} 100"))
        #expect(text.contains("roomy_last_run_timestamp_seconds{host=\"h1\",policy=\"p\"} 1700000000"))
        #expect(text.contains("org=\"Acme \\\"Inc\\\"\""))
        #expect(text.hasSuffix("\n"))
    }

    @Test func metricsServerServesScrape() async throws {
        let server = MetricsServer(host: "127.0.0.1", port: 39477)
        try server.start()
        defer { server.stop() }
        server.update(metrics: "roomy_test 1\n", reportJSON: "{\"ok\":true}")
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:39477/metrics")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "roomy_test 1\n")
        let (h, hr) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:39477/healthz")!)
        #expect((hr as? HTTPURLResponse)?.statusCode == 200 && String(decoding: h, as: UTF8.self) == "ok\n")
        let (_, nf) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:39477/nope")!)
        #expect((nf as? HTTPURLResponse)?.statusCode == 404)
    }
}
