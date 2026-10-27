//
//  HubServer.swift
//  RoomyFleet
//
//  The central service agents report to. Serves the dashboard, a JSON API, fleet-wide
//  Prometheus metrics and centrally managed policies. Two tokens: agents may only post reports
//  and fetch policies; the admin token reads and changes everything.
//

import Foundation
import RoomyCore

public struct HubConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var dataDir: URL
    public var agentToken: String?
    public var adminToken: String?
    public var staleAfter: TimeInterval
    public var licenseToken: String?
    public var title: String
    /// Hosts the community edition tracks before asking for a license.
    public static let communityHostLimit = 5

    public init(host: String = "127.0.0.1", port: UInt16 = 9478, dataDir: URL, agentToken: String? = nil, adminToken: String? = nil,
                staleAfter: TimeInterval = 24 * 3600, licenseToken: String? = nil, title: String = "Roomy Hub") {
        self.host = host; self.port = port; self.dataDir = dataDir; self.agentToken = agentToken; self.adminToken = adminToken
        self.staleAfter = staleAfter; self.licenseToken = licenseToken; self.title = title
    }
}

public struct HubAck: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var host: String
    public var hostsKnown: Int
    public var hostLimit: Int
    public var edition: String
    public var message: String
}

public final class HubServer: @unchecked Sendable {
    public let config: HubConfig
    public let store: HubStore
    private var http: HTTPServer?
    public var log: @Sendable (String) -> Void = { _ in }
    public let startedAt = Date()

    public init(config: HubConfig) throws {
        self.config = config
        self.store = try HubStore(dataDir: config.dataDir, staleAfter: config.staleAfter, title: config.title)
    }

    public var port: UInt16 { http?.port ?? config.port }

    public func start() throws {
        let server = HTTPServer(host: config.host, port: config.port) { [weak self] req in
            guard let self else { return .error("shutting down", status: 503) }
            return self.route(req)
        }
        try server.start()
        http = server
        store.appendEvent(HubEvent(time: Date(), kind: .hubStarted, host: nil, message: "hub started on \(config.host):\(server.port) · \(licenseInfo().edition)", bytes: nil))
    }

    public func stop() { http?.stop() }

    // MARK: License

    public func licenseStatus() -> LicenseStatus {
        LicenseVerifier.status(token: config.licenseToken)
    }

    public func hostLimit() -> Int {
        let s = licenseStatus()
        return s.isFleet ? (s.payload?.maxHosts ?? HubConfig.communityHostLimit) : HubConfig.communityHostLimit
    }

    public func licenseInfo() -> HubLicenseInfo {
        let s = licenseStatus()
        let limit = hostLimit()
        return HubLicenseInfo(edition: s.edition.rawValue, org: s.payload?.org, maxHosts: limit, expiresAt: s.payload?.expiresAt,
                              problem: s.problem, hostsKnown: store.hostCount, hostsOverLimit: store.hostsOverLimit(limit))
    }

    // MARK: Auth

    enum Role { case agent, admin }

    func authorize(_ req: HTTPRequest, as role: Role) -> HTTPResponse? {
        let token = req.bearerToken
        switch role {
        case .admin:
            guard let admin = config.adminToken, !admin.isEmpty else { return nil }
            return constantTimeEqual(token, admin) ? nil : .error("admin token required", status: 401)
        case .agent:
            let agent = config.agentToken ?? ""
            let admin = config.adminToken ?? ""
            if agent.isEmpty && admin.isEmpty { return nil }
            if !agent.isEmpty, constantTimeEqual(token, agent) { return nil }
            if !admin.isEmpty, constantTimeEqual(token, admin) { return nil }
            return .error("agent token required", status: 401)
        }
    }

