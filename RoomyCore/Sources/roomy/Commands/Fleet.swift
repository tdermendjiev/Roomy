//
//  Fleet.swift
//  roomy
//
//  Unattended operation for many hosts: policy-driven runs, Prometheus metrics, tamper-evident audit, licensing.
//

import ArgumentParser
import Foundation
import RoomyCore
import RoomyFleet

struct Fleet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Policy-driven, unattended cleanup with audit log and Prometheus metrics (Roomy Fleet).",
        subcommands: [FleetRun.self, FleetServe.self, FleetPolicyCmd.self, FleetAudit.self, FleetLicense.self, FleetMetrics.self]
    )
}

struct PolicyArg: ParsableArguments {
    @Option(name: [.customLong("policy"), .short], help: "Policy JSON file. Default: $ROOMY_POLICY, /etc/roomy/policy.json, ~/.roomy/policy.json.")
    var policyPath: String?
    @Flag(name: .long, help: "Ignore hub.policy: run with the local file even if the policy names a hub-managed one.") var localPolicy = false

    func load() throws -> FleetPolicy {
        let candidates = [policyPath, ProcessInfo.processInfo.environment["ROOMY_POLICY"], "/etc/roomy/policy.json", "~/.roomy/policy.json"]
            .compactMap { $0 }.map { ($0 as NSString).expandingTildeInPath }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return try FleetPolicy.load(from: URL(fileURLWithPath: c))
        }
        throw ValidationError("No policy file found. Pass --policy FILE or create one with `roomy fleet policy init`.")
    }

    /// The local policy, replaced by the hub-managed one it names when reachable. A hub outage never stops a run:
    /// the local file is the fallback and the audit log records which one was used.
    func loadResolvingHub(log: (String) -> Void) async throws -> FleetPolicy {
        let local = try load()
        guard !localPolicy, let name = local.hub.policy, !name.isEmpty, let url = local.resolvedHubURL else { return local }
        do {
            let remote = try await HubClient(baseURL: url, token: local.resolvedHubToken()).fetchPolicy(named: name)
            log("policy '\(name)' pulled from \(url.host ?? url.absoluteString)")
            return local.applyingRemote(remote)
        } catch {
            log("warning: could not pull policy '\(name)' from hub (\(error.localizedDescription)); using local policy '\(local.name)'")
            return local
        }
    }
}

