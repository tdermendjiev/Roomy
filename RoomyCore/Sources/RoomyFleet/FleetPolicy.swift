//
//  FleetPolicy.swift
//  RoomyFleet
//
//  A policy is a JSON file checked into configuration management. It says what Roomy may
//  remove on its own, what it must never touch, how removed items are disposed of, and where
//  audit and metrics go. The safety tiers from RoomyCore are its vocabulary.
//

import Foundation
import RoomyCore

public struct FleetPolicy: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public struct Scan: Codable, Equatable, Sendable {
        /// Directories to walk for project artifacts. `~` expands to the effective home. Empty → no project walk.
        public var roots: [String]
        /// Home directory to probe for tool caches. Nil → the current user's home.
        public var home: String?
        /// System categories to probe. Nil → every category available on this platform.
        public var categories: [String]?
        /// Ecosystem tags to include. Nil → all.
        public var ecosystems: [String]?
        /// Paths or globs to skip entirely.
        public var exclude: [String]
        /// Extra rule catalog files merged over the built-in one.
        public var extraRules: [String]
        /// Built-in or extra rule ids to switch off.
        public var disabledRules: [String]

        public init(roots: [String] = ["~"], home: String? = nil, categories: [String]? = nil, ecosystems: [String]? = nil,
                    exclude: [String] = [], extraRules: [String] = [], disabledRules: [String] = []) {
            self.roots = roots; self.home = home; self.categories = categories; self.ecosystems = ecosystems
            self.exclude = exclude; self.extraRules = extraRules; self.disabledRules = disabledRules
        }

