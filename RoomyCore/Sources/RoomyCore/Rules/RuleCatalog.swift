//
//  RuleCatalog.swift
//  RoomyCore
//
//  The rule catalog is data. The built-in copy is embedded in the binary at build time
//  (`Rules/builtin-rules.json`), and extra catalogs can be merged in from disk, which is
//  how a fleet policy or a user adds rules without a new release.
//

import Foundation

/// A folder name found while walking project trees.
public struct ProjectArtifactRule: Codable, Sendable, Equatable, Identifiable {
    public struct Marker: Codable, Sendable, Equatable {
        /// Ecosystem to assign when one of `files` exists next to the folder.
        public var ecosystem: String
        /// File names or simple globs (`*.csproj`) looked up in the parent directory.
        public var files: [String]
        public init(ecosystem: String, files: [String]) {
            self.ecosystem = ecosystem
            self.files = files
        }
    }

    public var id: String
    /// Last path component to match.
    public var folderName: String
    /// When set, the folder only matches if its parent folder has this name (e.g. `.claude/worktrees`).
    public var parentName: String?
    public var label: String
    /// Ecosystem when no marker matches.
    public var ecosystem: String
    public var tier: ArtifactSafetyTier
    public var restoreHint: String?
    /// Marker files that refine the ecosystem. First match wins.
    public var markers: [Marker]
    /// When true, the folder is ignored unless a marker matches (used for ambiguous names like `obj`).
    public var requireMarker: Bool
    /// Platforms where the rule applies. Empty means all.
    public var platforms: [RoomyPlatform]

    public init(
        id: String,
        folderName: String,
        parentName: String? = nil,
        label: String,
        ecosystem: String,
        tier: ArtifactSafetyTier = .safe,
        restoreHint: String? = nil,
        markers: [Marker] = [],
        requireMarker: Bool = false,
        platforms: [RoomyPlatform] = []
    ) {
        self.id = id
        self.folderName = folderName
        self.parentName = parentName
        self.label = label
        self.ecosystem = ecosystem
        self.tier = tier
        self.restoreHint = restoreHint
        self.markers = markers
        self.requireMarker = requireMarker
        self.platforms = platforms
    }

    enum CodingKeys: String, CodingKey {
        case id, folderName, parentName, label, ecosystem, tier, restoreHint, markers, requireMarker, platforms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folderName = try c.decode(String.self, forKey: .folderName)
        parentName = try c.decodeIfPresent(String.self, forKey: .parentName)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? folderName
        ecosystem = try c.decodeIfPresent(String.self, forKey: .ecosystem) ?? "general"
        tier = try c.decodeIfPresent(ArtifactSafetyTier.self, forKey: .tier) ?? .safe
        restoreHint = try c.decodeIfPresent(String.self, forKey: .restoreHint)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        requireMarker = try c.decodeIfPresent(Bool.self, forKey: .requireMarker) ?? false
        platforms = try c.decodeIfPresent([RoomyPlatform].self, forKey: .platforms) ?? []
    }

    public func applies(to platform: RoomyPlatform) -> Bool {
        platforms.isEmpty || platforms.contains(platform)
    }
}

