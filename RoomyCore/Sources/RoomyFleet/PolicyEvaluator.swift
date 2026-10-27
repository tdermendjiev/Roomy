//
//  PolicyEvaluator.swift
//  RoomyFleet
//
//  Turns a scan report plus a policy into a cleanup plan, recording why each item was or
//  was not selected. Pure function; nothing here touches the disk.
//

import Foundation
import RoomyCore

public enum SkipReason: String, Codable, Sendable, Equatable {
    case tierNeverRemoved
    case tierNotAutoCleaned
    case ruleNeverRemoved
    case pathProtected
    case categoryNotAllowed
    case ecosystemNotAllowed
    case tooRecent
    case idleUnknown
    case tooSmall
    case overBudget
}

public struct PolicyDecision: Sendable, Equatable {
    public struct Skipped: Sendable, Equatable, Codable {
        public let item: ScanReportItem
        public let reason: SkipReason
    }

    public let plan: CleanupPlan
    public let selected: [ScanReportItem]
    public let skipped: [Skipped]

    public var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }
    public var skippedBytesByReason: [SkipReason: Int64] {
        var out: [SkipReason: Int64] = [:]
        for s in skipped { out[s.reason, default: 0] += s.item.bytes }
        return out
    }
}

public enum PolicyEvaluator {
    public static func evaluate(report: ScanReport, policy: FleetPolicy, now: Date = Date()) -> PolicyDecision {
        let home = URL(fileURLWithPath: report.home, isDirectory: true)
        let protectedFilter = RoomyScanExclusionFilter(rawExclusions: policy.never.paths, homeDirectory: home)
        let neverRules = Set(policy.never.ruleIDs)
        let allowedTiers = Set(policy.autoClean.tiers)
        let neverTiers = Set(policy.never.tiers)
        let allowedCategories = policy.autoClean.categories.map(Set.init)
        let allowedEcosystems = policy.autoClean.ecosystems.map(Set.init)

        var selected: [ScanReportItem] = []
        var skipped: [PolicyDecision.Skipped] = []
        var plannedBytes: Int64 = 0

        // Largest first, so a byte budget buys the most space.
        for item in report.items.sorted(by: { $0.bytes > $1.bytes }) {
            func skip(_ r: SkipReason) { skipped.append(.init(item: item, reason: r)) }

            if neverTiers.contains(item.tier) { skip(.tierNeverRemoved); continue }
            if !allowedTiers.contains(item.tier) { skip(.tierNotAutoCleaned); continue }
            if let r = item.ruleID, neverRules.contains(r) { skip(.ruleNeverRemoved); continue }
            if item.source == .projectWalk || item.source == .systemProbe {
                if protectedFilter.shouldExclude(path: item.path) { skip(.pathProtected); continue }
            }
            if let cats = allowedCategories, !cats.contains(item.category) { skip(.categoryNotAllowed); continue }
            if let ecos = allowedEcosystems, !ecos.contains(item.ecosystem) { skip(.ecosystemNotAllowed); continue }
            if item.bytes < policy.autoClean.minBytes { skip(.tooSmall); continue }
            if policy.autoClean.minIdleDays > 0 {
                if let idle = item.idleDays {
                    if idle < policy.autoClean.minIdleDays { skip(.tooRecent); continue }
                } else if policy.autoClean.requireKnownIdle {
                    skip(.idleUnknown); continue
                }
            } else if policy.autoClean.requireKnownIdle, item.idleDays == nil {
                skip(.idleUnknown); continue
            }
            if let maxBytes = policy.autoClean.maxBytesPerRun, plannedBytes + item.bytes > maxBytes { skip(.overBudget); continue }
            if let maxItems = policy.autoClean.maxItemsPerRun, selected.count >= maxItems { skip(.overBudget); continue }

            selected.append(item)
            plannedBytes += item.bytes
        }

        let plan = CleanupPlan(items: selected.map(CleanupPlan.Item.init), method: policy.disposal.method,
                               reason: "policy:\(policy.name)", now: now)
        return PolicyDecision(plan: plan, selected: selected, skipped: skipped)
    }
}
