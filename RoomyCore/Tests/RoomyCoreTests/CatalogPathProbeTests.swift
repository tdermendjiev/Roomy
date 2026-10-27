import Foundation
import Testing
@testable import RoomyCore

struct CatalogPathProbeTests {
    private func catalog(_ rules: [SystemPathRule]) -> RuleCatalog {
        RuleCatalog(catalogVersion: "t", projectRules: [], systemRules: rules)
    }

    @Test func directoryRuleProducesOneFinding() async throws {
        let home = try TestFS.makeTempDir("roomy-home")
        defer { try? FileManager.default.removeItem(at: home) }
        try TestFS.writeFile(at: home.appendingPathComponent(".ollama/models/blob"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: home.appendingPathComponent(".cache/tiny/x"), bytes: 16)

        let rules = [
            SystemPathRule(id: "ollama", category: "aiTools", label: "Ollama models", ecosystem: "ai", restoreHint: "ollama pull",
                           paths: [RoomyPlatform.current.rawValue: [".ollama/models"]]),
            SystemPathRule(id: "tiny", category: "aiTools", label: "tiny", ecosystem: "ai", paths: [RoomyPlatform.current.rawValue: [".cache/tiny"]]),
            SystemPathRule(id: "other-platform", category: "aiTools", label: "nope", ecosystem: "ai",
                           paths: [RoomyPlatform.current == .macOS ? "linux" : "macos": [".ollama/models"]]),
        ]
        let ctx = SystemProbeContext(home: home, catalog: catalog(rules))
        let findings = await CatalogPathProbe(categoryKey: "aiTools").scan(context: ctx)
        #expect(findings.count == 1)
        let f = try #require(findings.first)
        #expect(f.label == "Ollama models")
        #expect(f.ruleID == "ollama")
        #expect(f.groupRoot == RoomySystemGroupRoot.aiTools)
        #expect(f.safetyTier == .safe)
        #expect(f.sizeBytes >= Int64(TestFS.twoMB))
    }

    @Test func childrenModeAndGlobsAndFiles() async throws {
        let home = try TestFS.makeTempDir("roomy-home")
        defer { try? FileManager.default.removeItem(at: home) }
        try TestFS.writeFile(at: home.appendingPathComponent(".pyenv/versions/3.11.4/bin/python"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: home.appendingPathComponent(".pyenv/versions/3.12.0/bin/python"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: home.appendingPathComponent("apps/Cursor/Crashpad/pending/a.dmp"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: home.appendingPathComponent("apps/Code/Crashpad/pending/b.dmp"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: home.appendingPathComponent(".codex/logs_2.sqlite"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: home.appendingPathComponent(".codex/logs_2.sqlite-wal"), bytes: 10)

        let p = RoomyPlatform.current.rawValue
        let rules = [
            SystemPathRule(id: "pyenv", category: "python", label: "pyenv", ecosystem: "py", tier: .caution,
                           paths: [p: [".pyenv/versions"]], mode: .children, activity: .self, childLabel: "pyenv {name}"),
            SystemPathRule(id: "crash", category: "agentHost", label: "Crash dumps", ecosystem: "general",
                           paths: [p: ["apps/*/Crashpad/pending"]], childLabel: "{parent} crash dumps"),
            SystemPathRule(id: "codex-sqlite", category: "aiTools", label: "Codex logs db", ecosystem: "ai", tier: .caution,
                           paths: [p: [".codex/logs_*.sqlite", ".codex/logs_*.sqlite-wal"]], kind: .file),
        ]
        let ctx = SystemProbeContext(home: home, catalog: catalog(rules))
        let python = await CatalogPathProbe(categoryKey: "python").scan(context: ctx)
        #expect(Set(python.map(\.label)) == ["pyenv 3.11.4", "pyenv 3.12.0"])
        #expect(python.allSatisfy { $0.lastActivityDate != nil && $0.safetyTier == .caution })

        let crash = await CatalogPathProbe(categoryKey: "agentHost").scan(context: ctx)
        #expect(Set(crash.map(\.label)) == ["Cursor crash dumps", "Code crash dumps"])

        let codex = await CatalogPathProbe(categoryKey: "aiTools").scan(context: ctx)
        #expect(codex.count == 1) // the -wal file is under the 1 MB floor
        #expect(codex.first?.path.hasSuffix("logs_2.sqlite") == true)
    }

    @Test func pathResolverExpandsVariablesAndTilde() {
        let home = URL(fileURLWithPath: "/home/agent")
        let r = RoomyPathResolver(home: home, environment: ["UV_CACHE_DIR": "/data/uv", "TMPDIR": "/var/tmp"])
        #expect(r.resolve("~/.cache/pip")?.path == "/home/agent/.cache/pip")
        #expect(r.resolve(".cache/pip")?.path == "/home/agent/.cache/pip")
        #expect(r.resolve("$UV_CACHE_DIR")?.path == "/data/uv")
        #expect(r.resolve("$XDG_CACHE_HOME/uv")?.path == "/home/agent/.cache/uv")
        #expect(r.resolve("$TMPDIR/claude-*")?.path == "/var/tmp/claude-*")
        #expect(r.resolve("$NOT_SET_ANYWHERE/x") == nil)
        #expect(r.display("/home/agent/x") == "~/x")
    }

    @Test func exclusionsAndCancellationRespected() async throws {
        let home = try TestFS.makeTempDir("roomy-home")
        defer { try? FileManager.default.removeItem(at: home) }
        try TestFS.writeFile(at: home.appendingPathComponent(".ollama/models/blob"), bytes: TestFS.twoMB)
        let rules = [SystemPathRule(id: "ollama", category: "aiTools", label: "Ollama", ecosystem: "ai", paths: [RoomyPlatform.current.rawValue: [".ollama/models"]])]
        let filter = RoomyScanExclusionFilter(entries: [ExclusionEntry(pathDisplay: home.appendingPathComponent(".ollama").path, kind: .path)], homeDirectory: home)
        let excluded = await CatalogPathProbe(categoryKey: "aiTools").scan(context: SystemProbeContext(home: home, exclusionFilter: filter, catalog: catalog(rules)))
        #expect(excluded.isEmpty)
        let cancelled = await CatalogPathProbe(categoryKey: "aiTools").scan(context: SystemProbeContext(home: home, catalog: catalog(rules), shouldCancel: { true }))
        #expect(cancelled.isEmpty)
    }
}
