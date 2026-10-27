//
//  Activity.swift
//  RoomyCore
//
//  Project age classification. Shared by the app's age bar, the project list and fleet policies.
//

import Foundation

/// How recently a project (or tool group) was touched.
public enum ProjectActivity: String, CaseIterable, Identifiable, Codable, Sendable, Equatable {
    case active
    case recent
    case inactive
    case dormant

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .active: return "Active"
        case .recent: return "Recent"
        case .inactive: return "Inactive"
        case .dormant: return "Dormant"
        }
    }
}

/// Folder-mtime → activity rules. Thresholds come from settings or policy.
public enum ScanActivityClassification {
    /// Months since the project folder was last modified. System groups are treated as 12 months.
    public static func modificationMonthsAgo(projectPath: String, now: Date = Date()) -> Int {
        if RoomySystemGroupRoot.isSystemRoot(projectPath) {
            return 12
        }
        let url = URL(fileURLWithPath: projectPath)
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = vals.contentModificationDate else {
            return 36
        }
        return monthsBetween(date, and: now)
    }

    public static func modificationMonthsAgo(date: Date?, now: Date = Date()) -> Int {
        guard let date else { return 12 }
        return monthsBetween(date, and: now)
    }

    public static func activity(monthsAgo: Int, dormantMonths: Int, inactiveMonths: Int) -> ProjectActivity {
        if monthsAgo >= dormantMonths { return .dormant }
        if monthsAgo >= inactiveMonths { return .inactive }
        if monthsAgo >= 1 { return .recent }
        return .active
    }

    /// Days since a date, for policies that express idle time in days.
    public static func daysSince(_ date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    private static func monthsBetween(_ from: Date, and to: Date) -> Int {
        let comps = Calendar(identifier: .gregorian).dateComponents([.month], from: from, to: to)
        return max(0, comps.month ?? 0)
    }
}
