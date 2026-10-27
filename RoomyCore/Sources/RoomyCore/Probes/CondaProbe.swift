//
//  CondaProbe.swift
//  RoomyCore
//

import Foundation

public struct CondaProbe: SystemArtifactProbe {
    public let categoryKey = "python"

    public init() {}

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        guard resolveCondaExecutable(home: context.home) != nil else { return [] }
        if context.shouldCancel() { return [] }

        var findings: [ScanArtifactFinding] = []
        let cleanTargets: [(args: [String], label: String, deletionKey: String)] = [
            (["clean", "--packages", "--dry-run"], "Conda unused packages", "conda:clean:packages"),
            (["clean", "--tarballs", "--dry-run"], "Conda tarballs", "conda:clean:tarballs"),
            (["clean", "--index-cache", "--dry-run"], "Conda index cache", "conda:clean:index-cache"),
        ]
        for target in cleanTargets {
            if context.shouldCancel() { break }
            if let finding = condaCleanFinding(args: target.args, label: target.label, deletionKey: target.deletionKey) {
                findings.append(finding)
            }
        }
        findings.append(contentsOf: await dormantCondaEnvironments(context: context))
        return findings
    }

    private func resolveCondaExecutable(home: URL) -> String? {
        if let path = ProcessRunner.which("conda") { return path }
        let candidates = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba"]
            .map { home.appendingPathComponent("\($0)/bin/conda").path }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runConda(_ arguments: [String]) -> String? {
        ProcessRunner.output(executable: ProcessRunner.envExecutable, arguments: ["conda"] + arguments, timeout: 15)
    }

    private func condaCleanFinding(args: [String], label: String, deletionKey: String) -> ScanArtifactFinding? {
        guard let output = runConda(args) else { return nil }
        let lower = output.lowercased()
        if lower.contains("there are no") || lower.contains("nothing to") { return nil }
        let size = SystemProbeHelpers.parseSizeFromCondaDryRun(output) ?? SystemProbeHelpers.minBytes
        guard size >= SystemProbeHelpers.minBytes else { return nil }
        return SystemProbeHelpers.finding(
            path: deletionKey, label: label, sizeBytes: size, ecosystemTag: "py",
            groupRoot: RoomySystemGroupRoot.python, source: .condaCLI,
            restoreHint: "conda install or conda env update re-downloads as needed", ruleID: "conda-clean"
        )
    }

    private func dormantCondaEnvironments(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        guard let json = runConda(["env", "list", "--json"]),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envs = object["envs"] as? [String] else { return [] }
        let base = runConda(["info", "--base"])?.trimmingCharacters(in: .whitespacesAndNewlines)

        var findings: [ScanArtifactFinding] = []
        for envPath in envs {
            if context.shouldCancel() { break }
            if envPath == base { continue } // never offer base env deletion
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if context.exclusionFilter.shouldExcludeDirectory(url: url) { continue }
            guard SystemProbeHelpers.pathExists(envPath) else { continue }
            let size = await Task.detached { RoomyDirectorySizeReader.bytes(at: url) }.value
            guard let size, size >= SystemProbeHelpers.minBytes else { continue }
            let envName = url.lastPathComponent
            findings.append(SystemProbeHelpers.finding(
                path: "conda:env:\(envName)", label: "conda env: \(envName)", sizeBytes: size, ecosystemTag: "py",
                groupRoot: RoomySystemGroupRoot.python, source: .condaCLI, safetyTier: .caution,
                restoreHint: "conda env create -f environment.yml if you exported one",
                lastActivityDate: RoomyDirectorySizeReader.modificationDate(at: url), ruleID: "conda-env"
            ))
        }
        return findings
    }
}
