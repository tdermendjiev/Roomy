//
//  Scan.swift
//  roomy
//

import ArgumentParser
import Foundation
import RoomyCore

struct ScanOptions: ParsableArguments {
    @Argument(help: "Directories to walk for project artifacts. Default: your home directory.")
    var roots: [String] = []

    @Option(name: .long, help: "Home directory to probe for tool caches (default: current user). Useful when scanning another user's home or a mounted image.")
    var home: String?

    @Option(name: .long, parsing: .upToNextOption, help: "System categories to probe: \(RoomySystemScanCategories.all.map(\.key).joined(separator: ", ")). Default: all available on this platform.")
    var categories: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Ecosystems to include: \(RoomySettingsEcosystems.all.map(\.key).joined(separator: ", ")). Default: all.")
    var ecosystems: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Paths or globs to skip.")
    var exclude: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Extra rule catalog JSON files merged over the built-in catalog.")
    var rules: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Rule ids to disable.")
    var disableRule: [String] = []

    @Flag(name: .long, help: "Skip the system probes (tool caches, Docker, models).")
    var noSystem = false

    @Flag(name: .long, help: "Skip walking project directories.")
    var noProjects = false

    @Flag(name: .shortAndLong, help: "No progress output on stderr.")
    var quiet = false

    func resolvedHome() -> URL {
        if let h = home, !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true) }
        return RoomyHost.homeDirectory
    }

    func resolvedRoots() -> [URL] {
        let home = resolvedHome()
        if noProjects { return [] }
        if roots.isEmpty { return [home] }
        let resolver = RoomyPathResolver(home: home)
        return roots.compactMap { resolver.resolve($0) }
    }

    func catalog() throws -> RuleCatalog {
        var c = RuleCatalog.builtin
        for r in rules { c = c.merged(with: try RuleCatalog.load(from: URL(fileURLWithPath: (r as NSString).expandingTildeInPath))) }
        return c.removing(ruleIDs: Set(disableRule))
    }

    func validateChoices() throws {
        for c in categories where !RoomySystemScanCategories.allKeys.contains(c) {
            throw ValidationError("Unknown category '\(c)'. Known: \(RoomySystemScanCategories.all.map(\.key).joined(separator: ", "))")
        }
        for e in ecosystems where !RoomySettingsEcosystems.allKeys.contains(e) {
            throw ValidationError("Unknown ecosystem '\(e)'. Known: \(RoomySettingsEcosystems.all.map(\.key).joined(separator: ", "))")
        }
    }

    /// Runs the scan and builds the report. Progress goes to stderr unless quiet.
    func scan(dormantMonths: Int = 24, inactiveMonths: Int = 6) async throws -> ScanReport {
        try validateChoices()
        let started = Date()
        let home = resolvedHome()
        let catalog = try catalog()
        let ecos = ecosystems.isEmpty ? RoomySettingsEcosystems.allKeys : Set(ecosystems)
        let cats: Set<String> = noSystem ? [] : (categories.isEmpty ? Set(RoomySystemScanCategories.available.map(\.key)) : Set(categories))
        let filter = RoomyScanExclusionFilter(rawExclusions: exclude, homeDirectory: home)
        let roots = resolvedRoots()

        var project = ScanAggregate.empty
        for root in roots {
            Output.status("scanning \(RoomyPathResolver(home: home).display(root.path)) …", quiet: quiet)
            let agg = await FilesystemArtifactScanner.scan(root: root, homeDirectory: home, enabledEcosystemTags: ecos,
                                                           exclusionFilter: filter, catalog: catalog, shouldCancel: { false }, onProgress: { _ in })
            project = ScanAggregate.merge(project, agg)
        }
        var system = ScanAggregate.empty
        if !cats.isEmpty {
            Output.status("probing \(cats.count) system categories …", quiet: quiet)
            system = await SystemArtifactScanner.scan(homeDirectory: home, enabledCategories: cats, enabledEcosystemTags: ecos,
                                                      exclusionFilter: filter, projectAggregate: project, catalog: catalog,
                                                      shouldCancel: { false }, onProgress: { _ in })
        }
        let merged = ScanAggregate.merge(project, system)
        return ScanReport(aggregate: merged, scanRoot: roots.first ?? home, home: home,
                          durationSeconds: Date().timeIntervalSince(started), partial: false,
                          roomyVersion: RoomyCoreInfo.version, catalogVersion: catalog.catalogVersion,
                          dormantMonths: dormantMonths, inactiveMonths: inactiveMonths)
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find reclaimable artifacts. Never deletes anything.",
        discussion: """
        Prints a table, or the full report as JSON with --json (schema version \(RoomyReportSchema.version)).
        With --plan FILE, also writes a cleanup plan containing every finding at or below --plan-tier
        (default: safe) and older than --min-idle-days, ready for `roomy clean --plan FILE`.
        """
    )

    @OptionGroup var options: ScanOptions

    @Flag(name: .long, help: "Print the full report as JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Write a cleanup plan to this file.")
    var plan: String?

    @Option(name: .long, help: "Highest safety tier to include in the plan (safe, caution, warning).")
    var planTier: ArtifactSafetyTier = .safe

    @Option(name: .long, help: "Only plan items idle for at least this many days (items with unknown idle time are included unless --require-known-idle).")
    var minIdleDays: Int = 0

    @Flag(name: .long, help: "Exclude items whose idle time is unknown from the plan.")
    var requireKnownIdle = false

    @Option(name: .long, help: "Disposal method to record in the plan (trash, quarantine, delete). Default: trash on macOS, quarantine on Linux.")
    var method: DisposalMethod?

    @Option(name: .long, help: "Rows to show in the table.")
    var top: Int = 40

    func run() async throws {
        let report = try await options.scan()
        if json {
            Output.printJSONData(try report.encoded())
        } else {
            printTable(report)
        }
        if let planPath = plan {
            let items = report.items.filter { item in
                guard item.tier <= planTier else { return false }
                if minIdleDays > 0 {
                    if let idle = item.idleDays { return idle >= minIdleDays }
                    return !requireKnownIdle
                }
                if requireKnownIdle, item.idleDays == nil { return false }
                return true
            }
            let plan = CleanupPlan(items: items.map(CleanupPlan.Item.init),
                                   method: method ?? (RoomyPlatform.current == .macOS ? .trash : .quarantine),
                                   reason: "roomy scan --plan")
            let url = URL(fileURLWithPath: (planPath as NSString).expandingTildeInPath)
            try plan.encoded().write(to: url, options: .atomic)
            Output.status("plan: \(items.count) items, \(ByteFormatting.format(plan.totalBytes)) (tier ≤ \(Output.tierLabel(planTier))) → \(planPath)", quiet: false)
            Output.status("next: roomy clean --plan \(planPath)", quiet: false)
        }
    }

    private func printTable(_ r: ScanReport) {
        let safe = r.bytesByTier["safe"] ?? 0, caution = r.bytesByTier["caution"] ?? 0, warning = r.bytesByTier["warning"] ?? 0
        print("roomy \(r.roomyVersion) · \(r.host) · scanned \(RoomyPathResolver(home: URL(fileURLWithPath: r.home)).display(r.scanRoot)) in \(String(format: "%.1f", r.durationSeconds))s")
        print("Reclaimable: \(ByteFormatting.format(r.totalBytes)) in \(r.items.count) findings · safe \(ByteFormatting.format(safe)) · review \(ByteFormatting.format(caution)) · irreversible \(ByteFormatting.format(warning))")
        if let v = r.volume {
            print("Volume: \(ByteFormatting.format(v.availableBytes)) free of \(ByteFormatting.format(v.totalBytes))")
        }
        if r.items.isEmpty { print("\nNothing to reclaim."); return }
        print("")
        let rows = r.items.prefix(top).map { i -> [String] in
            [ByteFormatting.format(i.bytes), Output.tierLabel(i.tier), i.category,
             i.idleDays.map { "\($0)d" } ?? "-", Output.truncateMiddle(i.displayPath, max: 60), i.label]
        }
        print(Output.table(rows, header: ["SIZE", "TIER", "CATEGORY", "IDLE", "PATH", "LABEL"]))
        if r.items.count > top { print("… \(r.items.count - top) more. Use --top N or --json.") }
    }
}
