//
//  ScanExclusionFilter.swift
//  RoomyCore
//
//  Applies exclusions during scans (prefix paths + fnmatch globs).
//  `**` in a pattern is simplified to `*` before matching; prefer explicit path prefixes for deep trees.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ExclusionRowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case project
    case path
    case pattern

    public var title: String {
        switch self {
        case .project: return "Project"
        case .path: return "Path"
        case .pattern: return "Pattern"
        }
    }
}

public struct ExclusionEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var pathDisplay: String
    public var kind: ExclusionRowKind
    public var addedAt: Date

    public init(id: UUID = UUID(), pathDisplay: String, kind: ExclusionRowKind, addedAt: Date = Date()) {
        self.id = id
        self.pathDisplay = pathDisplay
        self.kind = kind
        self.addedAt = addedAt
    }
}

public struct RoomyScanExclusionFilter: Sendable {
    /// Longest first so nested paths match correctly when iterating.
    private let pathPrefixes: [String]
    private let globPatterns: [String]

    public static let empty = RoomyScanExclusionFilter(pathPrefixes: [], globPatterns: [])

    public init(entries: [ExclusionEntry], homeDirectory: URL) {
        var prefixes: [String] = []
        var globs: [String] = []
        let homePath = homeDirectory.path

        for entry in entries {
            let display = entry.pathDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { continue }

            switch entry.kind {
            case .path, .project:
                let abs = Self.absoluteNormalizedPath(display: display, homePath: homePath)
                if !abs.isEmpty { prefixes.append(abs) }
            case .pattern:
                if Self.looksLikeGlob(display) {
                    let expanded = Self.expandTildeInPattern(display, homePath: homePath)
                    let simplified = expanded.replacingOccurrences(of: "**", with: "*")
                    if !simplified.isEmpty { globs.append(simplified) }
                } else {
                    let abs = Self.absoluteNormalizedPath(display: display, homePath: homePath)
                    if !abs.isEmpty { prefixes.append(abs) }
                }
            }
        }

        pathPrefixes = Array(Set(prefixes)).sorted { $0.count > $1.count }
        globPatterns = Array(Set(globs))
    }

    /// Convenience for CLI flags: plain strings become paths or patterns depending on glob characters.
    public init(rawExclusions: [String], homeDirectory: URL) {
        let entries = rawExclusions.map { raw in
            ExclusionEntry(pathDisplay: raw, kind: Self.looksLikeGlob(raw) ? .pattern : .path)
        }
        self.init(entries: entries, homeDirectory: homeDirectory)
    }

    private init(pathPrefixes: [String], globPatterns: [String]) {
        self.pathPrefixes = pathPrefixes
        self.globPatterns = globPatterns
    }

    public var isEmpty: Bool { pathPrefixes.isEmpty && globPatterns.isEmpty }

    public func shouldExcludeDirectory(url: URL) -> Bool {
        shouldExclude(path: url.standardizedFileURL.path)
    }

    public func shouldExclude(path rawPath: String) -> Bool {
        let path = Self.normalizePath(rawPath)
        guard !path.isEmpty else { return false }

        for prefix in pathPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        for pattern in globPatterns {
            if Self.pathMatchesGlob(pattern: pattern, path: path) { return true }
        }
        return false
    }

    // MARK: - Paths

    private static func absoluteNormalizedPath(display: String, homePath: String) -> String {
        let expanded: String
        if display == "~" {
            expanded = homePath
        } else if display.hasPrefix("~/") {
            expanded = homePath + "/" + String(display.dropFirst(2))
        } else {
            expanded = (display as NSString).expandingTildeInPath
        }
        let std = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        return normalizePath(std)
    }

    private static func normalizePath(_ path: String) -> String {
        if path.isEmpty || path == "/" { return path }
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func expandTildeInPattern(_ pattern: String, homePath: String) -> String {
        if pattern == "~" { return homePath }
        if pattern.hasPrefix("~/") { return homePath + "/" + String(pattern.dropFirst(2)) }
        return pattern
    }

    static func looksLikeGlob(_ s: String) -> Bool {
        s.contains("*") || s.contains("?") || s.contains("[")
    }

    // MARK: - Glob (fnmatch + path tails)

    private static func pathMatchesGlob(pattern: String, path: String) -> Bool {
        let flags = FNM_PATHNAME
        if fnmatch(pattern, path, flags) == 0 { return true }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if fnmatch(pattern, trimmed, flags) == 0 { return true }
        let parts = trimmed.split(separator: "/")
        guard parts.count > 1 else { return false }
        for drop in 1..<parts.count {
            let tail = parts.dropFirst(drop).joined(separator: "/")
            if fnmatch(pattern, tail, flags) == 0 { return true }
        }
        return false
    }
}

/// Shared glob helper for catalog path specs.
enum GlobMatcher {
    static func matches(name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    static func isGlob(_ s: String) -> Bool {
        s.contains("*") || s.contains("?") || s.contains("[")
    }
}
