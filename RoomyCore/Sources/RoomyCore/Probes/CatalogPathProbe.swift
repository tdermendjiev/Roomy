//
//  CatalogPathProbe.swift
//  RoomyCore
//
//  Turns `SystemPathRule`s from the catalog into findings. One probe instance per category.
//

import Foundation

public struct CatalogPathProbe: SystemArtifactProbe {
    public let categoryKey: String

    public init(categoryKey: String) {
        self.categoryKey = categoryKey
    }

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        let rules = context.catalog.systemRules(for: context.platform, categories: [categoryKey])
        if rules.isEmpty { return [] }

        struct Candidate {
            var url: URL
            var rule: SystemPathRule
            var label: String
            var isFile: Bool
        }

        var seen: Set<String> = []
        var candidates: [Candidate] = []

        for rule in rules {
            if context.shouldCancel() { return [] }
            for spec in rule.pathSpecs(for: context.platform) {
                for base in Self.expand(spec: spec, resolver: context.resolver) {
                    if context.shouldCancel() { return [] }
                    switch rule.mode {
                    case .directory:
                        let isFile = rule.kind == .file
                        guard SystemProbeHelpers.pathExists(base.path, isDirectory: !isFile) else { continue }
                        if context.exclusionFilter.shouldExcludeDirectory(url: base) { continue }
                        guard seen.insert(base.path).inserted else { continue }
                        candidates.append(Candidate(url: base, rule: rule, label: Self.label(for: rule, url: base, spec: spec), isFile: isFile))
                    case .children:
                        guard SystemProbeHelpers.pathExists(base.path) else { continue }
                        if context.exclusionFilter.shouldExcludeDirectory(url: base) { continue }
                        for child in SystemProbeHelpers.childDirectories(of: base) {
                            if context.exclusionFilter.shouldExcludeDirectory(url: child) { continue }
                            guard seen.insert(child.path).inserted else { continue }
                            candidates.append(Candidate(url: child, rule: rule, label: Self.label(for: rule, url: child, spec: spec), isFile: false))
                        }
                    }
                }
            }
        }

        if candidates.isEmpty || context.shouldCancel() { return [] }

        let dirURLs = candidates.filter { !$0.isFile }.map(\.url)
        let sizes = await RoomyDirectorySizeReader.bytesConcurrently(urls: dirURLs, shouldCancel: context.shouldCancel)

        var findings: [ScanArtifactFinding] = []
        for c in candidates {
            let size: Int64?
            if c.isFile {
                size = RoomyDirectorySizeReader.fileBytes(at: c.url)
            } else {
                size = sizes[c.url]
            }
            guard let size, size >= SystemProbeHelpers.minBytes else { continue }
            let activity: Date?
            switch c.rule.activity {
            case .none: activity = nil
            case .self: activity = RoomyDirectorySizeReader.modificationDate(at: c.url)
            case .newestChild: activity = c.isFile
                ? RoomyDirectorySizeReader.modificationDate(at: c.url)
                : RoomyDirectorySizeReader.newestModificationDate(in: c.url)
            }
            findings.append(SystemProbeHelpers.finding(
                path: c.url.path,
                label: c.label,
                sizeBytes: size,
                ecosystemTag: c.rule.ecosystem,
                groupRoot: c.rule.groupRoot,
                safetyTier: c.rule.tier,
                restoreHint: c.rule.restoreHint,
                lastActivityDate: activity,
                ruleID: c.rule.id
            ))
        }
        return findings
    }

    /// Expands `~`, variables and globs in any path component. Returns existing matches only when globbing.
    static func expand(spec: String, resolver: RoomyPathResolver) -> [URL] {
        guard let resolved = resolver.resolve(spec) else { return [] }
        let path = resolved.path
        guard GlobMatcher.isGlob(path) else { return [resolved] }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var current: [URL] = [URL(fileURLWithPath: "/", isDirectory: true)]
        let fm = FileManager.default
        for component in components {
            var next: [URL] = []
            if GlobMatcher.isGlob(component) {
                for base in current {
                    guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
                    for name in names.sorted() where GlobMatcher.matches(name: name, pattern: component) {
                        next.append(base.appendingPathComponent(name))
                    }
                }
            } else {
                for base in current {
                    let candidate = base.appendingPathComponent(component)
                    if fm.fileExists(atPath: candidate.path) { next.append(candidate) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current.map { $0.standardizedFileURL }
    }

    static func label(for rule: SystemPathRule, url: URL, spec: String) -> String {
        let name = url.lastPathComponent
        if let template = rule.childLabel {
            return template
                .replacingOccurrences(of: "{name}", with: name)
                .replacingOccurrences(of: "{parent}", with: Self.parentDisplayName(for: url))
        }
        if rule.mode == .children { return "\(rule.label) · \(name)" }
        if GlobMatcher.isGlob(spec) {
            let lastComponent = spec.split(separator: "/").last.map(String.init) ?? spec
            if GlobMatcher.isGlob(lastComponent) {
                // `/tmp/claude-*` → "Claude Code scratch directories · claude-501"
                return "\(rule.label) · \(name)"
            }
            // `Library/Application Support/*/Crashpad/pending` → "Cursor · Crash dumps"
            return "\(Self.parentDisplayName(for: url)) · \(rule.label)"
        }
        return rule.label
    }

    /// For `.../<App>/Crashpad/pending`, returns `<App>`; otherwise the parent folder name.
    private static func parentDisplayName(for url: URL) -> String {
        var cursor = url.deletingLastPathComponent()
        let skip: Set<String> = ["Crashpad", "pending", "completed", "web", "tmp", "X"]
        var hops = 0
        while skip.contains(cursor.lastPathComponent), hops < 4 {
            cursor = cursor.deletingLastPathComponent()
            hops += 1
        }
        return cursor.lastPathComponent
    }
}
