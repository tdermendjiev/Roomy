//
//  FilesystemArtifactScanner.swift
//  RoomyCore
//
//  Walks a directory tree, detects regenerable artifact folders from the rule catalog, measures sizes.
//  Runs off the main thread; progress is reported on the caller’s schedule.
//

import Foundation

public struct FilesystemArtifactScanner: Sendable {

    public struct ProgressTick: Sendable {
        public var foldersScanned: Int
        /// Distinct project roots seen so far (parent of an artifact folder).
        public var projectRootsFound: Int
        /// Tilde-shortened path for UI
        public var currentPathDisplay: String
        public var artifactsFound: Int
        public var recoverableBytes: Int64
        public var latestFinding: ScanArtifactFinding?
    }

    /// Scan `root` and invoke `onProgress` periodically from a background task.
    /// `enabledEcosystemTags`: only artifact rules whose resolved ecosystem tag is in this set are counted; empty set skips all rules.
    public static func scan(
        root: URL,
        homeDirectory: URL,
        enabledEcosystemTags: Set<String>,
        exclusionFilter: RoomyScanExclusionFilter = .empty,
        catalog: RuleCatalog = .builtin,
        shouldCancel: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (ProgressTick) -> Void
    ) async -> ScanAggregate {
        await Task.detached(priority: .userInitiated) {
            performScan(
                root: root,
                homeDirectory: homeDirectory,
                enabledEcosystemTags: enabledEcosystemTags,
                exclusionFilter: exclusionFilter,
                catalog: catalog,
                shouldCancel: shouldCancel,
                onProgress: onProgress
            )
        }.value
    }

    /// Synchronous variant for the CLI and tests.
    public static func performScan(
        root: URL,
        homeDirectory: URL,
        enabledEcosystemTags: Set<String>,
        exclusionFilter: RoomyScanExclusionFilter = .empty,
        catalog: RuleCatalog = .builtin,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (ProgressTick) -> Void = { _ in }
    ) -> ScanAggregate {
        var foldersScanned = 0
        var findings: [ScanArtifactFinding] = []
        var projectRoots: Set<String> = []
        var totalBytes: Int64 = 0
        var lastProgress = Date(timeIntervalSince1970: 0)

        let rules = catalog.projectRules(for: RoomyPlatform.current)
        var rulesByName: [String: [ProjectArtifactRule]] = [:]
        for r in rules { rulesByName[r.folderName, default: []].append(r) }

        let fm = FileManager.default
        if exclusionFilter.shouldExcludeDirectory(url: root) { return .empty }
        let rootPath = root.standardizedFileURL.path
        let skipFilter = catalog.walkSkipFilter(home: homeDirectory, scanRoot: root)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return .empty }

        while let url = enumerator.nextObject() as? URL {
            if shouldCancel() { break }

            if exclusionFilter.shouldExcludeDirectory(url: url) {
                enumerator.skipDescendants()
                continue
            }
            // Tool-owned trees (~/.nvm, ~/.cursor-server, ~/Library …) are never walked unless they are the root itself.
            if url.path != rootPath, skipFilter.shouldExcludeDirectory(url: url) {
                enumerator.skipDescendants()
                continue
            }

            foldersScanned += 1
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 0.12 || foldersScanned % 64 == 0 {
                lastProgress = now
                onProgress(ProgressTick(
                    foldersScanned: foldersScanned,
                    projectRootsFound: projectRoots.count,
                    currentPathDisplay: prettyPath(url, home: homeDirectory),
                    artifactsFound: findings.count,
                    recoverableBytes: totalBytes,
                    latestFinding: findings.last
                ))
            }

            let name = url.lastPathComponent
            guard let candidates = rulesByName[name] else { continue }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let projectDir = url.deletingLastPathComponent()
            guard let (rule, eco) = resolveRule(candidates, projectDir: projectDir) else { continue }

            if !enabledEcosystemTags.contains(eco) {
                // Still don't descend into a matched artifact: nothing useful lives under node_modules.
                enumerator.skipDescendants()
                continue
            }

            let size: Int64
            do {
                size = try directorySize(at: url)
            } catch {
                enumerator.skipDescendants()
                continue
            }

            // For `.claude/worktrees` the "project" is the repo, not the `.claude` folder.
            let projectRoot = rule.parentName != nil ? projectDir.deletingLastPathComponent().path : projectDir.path
            projectRoots.insert(projectRoot)
            totalBytes += size

            let finding = ScanArtifactFinding(
                path: url.path,
                label: rule.label,
                sizeBytes: size,
                ecosystemTag: eco,
                safetyTier: rule.tier,
                restoreHint: rule.restoreHint,
                lastActivityDate: nil,
                ruleID: rule.id
            )
            findings.append(finding)

            onProgress(ProgressTick(
                foldersScanned: foldersScanned,
                projectRootsFound: projectRoots.count,
                currentPathDisplay: prettyPath(url, home: homeDirectory),
                artifactsFound: findings.count,
                recoverableBytes: totalBytes,
                latestFinding: finding
            ))

            enumerator.skipDescendants()
        }

