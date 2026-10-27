import Foundation
import Testing
@testable import RoomyCore

struct FilesystemScannerTests {
    @Test func findsProjectArtifactsWithTiersAndEcosystems() throws {
        let root = try TestFS.makeTempDir("roomy-scan")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("my-app", isDirectory: true)
        try TestFS.writeFile(at: app.appendingPathComponent("node_modules/left-pad/index.js"), bytes: 4096)
        try TestFS.writeFile(at: app.appendingPathComponent(".aider.tags.cache.v3/cache.db"), bytes: 4096)
        try TestFS.writeFile(at: app.appendingPathComponent(".crush/crush.db"), bytes: 4096)
        try TestFS.writeFile(at: app.appendingPathComponent(".chroma/chroma.sqlite3"), bytes: 4096)
        try TestFS.writeFile(at: app.appendingPathComponent(".claude/worktrees/feature-x/README.md"), bytes: 10)

        let rust = root.appendingPathComponent("rusty", isDirectory: true)
        try TestFS.writeFile(at: rust.appendingPathComponent("Cargo.toml"), bytes: 10)
        try TestFS.writeFile(at: rust.appendingPathComponent("target/debug/bin"), bytes: 4096)

        let java = root.appendingPathComponent("javaish", isDirectory: true)
        try TestFS.writeFile(at: java.appendingPathComponent("build.gradle"), bytes: 10)
        try TestFS.writeFile(at: java.appendingPathComponent("build/classes/A.class"), bytes: 4096)

        let dotnet = root.appendingPathComponent("dn", isDirectory: true)
        try TestFS.writeFile(at: dotnet.appendingPathComponent("obj/x.o"), bytes: 4096) // no csproj → ignored

        let agg = FilesystemArtifactScanner.performScan(
            root: root, homeDirectory: root, enabledEcosystemTags: RoomySettingsEcosystems.allKeys
        )
        let byLabel = Dictionary(grouping: agg.allFindings, by: \.label)

        #expect(byLabel["node_modules"]?.first?.ecosystemTag == "npm")
        #expect(byLabel[".aider.tags.cache"]?.first?.safetyTier == .safe)
        #expect(byLabel[".crush"]?.first?.safetyTier == .warning)
        #expect(byLabel[".chroma"]?.first?.safetyTier == .caution)
        #expect(byLabel["target/"]?.first?.ecosystemTag == "rust")
        #expect(byLabel["build"]?.first?.ecosystemTag == "java")
        #expect(byLabel["obj"] == nil)

        let worktrees = try #require(byLabel["Claude Code worktrees"]?.first)
        #expect(worktrees.safetyTier == .warning)
        #expect(worktrees.ruleID == "claude-worktrees")
        // Grouped under the repo, not under `.claude`
        #expect(agg.artifactsByProjectRoot[app.path]?.contains(worktrees) == true)

        #expect(agg.projectRootPaths.contains(app.path))
        #expect(agg.projectRootPaths.contains(rust.path))
        #expect(agg.totalBytes > 0)
        #expect(agg.artifactCount == 7)
    }

    @Test func disabledEcosystemsAreSkipped() throws {
        let root = try TestFS.makeTempDir("roomy-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFS.writeFile(at: root.appendingPathComponent("p/node_modules/a.js"), bytes: 100)
        try TestFS.writeFile(at: root.appendingPathComponent("p/.venv/lib/x.py"), bytes: 100)
        let agg = FilesystemArtifactScanner.performScan(root: root, homeDirectory: root, enabledEcosystemTags: ["py"])
        #expect(agg.allFindings.map(\.label) == [".venv"])
    }

    @Test func exclusionsPruneSubtrees() throws {
        let root = try TestFS.makeTempDir("roomy-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFS.writeFile(at: root.appendingPathComponent("keep/node_modules/a.js"), bytes: 100)
        try TestFS.writeFile(at: root.appendingPathComponent("skip/node_modules/a.js"), bytes: 100)
        let filter = RoomyScanExclusionFilter(entries: [ExclusionEntry(pathDisplay: root.appendingPathComponent("skip").path, kind: .path)], homeDirectory: root)
        let agg = FilesystemArtifactScanner.performScan(root: root, homeDirectory: root, enabledEcosystemTags: ["npm"], exclusionFilter: filter)
        #expect(agg.artifactCount == 1)
        #expect(agg.allFindings.first?.path.contains("/keep/") == true)

        let glob = RoomyScanExclusionFilter(rawExclusions: ["*/skip/*"], homeDirectory: root)
        let agg2 = FilesystemArtifactScanner.performScan(root: root, homeDirectory: root, enabledEcosystemTags: ["npm"], exclusionFilter: glob)
        #expect(agg2.artifactCount == 1)
    }

    @Test func customCatalogIsHonoured() throws {
        let root = try TestFS.makeTempDir("roomy-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFS.writeFile(at: root.appendingPathComponent("p/zig-out/bin"), bytes: 100)
        let custom = RuleCatalog(catalogVersion: "t", projectRules: [
            ProjectArtifactRule(id: "zig-out", folderName: "zig-out", label: "zig-out", ecosystem: "general"),
        ], systemRules: [])
        let agg = FilesystemArtifactScanner.performScan(root: root, homeDirectory: root, enabledEcosystemTags: ["general"], catalog: custom)
        #expect(agg.allFindings.first?.ruleID == "zig-out")
    }

    @Test func toolOwnedTreesAreNotWalked() throws {
        let home = try TestFS.makeTempDir("roomy-home")
        defer { try? FileManager.default.removeItem(at: home) }
        try TestFS.writeFile(at: home.appendingPathComponent(".cursor-server/bin/abc/node_modules/x.js"), bytes: 100)
        try TestFS.writeFile(at: home.appendingPathComponent(".nvm/versions/node/v22/lib/node_modules/npm/x.js"), bytes: 100)
        try TestFS.writeFile(at: home.appendingPathComponent("repo/.git/modules/node_modules/x.js"), bytes: 100)
        try TestFS.writeFile(at: home.appendingPathComponent("repo/node_modules/x.js"), bytes: 100)
        #expect(!RuleCatalog.builtin.walkSkipSpecs(for: .current).isEmpty)
        let agg = FilesystemArtifactScanner.performScan(root: home, homeDirectory: home, enabledEcosystemTags: ["npm"])
        #expect(agg.allFindings.map(\.path) == [home.appendingPathComponent("repo/node_modules").path])
        // Scanning a skipped tree explicitly as the root still works
        let inside = FilesystemArtifactScanner.performScan(root: home.appendingPathComponent(".nvm"), homeDirectory: home, enabledEcosystemTags: ["npm"])
        #expect(inside.artifactCount == 1)
    }

    @Test func displayPathShortensHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(FilesystemArtifactScanner.shortenedDisplayPath(filePath: "/Users/me/x/y", homeDirectory: home) == "~/x/y")
        #expect(FilesystemArtifactScanner.shortenedDisplayPath(filePath: "/opt/z", homeDirectory: home) == "/opt/z")
    }
}
