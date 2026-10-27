//
//  Hub.swift
//  roomy
//
//  Roomy Hub: the central service hosts report to. `serve` runs it; the other subcommands talk
//  to a running hub from an operator's machine; `demo` fills a data directory with a synthetic fleet.
//

import ArgumentParser
import Foundation
import RoomyCore
import RoomyFleet

struct Hub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Central inventory, dashboard and fleet-wide metrics for many Roomy hosts (Roomy Hub).",
        discussion: """
        Hosts report after every `roomy fleet run` when their policy sets `hub.url`. The hub keeps the latest
        report and a history per host, serves a dashboard at /, a JSON API under /api/v1 and Prometheus
        metrics at /metrics, and hands out centrally managed policies.
        """,
        subcommands: [HubServe.self, HubStatus.self, HubHosts.self, HubHost.self, HubRemove.self, HubPolicy.self, HubEvents.self, HubDemo_.self, HubToken.self]
    )
}

struct HubConnection: ParsableArguments {
    @Option(name: .long, help: "Hub base URL. Default: $ROOMY_HUB_URL or http://127.0.0.1:9478.") var url: String?
    @Option(name: .long, help: "Admin token. Default: $ROOMY_HUB_TOKEN or ~/.roomy/hub-admin.token.") var token: String?

    func client() throws -> HubClient {
        let env = ProcessInfo.processInfo.environment
        let base = url ?? env["ROOMY_HUB_URL"] ?? "http://127.0.0.1:9478"
        var tok = token ?? env["ROOMY_HUB_TOKEN"]
        if tok == nil {
            let f = RoomyHost.homeDirectory.appendingPathComponent(".roomy/hub-admin.token")
            tok = (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try HubClient(urlString: base, token: tok)
    }
}

struct HubServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Run the hub: dashboard, API, metrics, policy distribution.")

    @Option(name: .long, help: "host:port to listen on. Default 127.0.0.1:9478; use 0.0.0.0:9478 to accept agents from the network.") var listen: String = "127.0.0.1:9478"
    @Option(name: .long, help: "Where host files, policies and the event log live. Default $ROOMY_HUB_DATA or ~/.roomy/hub.") var dataDir: String?
    @Option(name: .long, help: "Token agents must present (or $ROOMY_HUB_AGENT_TOKEN).") var agentToken: String?
    @Option(name: .long, help: "File holding the agent token.") var agentTokenFile: String?
    @Option(name: .long, help: "Token for the dashboard, API and /metrics (or $ROOMY_HUB_ADMIN_TOKEN). Without one, everything is open: bind to localhost or a private network.") var adminToken: String?
    @Option(name: .long, help: "File holding the admin token.") var adminTokenFile: String?
    @Option(name: .long, help: "A host is stale after this long without a report when it did not state its interval, e.g. 24h.") var staleAfter: String = "24h"
    @Option(name: .long, help: "Fleet license token (or $ROOMY_LICENSE, /etc/roomy/license.key, ~/.roomy/license.key). Sets the host allowance.") var license: String?
    @Option(name: .long, help: "Name shown in the dashboard header.") var title: String = "Roomy Hub"

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stale = Output.parseDuration(staleAfter), stale >= 60 else { throw ValidationError("--stale-after must be a duration like 6h or 2d") }
        var pol = FleetPolicy(); pol.metrics.listen = listen
        let address = pol.resolvedListenAddress
        let data = URL(fileURLWithPath: ((dataDir ?? env["ROOMY_HUB_DATA"] ?? "~/.roomy/hub") as NSString).expandingTildeInPath, isDirectory: true)
        func token(_ direct: String?, _ file: String?, _ envKey: String) -> String? {
            if let d = direct, !d.isEmpty { return d }
            if let f = file, let s = try? String(contentsOf: URL(fileURLWithPath: (f as NSString).expandingTildeInPath), encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t }
            }
            if let e = env[envKey], !e.isEmpty { return e }
            return nil
        }
        let licenseToken = license ?? FleetPolicy().resolvedLicenseKey()
        let config = HubConfig(host: address.host, port: address.port, dataDir: data,
                               agentToken: token(agentToken, agentTokenFile, "ROOMY_HUB_AGENT_TOKEN"),
                               adminToken: token(adminToken, adminTokenFile, "ROOMY_HUB_ADMIN_TOKEN"),
                               staleAfter: stale, licenseToken: licenseToken, title: title)
        let server = try HubServer(config: config)
        server.log = { Output.warn($0) }
        try server.start()
        let lic = server.licenseInfo()
        Output.warn("roomy hub \(RoomyCoreInfo.version) · http://\(address.host):\(server.port)/ · data \(data.path)")
        Output.warn("edition \(lic.edition)\(lic.org.map { " (\($0))" } ?? "") · up to \(lic.maxHosts) hosts · \(lic.hostsKnown) known · agent token \(config.agentToken == nil ? "NOT SET" : "set") · admin token \(config.adminToken == nil ? "NOT SET (API open)" : "set")")
        if config.adminToken == nil, address.host != "127.0.0.1" {
            Output.warn("warning: listening on \(address.host) without --admin-token; anyone who can reach the port can read the inventory")
        }
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}

