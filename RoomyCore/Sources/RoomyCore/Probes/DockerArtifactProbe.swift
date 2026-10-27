//
//  DockerArtifactProbe.swift
//  RoomyCore
//

import Foundation

public struct DockerArtifactProbe: SystemArtifactProbe {
    public let categoryKey = "docker"

    public init() {}

    public func scan(context: SystemProbeContext) async -> [ScanArtifactFinding] {
        guard let docker = Self.resolveDocker() else { return [] }
        guard dockerInfo(executable: docker) else { return [] }
        if context.shouldCancel() { return [] }

        var findings: [ScanArtifactFinding] = []

        if let dangling = danglingImages(executable: docker), dangling.bytes >= SystemProbeHelpers.minBytes {
            findings.append(SystemProbeHelpers.finding(
                path: "docker:prune:dangling",
                label: "Docker dangling images (\(dangling.count))",
                sizeBytes: dangling.bytes, ecosystemTag: "general",
                groupRoot: RoomySystemGroupRoot.docker, source: .dockerCLI, safetyTier: .caution,
                restoreHint: "docker pull re-downloads images as needed", ruleID: "docker-dangling-images"
            ))
        }

        if let buildCache = buildCacheSize(executable: docker), buildCache >= SystemProbeHelpers.minBytes {
            findings.append(SystemProbeHelpers.finding(
                path: "docker:prune:buildcache",
                label: "Docker build cache",
                sizeBytes: buildCache, ecosystemTag: "general",
                groupRoot: RoomySystemGroupRoot.docker, source: .dockerCLI, safetyTier: .caution,
                restoreHint: "Rebuilds recreate build cache", ruleID: "docker-build-cache"
            ))
        }

        findings.append(contentsOf: unusedVolumes(executable: docker, shouldCancel: context.shouldCancel))
        return findings
    }

    public static func resolveDocker() -> String? {
        ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker", ProcessRunner.which("docker")]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runDocker(_ executable: String, _ args: [String]) -> String? {
        ProcessRunner.output(executable: executable, arguments: args, timeout: 12)
    }

    private func dockerInfo(executable: String) -> Bool {
        runDocker(executable, ["info", "--format", "{{.ServerVersion}}"]) != nil
    }

    private func danglingImages(executable: String) -> (count: Int, bytes: Int64)? {
        guard let out = runDocker(executable, ["images", "-f", "dangling=true", "--format", "{{.ID}}"]) else { return nil }
        let ids = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if ids.isEmpty { return nil }
        var total: Int64 = 0
        for id in ids {
            if let sizeLine = runDocker(executable, ["inspect", "--format", "{{.Size}}", id]),
               let size = Int64(sizeLine.trimmingCharacters(in: .whitespacesAndNewlines)) {
                total += size
            }
        }
        return (ids.count, max(total, Int64(ids.count) * SystemProbeHelpers.minBytes))
    }

    private func buildCacheSize(executable: String) -> Int64? {
        guard let out = runDocker(executable, ["system", "df", "--format", "{{.Type}}\t{{.Size}}"]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2, parts[0].lowercased().contains("build") else { continue }
            return Self.parseDockerSize(String(parts[1]))
        }
        return nil
    }

    private func unusedVolumes(executable: String, shouldCancel: @escaping @Sendable () -> Bool) -> [ScanArtifactFinding] {
        guard let out = runDocker(executable, ["volume", "ls", "--format", "{{.Name}}"]) else { return [] }
        let used = usedVolumeNames(executable: executable)
        var findings: [ScanArtifactFinding] = []
        for name in out.split(separator: "\n").map(String.init) where !name.isEmpty {
            if shouldCancel() { break }
            if used.contains(name) { continue }
            findings.append(SystemProbeHelpers.finding(
                path: "docker:volume:\(name)",
                label: "Docker volume: \(name)",
                sizeBytes: SystemProbeHelpers.minBytes, ecosystemTag: "general",
                groupRoot: RoomySystemGroupRoot.docker, source: .dockerCLI, safetyTier: .warning,
                restoreHint: "Volumes may contain database data — not recoverable", ruleID: "docker-unused-volume"
            ))
        }
        return findings
    }

    private func usedVolumeNames(executable: String) -> Set<String> {
        guard let out = runDocker(executable, ["ps", "-a", "--format", "{{.Names}}"]) else { return [] }
        var used: Set<String> = []
        for container in out.split(separator: "\n").map(String.init) where !container.isEmpty {
            if let mounts = runDocker(executable, ["inspect", "--format", "{{range .Mounts}}{{.Name}} {{end}}", container]) {
                for part in mounts.split(separator: " ") where !part.isEmpty { used.insert(String(part)) }
            }
        }
        return used
    }

    static func parseDockerSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("GB"), let val = Double(trimmed.dropLast(2)) { return Int64(val * 1_073_741_824) }
        if trimmed.hasSuffix("MB"), let val = Double(trimmed.dropLast(2)) { return Int64(val * 1_048_576) }
        if trimmed.hasSuffix("kB"), let val = Double(trimmed.dropLast(2)) { return Int64(val * 1024) }
        if trimmed.hasSuffix("B"), let val = Double(trimmed.dropLast(1)) { return Int64(val) }
        return nil
    }
}
