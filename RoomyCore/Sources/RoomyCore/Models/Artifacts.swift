//
//  Artifacts.swift
//  RoomyCore
//
//  Core value types shared by the Mac app, the CLI and the fleet tooling.
//  Foundation only. Nothing in this file may know about a UI.
//

import Foundation

/// Where a finding came from. Decides how it is deleted.
public enum ArtifactSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// A folder found while walking project trees (node_modules, .venv, target/ …).
    case projectWalk
    /// A fixed-path folder owned by a tool (DerivedData, ~/.cache/pip, Cursor's state …).
    case systemProbe
    /// A `docker:` target removed through the Docker CLI.
    case dockerCLI
    /// A `conda:` target removed through the Conda CLI.
    case condaCLI
    /// A `pip:orphan:` target handled through pip.
    case pipCLI
}

/// How safe it is to remove a finding. This is the vocabulary that policies,
/// the app's badges and the CLI's refusals all share.
public enum ArtifactSafetyTier: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    /// Fully regenerable from source or re-downloadable. Deleting loses nothing.
    case safe
    /// Regenerable but with a cost (re-download, rebuild) or mixed with user data. Review first.
    case caution
    /// Not regenerable. Session history, archives, database volumes. Never bulk-selected.
    case warning

    public var displayLabel: String {
        switch self {
        case .safe: return "Safe"
        case .caution: return "Review"
        case .warning: return "Irreversible"
        }
    }

    private var rank: Int {
        switch self {
        case .safe: return 0
        case .caution: return 1
        case .warning: return 2
        }
    }

    public static func < (lhs: ArtifactSafetyTier, rhs: ArtifactSafetyTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum RoomyArtifactSafety {
    /// Bulk dormant selection (app) and unattended policies (fleet) skip warning-tier artifacts.
    public static func isEligibleForBulkDormantSelection(tier: ArtifactSafetyTier) -> Bool {
        tier != .warning
    }
}

/// One discovered artifact directory (e.g. a `node_modules` tree) or CLI-managed target.
public struct ScanArtifactFinding: Sendable, Codable, Equatable, Hashable {
    /// Filesystem path, or a synthetic target (`docker:prune:dangling`, `conda:env:foo`, `pip:orphan:/path`).
    public var path: String
    /// Last path component or display label (e.g. `node_modules`, `target/`, `Ollama models`).
    public var label: String
    public var sizeBytes: Int64
    /// Short tag: npm, py, rust, swift, go, java, ruby, dotnet, ai, general
    public var ecosystemTag: String
    /// Synthetic group key for system artifacts (see `RoomySystemGroupRoot`); nil for project-walk findings.
    public var groupRoot: String?
    public var source: ArtifactSource
    public var safetyTier: ArtifactSafetyTier
    public var restoreHint: String?
    public var lastActivityDate: Date?
    /// Identifier of the catalog rule that produced this finding, when one did.
    public var ruleID: String?

    public init(
        path: String,
        label: String,
        sizeBytes: Int64,
        ecosystemTag: String,
        groupRoot: String? = nil,
        source: ArtifactSource = .projectWalk,
        safetyTier: ArtifactSafetyTier = .safe,
        restoreHint: String? = nil,
        lastActivityDate: Date? = nil,
        ruleID: String? = nil
    ) {
        self.path = path
        self.label = label
        self.sizeBytes = sizeBytes
        self.ecosystemTag = ecosystemTag
        self.groupRoot = groupRoot
        self.source = source
        self.safetyTier = safetyTier
        self.restoreHint = restoreHint
        self.lastActivityDate = lastActivityDate
        self.ruleID = ruleID
    }

    enum CodingKeys: String, CodingKey {
        case path, label, sizeBytes, ecosystemTag, groupRoot, source, safetyTier, restoreHint, lastActivityDate, ruleID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        label = try c.decode(String.self, forKey: .label)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        ecosystemTag = try c.decode(String.self, forKey: .ecosystemTag)
        groupRoot = try c.decodeIfPresent(String.self, forKey: .groupRoot)
        source = try c.decodeIfPresent(ArtifactSource.self, forKey: .source) ?? .projectWalk
        safetyTier = try c.decodeIfPresent(ArtifactSafetyTier.self, forKey: .safetyTier) ?? .safe
        restoreHint = try c.decodeIfPresent(String.self, forKey: .restoreHint)
        lastActivityDate = try c.decodeIfPresent(Date.self, forKey: .lastActivityDate)
        ruleID = try c.decodeIfPresent(String.self, forKey: .ruleID)
    }

    /// True for `docker:`, `conda:` and `pip:` targets that are not filesystem paths.
    public var isCLITarget: Bool {
        path.hasPrefix("docker:") || path.hasPrefix("conda:") || path.hasPrefix("pip:")
    }
}

/// Rolled-up numbers for a scan.
public struct ScanAggregate: Sendable, Codable, Equatable {
    public var totalBytes: Int64
    /// Distinct “project” roots (parent folder of an artifact) plus synthetic system group keys.
    public var projectRootPaths: Set<String>
    public var artifactCount: Int
    /// ecosystem tag -> total bytes
    public var bytesByEcosystem: [String: Int64]
    /// ecosystem tag -> distinct project roots touching that ecosystem
    public var ecosystemProjectRoots: [String: Set<String>]
    /// Largest 32 findings, for tickers and summaries.
    public var sampleFindings: [ScanArtifactFinding]
    /// Expanded filesystem path (or system group key) -> findings under that root.
    public var artifactsByProjectRoot: [String: [ScanArtifactFinding]]

    public init(
        totalBytes: Int64,
        projectRootPaths: Set<String>,
        artifactCount: Int,
        bytesByEcosystem: [String: Int64],
        ecosystemProjectRoots: [String: Set<String>],
        sampleFindings: [ScanArtifactFinding],
        artifactsByProjectRoot: [String: [ScanArtifactFinding]]
    ) {
        self.totalBytes = totalBytes
        self.projectRootPaths = projectRootPaths
        self.artifactCount = artifactCount
        self.bytesByEcosystem = bytesByEcosystem
        self.ecosystemProjectRoots = ecosystemProjectRoots
        self.sampleFindings = sampleFindings
        self.artifactsByProjectRoot = artifactsByProjectRoot
    }

    public static let empty = ScanAggregate(
        totalBytes: 0,
        projectRootPaths: Set(),
        artifactCount: 0,
        bytesByEcosystem: [:],
        ecosystemProjectRoots: [:],
        sampleFindings: [],
        artifactsByProjectRoot: [:]
    )

    /// Every finding, flattened. Order is not stable; sort before presenting.
    public var allFindings: [ScanArtifactFinding] {
        artifactsByProjectRoot.values.flatMap { $0 }
    }

    /// Builds an aggregate from a flat list of findings, grouping by `groupRoot` or parent folder.
    public static func build(from findings: [ScanArtifactFinding]) -> ScanAggregate {
        var totalBytes: Int64 = 0
        var projectRoots: Set<String> = []
        var bytesByEcosystem: [String: Int64] = [:]
        var ecoProjects: [String: Set<String>] = [:]
        var artifactsByProjectRoot: [String: [ScanArtifactFinding]] = [:]

        for finding in findings {
            totalBytes += finding.sizeBytes
            let root: String
            if let g = finding.groupRoot {
                root = g
            } else if finding.isCLITarget {
                root = finding.path
            } else {
                root = URL(fileURLWithPath: finding.path).deletingLastPathComponent().path
            }
            projectRoots.insert(root)
            bytesByEcosystem[finding.ecosystemTag, default: 0] += finding.sizeBytes
            ecoProjects[finding.ecosystemTag, default: []].insert(root)
            artifactsByProjectRoot[root, default: []].append(finding)
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

    public static func merge(_ a: ScanAggregate, _ b: ScanAggregate) -> ScanAggregate {
        if a.artifactCount == 0 { return b }
        if b.artifactCount == 0 { return a }

        var mergedRoots = a.projectRootPaths
        mergedRoots.formUnion(b.projectRootPaths)

        var mergedByRoot = a.artifactsByProjectRoot
        for (root, findings) in b.artifactsByProjectRoot {
            mergedByRoot[root, default: []].append(contentsOf: findings)
        }

        var allFindings: [ScanArtifactFinding] = []
        for findings in mergedByRoot.values {
            allFindings.append(contentsOf: findings)
        }

        var bytesByEco = a.bytesByEcosystem
        for (eco, bytes) in b.bytesByEcosystem {
            bytesByEco[eco, default: 0] += bytes
        }

        var ecoProjects = a.ecosystemProjectRoots
        for (eco, roots) in b.ecosystemProjectRoots {
            ecoProjects[eco, default: []].formUnion(roots)
        }

        let sortedSamples = allFindings.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(32)
        return ScanAggregate(
            totalBytes: a.totalBytes + b.totalBytes,
            projectRootPaths: mergedRoots,
            artifactCount: allFindings.count,
            bytesByEcosystem: bytesByEco,
            ecosystemProjectRoots: ecoProjects,
            sampleFindings: Array(sortedSamples),
            artifactsByProjectRoot: mergedByRoot
        )
    }
}

/// Git and disk facts about one project folder.
public struct ProjectGitMetadata: Equatable, Sendable, Codable {
    public var isGitRepo: Bool
    public var lastCommitDate: Date?
    public var commitSubject: String
    public var isClean: Bool
    public var gitStatusLine: String
    public var totalProjectSizeBytes: Int64
    public var lastModified: Date?

    public init(
        isGitRepo: Bool,
        lastCommitDate: Date?,
        commitSubject: String,
        isClean: Bool,
        gitStatusLine: String,
        totalProjectSizeBytes: Int64,
        lastModified: Date?
    ) {
        self.isGitRepo = isGitRepo
        self.lastCommitDate = lastCommitDate
        self.commitSubject = commitSubject
        self.isClean = isClean
        self.gitStatusLine = gitStatusLine
        self.totalProjectSizeBytes = totalProjectSizeBytes
        self.lastModified = lastModified
    }
}

/// Human-readable byte counts, shared by CLI and app.
public enum ByteFormatting {
    public static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }
}
