import Foundation
import Testing
@testable import RoomyCore

struct AIToolsProbeTests {
    @Test func categoriesAreRegistered() {
        #expect(RoomySystemScanCategories.all.contains { $0.key == "aiTools" })
        #expect(RoomySystemScanCategories.all.contains { $0.key == "agentHost" })
        #expect(RoomySystemGroupRoot.isSystemRoot(RoomySystemGroupRoot.aiTools))
        #expect(RoomySystemGroupRoot.displayName(for: RoomySystemGroupRoot.aiTools) == "AI coding tools")
        #expect(RoomySystemGroupRoot.category(forGroupRoot: RoomySystemGroupRoot.agentHost) == "agentHost")
        #expect(RoomyAppSettings.default.enabledEcosystemKeysForScan.contains("ai"))
    }

    @Test func claudeProjectPathEncoding() {
        #expect(AIToolsProbe.encodeClaudeProjectPath("/Users/me/workspace/my_app") == "-Users-me-workspace-my-app")
        let home = "-Users-me"
        #expect(AIToolsProbe.claudeProjectDisplayName(folderName: "-Users-me-workspace-app", encodedHome: home) == "workspace-app")
        #expect(AIToolsProbe.claudeProjectDisplayName(folderName: "-Users-me", encodedHome: home) == "Home")
        #expect(AIToolsProbe.claudeProjectDisplayName(folderName: "-Volumes-ext-proj", encodedHome: home) == "Volumes-ext-proj")
    }

    @Test func staleCursorAgentVersionsKeepsSymlinkTarget() throws {
        let base = try TestFS.makeTempDir("cursor-agent")
        defer { try? FileManager.default.removeItem(at: base) }
        let versions = base.appendingPathComponent("share/cursor-agent/versions")
        for v in ["2026.08.11-aaa", "2026.09.26-bbb", "2026.10.22-ccc"] {
            try TestFS.writeFile(at: versions.appendingPathComponent("\(v)/cursor-agent"), bytes: 10)
        }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("bin/cursor-agent"),
            withDestinationURL: versions.appendingPathComponent("2026.09.26-bbb/cursor-agent")
        )
        let stale = AIToolsProbe.staleCursorAgentVersions(agentCLILocalDir: base).map(\.lastPathComponent)
        #expect(Set(stale) == ["2026.08.11-aaa", "2026.10.22-ccc"])
    }

    @Test func staleCursorAgentVersionsWithoutSymlinkKeepsNewest() throws {
        let base = try TestFS.makeTempDir("cursor-agent")
        defer { try? FileManager.default.removeItem(at: base) }
        let versions = base.appendingPathComponent("share/cursor-agent/versions")
        for v in ["2026.08.11-aaa", "2026.10.22-ccc"] {
            try TestFS.writeFile(at: versions.appendingPathComponent("\(v)/cursor-agent"), bytes: 10)
        }
        #expect(AIToolsProbe.staleCursorAgentVersions(agentCLILocalDir: base).map(\.lastPathComponent) == ["2026.08.11-aaa"])
    }

    @Test func scanFindsElectronCachesExtensionsAndPerProjectSessions() async throws {
        let home = try TestFS.makeTempDir("roomy-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = SystemProbeContext(home: home)
        let cursor = ctx.appDataDirectory(appName: "Cursor")
        try TestFS.writeFile(at: cursor.appendingPathComponent("CachedData/x.bin"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: cursor.appendingPathComponent("User/globalStorage/saoudrizwan.claude-dev/tasks/1/a.json"), bytes: TestFS.twoMB)

        let encodedHome = AIToolsProbe.encodeClaudeProjectPath(home.path)
        let oldProject = home.appendingPathComponent(".claude/projects/\(encodedHome)-workspace-old")
        let newProject = home.appendingPathComponent(".claude/projects/\(encodedHome)-workspace-new")
        try TestFS.writeFile(at: oldProject.appendingPathComponent("a.jsonl"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: newProject.appendingPathComponent("b.jsonl"), bytes: TestFS.twoMB)
        try TestFS.setModified(oldProject.appendingPathComponent("a.jsonl"), daysAgo: 730)
        try TestFS.setModified(oldProject, daysAgo: 730)

        let findings = await AIToolsProbe().scan(context: ctx)
        #expect(findings.allSatisfy { $0.groupRoot == RoomySystemGroupRoot.aiTools && $0.ecosystemTag == "ai" })

        let cached = try #require(findings.first { $0.label == "Cursor CachedData" })
        #expect(cached.safetyTier == .safe)
        let cline = try #require(findings.first { $0.label.hasPrefix("Cline tasks & checkpoints") })
        #expect(cline.safetyTier == .warning)
        #expect(cline.lastActivityDate != nil)

        let old = try #require(findings.first { $0.label == "Claude Code sessions · workspace-old" })
        let new = try #require(findings.first { $0.label == "Claude Code sessions · workspace-new" })
        #expect(old.safetyTier == .warning && new.safetyTier == .warning)
        #expect(!RoomyArtifactSafety.isEligibleForBulkDormantSelection(tier: old.safetyTier))
        let oldDate = try #require(old.lastActivityDate)
        let newDate = try #require(new.lastActivityDate)
        #expect(oldDate < newDate)
    }

    /// Home-relative categories only: `agentHost` also has absolute-path rules (/tmp/claude-*) that may match on a dev machine.
    @Test func fullSystemScanOnEmptyHomeIsEmpty() async throws {
        let home = try TestFS.makeTempDir("roomy-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let agg = await SystemArtifactScanner.scan(
            homeDirectory: home, enabledCategories: ["aiTools", "globalCaches", "python"],
            enabledEcosystemTags: RoomySettingsEcosystems.allKeys, exclusionFilter: .empty,
            projectAggregate: .empty, shouldCancel: { false }, onProgress: { _ in }
        )
        #expect(agg.artifactCount == 0)
    }

    @Test func probesAreFilteredByPlatform() {
        let mac = SystemArtifactScanner.buildProbes(enabledCategories: RoomySystemScanCategories.allKeys, platform: .macOS)
        let linux = SystemArtifactScanner.buildProbes(enabledCategories: RoomySystemScanCategories.allKeys, platform: .linux)
        #expect(mac.contains { $0 is XcodeArchivesProbe })
        #expect(!linux.contains { $0 is XcodeArchivesProbe })
        #expect(!linux.contains { $0 is HomebrewCacheProbe })
        #expect(linux.contains { $0 is AIToolsProbe })
        #expect(linux.contains { ($0 as? CatalogPathProbe)?.categoryKey == "agentHost" })
        #expect(!linux.contains { ($0 as? CatalogPathProbe)?.categoryKey == "xcode" })
    }
}
