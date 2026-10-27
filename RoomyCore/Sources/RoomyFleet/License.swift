//
//  License.swift
//  RoomyFleet
//
//  Offline-verifiable Ed25519 license tokens. Format: `ROOMY1.<base64url payload>.<base64url signature>`.
//  The public key is compiled in; the private key lives with whoever issues licenses
//  (see `roomy-licensetool`). No network call is ever made to check a license.
//

import Foundation
import Crypto
import RoomyCore

public struct LicensePayload: Codable, Equatable, Sendable {
    public var id: String
    public var org: String
    /// `fleet` is the paid edition. Anything else is treated as community.
    public var edition: String
    public var maxHosts: Int
    public var issuedAt: Date
    public var expiresAt: Date
    public var features: [String]

    public init(id: String = UUID().uuidString.lowercased(), org: String, edition: String = "fleet", maxHosts: Int,
                issuedAt: Date = Date(), expiresAt: Date, features: [String] = ["policy", "audit", "metrics", "serve"]) {
        self.id = id; self.org = org; self.edition = edition; self.maxHosts = maxHosts
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.features = features
    }
}

public enum LicenseEdition: String, Codable, Sendable {
    case community
    case fleet
}

public struct LicenseStatus: Equatable, Sendable {
    public let edition: LicenseEdition
    public let payload: LicensePayload?
    /// Why a supplied token was not accepted, if any.
    public let problem: String?

    public static let community = LicenseStatus(edition: .community, payload: nil, problem: nil)

    public var isFleet: Bool { edition == .fleet }
    public var summary: String {
        switch edition {
        case .community: return problem.map { "community (\($0))" } ?? "community"
        case .fleet:
            guard let p = payload else { return "fleet" }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            return "fleet · \(p.org) · up to \(p.maxHosts) hosts · expires \(f.string(from: p.expiresAt))"
        }
    }
}

public enum LicenseError: Error, LocalizedError, Equatable {
    case malformed
    case badSignature
    case expired(Date)
    case notYetValid(Date)

    public var errorDescription: String? {
        switch self {
        case .malformed: return "license token is malformed"
        case .badSignature: return "license signature does not verify"
        case .expired(let d): return "license expired on \(ISO8601DateFormatter().string(from: d))"
        case .notYetValid(let d): return "license is not valid before \(ISO8601DateFormatter().string(from: d))"
        }
    }
}

public enum LicenseVerifier {
    public static let tokenPrefix = "ROOMY1"

    /// Ed25519 public key (raw 32 bytes, base64). Replace only when rotating the issuing key.
    public static let publicKeyBase64 = "Aaw2tDY3oEVJsdq2Zqw1Rc3rr5FB02e0aS47a/77U6c="

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Verifies against the compiled-in key.
    public static func verify(token: String, now: Date = Date()) throws -> LicensePayload {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw LicenseError.badSignature
        }
        return try verify(token: token, publicKey: key, now: now)
    }

    public static func verify(token: String, publicKey: Curve25519.Signing.PublicKey, now: Date = Date()) throws -> LicensePayload {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == tokenPrefix,
              let payloadData = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2])) else {
            throw LicenseError.malformed
        }
        guard publicKey.isValidSignature(signature, for: payloadData) else { throw LicenseError.badSignature }
        let payload = try decoder.decode(LicensePayload.self, from: payloadData)
        if now > payload.expiresAt { throw LicenseError.expired(payload.expiresAt) }
        if now < payload.issuedAt.addingTimeInterval(-86_400) { throw LicenseError.notYetValid(payload.issuedAt) }
        return payload
    }

    /// Never throws: a missing or bad token means community edition with a note.
    public static func status(token: String?, now: Date = Date()) -> LicenseStatus {
        guard let token, !token.isEmpty else { return .community }
        do {
            let payload = try verify(token: token, now: now)
            return LicenseStatus(edition: payload.edition == "fleet" ? .fleet : .community, payload: payload, problem: nil)
        } catch {
            return LicenseStatus(edition: .community, payload: nil, problem: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: Issuing (used by roomy-licensetool and tests)

    public static func sign(payload: LicensePayload, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let body = try encoder.encode(payload)
        let sig = try privateKey.signature(for: body)
        return [tokenPrefix, Base64URL.encode(body), Base64URL.encode(sig)].joined(separator: ".")
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