        enum CodingKeys: String, CodingKey { case roots, home, categories, ecosystems, exclude, extraRules, disabledRules }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? ["~"]
            home = try c.decodeIfPresent(String.self, forKey: .home)
            categories = try c.decodeIfPresent([String].self, forKey: .categories)
            ecosystems = try c.decodeIfPresent([String].self, forKey: .ecosystems)
            exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
            extraRules = try c.decodeIfPresent([String].self, forKey: .extraRules) ?? []
            disabledRules = try c.decodeIfPresent([String].self, forKey: .disabledRules) ?? []
        }
    }

    public struct AutoClean: Codable, Equatable, Sendable {
        /// Tiers that may be removed without a human. Default: safe only.
        public var tiers: [ArtifactSafetyTier]
        /// Restrict to these categories (`project`, `aiTools`, …). Nil → any.
        public var categories: [String]?
        /// Restrict to these ecosystems. Nil → any.
        public var ecosystems: [String]?
        /// Only remove items idle for at least this many days. 0 → no age requirement.
        public var minIdleDays: Int
        /// When true, items whose idle time is unknown are skipped.
        public var requireKnownIdle: Bool
        /// Ignore findings smaller than this.
        public var minBytes: Int64
        /// Stop selecting once this many bytes are planned. Nil → unlimited.
        public var maxBytesPerRun: Int64?
        public var maxItemsPerRun: Int?

        public init(tiers: [ArtifactSafetyTier] = [.safe], categories: [String]? = nil, ecosystems: [String]? = nil,
                    minIdleDays: Int = 7, requireKnownIdle: Bool = false, minBytes: Int64 = 1_048_576,
                    maxBytesPerRun: Int64? = nil, maxItemsPerRun: Int? = nil) {
            self.tiers = tiers; self.categories = categories; self.ecosystems = ecosystems; self.minIdleDays = minIdleDays
            self.requireKnownIdle = requireKnownIdle; self.minBytes = minBytes; self.maxBytesPerRun = maxBytesPerRun; self.maxItemsPerRun = maxItemsPerRun
        }

        enum CodingKeys: String, CodingKey { case tiers, categories, ecosystems, minIdleDays, requireKnownIdle, minBytes, maxBytesPerRun, maxItemsPerRun }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tiers = try c.decodeIfPresent([ArtifactSafetyTier].self, forKey: .tiers) ?? [.safe]
            categories = try c.decodeIfPresent([String].self, forKey: .categories)
            ecosystems = try c.decodeIfPresent([String].self, forKey: .ecosystems)
            minIdleDays = try c.decodeIfPresent(Int.self, forKey: .minIdleDays) ?? 7
            requireKnownIdle = try c.decodeIfPresent(Bool.self, forKey: .requireKnownIdle) ?? false
            minBytes = try c.decodeIfPresent(Int64.self, forKey: .minBytes) ?? 1_048_576
            maxBytesPerRun = try c.decodeIfPresent(Int64.self, forKey: .maxBytesPerRun)
            maxItemsPerRun = try c.decodeIfPresent(Int.self, forKey: .maxItemsPerRun)
        }
    }

    public struct Never: Codable, Equatable, Sendable {
        /// Tiers that are never removed by policy, whatever `autoClean` says. Default: warning.
        public var tiers: [ArtifactSafetyTier]
        public var ruleIDs: [String]
        /// Path prefixes or globs that are never removed even if a rule matches them.
        public var paths: [String]

        public init(tiers: [ArtifactSafetyTier] = [.warning], ruleIDs: [String] = [], paths: [String] = []) {
            self.tiers = tiers; self.ruleIDs = ruleIDs; self.paths = paths
        }

        enum CodingKeys: String, CodingKey { case tiers, ruleIDs, paths }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tiers = try c.decodeIfPresent([ArtifactSafetyTier].self, forKey: .tiers) ?? [.warning]
            ruleIDs = try c.decodeIfPresent([String].self, forKey: .ruleIDs) ?? []
            paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        }
    }

    public struct Disposal: Codable, Equatable, Sendable {
        public var method: DisposalMethod
        public var quarantineDir: String?
        public var retentionDays: Int
        /// Purge expired quarantine (and, on Linux, expired trash) at the end of every run.
        public var purgeOnRun: Bool

        public init(method: DisposalMethod = .quarantine, quarantineDir: String? = nil, retentionDays: Int = 7, purgeOnRun: Bool = true) {
            self.method = method; self.quarantineDir = quarantineDir; self.retentionDays = retentionDays; self.purgeOnRun = purgeOnRun
        }

        enum CodingKeys: String, CodingKey { case method, quarantineDir, retentionDays, purgeOnRun }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            method = try c.decodeIfPresent(DisposalMethod.self, forKey: .method) ?? .quarantine
            quarantineDir = try c.decodeIfPresent(String.self, forKey: .quarantineDir)
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
            purgeOnRun = try c.decodeIfPresent(Bool.self, forKey: .purgeOnRun) ?? true
        }
    }

    public struct Audit: Codable, Equatable, Sendable {
        /// Append-only JSON Lines file. Nil → `~/.roomy/audit.jsonl`.
        public var path: String?
        public init(path: String? = nil) { self.path = path }
    }

    public struct Metrics: Codable, Equatable, Sendable {
        /// Prometheus textfile-collector output. Written atomically after each run.
        public var textfile: String?
        /// `host:port` for `roomy fleet serve`. Nil → 127.0.0.1:9477.
        public var listen: String?
        public init(textfile: String? = nil, listen: String? = nil) { self.textfile = textfile; self.listen = listen }
    }

    public struct License: Codable, Equatable, Sendable {
        public var key: String?
        public var keyFile: String?
        public init(key: String? = nil, keyFile: String? = nil) { self.key = key; self.keyFile = keyFile }
    }

    /// Central reporting. When `url` is set, every run posts a summary to a Roomy Hub.
    public struct Hub: Codable, Equatable, Sendable {
        /// `http(s)://hub.example.internal:9478`. Nil → no reporting.
        public var url: String?
        public var token: String?
        /// File holding the agent token (mode 0600). `$ROOMY_HUB_TOKEN` is also honoured.
        public var tokenFile: String?
        /// Name of a hub-managed policy to pull before each run. The local file then only bootstraps `hub` and `license`.
        public var policy: String?
        /// Labels shown on the dashboard: role, region, team…
        public var tags: [String: String]
        /// Largest findings to include in the report. 0 disables.
        public var topItems: Int
        /// Expected seconds between runs, so the hub can tell a quiet host from a dead one. Set automatically by `fleet serve`.
        public var intervalSeconds: Int?

        public init(url: String? = nil, token: String? = nil, tokenFile: String? = nil, policy: String? = nil,
                    tags: [String: String] = [:], topItems: Int = 25, intervalSeconds: Int? = nil) {
            self.url = url; self.token = token; self.tokenFile = tokenFile; self.policy = policy; self.tags = tags
            self.topItems = topItems; self.intervalSeconds = intervalSeconds
        }

        enum CodingKeys: String, CodingKey { case url, token, tokenFile, policy, tags, topItems, intervalSeconds }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            token = try c.decodeIfPresent(String.self, forKey: .token)
            tokenFile = try c.decodeIfPresent(String.self, forKey: .tokenFile)
            policy = try c.decodeIfPresent(String.self, forKey: .policy)
            tags = try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
            topItems = try c.decodeIfPresent(Int.self, forKey: .topItems) ?? 25
            intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        }
    }

    public var schemaVersion: Int
    public var name: String
    public var scan: Scan
    public var autoClean: AutoClean
    public var never: Never
    public var disposal: Disposal
    public var audit: Audit
    public var metrics: Metrics
    public var license: License
    public var hub: Hub
    public var lockFile: String?
    /// Evaluate and report, but dispose of nothing.
    public var dryRun: Bool
    /// Age thresholds for activity labels in reports.
    public var dormantMonths: Int
    public var inactiveMonths: Int

    public init(name: String = "default", scan: Scan = Scan(), autoClean: AutoClean = AutoClean(), never: Never = Never(),
                disposal: Disposal = Disposal(), audit: Audit = Audit(), metrics: Metrics = Metrics(), license: License = License(),
                hub: Hub = Hub(), lockFile: String? = nil, dryRun: Bool = false, dormantMonths: Int = 24, inactiveMonths: Int = 6) {
        schemaVersion = FleetPolicy.supportedSchemaVersion
        self.name = name; self.scan = scan; self.autoClean = autoClean; self.never = never; self.disposal = disposal
        self.audit = audit; self.metrics = metrics; self.license = license; self.hub = hub; self.lockFile = lockFile; self.dryRun = dryRun
        self.dormantMonths = dormantMonths; self.inactiveMonths = inactiveMonths
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, name, scan, autoClean, never, disposal, audit, metrics, license, hub, lockFile, dryRun, dormantMonths, inactiveMonths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= FleetPolicy.supportedSchemaVersion else { throw FleetPolicyError.unsupportedSchema(schemaVersion) }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "default"
        scan = try c.decodeIfPresent(Scan.self, forKey: .scan) ?? Scan()
        autoClean = try c.decodeIfPresent(AutoClean.self, forKey: .autoClean) ?? AutoClean()
        never = try c.decodeIfPresent(Never.self, forKey: .never) ?? Never()
        disposal = try c.decodeIfPresent(Disposal.self, forKey: .disposal) ?? Disposal()
        audit = try c.decodeIfPresent(Audit.self, forKey: .audit) ?? Audit()
        metrics = try c.decodeIfPresent(Metrics.self, forKey: .metrics) ?? Metrics()
        license = try c.decodeIfPresent(License.self, forKey: .license) ?? License()
        hub = try c.decodeIfPresent(Hub.self, forKey: .hub) ?? Hub()
        lockFile = try c.decodeIfPresent(String.self, forKey: .lockFile)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        dormantMonths = try c.decodeIfPresent(Int.self, forKey: .dormantMonths) ?? 24
        inactiveMonths = try c.decodeIfPresent(Int.self, forKey: .inactiveMonths) ?? 6
    }

    // MARK: Loading

    public static func load(from url: URL) throws -> FleetPolicy {
        let data = try Data(contentsOf: url)
        let policy = try JSONDecoder().decode(FleetPolicy.self, from: data)
        try policy.validate()
        return policy
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public func validate() throws {
        for tier in autoClean.tiers where never.tiers.contains(tier) {
            throw FleetPolicyError.invalid("tier '\(tier.rawValue)' is both in autoClean.tiers and never.tiers")
        }
        if let cats = scan.categories {
            for c in cats where !RoomySystemScanCategories.allKeys.contains(c) {
                throw FleetPolicyError.invalid("unknown scan category '\(c)'")
            }
        }
        if let ecos = scan.ecosystems {
            for e in ecos where !RoomySettingsEcosystems.allKeys.contains(e) {
                throw FleetPolicyError.invalid("unknown ecosystem '\(e)'")
            }
        }
        if disposal.retentionDays < 0 { throw FleetPolicyError.invalid("disposal.retentionDays must be >= 0") }
        if autoClean.minIdleDays < 0 { throw FleetPolicyError.invalid("autoClean.minIdleDays must be >= 0") }
        if let u = hub.url, !u.isEmpty {
            guard let url = URL(string: u), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
                throw FleetPolicyError.invalid("hub.url must be an http(s) URL")
            }
        }
        if hub.topItems < 0 || hub.topItems > 200 { throw FleetPolicyError.invalid("hub.topItems must be between 0 and 200") }
    }

    // MARK: Resolved paths

    public var resolvedHome: URL {
        if let h = scan.home, !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true) }
        return RoomyHost.homeDirectory
    }

    public func resolvedRoots() -> [URL] {
        let resolver = RoomyPathResolver(home: resolvedHome)
        return scan.roots.compactMap { resolver.resolve($0) }
    }

    public var resolvedAuditPath: URL {
        let resolver = RoomyPathResolver(home: resolvedHome)
        if let p = audit.path, let u = resolver.resolve(p) { return u }
        return resolvedHome.appendingPathComponent(".roomy/audit.jsonl")
    }

    public var resolvedLockPath: URL {
        let resolver = RoomyPathResolver(home: resolvedHome)
        if let p = lockFile, let u = resolver.resolve(p) { return u }
        return resolvedHome.appendingPathComponent(".roomy/fleet.lock")
    }

    public var resolvedQuarantine: QuarantineConfig {
        let resolver = RoomyPathResolver(home: resolvedHome)
        let dir = disposal.quarantineDir.flatMap { resolver.resolve($0) } ?? QuarantineConfig.default(home: resolvedHome).directory
        return QuarantineConfig(directory: dir, retentionDays: disposal.retentionDays)
    }

    public var resolvedMetricsTextfile: URL? {
        guard let t = metrics.textfile else { return nil }
        return RoomyPathResolver(home: resolvedHome).resolve(t)
    }

    public var resolvedListenAddress: (host: String, port: UInt16) {
        let raw = metrics.listen ?? "127.0.0.1:9477"
        if let colon = raw.lastIndex(of: ":"), let port = UInt16(raw[raw.index(after: colon)...]) {
            let host = String(raw[..<colon])
            return (host.isEmpty ? "0.0.0.0" : host, port)
        }
        return ("127.0.0.1", 9477)
    }

    /// Loads the effective rule catalog: built-in, plus extra files, minus disabled ids.
    public func resolvedCatalog() throws -> RuleCatalog {
        var catalog = RuleCatalog.builtin
        let resolver = RoomyPathResolver(home: resolvedHome)
        for spec in scan.extraRules {
            guard let url = resolver.resolve(spec) else { continue }
            catalog = catalog.merged(with: try RuleCatalog.load(from: url))
        }
        return catalog.removing(ruleIDs: Set(scan.disabledRules))
    }

    public func resolvedLicenseKey() -> String? {
        if let k = license.key, !k.isEmpty { return k }
        let resolver = RoomyPathResolver(home: resolvedHome)
        let candidates = [license.keyFile, "/etc/roomy/license.key", "~/.roomy/license.key"].compactMap { $0 }
        for spec in candidates {
            guard let url = resolver.resolve(spec), let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["ROOMY_LICENSE"], !env.isEmpty { return env }
        return nil
    }

    // MARK: Hub

    /// The hub to report to, or nil when central reporting is off.
    public var resolvedHubURL: URL? {
        guard let u = hub.url, !u.isEmpty else { return nil }
        return URL(string: u)
    }

    public func resolvedHubToken() -> String? {
        if let t = hub.token, !t.isEmpty { return t }
        let resolver = RoomyPathResolver(home: resolvedHome)
        let candidates = [hub.tokenFile, "/etc/roomy/hub.token", "~/.roomy/hub.token"].compactMap { $0 }
        for spec in candidates {
            guard let url = resolver.resolve(spec), let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["ROOMY_HUB_TOKEN"], !env.isEmpty { return env }
        return nil
    }

    /// A hub-managed policy replaces this one, except for the parts that only make sense locally:
    /// how to reach the hub, the license, and the home directory when the remote policy does not set one.
    public func applyingRemote(_ remote: FleetPolicy) -> FleetPolicy {
        var merged = remote
        merged.hub = hub
        if merged.hub.intervalSeconds == nil { merged.hub.intervalSeconds = remote.hub.intervalSeconds }
        if merged.license.key == nil, merged.license.keyFile == nil { merged.license = license }
        if merged.scan.home == nil { merged.scan.home = scan.home }
        if merged.lockFile == nil { merged.lockFile = lockFile }
        return merged
    }

    // MARK: Profiles

    /// A headless agent host: no project walk, tool caches and leftovers only, quarantine, metrics for node_exporter.
    public static func agentHostProfile() -> FleetPolicy {
        FleetPolicy(
            name: "agent-host",
            scan: Scan(roots: ["~"], categories: ["aiTools", "agentHost", "globalCaches", "docker", "python"]),
            autoClean: AutoClean(tiers: [.safe], minIdleDays: 3),
            never: Never(tiers: [.warning], paths: ["~/.claude/projects", "~/.codex/sessions"]),
            disposal: Disposal(method: .quarantine, retentionDays: 7, purgeOnRun: true),
            audit: Audit(path: "~/.roomy/audit.jsonl"),
            metrics: Metrics(textfile: "/var/lib/node_exporter/textfile_collector/roomy.prom", listen: "127.0.0.1:9477")
        )
    }

    /// A developer workstation: walk projects, remove only safe artifacts idle for a month, keep Trash semantics.
    public static func developerProfile() -> FleetPolicy {
        FleetPolicy(
            name: "developer",
            scan: Scan(roots: ["~"]),
            autoClean: AutoClean(tiers: [.safe], minIdleDays: 30, requireKnownIdle: true),
            never: Never(tiers: [.warning]),
            disposal: Disposal(method: .trash, retentionDays: 14, purgeOnRun: false)
        )
    }
}

public enum FleetPolicyError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "Policy schema \(v) is newer than this build supports (\(FleetPolicy.supportedSchemaVersion))."
        case .invalid(let why): return "Invalid policy: \(why)."
        }
    }
}
