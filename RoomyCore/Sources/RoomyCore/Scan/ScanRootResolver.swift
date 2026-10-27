//
//  ScanRootResolver.swift
//  RoomyCore
//

import Foundation

public enum RoomyScanRootResolver {
    /// Label shown in scanning/results UI; URL is the enumerator root.
    public static func resolve(from settings: RoomyAppSettings, home: URL = RoomyHost.homeDirectory) -> (label: String, rootURL: URL) {
        switch settings.defaultScanLocation {
        case .home:
            return ("~/", home)
        case .custom:
            let path = settings.customScanPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty { return ("~/", home) }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            return (url.path, url)
        case .entireMac:
            let root = URL(fileURLWithPath: "/", isDirectory: true)
            return (RoomyPlatform.current == .macOS ? "Entire Mac" : "/", root)
        }
    }

    /// Restores a scan root from a persisted or legacy display label (e.g. last scan).
    public static func rootURL(fromDisplayLabel label: String, home: URL = RoomyHost.homeDirectory) -> URL {
        if label == "~/" { return home }
        if label.hasPrefix("~/") {
            let rest = String(label.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rest.isEmpty { return home }
            return home.appendingPathComponent(rest, isDirectory: true)
        }
        if label == "Entire Mac" || label == "/" {
            return URL(fileURLWithPath: "/", isDirectory: true)
        }
        if label == "All user-accessible paths" {
            return URL(fileURLWithPath: RoomyPlatform.current == .macOS ? "/Users" : "/home", isDirectory: true)
        }
        if label.hasPrefix("/") {
            return URL(fileURLWithPath: label, isDirectory: true)
        }
        return home
    }
}
