//
//  AIToolsProbe.swift
//  RoomyCore
//
//  The parts of the AI-tools category that need logic rather than a fixed path:
//  Electron app caches per app, VS Code-family agent extension storage, Claude Code per-project
//  transcripts, and Cursor's stale agent CLI versions. Fixed paths live in the rule catalog.
//

import Foundation

public struct AIToolsProbe: SystemArtifactProbe {
    public let categoryKey = "aiTools"

    public init() {}

    /// Electron-based AI editors and apps; each gets the standard cache subfolders.
    static let electronApps: [(appName: String, displayName: String, platforms: Set<RoomyPlatform>)] = [
        ("Claude", "Claude desktop", [.macOS, .linux]),
        ("Cursor", "Cursor", [.macOS, .linux]),
        ("Windsurf", "Windsurf", [.macOS, .linux]),
        ("Kiro", "Kiro", [.macOS, .linux]),
        ("Trae", "Trae", [.macOS, .linux]),
        ("Void", "Void", [.macOS, .linux]),
        ("Codex", "Codex desktop", [.macOS]),
        ("com.openai.codex", "Codex desktop", [.macOS]),
    ]
    static let electronCacheSubdirs = ["Cache", "CachedData", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "GraphiteDawnCache"]

    /// VS Code-family editors whose globalStorage can hold agent extension checkpoints.
    static let vsCodeFamily: [(appName: String, displayName: String)] = [
        ("Code", "VS Code"),
        ("Code - Insiders", "VS Code Insiders"),
        ("Cursor", "Cursor"),
        ("Windsurf", "Windsurf"),
    ]
    static let agentExtensions: [(id: String, displayName: String)] = [
        ("saoudrizwan.claude-dev", "Cline"),
        ("rooveterinaryinc.roo-cline", "Roo Code"),
        ("kilocode.kilo-code", "Kilo Code"),
    ]

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        struct Candidate {
            var url: URL
            var label: String
            var tier: ArtifactSafetyTier
            var restoreHint: String
            var ruleID: String
            var activity: Bool
        }
        var candidates: [Candidate] = []

        for app in Self.electronApps where app.platforms.contains(context.platform) {
            let base = context.appDataDirectory(appName: app.appName)
            for sub in Self.electronCacheSubdirs {
                candidates.append(Candidate(
                    url: base.appendingPathComponent(sub, isDirectory: true),
                    label: "\(app.displayName) \(sub)", tier: .safe,
                    restoreHint: "Rebuilt by \(app.displayName) on next launch",
                    ruleID: "electron-cache", activity: false
                ))
            }
        }

        for editor in Self.vsCodeFamily {
            let globalStorage = context.appDataDirectory(appName: editor.appName)
                .appendingPathComponent("User/globalStorage", isDirectory: true)
            for ext in Self.agentExtensions {
                candidates.append(Candidate(
                    url: globalStorage.appendingPathComponent(ext.id, isDirectory: true),
                    label: "\(ext.displayName) tasks & checkpoints (\(editor.displayName))", tier: .warning,
                    restoreHint: "Past \(ext.displayName) tasks cannot be resumed",
                    ruleID: "vscode-agent-extension-storage", activity: true
                ))
            }
        }

        // Cursor downloads a new agent CLI build on every update and never removes the old ones.
        for stale in Self.staleCursorAgentVersions(context: context) {
            candidates.append(Candidate(
                url: stale, label: "Cursor agent CLI · stale build \(stale.lastPathComponent)", tier: .safe,
                restoreHint: "Only the version linked from bin/cursor-agent is used; Cursor re-downloads if needed",
                ruleID: "cursor-stale-agent-versions", activity: false
            ))
        }

        var seen: Set<String> = []
        var toSize: [(Candidate, Date?)] = []
        for c in candidates {
            if context.shouldCancel() { return [] }
            guard seen.insert(c.url.path).inserted else { continue }
            guard SystemProbeHelpers.pathExists(c.url.path) else { continue }
            if context.exclusionFilter.shouldExcludeDirectory(url: c.url) { continue }
            let activity = c.activity ? RoomyDirectorySizeReader.newestModificationDate(in: c.url) : nil
            toSize.append((c, activity))
        }

