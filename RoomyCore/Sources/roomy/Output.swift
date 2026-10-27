//
//  Output.swift
//  roomy
//

import Foundation
import RoomyCore

enum Output {
    static var stderr = FileHandle.standardError

    static func warn(_ s: String) {
        stderr.write(Data(("roomy: " + s + "\n").utf8))
    }

    static func status(_ s: String, quiet: Bool) {
        guard !quiet else { return }
        stderr.write(Data((s + "\n").utf8))
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(value), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    static func printJSONData(_ data: Data) {
        if let s = String(data: data, encoding: .utf8) { print(s) }
    }

    /// Left-aligned columns; the last column is not padded.
    static func table(_ rows: [[String]], header: [String]) -> String {
        let all = [header] + rows
        var widths = Array(repeating: 0, count: header.count)
        for r in all { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
        func line(_ r: [String]) -> String {
            r.enumerated().map { i, c in
                i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    static func truncateMiddle(_ s: String, max: Int) -> String {
        guard s.count > max, max > 5 else { return s }
        let keep = (max - 1) / 2
        return String(s.prefix(keep)) + "…" + String(s.suffix(max - 1 - keep))
    }

    static func tierLabel(_ t: ArtifactSafetyTier) -> String {
        switch t {
        case .safe: return "safe"
        case .caution: return "review"
        case .warning: return "IRREVERSIBLE"
        }
    }

    static var isTTY: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

    static func confirm(_ prompt: String) -> Bool {
        print(prompt + " [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Double(t) { return n }
        guard let last = t.last, let n = Double(t.dropLast()) else { return nil }
        switch last {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86_400
        default: return nil
        }
    }
}

extension ArtifactSafetyTier: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "safe": self = .safe
        case "caution", "review": self = .caution
        case "warning", "irreversible": self = .warning
        default: return nil
        }
    }
    public static var allValueStrings: [String] { ["safe", "caution", "warning"] }
}

extension DisposalMethod: ExpressibleByArgument {}
extension RoomyPlatform: ExpressibleByArgument {}

import ArgumentParser
