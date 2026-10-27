//
//  HubClient.swift
//  RoomyFleet
//
//  HTTP client used by agents (post a report, pull a policy) and by `roomy hub …` on an
//  operator's machine (inventory, summary, policies). Built on HTTPClient (sockets, or curl
//  for https) so the static Linux binary stays free of libcurl.
//

import Foundation
import RoomyCore

public struct HubClient: Sendable {
    public let baseURL: URL
    public let token: String?
    public let timeout: TimeInterval

    public init(baseURL: URL, token: String?, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout
    }

    public init(urlString: String, token: String?, timeout: TimeInterval = 15) throws {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw HubClientError.badURL(urlString)
        }
        self.init(baseURL: url, token: token, timeout: timeout)
    }

    public enum HubClientError: Error, LocalizedError {
        case badURL(String)
        case transport(String)
        case http(Int, String)
        case rejected(HubAck)

        public var errorDescription: String? {
            switch self {
            case .badURL(let s): return "not an http(s) URL: \(s)"
            case .transport(let m): return "hub unreachable: \(m)"
            case .http(let code, let body): return "hub returned \(code): \(body.prefix(200))"
            case .rejected(let ack): return "hub refused the report: \(ack.message)"
            }
        }
    }

    struct Prepared { var method: String; var url: URL; var headers: [String: String]; var body: Data? }

    func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") -> Prepared {
        var url = baseURL
        let pathAndQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        for component in pathAndQuery[0].split(separator: "/") { url.appendPathComponent(String(component)) }
        if pathAndQuery.count > 1, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.percentEncodedQuery = String(pathAndQuery[1])
            url = comps.url ?? url
        }
        var headers: [String: String] = [:]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        if body != nil { headers["Content-Type"] = contentType }
        return Prepared(method: method, url: url, headers: headers, body: body)
    }

    func send(_ r: Prepared) async throws -> (Int, Data) {
        let timeout = self.timeout
        return try await Task.detached(priority: .userInitiated) {
            do {
                let resp = try HTTPClient.request(method: r.method, url: r.url, headers: r.headers, body: r.body, timeout: timeout)
                return (resp.status, resp.body)
            } catch let e as HTTPClientError {
                throw HubClientError.transport(e.localizedDescription)
            }
        }.value
    }

    func decode<T: Decodable>(_ type: T.Type, _ pair: (Int, Data)) throws -> T {
        let (code, data) = pair
        guard (200..<300).contains(code) else { throw HubClientError.http(code, String(decoding: data, as: UTF8.self)) }
        return try HubJSON.decoder.decode(T.self, from: data)
    }

    // MARK: Agent side

    public func postReport(_ report: HubHostReport) async throws -> HubAck {
        let body = try HubJSON.encoder.encode(report)
        let (code, data) = try await send(request("POST", "api/v1/report", body: body))
        if code == 402, let ack = try? HubJSON.decoder.decode(HubAck.self, from: data) { throw HubClientError.rejected(ack) }
        return try decode(HubAck.self, (code, data))
    }

    public func fetchPolicy(named name: String) async throws -> FleetPolicy {
        let (code, data) = try await send(request("GET", "api/v1/policies/\(name)"))
        guard (200..<300).contains(code) else { throw HubClientError.http(code, String(decoding: data, as: UTF8.self)) }
        let policy = try JSONDecoder().decode(FleetPolicy.self, from: data)
        try policy.validate()
        return policy
    }

    // MARK: Operator side

    public func info() async throws -> [String: String] { try decode([String: String].self, try await send(request("GET", "api/v1/info"))) }
    public func summary() async throws -> HubSummary { try decode(HubSummary.self, try await send(request("GET", "api/v1/summary"))) }
    public func license() async throws -> HubLicenseInfo { try decode(HubLicenseInfo.self, try await send(request("GET", "api/v1/license"))) }

    public struct HostRow: Codable, Sendable {
        public var host: String; public var status: HubHostStatus; public var statusReasons: [String]; public var overLicenseLimit: Bool
        public var firstSeen: Date; public var lastSeen: Date; public var reports: Int; public var note: String?; public var latest: HubHostReport
    }
    struct HostsEnvelope: Codable { var hosts: [HostRow] }
    struct PoliciesEnvelope: Codable { var policies: [String] }
    struct EventsEnvelope: Codable { var events: [HubEvent] }

    public func hosts() async throws -> [HostRow] { try decode(HostsEnvelope.self, try await send(request("GET", "api/v1/hosts"))).hosts }
    public func host(_ name: String) async throws -> HubHostRecord { try decode(HubHostRecord.self, try await send(request("GET", "api/v1/hosts/\(name)"))) }
    public func removeHost(_ name: String) async throws { _ = try decode([String: String].self, try await send(request("DELETE", "api/v1/hosts/\(name)"))) }
    public func setNote(_ name: String, note: String) async throws {
        _ = try decode([String: String].self, try await send(request("PUT", "api/v1/hosts/\(name)/note", body: Data(note.utf8), contentType: "text/plain")))
    }
    public func policies() async throws -> [String] { try decode(PoliciesEnvelope.self, try await send(request("GET", "api/v1/policies"))).policies }
    public func policyData(_ name: String) async throws -> Data {
        let (code, data) = try await send(request("GET", "api/v1/policies/\(name)"))
        guard (200..<300).contains(code) else { throw HubClientError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }
    public func putPolicy(_ name: String, data: Data) async throws {
        _ = try decode([String: String].self, try await send(request("PUT", "api/v1/policies/\(name)", body: data)))
    }
    public func removePolicy(_ name: String) async throws { _ = try decode([String: String].self, try await send(request("DELETE", "api/v1/policies/\(name)"))) }
    public func events(last n: Int = 50) async throws -> [HubEvent] { try decode(EventsEnvelope.self, try await send(request("GET", "api/v1/events?n=\(n)"))).events }
}