/// A fixed-path location owned by a tool, with per-platform paths.
public struct SystemPathRule: Codable, Sendable, Equatable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        /// The matched path itself is one finding.
        case directory
        /// Each immediate child directory of the matched path is a finding.
        case children
    }

    public enum Kind: String, Codable, Sendable {
        case directory
        case file
    }

    public enum Activity: String, Codable, Sendable {
        /// No activity date.
        case none
        /// Modification date of the matched item itself.
        case `self`
        /// Newest modification date among the item and its direct children.
        case newestChild
    }

    public var id: String
    /// Category key, see `RoomySystemScanCategories`.
    public var category: String
    public var label: String
    public var ecosystem: String
    public var tier: ArtifactSafetyTier
    public var restoreHint: String?
    /// platform raw value -> path specs. Specs may contain `~`, `$VAR`, and a glob in any component.
    public var paths: [String: [String]]
    public var mode: Mode
    public var kind: Kind
    public var activity: Activity
    /// Label template for `children` mode or glob matches: `{name}` is the matched folder, `{parent}` its parent.
    public var childLabel: String?

    public init(
        id: String,
        category: String,
        label: String,
        ecosystem: String,
        tier: ArtifactSafetyTier = .safe,
        restoreHint: String? = nil,
        paths: [String: [String]],
        mode: Mode = .directory,
        kind: Kind = .directory,
        activity: Activity = .none,
        childLabel: String? = nil
    ) {
        self.id = id
        self.category = category
        self.label = label
        self.ecosystem = ecosystem
        self.tier = tier
        self.restoreHint = restoreHint
        self.paths = paths
        self.mode = mode
        self.kind = kind
        self.activity = activity
        self.childLabel = childLabel
    }

    enum CodingKeys: String, CodingKey {
        case id, category, label, ecosystem, tier, restoreHint, paths, mode, kind, activity, childLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        label = try c.decode(String.self, forKey: .label)
        ecosystem = try c.decodeIfPresent(String.self, forKey: .ecosystem) ?? "general"
        tier = try c.decodeIfPresent(ArtifactSafetyTier.self, forKey: .tier) ?? .safe
        restoreHint = try c.decodeIfPresent(String.self, forKey: .restoreHint)
        paths = try c.decode([String: [String]].self, forKey: .paths)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .directory
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .directory
        activity = try c.decodeIfPresent(Activity.self, forKey: .activity) ?? .none
        childLabel = try c.decodeIfPresent(String.self, forKey: .childLabel)
    }

    public func pathSpecs(for platform: RoomyPlatform) -> [String] {
        paths[platform.rawValue] ?? []
    }

    public func applies(to platform: RoomyPlatform) -> Bool {
        !pathSpecs(for: platform).isEmpty
    }

    public var groupRoot: String {
        RoomySystemGroupRoot.groupRoot(forCategory: category)
    }
}

