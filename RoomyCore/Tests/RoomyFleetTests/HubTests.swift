import Foundation
import Testing
import RoomyCore
@testable import RoomyFleet
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HubTests {
    static func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-hub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func report(host: String, at: Date = Date(), reclaimable: Int64 = 10_000_000_000, disposed: Int64 = 1_000_000_000,
                       failures: Int = 0, freeFraction: Double = 0.5, interval: Int? = 21_600, dryRun: Bool = false) -> HubHostReport {
        HubHostReport(host: host, platform: .linux, roomyVersion: "1.3.0", catalogVersion: "2026.10.27", policyName: "agent-host", edition: "fleet",
                      org: "Test", tags: ["role": "agent"], runID: UUID().uuidString, startedAt: at, durationSeconds: 3, dryRun: dryRun,
                      succeeded: failures == 0, intervalSeconds: interval, findings: 12, reclaimableBytes: reclaimable,
                      bytesByTier: ["safe": reclaimable * 7 / 10, "caution": reclaimable * 2 / 10, "warning": reclaimable / 10],
                      bytesByCategory: ["aiTools": reclaimable / 2, "globalCaches": reclaimable / 2], plannedItems: 3, plannedBytes: disposed,
                      disposedItems: 3, disposedBytes: disposed, failures: failures, disposedBytesTotal: dryRun ? 0 : disposed * 10, disposedItemsTotal: dryRun ? 0 : 30,
                      failuresTotal: failures, runsTotal: 10, quarantineBytes: disposed, quarantineItems: 3, volumeTotalBytes: 1_000_000_000_000,
                      volumeAvailableBytes: Int64(1_000_000_000_000 * freeFraction), auditSeq: 99, auditHeadHash: "ab", licenseExpiresAt: nil,
                      topItems: [HubTopItem(path: "/home/agent/.cache/uv", label: "uv cache", bytes: 5_000_000_000, tier: .safe, category: "globalCaches", ruleID: "uv-cache", idleDays: 3)])
    }

    @Test func dryRunsAreNotCountedAsFreed() throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HubStore(dataDir: dir, staleAfter: 3600)
        let now = Date()
        try store.ingest(Self.report(host: "dry", at: now.addingTimeInterval(-60), disposed: 5_000_000_000, dryRun: true), receivedAt: now)
        try store.ingest(Self.report(host: "wet", at: now.addingTimeInterval(-30), disposed: 1_000_000_000), receivedAt: now)
        let license = HubLicenseInfo(edition: "community", org: nil, maxHosts: 5, expiresAt: nil, problem: nil, hostsKnown: 2, hostsOverLimit: [])
        let s = store.summary(now: now, license: license)
        #expect(s.hostsDryRun == 1)
        #expect(s.disposedBytesLast24h == 1_000_000_000)
        #expect(s.disposedBytesLast7d == 1_000_000_000)
        #expect(s.trend.map(\.disposedBytes).reduce(0, +) == 1_000_000_000)
        #expect(s.trend.map(\.runs).reduce(0, +) == 2)   // the dry run still counts as a run
        #expect(s.recentRuns.first { $0.host == "dry" }?.dryRun == true)
        #expect(s.recentRuns.first { $0.host == "dry" }?.disposedBytes == 5_000_000_000)   // "would remove", labelled as such
    }

    @Test func storeIngestsComputesStatusAndSummary() throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HubStore(dataDir: dir, staleAfter: 3600)
        let now = Date()
        try store.ingest(Self.report(host: "a", at: now.addingTimeInterval(-600)), receivedAt: now.addingTimeInterval(-600))
        try store.ingest(Self.report(host: "b", at: now.addingTimeInterval(-300), failures: 2), receivedAt: now.addingTimeInterval(-300))
        try store.ingest(Self.report(host: "c", at: now.addingTimeInterval(-3 * 86_400)), receivedAt: now.addingTimeInterval(-3 * 86_400))
        try store.ingest(Self.report(host: "d", at: now.addingTimeInterval(-100), freeFraction: 0.05), receivedAt: now.addingTimeInterval(-100))
        // second report for a → history grows, reports count increments
        try store.ingest(Self.report(host: "a", at: now, reclaimable: 8_000_000_000), receivedAt: now)

        let license = HubLicenseInfo(edition: "community", org: nil, maxHosts: 5, expiresAt: nil, problem: nil, hostsKnown: 4, hostsOverLimit: [])
        let inv = store.inventory(now: now, license: license)
        #expect(inv.map(\.host) == ["a", "b", "c", "d"])
        let by = Dictionary(uniqueKeysWithValues: inv.map { ($0.host, $0) })
        #expect(by["a"]?.status == .healthy)
        #expect(by["a"]?.reports == 2)
        #expect(by["a"]?.history.count == 2)
        #expect(by["b"]?.status == .attention)
        #expect(by["b"]?.statusReasons.first?.contains("failure") == true)
        #expect(by["c"]?.status == .stale)
        #expect(by["d"]?.status == .attention)
        #expect(by["d"]?.statusReasons.contains { $0.contains("disk") } == true)

        let s = store.summary(now: now, license: license)
        #expect(s.hosts == 4)
        #expect(s.hostsByStatus["healthy"] == 1 && s.hostsByStatus["attention"] == 2 && s.hostsByStatus["stale"] == 1)
        #expect(s.reclaimableBytes == 8_000_000_000 + 3 * 10_000_000_000)
        #expect(s.disposedBytesLast24h == 4 * 1_000_000_000)   // a twice, b, d; c is 3 days old
        #expect(s.hostsLowDisk == 1)
        #expect(s.trend.count == 14)
        #expect(s.topRules.first?.label == "uv cache")
        #expect(s.topRules.first?.hosts == 4)

        // Persistence: a fresh store reads the same inventory
        let reopened = try HubStore(dataDir: dir, staleAfter: 3600)
        #expect(reopened.hostCount == 4)
        #expect(reopened.file(for: "a")?.history.count == 2)

        // Host limit: new host refused, known host accepted
        #expect(throws: HubStore.IngestError.self) { try store.ingest(Self.report(host: "e"), hostLimit: 4) }
        try store.ingest(Self.report(host: "a"), hostLimit: 4)
        #expect(store.hostsOverLimit(2).count == 2)
        #expect(store.remove(host: "c"))
        #expect(store.hostCount == 3)
        #expect(store.events(last: 10).first?.kind == .hostRemoved)
    }

    @Test func policiesRoundTripThroughStore() throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HubStore(dataDir: dir)
        try store.putPolicy(.agentHostProfile(), named: "agent-host")
        #expect(store.policyNames() == ["agent-host"])
        #expect(store.policy(named: "agent-host")?.name == "agent-host")
        #expect(throws: HubStoreError.self) { try store.putPolicy(.agentHostProfile(), named: "../etc/passwd") }
        #expect(store.removePolicy(named: "agent-host"))
        #expect(store.policyNames().isEmpty)
    }

    @Test func remotePolicyKeepsLocalHubAndLicense() throws {
        var local = FleetPolicy(name: "bootstrap")
        local.hub.url = "http://hub:9478"; local.hub.policy = "agent-host"; local.hub.tags = ["role": "ci"]
        local.license.keyFile = "/etc/roomy/license.key"
        local.scan.home = "/home/ci"
        var remote = FleetPolicy.agentHostProfile()
        remote.autoClean.minIdleDays = 1
        let merged = local.applyingRemote(remote)
        #expect(merged.name == "agent-host")
        #expect(merged.autoClean.minIdleDays == 1)
        #expect(merged.hub.url == "http://hub:9478")
        #expect(merged.hub.tags == ["role": "ci"])
        #expect(merged.license.keyFile == "/etc/roomy/license.key")
        #expect(merged.scan.home == "/home/ci")
        // hub section validates
        var bad = FleetPolicy(); bad.hub.url = "ftp://x"
        #expect(throws: FleetPolicyError.self) { try bad.validate() }
        // hub section decodes from JSON and round-trips
        let json = """
        {"name":"p","hub":{"url":"https://hub.example:9478","policy":"ci","tags":{"team":"infra"},"topItems":10}}
        """
        let p = try JSONDecoder().decode(FleetPolicy.self, from: Data(json.utf8))
        #expect(p.hub.url == "https://hub.example:9478" && p.hub.policy == "ci" && p.hub.topItems == 10 && p.hub.tags["team"] == "infra")
        #expect(p.resolvedHubURL?.host == "hub.example")
    }

    @Test func serverAuthIngestAndMetricsOverHTTP() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let config = HubConfig(host: "127.0.0.1", port: 0, dataDir: dir, agentToken: "agent-secret", adminToken: "admin-secret", staleAfter: 3600, title: "Test Hub")
        let server = try HubServer(config: config)
        try server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"

        // Dashboard is public, API is not
        let (dashCode, dashBody) = try await Self.get("\(base)/", token: nil)
        #expect(dashCode == 200 && dashBody.contains("Test Hub") && dashBody.contains("Roomy Hub"))
        #expect(try await Self.get("\(base)/api/v1/summary", token: nil).0 == 401)
        #expect(try await Self.get("\(base)/api/v1/summary", token: "wrong").0 == 401)
        #expect(try await Self.get("\(base)/metrics", token: nil).0 == 401)
        #expect(try await Self.get("\(base)/healthz", token: nil).0 == 200)

        // Agent posts with the agent token; cannot read the inventory
        let agent = HubClient(baseURL: URL(string: base)!, token: "agent-secret")
        let ack = try await agent.postReport(Self.report(host: "agent-01"))
        #expect(ack.accepted && ack.hostsKnown == 1 && ack.hostLimit == HubConfig.communityHostLimit)
        do { _ = try await agent.hosts(); Issue.record("agent token must not read inventory") } catch {}
        #expect(try await Self.get("\(base)/api/v1/report", token: "agent-secret").0 == 404) // GET on report is not a route

        // Admin reads everything
        let admin = HubClient(baseURL: URL(string: base)!, token: "admin-secret")
        let hosts = try await admin.hosts()
        #expect(hosts.count == 1 && hosts[0].host == "agent-01" && hosts[0].status == .healthy)
        let one = try await admin.host("agent-01")
        #expect(one.latest.topItems.count == 1)
        let summary = try await admin.summary()
        #expect(summary.hosts == 1 && summary.license.edition == "community")
        try await admin.setNote("agent-01", note: "canary box")
        #expect(try await admin.host("agent-01").note == "canary box")

        // Policies: agents may fetch, only admin may push
        try await admin.putPolicy("ci", data: try FleetPolicy.agentHostProfile().encoded())
        #expect(try await agent.policies() == ["ci"])
        #expect(try await agent.fetchPolicy(named: "ci").name == "agent-host")
        do { try await agent.putPolicy("x", data: try FleetPolicy().encoded()); Issue.record("agent must not push") } catch {}
        let (badCode, _) = try await Self.put("\(base)/api/v1/policies/bad", token: "admin-secret", body: Data("{\"autoClean\":{\"tiers\":[\"warning\"]}}".utf8))
        #expect(badCode == 400)

        // Metrics
        let (mCode, metrics) = try await Self.get("\(base)/metrics", token: "admin-secret")
        #expect(mCode == 200)
        #expect(metrics.contains("roomy_hub_hosts{status=\"healthy\"} 1"))
        #expect(metrics.contains("roomy_hub_host_reclaimable_bytes{host=\"agent-01\",tier=\"safe\"} 7000000000"))
        #expect(metrics.contains("roomy_hub_host_info{host=\"agent-01\",platform=\"linux\""))

        // Host limit enforced at the API: community edition allows communityHostLimit hosts
        for i in 2...HubConfig.communityHostLimit { _ = try await agent.postReport(Self.report(host: "agent-0\(i)")) }
        do { _ = try await agent.postReport(Self.report(host: "agent-99")); Issue.record("should be refused") }
        catch let e as HubClient.HubClientError { if case .rejected(let a) = e { #expect(!a.accepted) } else { Issue.record("wrong error \(e)") } }
        #expect(try await admin.summary().hosts == HubConfig.communityHostLimit)
        try await admin.removeHost("agent-02")
        #expect(try await admin.hosts().count == HubConfig.communityHostLimit - 1)
        let events = try await admin.events(last: 5)
        #expect(events.first?.kind == .hostRemoved)
    }

    @Test func fleetRunReportsToHub() async throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let server = try HubServer(config: HubConfig(host: "127.0.0.1", port: 0, dataDir: dir.appendingPathComponent("hub"), agentToken: "t"))
        try server.start(); defer { server.stop() }

        let home = dir.appendingPathComponent("home")
        let nm = home.appendingPathComponent("p/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try Data(count: 2 * 1_048_576).write(to: nm.appendingPathComponent("a"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: home.appendingPathComponent("p").path)

        var policy = FleetPolicy(name: "hubbed")
        policy.scan.home = home.path; policy.scan.roots = [home.path]; policy.scan.categories = []
        policy.audit.path = dir.appendingPathComponent("audit.jsonl").path
        policy.lockFile = dir.appendingPathComponent("lock").path
        policy.disposal.quarantineDir = dir.appendingPathComponent("q").path
        policy.hub.url = "http://127.0.0.1:\(server.port)"
        policy.hub.token = "t"
        policy.hub.tags = ["role": "test"]
        let result = try await FleetRunner(policy: policy, roomyVersion: "test", intervalSeconds: 600).run()
        #expect(result.hubError == nil, Comment(rawValue: result.hubError ?? ""))
        #expect(result.hubAck?.accepted == true)
        let records = try AuditLog.readAll(from: policy.resolvedAuditPath)
        #expect(records.contains { $0.event == .hubReported })
        let stored = server.store.file(for: result.report.host)
        #expect(stored?.latest.disposedItems == 1)
        #expect(stored?.latest.tags["role"] == "test")
        #expect(stored?.latest.intervalSeconds == 600)
        #expect(stored?.latest.auditSeq == records.filter { $0.event != .hubReported }.count)
        #expect(stored?.latest.topItems.first?.label == "node_modules")

        // Unreachable hub: run still succeeds, error recorded
        policy.hub.url = "http://127.0.0.1:1"
        let second = try await FleetRunner(policy: policy, roomyVersion: "test").run()
        #expect(second.hubAck == nil && second.hubError != nil)
        #expect(second.disposal.failures.isEmpty)
    }

    @Test func demoIsDeterministicAndPlausible() throws {
        let a = try Self.tempDir(), b = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let now = Date()
        let s1 = try HubStore(dataDir: a), s2 = try HubStore(dataDir: b)
        let n1 = try HubDemo.populate(store: s1, hosts: 12, seed: 3, now: now)
        let n2 = try HubDemo.populate(store: s2, hosts: 12, seed: 3, now: now)
        #expect(n1 == n2 && n1.count == 12 && Set(n1).count == 12)
        #expect(s1.inventory(now: now).map(\.latest.reclaimableBytes) == s2.inventory(now: now).map(\.latest.reclaimableBytes))
        let lic = HubLicenseInfo(edition: "fleet", org: "x", maxHosts: 100, expiresAt: nil, problem: nil, hostsKnown: 12, hostsOverLimit: [])
        let sum = s1.summary(now: now, license: lic)
        #expect(sum.hosts == 12)
        #expect(sum.hostsByPlatform["macos"] ?? 0 > 0 && sum.hostsByPlatform["linux"] ?? 0 > 0)
        #expect((sum.hostsByStatus["stale"] ?? 0) >= 1)
        #expect((sum.hostsByStatus["attention"] ?? 0) >= 1)
        #expect(sum.disposedBytesLast24h > 0)
        #expect(s1.inventory(now: now).allSatisfy { $0.history.count > 10 })
        #expect(s1.inventory(now: now).allSatisfy { !$0.latest.topItems.isEmpty })
    }

    @Test func reportDecodesLeniently() throws {
        let minimal = Data("{\"host\":\"x\"}".utf8)
        let r = try HubJSON.decoder.decode(HubHostReport.self, from: minimal)
        #expect(r.host == "x" && r.schemaVersion == 1 && r.topItems.isEmpty && r.edition == "community")
        let full = Self.report(host: "y")
        let back = try HubJSON.decoder.decode(HubHostReport.self, from: try HubJSON.encoder.encode(full))
        #expect(back.host == "y" && back.bytesByTier == full.bytesByTier && back.topItems == full.topItems)
    }

    // MARK: helpers

    static func get(_ url: String, token: String?) async throws -> (Int, String) {
        var r = URLRequest(url: URL(string: url)!)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await send(r)
    }

    static func put(_ url: String, token: String?, body: Data) async throws -> (Int, String) {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "PUT"; r.httpBody = body
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await send(r)
    }

    static func send(_ r: URLRequest) async throws -> (Int, String) {
        try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: r) { data, resp, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self)))
            }.resume()
        }
    }
}
