//
//  HomebrewCacheProbe.swift
//  RoomyCore
//
//  The formula cache under the brew prefix. The fixed user-level caches are catalog rules.
//

import Foundation

public struct HomebrewCacheProbe: SystemArtifactProbe {
    public let categoryKey = "homebrew"
    public var supportedPlatforms: Set<RoomyPlatform> { [.macOS] }

    public init() {}

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        guard ProcessRunner.which("brew") != nil,
              let prefixOut = ProcessRunner.output(executable: ProcessRunner.envExecutable, arguments: ["brew", "--prefix"], timeout: 5)
        else { return [] }
        if context.shouldCancel() { return [] }
        let cachePath = URL(fileURLWithPath: prefixOut, isDirectory: true).appendingPathComponent("var/homebrew/cache", isDirectory: true)
        guard SystemProbeHelpers.pathExists(cachePath.path), !context.exclusionFilter.shouldExcludeDirectory(url: cachePath) else { return [] }
        let size = await Task.detached { RoomyDirectorySizeReader.bytes(at: cachePath) }.value
        guard let size, size >= SystemProbeHelpers.minBytes else { return [] }
        return [SystemProbeHelpers.finding(
            path: cachePath.path, label: "Homebrew formula cache", sizeBytes: size, ecosystemTag: "general",
            groupRoot: RoomySystemGroupRoot.homebrew,
            restoreHint: "Caches rebuild automatically; use brew reinstall for removed downloads", ruleID: "homebrew-formula-cache"
        )]
    }
}
