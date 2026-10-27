//
//  SystemArtifactScanner.swift
//  RoomyCore
//

import Foundation

public struct SystemArtifactScanner: Sendable {
    public struct ProgressTick: Sendable {
        public var phaseLabel: String
        public var artifactsFound: Int
        public var recoverableBytes: Int64
        public var latestFinding: ScanArtifactFinding?
    }

    public static func scan(
        homeDirectory: URL,
        enabledCategories: Set<String>,
        enabledEcosystemTags: Set<String>,
        exclusionFilter: RoomyScanExclusionFilter,
        projectAggregate: ScanAggregate,
        catalog: RuleCatalog = .builtin,
        shouldCancel: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (ProgressTick) -> Void
    ) async -> ScanAggregate {
        let context = SystemProbeContext(home: homeDirectory, exclusionFilter: exclusionFilter, catalog: catalog, shouldCancel: shouldCancel)
        let probes = buildProbes(enabledCategories: enabledCategories, platform: context.platform)
        var allFindings: [ScanArtifactFinding] = []
        var totalBytes: Int64 = 0

        func report(_ f: ScanArtifactFinding?) {
            onProgress(ProgressTick(phaseLabel: "Checking system caches…", artifactsFound: allFindings.count,
                                    recoverableBytes: totalBytes, latestFinding: f))
        }

        for probe in probes {
            if shouldCancel() { break }
            report(allFindings.last)
            let findings = await probe.scan(context: context)
            for f in findings where enabledEcosystemTags.contains(f.ecosystemTag) || f.ecosystemTag == "general" {
                allFindings.append(f)
                totalBytes += f.sizeBytes
                report(f)
            }
        }

        if enabledCategories.contains("python"), !shouldCancel() {
            let pipFindings = await PipOrphanProbe().scan(projectAggregate: projectAggregate, shouldCancel: shouldCancel)
            for f in pipFindings where enabledEcosystemTags.contains(f.ecosystemTag) {
                allFindings.append(f)
                totalBytes += f.sizeBytes
            }
        }

        return ScanAggregate.build(from: allFindings)
    }

    /// Catalog probes for every enabled category, plus the code-backed probes that need them.
    public static func buildProbes(enabledCategories: Set<String>, platform: RoomyPlatform = .current) -> [any SystemArtifactProbe] {
        var probes: [any SystemArtifactProbe] = []
        for category in RoomySystemScanCategories.all where enabledCategories.contains(category.key) && category.platforms.contains(platform) {
            probes.append(CatalogPathProbe(categoryKey: category.key))
        }
        let coded: [any SystemArtifactProbe] = [
            XcodeArchivesProbe(), CoreSimulatorProbe(),
            GlobalModulesProbe(), CondaProbe(), HomebrewCacheProbe(), DockerArtifactProbe(), AIToolsProbe(),
        ]
        for probe in coded where enabledCategories.contains(probe.categoryKey) && probe.supportedPlatforms.contains(platform) {
            probes.append(probe)
        }
        return probes
    }
}