struct HubStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Fleet-wide summary from a running hub.")
    @OptionGroup var conn: HubConnection
    @Flag(name: .long) var json = false
    func run() async throws {
        let s = try await conn.client().summary()
        if json { Output.printJSON(s); return }
        let st = s.hostsByStatus
        print("\(s.title) · \(s.hosts) hosts · \(st["healthy"] ?? 0) healthy · \(st["attention"] ?? 0) attention · \(st["stale"] ?? 0) stale · license \(s.license.edition) (\(s.license.hostsKnown)/\(s.license.maxHosts) hosts)")
        print("reclaimable: \(ByteFormatting.format(s.reclaimableBytes)) (safe \(ByteFormatting.format(s.bytesByTier["safe"] ?? 0)) · review \(ByteFormatting.format(s.bytesByTier["caution"] ?? 0)) · irreversible \(ByteFormatting.format(s.bytesByTier["warning"] ?? 0)))")
        print("freed: \(ByteFormatting.format(s.disposedBytesLast24h)) last 24h · \(ByteFormatting.format(s.disposedBytesLast7d)) last 7d · \(ByteFormatting.format(s.disposedBytesTotal)) all-time · \(s.runsTotal) runs · \(s.failuresTotal) failures")
        print("disk: \(s.hostsLowDisk) host(s) under 10% free · \(ByteFormatting.format(s.volumeAvailableBytes)) free of \(ByteFormatting.format(s.volumeTotalBytes)) · quarantine \(ByteFormatting.format(s.quarantineBytes))")
        if !s.topReclaimable.isEmpty {
            print("\nmost to reclaim:")
            for t in s.topReclaimable.prefix(5) { print("  \(t.host.padding(toLength: 24, withPad: " ", startingAt: 0)) \(ByteFormatting.format(t.bytes))") }
        }
        if !s.license.hostsOverLimit.isEmpty { print("\nover license allowance: \(s.license.hostsOverLimit.joined(separator: ", "))") }
    }
}

struct HubHosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hosts", abstract: "Inventory table.")
    @OptionGroup var conn: HubConnection
    @Option(name: .long, help: "Only hosts with this status: healthy, attention, stale.") var status: String?
    @Flag(name: .long) var json = false
    func run() async throws {
        var rows = try await conn.client().hosts()
        if let s = status { rows = rows.filter { $0.status.rawValue == s } }
        if json { Output.printJSON(rows); return }
        let f = ISO8601DateFormatter()
        print(Output.table(rows.map { h in
            let r = h.latest
            let free = r.volumeFreeFraction.map { "\(Int($0 * 100))%" } ?? "-"
            return [h.host, h.status.rawValue, r.platform.rawValue, r.policyName + (r.dryRun ? " (dry)" : ""), ByteFormatting.format(r.reclaimableBytes),
                    ByteFormatting.format(r.disposedBytesTotal), free, f.string(from: h.lastSeen), h.statusReasons.joined(separator: "; ")]
        }, header: ["HOST", "STATUS", "OS", "POLICY", "RECLAIMABLE", "FREED", "FREE", "LAST REPORT", "NOTES"]))
    }
}

