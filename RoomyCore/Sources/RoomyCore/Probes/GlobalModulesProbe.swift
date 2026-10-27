//
//  GlobalModulesProbe.swift
//  RoomyCore
//

import Foundation

public struct GlobalModulesProbe: SystemArtifactProbe {
    public let categoryKey = "globalModules"

    public init() {}

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        var moduleRoots: [(URL, String)] = []
        if let npmGlobal = resolveNpmGlobalModules(home: context.home) { moduleRoots.append((npmGlobal, "Global npm modules")) }
        if let yarnGlobal = resolveYarnGlobalModules(home: context.home) { moduleRoots.append((yarnGlobal, "Global yarn modules")) }

        var findings: [ScanArtifactFinding] = []
        var seen: Set<String> = []
        for (url, label) in moduleRoots {
            if context.shouldCancel() { break }
            guard !seen.contains(url.path), SystemProbeHelpers.pathExists(url.path) else { continue }
            if context.exclusionFilter.shouldExcludeDirectory(url: url) { continue }
            let size = await Task.detached { RoomyDirectorySizeReader.bytes(at: url) }.value
            guard let size, size >= SystemProbeHelpers.minBytes else { continue }
            seen.insert(url.path)
            let packageCount = countTopLevelPackages(at: url)
            findings.append(SystemProbeHelpers.finding(
                path: url.path,
                label: packageCount > 0 ? "\(label) (\(packageCount) packages)" : label,
                sizeBytes: size, ecosystemTag: "npm", groupRoot: RoomySystemGroupRoot.globalModules,
                safetyTier: .caution, restoreHint: "Reinstall with npm install -g or yarn global add",
                lastActivityDate: RoomyDirectorySizeReader.modificationDate(at: url), ruleID: "global-node-modules"
            ))
        }
        return findings
    }

    private func resolveNpmGlobalModules(home: URL) -> URL? {
        if let prefix = ProcessRunner.output(executable: ProcessRunner.envExecutable, arguments: ["npm", "prefix", "-g"], timeout: 5) {
            let modules = URL(fileURLWithPath: prefix, isDirectory: true).appendingPathComponent("lib/node_modules", isDirectory: true)
            if SystemProbeHelpers.pathExists(modules.path) { return modules }
        }
        let fallbacks = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules", isDirectory: true),
            home.appendingPathComponent(".npm-global/lib/node_modules", isDirectory: true),
        ]
        for url in fallbacks where SystemProbeHelpers.pathExists(url.path) { return url }
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        for versionDir in SystemProbeHelpers.childDirectories(of: nvmRoot) {
            let modules = versionDir.appendingPathComponent("lib/node_modules", isDirectory: true)
            if SystemProbeHelpers.pathExists(modules.path) { return modules }
        }
        return nil
    }

    private func resolveYarnGlobalModules(home: URL) -> URL? {
        if let globalDir = ProcessRunner.output(executable: ProcessRunner.envExecutable, arguments: ["yarn", "global", "dir"], timeout: 5) {
            let modules = URL(fileURLWithPath: globalDir, isDirectory: true).appendingPathComponent("node_modules", isDirectory: true)
            if SystemProbeHelpers.pathExists(modules.path) { return modules }
        }
        let classic = home.appendingPathComponent(".config/yarn/global/node_modules", isDirectory: true)
        if SystemProbeHelpers.pathExists(classic.path) { return classic }
        return nil
    }

    private func countTopLevelPackages(at url: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
    }
}