        // Claude Code keeps one transcript folder per project; surface each so age can be judged per project.
        let claudeProjects = context.home.appendingPathComponent(".claude/projects", isDirectory: true)
        if SystemProbeHelpers.pathExists(claudeProjects.path),
           !context.exclusionFilter.shouldExcludeDirectory(url: claudeProjects) {
            for entry in Self.claudeProjectFolders(in: claudeProjects, home: context.home) {
                if context.shouldCancel() { return [] }
                guard seen.insert(entry.url.path).inserted else { continue }
                if context.exclusionFilter.shouldExcludeDirectory(url: entry.url) { continue }
                toSize.append((
                    Candidate(url: entry.url, label: "Claude Code sessions · \(entry.displayName)", tier: .warning,
                              restoreHint: "Past Claude Code sessions for this project cannot be resumed",
                              ruleID: "claude-project-sessions", activity: true),
                    RoomyDirectorySizeReader.newestModificationDate(in: entry.url)
                ))
            }
        }

        if toSize.isEmpty || context.shouldCancel() { return [] }

        let sizes = await RoomyDirectorySizeReader.bytesConcurrently(urls: toSize.map { $0.0.url }, shouldCancel: context.shouldCancel)

        var findings: [ScanArtifactFinding] = []
        for (c, activity) in toSize {
            guard let size = sizes[c.url], size >= SystemProbeHelpers.minBytes else { continue }
            findings.append(SystemProbeHelpers.finding(
                path: c.url.path, label: c.label, sizeBytes: size, ecosystemTag: "ai",
                groupRoot: RoomySystemGroupRoot.aiTools, safetyTier: c.tier,
                restoreHint: c.restoreHint, lastActivityDate: activity, ruleID: c.ruleID
            ))
        }
        return findings
    }

    // MARK: Cursor agent CLI versions

    /// Version folders under Cursor's agent-cli store that are not the target of the `bin/cursor-agent` symlink.
    public static func staleCursorAgentVersions(context: SystemProbeContext) -> [URL] {
        let base = context.appDataDirectory(appName: "Cursor")
            .appendingPathComponent("User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local", isDirectory: true)
        return staleCursorAgentVersions(agentCLILocalDir: base)
    }

    public static func staleCursorAgentVersions(agentCLILocalDir base: URL) -> [URL] {
        let versions = base.appendingPathComponent("share/cursor-agent/versions", isDirectory: true)
        guard SystemProbeHelpers.pathExists(versions.path) else { return [] }
        let link = base.appendingPathComponent("bin/cursor-agent")
        var live: String? = nil
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : link.deletingLastPathComponent().appendingPathComponent(dest)
            // .../versions/<version>/cursor-agent -> <version>
            live = resolved.standardizedFileURL.deletingLastPathComponent().lastPathComponent
        }
        let all = SystemProbeHelpers.childDirectories(of: versions)
        guard all.count > 1 else { return [] }
        // Without a readable symlink, keep the newest by name (versions are date-prefixed) and offer the rest.
        let keep = live ?? all.map(\.lastPathComponent).sorted().last
        return all.filter { $0.lastPathComponent != keep }
    }

    // MARK: Claude project folders

    public struct ClaudeProjectFolder: Equatable {
        public var url: URL
        public var displayName: String
    }

    /// Claude Code encodes a project path by replacing every non-alphanumeric character with `-`.
    /// Strip the encoded home prefix so `-Users-me-workspace-app` reads as `workspace-app`.
    public static func claudeProjectFolders(in projectsDir: URL, home: URL) -> [ClaudeProjectFolder] {
        let encodedHome = encodeClaudeProjectPath(home.path)
        return SystemProbeHelpers.childDirectories(of: projectsDir).map { url in
            ClaudeProjectFolder(url: url, displayName: claudeProjectDisplayName(folderName: url.lastPathComponent, encodedHome: encodedHome))
        }
    }

    public static func encodeClaudeProjectPath(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public static func claudeProjectDisplayName(folderName: String, encodedHome: String) -> String {
        if folderName == encodedHome { return "Home" }
        if folderName.hasPrefix(encodedHome + "-") {
            let rest = folderName.dropFirst(encodedHome.count + 1)
            return rest.isEmpty ? "Home" : String(rest)
        }
        return folderName.hasPrefix("-") ? String(folderName.dropFirst()) : folderName
    }

    public static func newestModificationDate(in dir: URL) -> Date? {
        RoomyDirectorySizeReader.newestModificationDate(in: dir)
    }
}