public struct RuleCatalog: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var catalogVersion: String
    public var projectRules: [ProjectArtifactRule]
    public var systemRules: [SystemPathRule]
    /// Directories the project walk never enters: `all`, `macos`, `linux` → path specs (`~`-relative or absolute; bare names match any folder with that name).
    public var walkSkip: [String: [String]]

    public static let supportedSchemaVersion = 1

    public init(schemaVersion: Int = RuleCatalog.supportedSchemaVersion, catalogVersion: String, projectRules: [ProjectArtifactRule],
                systemRules: [SystemPathRule], walkSkip: [String: [String]] = [:]) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.projectRules = projectRules
        self.systemRules = systemRules
        self.walkSkip = walkSkip
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, catalogVersion, projectRules, systemRules, walkSkip }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        catalogVersion = try c.decodeIfPresent(String.self, forKey: .catalogVersion) ?? "custom"
        projectRules = try c.decodeIfPresent([ProjectArtifactRule].self, forKey: .projectRules) ?? []
        systemRules = try c.decodeIfPresent([SystemPathRule].self, forKey: .systemRules) ?? []
        walkSkip = try c.decodeIfPresent([String: [String]].self, forKey: .walkSkip) ?? [:]
    }

    /// Skip specs for a platform: the shared list plus the platform list.
    public func walkSkipSpecs(for platform: RoomyPlatform) -> [String] {
        (walkSkip["all"] ?? []) + (walkSkip[platform.rawValue] ?? [])
    }

    /// Builds the exclusion filter the project walk uses for tool-owned trees.
    /// Bare names (no `/`) become `*/name` globs; everything else resolves against `home`.
    /// Specs that are the scan root itself or one of its ancestors are dropped, so scanning
    /// `~/.nvm` on purpose still works even though `~/.nvm` is skipped during a home scan.
    public func walkSkipFilter(home: URL, platform: RoomyPlatform = .current, scanRoot: URL? = nil) -> RoomyScanExclusionFilter {
        let resolver = RoomyPathResolver(home: home)
        let rootPath = scanRoot?.standardizedFileURL.path
        var raw: [String] = []
        for spec in walkSkipSpecs(for: platform) {
            if !spec.contains("/") && !spec.hasPrefix("~") {
                raw.append("*/\(spec)")
            } else if let url = resolver.resolve(spec) {
                let path = url.standardizedFileURL.path
                if let rootPath, rootPath == path || rootPath.hasPrefix(path + "/") { continue }
                raw.append(path)
            }
        }
        return RoomyScanExclusionFilter(rawExclusions: raw, homeDirectory: home)
    }

    /// The catalog compiled into this binary.
    public static let builtin: RuleCatalog = {
        let data = Data(PackageResources.builtin_rules_json)
        do {
            return try RuleCatalog.decode(data)
        } catch {
            fatalError("Built-in rule catalog is invalid: \(error)")
        }
    }()

    public static func decode(_ data: Data) throws -> RuleCatalog {
        let catalog = try JSONDecoder().decode(RuleCatalog.self, from: data)
        guard catalog.schemaVersion <= supportedSchemaVersion else {
            throw RuleCatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        try catalog.validate()
        return catalog
    }

    public static func load(from url: URL) throws -> RuleCatalog {
        try decode(try Data(contentsOf: url))
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Rules from `other` override rules with the same id; new ids are appended.
    public func merged(with other: RuleCatalog) -> RuleCatalog {
        var project = projectRules
        for r in other.projectRules {
            if let i = project.firstIndex(where: { $0.id == r.id }) { project[i] = r } else { project.append(r) }
        }
        var system = systemRules
        for r in other.systemRules {
            if let i = system.firstIndex(where: { $0.id == r.id }) { system[i] = r } else { system.append(r) }
        }
        var skip = walkSkip
        for (k, v) in other.walkSkip { skip[k, default: []].append(contentsOf: v) }
        return RuleCatalog(
            schemaVersion: max(schemaVersion, other.schemaVersion),
            catalogVersion: "\(catalogVersion)+\(other.catalogVersion)",
            projectRules: project,
            systemRules: system,
            walkSkip: skip
        )
    }

    /// Removes rules by id (policy `disabledRules`).
    public func removing(ruleIDs: Set<String>) -> RuleCatalog {
        var copy = self
        copy.projectRules.removeAll { ruleIDs.contains($0.id) }
        copy.systemRules.removeAll { ruleIDs.contains($0.id) }
        return copy
    }

    public func projectRules(for platform: RoomyPlatform) -> [ProjectArtifactRule] {
        projectRules.filter { $0.applies(to: platform) }
    }

    public func systemRules(for platform: RoomyPlatform, categories: Set<String>? = nil) -> [SystemPathRule] {
        systemRules.filter { rule in
            rule.applies(to: platform) && (categories?.contains(rule.category) ?? true)
        }
    }

    public func rule(id: String) -> (project: ProjectArtifactRule?, system: SystemPathRule?) {
        (projectRules.first { $0.id == id }, systemRules.first { $0.id == id })
    }

    public func validate() throws {
        var seen: Set<String> = []
        for r in projectRules {
            guard !r.id.isEmpty, !r.folderName.isEmpty else { throw RuleCatalogError.invalidRule(r.id, "empty id or folderName") }
            guard seen.insert(r.id).inserted else { throw RuleCatalogError.duplicateID(r.id) }
        }
        for r in systemRules {
            guard !r.id.isEmpty else { throw RuleCatalogError.invalidRule(r.id, "empty id") }
            guard seen.insert(r.id).inserted else { throw RuleCatalogError.duplicateID(r.id) }
            for key in r.paths.keys where RoomyPlatform(rawValue: key) == nil {
                throw RuleCatalogError.invalidRule(r.id, "unknown platform '\(key)'")
            }
            if r.kind == .file && r.mode == .children {
                throw RuleCatalogError.invalidRule(r.id, "file rules cannot use children mode")
            }
        }
    }
}

public enum RuleCatalogError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case duplicateID(String)
    case invalidRule(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "Rule catalog schema \(v) is newer than this build supports (\(RuleCatalog.supportedSchemaVersion))."
        case .duplicateID(let id): return "Duplicate rule id '\(id)'."
        case .invalidRule(let id, let why): return "Rule '\(id)': \(why)."
        }
    }
}