    func constantTimeEqual(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Routes

    public func route(_ req: HTTPRequest) -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        let m = req.method

        if parts.isEmpty { return m == "GET" || m == "HEAD" ? dashboardPage() : .error("method not allowed", status: 405) }
        if parts == ["healthz"] { return .text("ok\n") }
        if parts == ["metrics"] {
            if let denied = authorize(req, as: .admin) { return denied }
            return HTTPResponse(status: 200, headers: ["Content-Type": "text/plain; version=0.0.4; charset=utf-8"], body: Data(metricsText().utf8))
        }
        if m == "OPTIONS" { return HTTPResponse(status: 204, headers: ["Allow": "GET, POST, PUT, DELETE, OPTIONS"]) }
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return .text("not found\n", status: 404) }
        let resource = parts[2]
        let arg = parts.count > 3 ? parts[3] : nil
        let sub = parts.count > 4 ? parts[4] : nil

        switch (resource, arg, sub) {
        case ("report", nil, nil) where m == "POST":
            if let denied = authorize(req, as: .agent) { return denied }
            return ingest(req)
        case ("info", nil, nil) where m == "GET":
            return .json(["name": "roomy-hub", "version": RoomyCoreInfo.version, "schema": "\(HubSchema.version)", "title": config.title,
                          "authRequired": (config.adminToken?.isEmpty == false) ? "true" : "false"])

        case ("policies", nil, nil) where m == "GET":
            if let denied = authorize(req, as: .agent) { return denied }
            return .json(["policies": store.policyNames()])
        case ("policies", let name?, nil) where m == "GET":
            if let denied = authorize(req, as: .agent) { return denied }
            guard let data = store.policyData(named: name) else { return .error("no policy '\(name)'", status: 404) }
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
        case ("policies", let name?, nil) where m == "PUT":
            if let denied = authorize(req, as: .admin) { return denied }
            do {
                let policy = try JSONDecoder().decode(FleetPolicy.self, from: req.body)
                try store.putPolicy(policy, named: name)
                log("policy '\(name)' updated")
                return .json(["ok": "true", "name": name])
            } catch {
                return .error("invalid policy: \(error.localizedDescription)", status: 400)
            }
        case ("policies", let name?, nil) where m == "DELETE":
            if let denied = authorize(req, as: .admin) { return denied }
            return store.removePolicy(named: name) ? .json(["ok": "true"]) : .error("no policy '\(name)'", status: 404)

        case ("summary", nil, nil) where m == "GET":
            if let denied = authorize(req, as: .admin) { return denied }
            return .json(store.summary(license: licenseInfo()))
        case ("license", nil, nil) where m == "GET":
            if let denied = authorize(req, as: .admin) { return denied }
            return .json(licenseInfo())
        case ("events", nil, nil) where m == "GET":
            if let denied = authorize(req, as: .admin) { return denied }
            let n = Int(req.query["n"] ?? "") ?? 50
            return .json(["events": store.events(last: min(max(n, 1), 500))])

        case ("hosts", nil, nil) where m == "GET":
            if let denied = authorize(req, as: .admin) { return denied }
            let inv = store.inventory(license: licenseInfo())
            // The list omits history and top items; fetch a host for those.
            struct Row: Encodable {
                var host: String; var status: HubHostStatus; var statusReasons: [String]; var overLicenseLimit: Bool
                var firstSeen: Date; var lastSeen: Date; var reports: Int; var note: String?; var latest: HubHostReport; var history: [HubHistoryPoint]
            }
            let rows = inv.map { h -> Row in
                var latest = h.latest; latest.topItems = []
                return Row(host: h.host, status: h.status, statusReasons: h.statusReasons, overLicenseLimit: h.overLicenseLimit,
                           firstSeen: h.firstSeen, lastSeen: h.lastSeen, reports: h.reports, note: h.note, latest: latest, history: Array(h.history.suffix(40)))
            }
            return .json(["hosts": rows])
        case ("hosts", let name?, nil) where m == "GET":
            if let denied = authorize(req, as: .admin) { return denied }
            guard let rec = store.inventory(license: licenseInfo()).first(where: { $0.host == name }) else { return .error("unknown host", status: 404) }
            return .json(rec)
        case ("hosts", let name?, nil) where m == "DELETE":
            if let denied = authorize(req, as: .admin) { return denied }
            log("host '\(name)' removed")
            return store.remove(host: name) ? .json(["ok": "true"]) : .error("unknown host", status: 404)
        case ("hosts", let name?, "note"?) where m == "PUT":
            if let denied = authorize(req, as: .admin) { return denied }
            let note = String(decoding: req.body, as: UTF8.self)
            do {
                return try store.setNote(host: name, note: note) ? .json(["ok": "true"]) : .error("unknown host", status: 404)
            } catch { return .error(error.localizedDescription, status: 500) }
        default:
            return .error("not found", status: 404)
        }
    }

    func ingest(_ req: HTTPRequest) -> HTTPResponse {
        let report: HubHostReport
        do { report = try HubJSON.decoder.decode(HubHostReport.self, from: req.body) } catch {
            return .error("bad report: \(error.localizedDescription)", status: 400)
        }
        guard !report.host.isEmpty, report.host.count <= 253 else { return .error("bad host name", status: 400) }
        let limit = hostLimit()
        do {
            try store.ingest(report, hostLimit: limit)
            log("report from \(report.host): \(report.findings) findings, \(ByteFormatting.format(report.disposedBytes)) \(report.dryRun ? "would be removed (dry run)" : "removed")")
            let ack = HubAck(accepted: true, host: report.host, hostsKnown: store.hostCount, hostLimit: limit,
                             edition: licenseStatus().edition.rawValue, message: "ok")
            return .json(ack)
        } catch let e as HubStore.IngestError {
            log("rejected report from \(report.host): \(e.localizedDescription)")
            let ack = HubAck(accepted: false, host: report.host, hostsKnown: store.hostCount, hostLimit: limit,
                             edition: licenseStatus().edition.rawValue, message: e.localizedDescription)
            return .json(ack, status: 402)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    func dashboardPage() -> HTTPResponse {
        var html = String(decoding: PackageResources.dashboard_html, as: UTF8.self)
        html = html.replacingOccurrences(of: "__HUB_TITLE__", with: config.title.replacingOccurrences(of: "<", with: "&lt;"))
        html = html.replacingOccurrences(of: "__ROOMY_VERSION__", with: RoomyCoreInfo.version)
        var r = HTTPResponse.html(html)
        r.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'"
        return r
    }

    // MARK: Metrics

    public func metricsText() -> String {
        let license = licenseInfo()
        let inv = store.inventory(license: license)
        let summary = store.summary(license: license)
        var out: [String] = []
        func esc(_ s: String) -> String { PrometheusRenderer.escape(s) }
        func labels(_ pairs: [(String, String)]) -> String { PrometheusRenderer.labels(pairs) }
        func emit(_ name: String, _ type: String, _ help: String, _ rows: [([(String, String)], String)]) {
            out.append("# HELP \(name) \(help)")
            out.append("# TYPE \(name) \(type)")
            for (l, v) in rows { out.append("\(name)\(labels(l)) \(v)") }
        }
        emit("roomy_hub_build_info", "gauge", "Hub version and edition. Always 1.",
             [([("version", RoomyCoreInfo.version), ("edition", license.edition), ("org", license.org ?? "")], "1")])
        emit("roomy_hub_hosts", "gauge", "Hosts in the inventory, by status.",
             HubHostStatus.allCases.map { ([("status", $0.rawValue)], "\(summary.hostsByStatus[$0.rawValue] ?? 0)") })
        emit("roomy_hub_license_hosts_max", "gauge", "Host allowance of the license in effect.", [([], "\(license.maxHosts)")])
        emit("roomy_hub_reclaimable_bytes", "gauge", "Reclaimable bytes across the fleet, by tier.",
             ArtifactSafetyTier.allCases.map { ([("tier", $0.rawValue)], "\(summary.bytesByTier[$0.rawValue] ?? 0)") })
        emit("roomy_hub_reclaimable_bytes_by_category", "gauge", "Reclaimable bytes across the fleet, by category.",
             summary.bytesByCategory.keys.sorted().map { ([("category", $0)], "\(summary.bytesByCategory[$0] ?? 0)") })
        emit("roomy_hub_disposed_bytes_total", "counter", "Bytes removed across the fleet (sum of host audit totals).", [([], "\(summary.disposedBytesTotal)")])
        emit("roomy_hub_disposed_bytes_last_24h", "gauge", "Bytes removed across the fleet in the last 24 hours.", [([], "\(summary.disposedBytesLast24h)")])
        emit("roomy_hub_dispose_failures_total", "counter", "Disposal failures across the fleet.", [([], "\(summary.failuresTotal)")])
        emit("roomy_hub_quarantine_bytes", "gauge", "Bytes held in quarantine across the fleet.", [([], "\(summary.quarantineBytes)")])
        emit("roomy_hub_volume_available_bytes", "gauge", "Free bytes summed over reporting hosts.", [([], "\(summary.volumeAvailableBytes)")])
        emit("roomy_hub_volume_total_bytes", "gauge", "Volume size summed over reporting hosts.", [([], "\(summary.volumeTotalBytes)")])
        emit("roomy_hub_hosts_low_disk", "gauge", "Hosts with less than 10% of the volume free.", [([], "\(summary.hostsLowDisk)")])

        let hostInfo = inv.map { h in
            ([("host", h.host), ("platform", h.latest.platform.rawValue), ("version", h.latest.roomyVersion), ("policy", h.latest.policyName),
              ("edition", h.latest.edition), ("status", h.status.rawValue)], "1")
        }
        emit("roomy_hub_host_info", "gauge", "One series per host with its platform, version, policy and status.", hostInfo)
        emit("roomy_hub_host_reclaimable_bytes", "gauge", "Reclaimable bytes per host, by tier.",
             inv.flatMap { h in ArtifactSafetyTier.allCases.map { ([("host", h.host), ("tier", $0.rawValue)], "\(h.latest.bytesByTier[$0.rawValue] ?? 0)") } })
        emit("roomy_hub_host_disposed_bytes_total", "counter", "Bytes removed per host since its audit log began.",
             inv.map { ([("host", $0.host)], "\($0.latest.disposedBytesTotal)") })
        emit("roomy_hub_host_last_run_disposed_bytes", "gauge", "Bytes removed in the host's last run (0 for a dry run).",
             inv.map { ([("host", $0.host)], "\($0.latest.dryRun ? 0 : $0.latest.disposedBytes)") })
        emit("roomy_hub_host_last_run_failures", "gauge", "Disposal failures in the host's last run.",
             inv.map { ([("host", $0.host)], "\($0.latest.failures)") })
        emit("roomy_hub_host_last_run_success", "gauge", "1 if the host's last run completed without failures.",
             inv.map { ([("host", $0.host)], $0.latest.succeeded ? "1" : "0") })
        emit("roomy_hub_host_dry_run", "gauge", "1 if the host runs its policy in dry-run mode.",
             inv.map { ([("host", $0.host)], $0.latest.dryRun ? "1" : "0") })
        emit("roomy_hub_host_last_report_timestamp_seconds", "gauge", "When the hub last heard from the host.",
             inv.map { ([("host", $0.host)], String(format: "%.0f", $0.lastSeen.timeIntervalSince1970)) })
        emit("roomy_hub_host_quarantine_bytes", "gauge", "Bytes the host holds in quarantine.",
             inv.map { ([("host", $0.host)], "\($0.latest.quarantineBytes)") })
        emit("roomy_hub_host_volume_available_bytes", "gauge", "Free bytes on the host's scanned volume.",
             inv.compactMap { h in h.latest.volumeAvailableBytes.map { ([("host", h.host)], "\($0)") } })
        emit("roomy_hub_host_volume_total_bytes", "gauge", "Size of the host's scanned volume.",
             inv.compactMap { h in h.latest.volumeTotalBytes.map { ([("host", h.host)], "\($0)") } })
        emit("roomy_hub_host_audit_seq", "gauge", "Sequence number at the head of the host's audit log.",
             inv.map { ([("host", $0.host)], "\($0.latest.auditSeq)") })
        _ = esc
        return out.joined(separator: "\n") + "\n"
    }
}