struct FleetRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Scan, apply the policy, dispose, audit, write metrics. One run.")

    @OptionGroup var policy: PolicyArg
    @Flag(name: .long, help: "Evaluate and log, dispose of nothing (overrides the policy's dryRun).") var dryRun = false
    @Flag(name: .long, help: "JSON summary on stdout.") var json = false
    @Flag(name: .shortAndLong, help: "Progress on stderr.") var verbose = false

    struct Summary: Encodable {
        var runID: String; var host: String; var policy: String; var edition: String; var dryRun: Bool
        var findings: Int; var reclaimableBytes: Int64; var selected: Int; var selectedBytes: Int64
        var disposed: Int; var disposedBytes: Int64; var failed: Int; var purged: Int; var durationSeconds: Double
        var skippedByReason: [String: Int]
        var hub: String?
    }

    func run() async throws {
        let pol = try await policy.loadResolvingHub(log: { if verbose { Output.warn($0) } })
        let runner = FleetRunner(policy: pol, log: { if verbose { Output.warn($0) } })
        let result: FleetRunResult
        do {
            result = try await runner.run(dryRunOverride: dryRun ? true : nil)
        } catch let e as FleetRunError {
            Output.warn(e.localizedDescription)
            if case .locked = e { throw ExitCode(ExitCodes.locked) }
            throw ExitCode(ExitCodes.error)
        }
        var byReason: [String: Int] = [:]
        for s in result.decision.skipped { byReason[s.reason.rawValue, default: 0] += 1 }
        if json {
            Output.printJSON(Summary(
                runID: result.runID, host: result.report.host, policy: pol.name, edition: result.license.edition.rawValue, dryRun: result.dryRun,
                findings: result.report.items.count, reclaimableBytes: result.report.totalBytes, selected: result.decision.selected.count,
                selectedBytes: result.decision.selectedBytes, disposed: result.disposal.receipts.count, disposedBytes: result.disposedBytes,
                failed: result.disposal.failures.count, purged: result.purged.receipts.count, durationSeconds: result.duration, skippedByReason: byReason,
                hub: result.hubAck.map { "reported (\($0.hostsKnown)/\($0.hostLimit) hosts)" } ?? result.hubError.map { "failed: \($0)" }))
        } else {
            print("roomy fleet run \(result.runID.prefix(8)) · \(result.report.host) · policy \(pol.name) · \(result.license.summary)\(result.dryRun ? " · DRY RUN" : "")")
            print("findings: \(result.report.items.count) (\(ByteFormatting.format(result.report.totalBytes))) · selected: \(result.decision.selected.count) (\(ByteFormatting.format(result.decision.selectedBytes)))")
            print("\(result.dryRun ? "would dispose" : "disposed"): \(result.disposal.receipts.count) (\(ByteFormatting.format(result.disposedBytes))) · failed: \(result.disposal.failures.count) · purged: \(result.purged.receipts.count) · \(String(format: "%.1f", result.duration))s")
            if !byReason.isEmpty {
                print("skipped: " + byReason.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
            for f in result.disposal.failures { print("FAILED \(f.path): \(f.message)") }
            print("audit: \(pol.resolvedAuditPath.path)" + (pol.resolvedMetricsTextfile.map { " · metrics: \($0.path)" } ?? ""))
            if let ack = result.hubAck { print("hub: reported to \(pol.hub.url ?? "") · \(ack.hostsKnown)/\(ack.hostLimit) hosts known") }
            if let e = result.hubError { print("hub: FAILED \(e)") }
        }
        if !result.succeeded { throw ExitCode(ExitCodes.partialFailure) }
    }
}

struct FleetServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the policy on an interval and serve Prometheus metrics over HTTP (GET /metrics, /healthz, /report).",
        discussion: "For hosts without node_exporter's textfile collector. Use the systemd unit in packaging/ to keep it running."
    )

    @OptionGroup var policy: PolicyArg
    @Option(name: .long, help: "Run interval, e.g. 30m, 6h, 1d. Default 6h.") var interval: String = "6h"
    @Option(name: .long, help: "host:port to listen on. Overrides the policy's metrics.listen.") var listen: String?
    @Flag(name: .long, help: "Serve metrics but never dispose (overrides the policy).") var dryRun = false
    @Flag(name: .long, help: "Run once immediately, then keep serving without further runs.") var once = false

    func run() async throws {
        let pol = try policy.load()
        guard let every = Output.parseDuration(interval), every >= 60 else { throw ValidationError("--interval must be at least 60 seconds (e.g. 30m, 6h)") }
        var address = pol.resolvedListenAddress
        if let l = listen {
            var p = FleetPolicy(); p.metrics.listen = l
            address = p.resolvedListenAddress
        }
        let server = MetricsServer(host: address.host, port: address.port)
        try server.start()
        Output.warn("serving metrics on http://\(address.host):\(address.port)/metrics · policy \(pol.name) · every \(interval)\(dryRun ? " · DRY RUN" : "")")
        while true {
            let effective = try await policy.loadResolvingHub(log: { Output.warn($0) })
            let runner = FleetRunner(policy: effective, intervalSeconds: Int(every), log: { Output.warn($0) })
            do {
                let result = try await runner.run(dryRunOverride: dryRun ? true : nil)
                let reportJSON = (try? result.report.encoded()).flatMap { String(data: $0, encoding: .utf8) }
                server.update(metrics: result.metricsText, reportJSON: reportJSON, healthy: result.succeeded)
            } catch {
                Output.warn("run failed: \(error.localizedDescription)")
                server.update(metrics: "# roomy: last run failed: \(error.localizedDescription)\n", healthy: false)
            }
            if once { break }
            try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
        // --once: keep serving until killed.
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}

struct FleetPolicyCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "policy", abstract: "Create and check policy files.",
                                                    subcommands: [PolicyInit.self, PolicyCheck.self, PolicyShow.self])

    struct PolicyInit: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "init", abstract: "Write a starter policy.")
        @Option(name: .long, help: "agent-host (headless server, quarantine, node_exporter metrics) or developer (workstation, Trash).") var profile: String = "agent-host"
        @Option(name: .shortAndLong, help: "Output file. Default: stdout.") var output: String?
        @Option(name: .long, help: "Report to this Roomy Hub after every run, e.g. http://hub.internal:9478.") var hub: String?
        @Option(name: .long, help: "Pull this hub-managed policy before each run (requires --hub).") var hubPolicy: String?
        @Option(name: .long, parsing: .upToNextOption, help: "Tags for the hub dashboard, key=value.") var tag: [String] = []

        func run() throws {
            var pol: FleetPolicy
            switch profile {
            case "agent-host", "agent", "server": pol = .agentHostProfile()
            case "developer", "dev", "workstation": pol = .developerProfile()
            default: throw ValidationError("unknown profile '\(profile)'; use agent-host or developer")
            }
            if let h = hub {
                pol.hub.url = h
                pol.hub.tokenFile = "/etc/roomy/hub.token"
                pol.hub.policy = hubPolicy
                for t in tag {
                    let kv = t.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { throw ValidationError("--tag expects key=value, got '\(t)'") }
                    pol.hub.tags[kv[0]] = kv[1]
                }
                try pol.validate()
            } else if hubPolicy != nil || !tag.isEmpty {
                throw ValidationError("--hub-policy and --tag require --hub")
            }
            let data = try pol.encoded()
            if let o = output {
                let url = URL(fileURLWithPath: (o as NSString).expandingTildeInPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                print("wrote \(url.path)")
            } else {
                Output.printJSONData(data)
            }
        }
    }

    struct PolicyCheck: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Validate a policy, scan, and show what it would remove. Disposes of nothing.")
        @OptionGroup var policy: PolicyArg
        @Flag(name: .long, help: "JSON output: report, selected items and skip reasons.") var json = false
        @Option(name: .long, help: "Also write the resulting plan here (for `roomy clean --plan`).") var plan: String?

        struct Out: Encodable { var policy: FleetPolicy; var license: String; var selected: [ScanReportItem]; var skipped: [PolicyDecision.Skipped]; var report: ScanReport }

        func run() async throws {
            let pol = try policy.load()
            let (report, decision, license) = try await FleetRunner(policy: pol).plan()
            if let p = plan { try decision.plan.encoded().write(to: URL(fileURLWithPath: (p as NSString).expandingTildeInPath), options: .atomic) }
            if json {
                Output.printJSON(Out(policy: pol, license: license.summary, selected: decision.selected, skipped: decision.skipped, report: report))
                return
            }
            print("policy \(pol.name) is valid · license: \(license.summary)")
            print("findings: \(report.items.count) (\(ByteFormatting.format(report.totalBytes))) · would remove: \(decision.selected.count) (\(ByteFormatting.format(decision.selectedBytes))) via \(pol.disposal.method.rawValue)")
            if !decision.selected.isEmpty {
                print("")
                print(Output.table(decision.selected.prefix(30).map { [ByteFormatting.format($0.bytes), Output.tierLabel($0.tier), $0.category, $0.idleDays.map { "\($0)d" } ?? "-", Output.truncateMiddle($0.displayPath, max: 70)] },
                                   header: ["SIZE", "TIER", "CATEGORY", "IDLE", "PATH"]))
                if decision.selected.count > 30 { print("… \(decision.selected.count - 30) more") }
            }
            let byReason = decision.skippedBytesByReason
            if !byReason.isEmpty {
                print("\nskipped: " + byReason.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \(ByteFormatting.format($0.value))" }.joined(separator: " · "))
            }
            if let p = plan { print("plan written to \(p)") }
        }
    }

    struct PolicyShow: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the effective policy with defaults filled in.")
        @OptionGroup var policy: PolicyArg
        func run() throws { Output.printJSONData(try policy.load().encoded()) }
    }
}

