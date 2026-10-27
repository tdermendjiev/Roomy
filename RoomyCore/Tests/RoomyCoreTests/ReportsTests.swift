import Foundation
import Testing
@testable import RoomyCore

struct ReportsTests {
    @Test func scanReportCarriesSchemaTotalsAndItems() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        let f1 = ScanArtifactFinding(path: "/Users/me/p/node_modules", label: "node_modules", sizeBytes: 100, ecosystemTag: "npm", ruleID: "node_modules")
        let f2 = ScanArtifactFinding(path: "/Users/me/.ollama/models", label: "Ollama models", sizeBytes: 50, ecosystemTag: "ai",
                                     groupRoot: RoomySystemGroupRoot.aiTools, source: .systemProbe, safetyTier: .safe, ruleID: "ollama-models")
        let f3 = ScanArtifactFinding(path: "docker:prune:dangling", label: "Docker dangling", sizeBytes: 25, ecosystemTag: "general",
                                     groupRoot: RoomySystemGroupRoot.docker, source: .dockerCLI, safetyTier: .caution)
        let agg = ScanAggregate.merge(
            FilesystemArtifactScanner.aggregate(findings: [f1], rules: RuleCatalog.builtin.projectRules),
            ScanAggregate.build(from: [f2, f3])
        )
        let report = ScanReport(aggregate: agg, scanRoot: home, home: home, durationSeconds: 1.5, partial: false, roomyVersion: "t")
        #expect(report.schemaVersion == 1)
        #expect(report.totalBytes == 175)
        #expect(report.bytesByTier["safe"] == 150)
        #expect(report.bytesByTier["caution"] == 25)
        #expect(report.bytesByCategory["project"] == 100)
        #expect(report.bytesByCategory["aiTools"] == 50)
        #expect(report.bytesByCategory["docker"] == 25)
        #expect(report.projectCount == 1)
        #expect(report.items.map(\.bytes) == [100, 50, 25])
        #expect(report.items[0].displayPath == "~/p/node_modules")
        #expect(report.items[2].displayPath == "docker:prune:dangling")
        #expect(report.items[0].id == StableID.make("/Users/me/p/node_modules"))

        let data = try report.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\" : 1"))
        let decoded = try ScanReport.decoder.decode(ScanReport.self, from: data)
        #expect(decoded.items.count == 3)
    }

    @Test func cleanupPlanRoundTripsAndDetectsMissing() throws {
        let item = CleanupPlan.Item(id: "a", path: "/nope/never/here", label: "x", bytes: 1, tier: .safe, category: "project", source: .projectWalk, ruleID: nil)
        let docker = CleanupPlan.Item(id: "b", path: "docker:prune:dangling", label: "d", bytes: 1, tier: .caution, category: "docker", source: .dockerCLI, ruleID: nil)
        let plan = CleanupPlan(items: [item, docker], method: .quarantine, reason: "test")
        #expect(plan.maxTier == .caution)
        #expect(plan.totalBytes == 2)
        #expect(plan.missingItems().map(\.id) == ["a"])
        let data = try plan.encoded()
        let again = try ScanReport.decoder.decode(CleanupPlan.self, from: data)
        #expect(again.items == plan.items)
        #expect(again.method == plan.method)
        #expect(again.reason == plan.reason)
        #expect(abs(again.createdAt.timeIntervalSince(plan.createdAt)) < 1)
    }

    @Test func stableIDIsDeterministic() {
        #expect(StableID.make("/a") == StableID.make("/a"))
        #expect(StableID.make("/a") != StableID.make("/b"))
        #expect(StableID.make("/a").count == 16)
    }

    @Test func tierOrderingAndLabels() {
        #expect(ArtifactSafetyTier.safe < .caution)
        #expect(ArtifactSafetyTier.caution < .warning)
        #expect(ArtifactSafetyTier.warning.displayLabel == "Irreversible")
        #expect(ByteFormatting.format(1_073_741_824) == "1.0 GB")
        #expect(ByteFormatting.format(1_048_576) == "1 MB")
    }

    @Test func activityClassification() {
        #expect(ScanActivityClassification.activity(monthsAgo: 30, dormantMonths: 24, inactiveMonths: 6) == .dormant)
        #expect(ScanActivityClassification.activity(monthsAgo: 7, dormantMonths: 24, inactiveMonths: 6) == .inactive)
        #expect(ScanActivityClassification.activity(monthsAgo: 2, dormantMonths: 24, inactiveMonths: 6) == .recent)
        #expect(ScanActivityClassification.activity(monthsAgo: 0, dormantMonths: 24, inactiveMonths: 6) == .active)
        #expect(ScanActivityClassification.daysSince(Date().addingTimeInterval(-3 * 86_400)) == 3)
    }
}