struct HubHost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "host", abstract: "Everything the hub knows about one host.")
    @OptionGroup var conn: HubConnection
    @Argument var name: String
    @Flag(name: .long) var json = false
    @Option(name: .long, help: "Set an operator note (empty string clears).") var note: String?
    func run() async throws {
        let c = try conn.client()
        if let n = note { try await c.setNote(name, note: n); print("note updated") }
        let h = try await c.host(name)
        if json { Output.printJSON(h); return }
        let r = h.latest
        print("\(h.host) · \(h.status.rawValue)\(h.statusReasons.isEmpty ? "" : " (\(h.statusReasons.joined(separator: "; ")))") · \(r.platform.rawValue) · roomy \(r.roomyVersion) · policy \(r.policyName)\(r.dryRun ? " · DRY RUN" : "") · \(r.edition)")
        print("reclaimable \(ByteFormatting.format(r.reclaimableBytes)) · freed \(ByteFormatting.format(r.disposedBytesTotal)) over \(r.runsTotal) runs · quarantine \(ByteFormatting.format(r.quarantineBytes)) · disk free \(r.volumeFreeFraction.map { "\(Int($0 * 100))%" } ?? "-") · audit seq \(r.auditSeq)")
        print("last run \(ISO8601DateFormatter().string(from: r.startedAt)): \(r.disposedItems) removed (\(ByteFormatting.format(r.disposedBytes))), \(r.failures) failed, \(r.findings) findings")
        if let n = h.note { print("note: \(n)") }
        if !r.topItems.isEmpty {
            print("")
            print(Output.table(r.topItems.prefix(20).map { [ByteFormatting.format($0.bytes), Output.tierLabel($0.tier), $0.category, $0.idleDays.map { "\($0)d" } ?? "-", Output.truncateMiddle($0.path, max: 70)] },
                               header: ["SIZE", "TIER", "CATEGORY", "IDLE", "PATH"]))
        }
    }
}

struct HubRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Drop a host from the inventory (it returns on its next report).")
    @OptionGroup var conn: HubConnection
    @Argument var name: String
    func run() async throws { try await conn.client().removeHost(name); print("removed \(name)") }
}

struct HubPolicy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "policy", abstract: "Centrally managed policies that hosts pull before each run.",
                                                    subcommands: [List.self, Get.self, Push.self, Remove.self])
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list")
        @OptionGroup var conn: HubConnection
        func run() async throws { for n in try await conn.client().policies() { print(n) } }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Print a hub policy as JSON.")
        @OptionGroup var conn: HubConnection
        @Argument var name: String
        func run() async throws { Output.printJSONData(try await conn.client().policyData(name)) }
    }
    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "push", abstract: "Validate a policy file and store it on the hub under NAME.")
        @OptionGroup var conn: HubConnection
        @Argument var name: String
        @Argument(help: "Policy JSON file.") var file: String
        func run() async throws {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let policy = try FleetPolicy.load(from: url)
            try await conn.client().putPolicy(name, data: try policy.encoded())
            print("pushed policy '\(name)' (\(policy.autoClean.tiers.map(\.rawValue).joined(separator: ",")) tiers, \(policy.disposal.method.rawValue))")
        }
    }
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove")
        @OptionGroup var conn: HubConnection
        @Argument var name: String
        func run() async throws { try await conn.client().removePolicy(name); print("removed policy '\(name)'") }
    }
}

struct HubEvents: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Recent hub activity.")
    @OptionGroup var conn: HubConnection
    @Option(name: [.customShort("n"), .long]) var lines: Int = 30
    @Flag(name: .long) var json = false
    func run() async throws {
        let ev = try await conn.client().events(last: lines)
        if json { Output.printJSON(ev); return }
        let f = ISO8601DateFormatter()
        for e in ev { print("\(f.string(from: e.time)) \(e.kind.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(e.host ?? "-") \(e.message)\(e.bytes.map { " \(ByteFormatting.format($0))" } ?? "")") }
    }
}

struct HubDemo_: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demo", abstract: "Fill a data directory with a synthetic fleet so you can try the dashboard.",
                                                    discussion: "Then: roomy hub serve --data-dir DIR. Nothing in the demo is real.")
    @Option(name: .long, help: "Data directory to write. Default ~/.roomy/hub-demo.") var dataDir: String = "~/.roomy/hub-demo"
    @Option(name: .long, help: "How many hosts.") var hosts: Int = 5
    @Option(name: .long) var seed: UInt64 = 7
    @Option(name: .long, help: "Organisation name the demo hosts report.") var org: String?
    @Flag(name: .long, help: "Delete the directory first.") var reset = false
    func run() throws {
        let dir = URL(fileURLWithPath: (dataDir as NSString).expandingTildeInPath, isDirectory: true)
        if reset { try? FileManager.default.removeItem(at: dir) }
        let store = try HubStore(dataDir: dir)
        let names = try RoomyFleet.HubDemo.populate(store: store, hosts: hosts, seed: seed, org: org)
        print("wrote \(names.count) demo hosts to \(dir.path): \(names.joined(separator: ", "))")
        print("try: roomy hub serve --data-dir \(dir.path) --title \"Demo fleet\"")
    }
}

struct HubToken: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token", abstract: "Generate a random token for --agent-token or --admin-token.")
    func run() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        print(Base64URL.encode(Data(bytes)))
    }
}