struct FleetAudit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit", abstract: "Inspect the tamper-evident audit log.",
                                                    subcommands: [AuditVerify.self, AuditTail.self])

    struct PathArg: ParsableArguments {
        @Option(name: .long, help: "Audit log path. Default ~/.roomy/audit.jsonl (or the policy's audit.path with --policy).") var path: String?
        @Option(name: .long, help: "Policy whose audit path to use.") var policy: String?
        func url() throws -> URL {
            if let p = path { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
            if let pol = policy { return try FleetPolicy.load(from: URL(fileURLWithPath: (pol as NSString).expandingTildeInPath)).resolvedAuditPath }
            return RoomyHost.homeDirectory.appendingPathComponent(".roomy/audit.jsonl")
        }
    }

    struct AuditVerify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify", abstract: "Recompute the hash chain; exit 1 if the log was edited or truncated.")
        @OptionGroup var where_: PathArg
        @Flag(name: .long) var json = false
        func run() throws {
            let url = try where_.url()
            let r = AuditLog.verify(url: url)
            if json { Output.printJSON(["path": url.path, "ok": r.ok ? "true" : "false", "records": "\(r.records)", "message": r.message]) }
            else { print("\(r.ok ? "ok" : "FAIL") \(url.path): \(r.message)") }
            if !r.ok { throw ExitCode(ExitCodes.error) }
        }
    }

    struct AuditTail: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tail", abstract: "Show the last records.")
        @OptionGroup var where_: PathArg
        @Option(name: [.customShort("n"), .long]) var lines: Int = 20
        @Flag(name: .long) var json = false
        func run() throws {
            let records = try AuditLog.readAll(from: try where_.url()).suffix(lines)
            if json { Output.printJSON(Array(records)); return }
            let f = ISO8601DateFormatter()
            for r in records {
                var line = "\(f.string(from: r.time)) \(r.event.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(r.actor)"
                if let p = r.path { line += " \(p)" }
                if let b = r.bytes { line += " \(ByteFormatting.format(b))" }
                if let m = r.method { line += " [\(m.rawValue)]" }
                if let reason = r.reason { line += " reason=\(reason)" }
                if let msg = r.message { line += " · \(msg)" }
                print(line)
            }
        }
    }
}

