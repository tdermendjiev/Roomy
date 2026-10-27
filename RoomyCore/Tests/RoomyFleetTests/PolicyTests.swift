import Foundation
import Testing
import RoomyCore
@testable import RoomyFleet

struct PolicyTests {
    private func item(_ path: String, bytes: Int64, tier: ArtifactSafetyTier, category: String = "project", ecosystem: String = "npm",
                      idle: Int? = 30, ruleID: String? = nil, source: ArtifactSource = .projectWalk) -> ScanReportItem {
        let f = ScanArtifactFinding(path: path, label: "x", sizeBytes: bytes, ecosystemTag: ecosystem,
                                    groupRoot: category == "project" ? nil : RoomySystemGroupRoot.groupRoot(forCategory: category),
                                    source: source, safetyTier: tier, ruleID: ruleID)
        return ScanReportItem(finding: f, group: "g", resolver: RoomyPathResolver(home: URL(fileURLWithPath: "/home/a")), idleDays: idle, activity: nil)
    }

    private func report(_ items: [ScanReportItem]) -> ScanReport {
        let agg = ScanAggregate.build(from: [])
        var r = ScanReport(aggregate: agg, scanRoot: URL(fileURLWithPath: "/home/a"), home: URL(fileURLWithPath: "/home/a"),
                           durationSeconds: 0, partial: false, roomyVersion: "t")
        r.items = items
        return r
    }

    @Test func defaultsAreSafeOnly() throws {
        let p = FleetPolicy()
        try p.validate()
        #expect(p.autoClean.tiers == [.safe])
        #expect(p.never.tiers == [.warning])
        #expect(p.disposal.method == .quarantine)
    }

    @Test func evaluatorAppliesTiersPathsAgeAndBudget() {
        var p = FleetPolicy(name: "t")
        p.autoClean.minIdleDays = 7
        p.autoClean.maxBytesPerRun = 150
        p.never.paths = ["/home/a/keep"]
        p.never.ruleIDs = ["cursor-state-backup"]
        let items = [
            item("/home/a/p1/node_modules", bytes: 100, tier: .safe),                       // selected
            item("/home/a/p2/node_modules", bytes: 100, tier: .safe),                       // over budget (150)
            item("/home/a/keep/node_modules", bytes: 10, tier: .safe),                      // protected path
            item("/home/a/p3/.venv", bytes: 10, tier: .safe, idle: 2),                      // too recent
            item("/home/a/p4/dist", bytes: 10, tier: .safe, idle: nil),                     // idle unknown but allowed
            item("/home/a/.cursor/x", bytes: 10, tier: .caution, category: "aiTools"),      // tier not auto-cleaned
            item("/home/a/.claude/projects/x", bytes: 10, tier: .warning, category: "aiTools"), // never
            item("/home/a/.config/Cursor/state.vscdb.backup", bytes: 10, tier: .safe, category: "aiTools", ruleID: "cursor-state-backup"), // rule never
            item("/home/a/p5/tiny", bytes: 5, tier: .safe),                                  // too small (minBytes 1 MB default) — use small minBytes below
        ]
        p.autoClean.minBytes = 8
        let d = PolicyEvaluator.evaluate(report: report(items), policy: p)
        #expect(Set(d.selected.map(\.path)) == ["/home/a/p1/node_modules", "/home/a/p4/dist"])
        let reasons = Dictionary(uniqueKeysWithValues: d.skipped.map { ($0.item.path, $0.reason) })
        #expect(reasons["/home/a/p2/node_modules"] == .overBudget)
        #expect(reasons["/home/a/keep/node_modules"] == .pathProtected)
        #expect(reasons["/home/a/p3/.venv"] == .tooRecent)
        #expect(reasons["/home/a/.cursor/x"] == .tierNotAutoCleaned)
        #expect(reasons["/home/a/.claude/projects/x"] == .tierNeverRemoved)
        #expect(reasons["/home/a/.config/Cursor/state.vscdb.backup"] == .ruleNeverRemoved)
        #expect(reasons["/home/a/p5/tiny"] == .tooSmall)
        #expect(d.plan.method == .quarantine)
        #expect(d.plan.reason == "policy:t")
        #expect(d.plan.items.count == 2)
    }

    @Test func requireKnownIdleSkipsUnknown() {
        var p = FleetPolicy()
        p.autoClean.minIdleDays = 0
        p.autoClean.requireKnownIdle = true
        p.autoClean.minBytes = 1
        let d = PolicyEvaluator.evaluate(report: report([item("/home/a/x/dist", bytes: 10, tier: .safe, idle: nil)]), policy: p)
        #expect(d.selected.isEmpty)
        #expect(d.skipped.first?.reason == .idleUnknown)
    }

    @Test func categoryAndEcosystemFilters() {
        var p = FleetPolicy()
        p.autoClean.minBytes = 1
        p.autoClean.categories = ["aiTools"]
        p.autoClean.ecosystems = ["ai"]
        let d = PolicyEvaluator.evaluate(report: report([
            item("/home/a/p/node_modules", bytes: 10, tier: .safe),
            item("/home/a/.ollama/models", bytes: 10, tier: .safe, category: "aiTools", ecosystem: "ai"),
            item("/home/a/.npm/_cacache", bytes: 10, tier: .safe, category: "globalCaches", ecosystem: "npm"),
        ]), policy: p)
        #expect(d.selected.map(\.path) == ["/home/a/.ollama/models"])
    }

    @Test func validationCatchesConflicts() {
        var p = FleetPolicy()
        p.autoClean.tiers = [.safe, .warning]
        #expect(throws: FleetPolicyError.self) { try p.validate() }
        var q = FleetPolicy()
        q.scan.categories = ["nope"]
        #expect(throws: FleetPolicyError.self) { try q.validate() }
    }

    @Test func profilesRoundTripAndDecodeWithDefaults() throws {
        for p in [FleetPolicy.agentHostProfile(), FleetPolicy.developerProfile()] {
            let data = try p.encoded()
            let again = try JSONDecoder().decode(FleetPolicy.self, from: data)
            #expect(again == p)
        }
        let minimal = try JSONDecoder().decode(FleetPolicy.self, from: #"{"name":"m","autoClean":{"minIdleDays":3}}"#.data(using: .utf8)!)
        #expect(minimal.autoClean.minIdleDays == 3)
        #expect(minimal.autoClean.tiers == [.safe])
        #expect(minimal.disposal.method == .quarantine)
        #expect(minimal.resolvedListenAddress.port == 9477)
    }

    @Test func listenAddressParsing() {
        var p = FleetPolicy()
        p.metrics.listen = "0.0.0.0:9100"
        #expect(p.resolvedListenAddress == ("0.0.0.0", 9100))
        p.metrics.listen = ":9200"
        #expect(p.resolvedListenAddress == ("0.0.0.0", 9200))
    }
}
