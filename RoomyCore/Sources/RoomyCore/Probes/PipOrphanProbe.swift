//
//  PipOrphanProbe.swift
//  RoomyCore
//
//  Compares installed packages in project venvs against requirements files.
//

import Foundation

public struct PipOrphanProbe: Sendable {
    public init() {}

    public func scan(projectAggregate: ScanAggregate, shouldCancel: @escaping @Sendable () -> Bool) async -> [ScanArtifactFinding] {
        var findings: [ScanArtifactFinding] = []
        for (projectRoot, artifacts) in projectAggregate.artifactsByProjectRoot {
            if shouldCancel() { break }
            if RoomySystemGroupRoot.isSystemRoot(projectRoot) { continue }
            for artifact in artifacts {
                if shouldCancel() { break }
                let name = artifact.label.lowercased()
                guard name.contains("venv") else { continue }
                let projectURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
                guard let declared = declaredPackages(in: projectURL) else { continue }
                guard let installed = installedPackages(venvPath: artifact.path) else { continue }
                let orphans = installed.subtracting(declared).filter { !isStandardPackage($0) }
                guard !orphans.isEmpty else { continue }
                findings.append(SystemProbeHelpers.finding(
                    path: "pip:orphan:\(artifact.path)",
                    label: "Unused pip packages (\(orphans.count))",
                    sizeBytes: max(Int64(orphans.count) * 10_485_760, SystemProbeHelpers.minBytes),
                    ecosystemTag: "py", groupRoot: projectRoot, source: .pipCLI, safetyTier: .caution,
                    restoreHint: "pip install to restore: \(orphans.sorted().prefix(5).joined(separator: ", "))",
                    ruleID: "pip-orphans"
                ))
            }
        }
        return findings
    }

    private func declaredPackages(in project: URL) -> Set<String>? {
        for file in ["requirements.txt", "requirements-dev.txt"].map({ project.appendingPathComponent($0) }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var names: Set<String> = []
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let token = trimmed.split { $0.isWhitespace || $0 == "@" || $0 == ";" }.first.map(String.init) ?? trimmed
                let normalized = token.replacingOccurrences(of: "_", with: "-").lowercased()
                    .components(separatedBy: CharacterSet(charactersIn: "[<=>!~")).first ?? token
                if !normalized.isEmpty { names.insert(normalized) }
            }
            if !names.isEmpty { return names }
        }
        return nil
    }

    private func installedPackages(venvPath: String) -> Set<String>? {
        let pip = URL(fileURLWithPath: venvPath, isDirectory: true).appendingPathComponent("bin/pip").path
        guard FileManager.default.isExecutableFile(atPath: pip) else { return nil }
        guard let out = ProcessRunner.output(executable: pip, arguments: ["list", "--format=freeze"], timeout: 15) else { return nil }
        var names: Set<String> = []
        for line in out.split(separator: "\n") {
            let pkg = line.split(separator: "==").first.map(String.init) ?? String(line)
            let normalized = pkg.replacingOccurrences(of: "_", with: "-").lowercased()
            if !normalized.isEmpty { names.insert(normalized) }
        }
        return names
    }

    private func isStandardPackage(_ name: String) -> Bool {
        ["pip", "setuptools", "wheel", "pkg-resources"].contains(name)
    }
}