struct FleetLicense: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "license", abstract: "Show or install a Roomy Fleet license.",
                                                    subcommands: [LicenseShow.self, LicenseInstall.self])

    struct LicenseShow: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the license in effect (policy, $ROOMY_LICENSE, /etc/roomy/license.key, ~/.roomy/license.key).")
        @OptionGroup var policy: PolicyArg
        @Flag(name: .long) var json = false
        func run() throws {
            let pol = (try? policy.load()) ?? FleetPolicy()
            let status = LicenseVerifier.status(token: pol.resolvedLicenseKey())
            if json {
                struct Out: Encodable { var edition: String; var summary: String; var payload: LicensePayload?; var problem: String? }
                Output.printJSON(Out(edition: status.edition.rawValue, summary: status.summary, payload: status.payload, problem: status.problem))
            } else {
                print(status.summary)
            }
        }
    }

    struct LicenseInstall: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Verify a token and write it to a key file.")
        @Argument(help: "The ROOMY1.… token.") var token: String
        @Option(name: .long, help: "Where to write it. Default ~/.roomy/license.key (use /etc/roomy/license.key for system-wide).") var path: String?
        func run() throws {
            let payload = try LicenseVerifier.verify(token: token)
            let url = URL(fileURLWithPath: ((path ?? "~/.roomy/license.key") as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            print("installed license for \(payload.org) (\(payload.edition), \(payload.maxHosts) hosts) at \(url.path)")
        }
    }
}

struct FleetMetrics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metrics", abstract: "Print the Prometheus metrics the policy would produce right now (scan only, no disposal).")
    @OptionGroup var policy: PolicyArg
    func run() async throws {
        let pol = try policy.load()
        let (report, decision, license) = try await FleetRunner(policy: pol).plan()
        let totals = AuditLog.totals(from: pol.resolvedAuditPath)
        let q = QuarantineDisposer(config: pol.resolvedQuarantine)
        let snapshot = FleetMetricsSnapshot(
            host: report.host, edition: license.edition.rawValue, org: license.payload?.org, version: RoomyCoreInfo.version,
            catalogVersion: report.catalogVersion, policyName: pol.name, reclaimableBytesByTier: report.bytesByTier,
            reclaimableBytesByCategory: report.bytesByCategory, reclaimableItems: report.items.count,
            plannedBytes: decision.selectedBytes, plannedItems: decision.selected.count, disposedBytesThisRun: 0, disposedItemsThisRun: 0,
            failuresThisRun: 0, disposedBytesTotal: totals.disposedBytes, disposedItemsTotal: totals.disposedItems, failuresTotal: totals.failures,
            purgedBytesTotal: totals.purgedBytes, runsTotal: totals.runs, lastRunStart: report.generatedAt, lastRunDurationSeconds: report.durationSeconds,
            lastRunSucceeded: true, dryRun: true, quarantineBytes: q.totalBytes, quarantineItems: q.entries().count,
            volumeTotalBytes: report.volume?.totalBytes, volumeAvailableBytes: report.volume?.availableBytes, licenseExpiresAt: license.payload?.expiresAt)
        print(PrometheusRenderer.render(snapshot), terminator: "")
    }
}