        return aggregate(findings: findings, rules: rules)
    }

    /// Groups findings under their project root (parent folder, or grandparent for `parentName` rules).
    static func aggregate(findings: [ScanArtifactFinding], rules: [ProjectArtifactRule]) -> ScanAggregate {
        let parentRules = Set(rules.filter { $0.parentName != nil }.map(\.id))
        var totalBytes: Int64 = 0
        var projectRoots: Set<String> = []
        var bytesByEcosystem: [String: Int64] = [:]
        var ecoProjects: [String: Set<String>] = [:]
        var artifactsByProjectRoot: [String: [ScanArtifactFinding]] = [:]

        for f in findings {
            let url = URL(fileURLWithPath: f.path)
            var root = url.deletingLastPathComponent()
            if let id = f.ruleID, parentRules.contains(id) { root = root.deletingLastPathComponent() }
            let rootPath = root.path
            projectRoots.insert(rootPath)
            totalBytes += f.sizeBytes
            bytesByEcosystem[f.ecosystemTag, default: 0] += f.sizeBytes
            ecoProjects[f.ecosystemTag, default: []].insert(rootPath)
            artifactsByProjectRoot[rootPath, default: []].append(f)
        }

        let sortedSamples = findings.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(32)
        return ScanAggregate(
            totalBytes: totalBytes,
            projectRootPaths: projectRoots,
            artifactCount: findings.count,
            bytesByEcosystem: bytesByEcosystem,
            ecosystemProjectRoots: ecoProjects,
            sampleFindings: Array(sortedSamples),
            artifactsByProjectRoot: artifactsByProjectRoot
        )
    }

    /// Picks the first rule whose parent constraint holds and resolves its ecosystem from marker files.
    static func resolveRule(_ candidates: [ProjectArtifactRule], projectDir: URL) -> (ProjectArtifactRule, String)? {
        let fm = FileManager.default
        for rule in candidates {
            if let parent = rule.parentName, projectDir.lastPathComponent != parent { continue }
            var eco: String? = nil
            for marker in rule.markers {
                if marker.files.contains(where: { markerExists($0, in: projectDir, fm: fm) }) {
                    eco = marker.ecosystem
                    break
                }
            }
            if eco == nil && rule.requireMarker { continue }
            return (rule, eco ?? rule.ecosystem)
        }
        return nil
    }

    private static func markerExists(_ pattern: String, in dir: URL, fm: FileManager) -> Bool {
        if GlobMatcher.isGlob(pattern) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            return names.contains { GlobMatcher.matches(name: $0, pattern: pattern) }
        }
        return fm.fileExists(atPath: dir.appendingPathComponent(pattern).path)
    }

    private static func directorySize(at root: URL) throws -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        while let fileURL = enumerator.nextObject() as? URL {
            let v = try fileURL.resourceValues(forKeys: keys)
            if v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    private static func prettyPath(_ url: URL, home: URL) -> String {
        RoomyPathResolver(home: home).display(url.path)
    }

    /// Tilde-shortened path for tickers and tables.
    public static func shortenedDisplayPath(filePath: String, homeDirectory home: URL) -> String {
        RoomyPathResolver(home: home).display(filePath)
    }
}
