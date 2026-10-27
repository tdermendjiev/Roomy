//
//  HubDemo.swift
//  RoomyFleet
//
//  Synthetic fleet for trying the dashboard before any host reports. Deterministic for a seed,
//  so `roomy hub demo --seed 7` produces the same inventory every time. Nothing here is real:
//  host names, paths and sizes are invented to look like a typical mixed fleet.
//

import Foundation
import RoomyCore

public enum HubDemo {
    struct RNG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
    }

    struct Archetype {
        var names: [String]
        var platform: RoomyPlatform
        var policy: String
        var tags: [String: String]
        var intervalHours: Int
        var volumeGB: ClosedRange<Int>
        var reclaimableGB: ClosedRange<Int>
        var dryRun: Bool
    }

    static let archetypes: [Archetype] = [
        .init(names: ["agent-eu-01", "agent-eu-02", "agent-eu-03", "agent-eu-04", "agent-us-01", "agent-us-02", "agent-us-03", "agent-ap-01", "agent-ap-02"],
              platform: .linux, policy: "agent-host", tags: ["role": "agent", "team": "platform"], intervalHours: 6, volumeGB: 400...1000, reclaimableGB: 12...90, dryRun: false),
        .init(names: ["openclaw-prod-1", "openclaw-prod-2", "openclaw-staging"],
              platform: .linux, policy: "agent-host", tags: ["role": "openclaw", "team": "automation"], intervalHours: 6, volumeGB: 200...500, reclaimableGB: 8...60, dryRun: false),
        .init(names: ["ci-runner-01", "ci-runner-02", "ci-runner-03", "ci-runner-04", "ci-runner-05"],
              platform: .linux, policy: "ci-runner", tags: ["role": "ci", "team": "infra"], intervalHours: 3, volumeGB: 500...2000, reclaimableGB: 30...220, dryRun: false),
        .init(names: ["gpu-box-1", "gpu-box-2", "gpu-box-3"],
              platform: .linux, policy: "gpu-host", tags: ["role": "training", "team": "research"], intervalHours: 12, volumeGB: 2000...4000, reclaimableGB: 80...600, dryRun: false),
        .init(names: ["mbp-alex", "mbp-sam", "mbp-jordan", "mbp-priya", "studio-render", "mini-build-1"],
              platform: .macOS, policy: "developer", tags: ["role": "workstation", "team": "apps"], intervalHours: 24, volumeGB: 500...2000, reclaimableGB: 5...70, dryRun: false),
        .init(names: ["agent-canary"], platform: .linux, policy: "agent-host-canary", tags: ["role": "agent", "stage": "canary"],
              intervalHours: 6, volumeGB: 400...400, reclaimableGB: 20...40, dryRun: true),
    ]

    struct Finding { var label: String; var path: String; var tier: ArtifactSafetyTier; var category: String; var ruleID: String; var gb: ClosedRange<Double>; var linuxOnly: Bool; var macOnly: Bool }

    static let findings: [Finding] = [
        .init(label: "Hugging Face hub cache", path: "~/.cache/huggingface/hub", tier: .safe, category: "aiTools", ruleID: "hf-hub", gb: 4...60, linuxOnly: false, macOnly: false),
        .init(label: "uv cache", path: "~/.cache/uv", tier: .safe, category: "globalCaches", ruleID: "uv-cache", gb: 0.5...9, linuxOnly: false, macOnly: false),
        .init(label: "pip cache", path: "~/.cache/pip", tier: .safe, category: "globalCaches", ruleID: "pip-cache", gb: 0.3...6, linuxOnly: false, macOnly: false),
        .init(label: "npm cache", path: "~/.npm/_cacache", tier: .safe, category: "globalCaches", ruleID: "npm-cache", gb: 0.4...5, linuxOnly: false, macOnly: false),
        .init(label: "Cursor agent CLI stale builds", path: "~/.local/share/cursor-agent/versions", tier: .safe, category: "aiTools", ruleID: "cursor-agent-stale-versions", gb: 1...7, linuxOnly: false, macOnly: false),
        .init(label: "Docker build cache", path: "docker:builder", tier: .caution, category: "docker", ruleID: "docker-build-cache", gb: 2...40, linuxOnly: false, macOnly: false),
        .init(label: "Claude Code transcripts", path: "~/.claude/projects", tier: .warning, category: "aiTools", ruleID: "claude-projects", gb: 0.2...3, linuxOnly: false, macOnly: false),
        .init(label: "Codex log databases", path: "~/.codex/logs", tier: .safe, category: "aiTools", ruleID: "codex-sqlite-logs", gb: 0.1...4, linuxOnly: false, macOnly: false),
        .init(label: "OpenClaw plugin captures", path: "~/.openclaw/captures", tier: .safe, category: "agentHost", ruleID: "openclaw-plugin-captures", gb: 1...25, linuxOnly: true, macOnly: false),
        .init(label: "Claude Code scratch directories", path: "/tmp/claude-1000", tier: .safe, category: "agentHost", ruleID: "claude-scratch-tmp", gb: 0.2...12, linuxOnly: true, macOnly: false),
        .init(label: "Trash (not emptied)", path: "~/.local/share/Trash", tier: .caution, category: "agentHost", ruleID: "xdg-trash", gb: 0.5...30, linuxOnly: true, macOnly: false),
        .init(label: "Playwright browsers", path: "~/.cache/ms-playwright", tier: .safe, category: "aiTools", ruleID: "playwright-browsers", gb: 0.8...3, linuxOnly: false, macOnly: false),
        .init(label: "Ollama models", path: "~/.ollama/models", tier: .safe, category: "aiTools", ruleID: "ollama-models", gb: 4...40, linuxOnly: false, macOnly: false),
        .init(label: "conda package cache", path: "~/miniconda3/pkgs", tier: .safe, category: "python", ruleID: "conda-pkgs", gb: 1...12, linuxOnly: false, macOnly: false),
        .init(label: "node_modules", path: "~/work/orders-service/node_modules", tier: .safe, category: "project", ruleID: "node_modules", gb: 0.3...2.5, linuxOnly: false, macOnly: false),
        .init(label: ".venv", path: "~/work/etl-pipeline/.venv", tier: .safe, category: "project", ruleID: "python-venv", gb: 0.2...1.8, linuxOnly: false, macOnly: false),
        .init(label: "Rust target", path: "~/work/indexer/target", tier: .safe, category: "project", ruleID: "rust-target", gb: 1...14, linuxOnly: false, macOnly: false),
        .init(label: "Xcode DerivedData", path: "~/Library/Developer/Xcode/DerivedData", tier: .safe, category: "xcode", ruleID: "xcode-derived-data", gb: 3...30, linuxOnly: false, macOnly: true),
        .init(label: "Cursor state database backup", path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup", tier: .caution, category: "aiTools", ruleID: "cursor-state-backup", gb: 0.5...2, linuxOnly: false, macOnly: true),
        .init(label: "Claude desktop VM bundles", path: "~/Library/Application Support/Claude/vm_bundles", tier: .safe, category: "aiTools", ruleID: "claude-desktop-vm-bundles", gb: 4...12, linuxOnly: false, macOnly: true),
        .init(label: "Homebrew cache", path: "~/Library/Caches/Homebrew", tier: .safe, category: "homebrew", ruleID: "homebrew-cache", gb: 0.5...6, linuxOnly: false, macOnly: true),
        .init(label: "CoreSimulator caches", path: "~/Library/Developer/CoreSimulator/Caches", tier: .safe, category: "xcode", ruleID: "coresimulator-caches", gb: 1...9, linuxOnly: false, macOnly: true),
    ]

    static let GB: Double = 1_000_000_000

    /// Writes `hosts` synthetic hosts with 14 days of history into the store.
    @discardableResult
    public static func populate(store: HubStore, hosts count: Int, seed: UInt64 = 7, now: Date = Date(), edition: String = "fleet", org: String? = nil) throws -> [String] {
        var rng = RNG(seed: seed)
        var names: [String] = []
        var pool: [(String, Archetype)] = []
        for a in archetypes { for n in a.names { pool.append((n, a)) } }
        // Keep archetype variety even for small counts: round-robin over archetypes.
        var byArchetype = archetypes.map { a in a.names.map { ($0, a) } }
        var chosen: [(String, Archetype)] = []
        while chosen.count < count {
            var progressed = false
            for i in byArchetype.indices where !byArchetype[i].isEmpty && chosen.count < count {
                chosen.append(byArchetype[i].removeFirst()); progressed = true
            }
            if !progressed {
                let (n, a) = pool[chosen.count % pool.count]
                chosen.append(("\(n)-\(chosen.count / pool.count + 2)", a))
            }
        }
        for (index, (name, a)) in chosen.enumerated() {
            let volume = Int64(rng.int(a.volumeGB)) * Int64(GB)
            let base = Double(rng.int(a.reclaimableGB)) * GB
            var free = Double(volume) * (0.12 + rng.unit() * 0.5)
            let lowDisk = index % 9 == 4
            if lowDisk { free = Double(volume) * (0.04 + rng.unit() * 0.05) }
            let stale = index % 11 == 7
            let failing = index % 13 == 5
            let interval = TimeInterval(a.intervalHours * 3600)
            let runsTotal = rng.int(40...400)
            var disposedTotal = Double(rng.int(50...900)) * GB
            var reclaimable = base
            let end = stale ? now.addingTimeInterval(-TimeInterval(rng.int(50...80)) * 3600) : now.addingTimeInterval(-rng.unit() * interval * 0.9)
            var t = end.addingTimeInterval(-14 * 86_400)
            var runID = 0
            var seq = runsTotal * 9
            var lastReport: HubHostReport?
            while t <= end {
                runID += 1
                // Reclaimable grows between runs (agents keep producing caches); a run removes part of the safe tier,
                // so the series hovers around the archetype's baseline instead of draining to zero.
                reclaimable = max(base * 0.25, reclaimable + base * (0.05 + rng.unit() * 0.3))
                if a.dryRun { reclaimable = min(reclaimable, base * 2.5) }   // nothing is removed, but caches do get evicted by the tools themselves
                let safeShare = 0.55 + rng.unit() * 0.3
                let cautionShare = (1 - safeShare) * (0.4 + rng.unit() * 0.4)
                let safe = reclaimable * safeShare, caution = reclaimable * cautionShare, warning = reclaimable - safe - caution
                let removes = !a.dryRun && (rng.chance(0.65) || (failing && t > end.addingTimeInterval(-interval * 1.5)))
                let disposed = removes ? safe * (0.3 + rng.unit() * 0.5) : 0
                let items = removes ? rng.int(2...18) : 0
                let failures = !removes ? 0 : (failing && t > end.addingTimeInterval(-interval * 1.5)) ? rng.int(1...3) : (rng.chance(0.004) ? 1 : 0)
                if !a.dryRun { reclaimable -= disposed; disposedTotal += disposed }
                free = min(Double(volume) * 0.95, free + disposed * 0.8 - (rng.unit() * base * 0.1))
                if lowDisk { free = min(free, Double(volume) * 0.09) }
                seq += 7 + items
                var cats: [String: Int64] = [:]
                var tops: [HubTopItem] = []
                let candidates = findings.filter { f in (!f.linuxOnly || a.platform == .linux) && (!f.macOnly || a.platform == .macOS) }
                var remaining = reclaimable
                for f in candidates.shuffled(using: &rng).prefix(rng.int(6...10)) where remaining > 0 {
                    let gb = f.gb.lowerBound + rng.unit() * (f.gb.upperBound - f.gb.lowerBound)
                    let bytes = Int64(min(gb * GB, remaining))
                    remaining -= Double(bytes)
                    cats[f.category, default: 0] += bytes
                    var path = f.path
                    if a.platform == .linux, path.hasPrefix("~") { path = "/home/agent" + path.dropFirst() }
                    if a.platform == .macOS, path.hasPrefix("~") { path = "/Users/\(name.replacingOccurrences(of: "mbp-", with: ""))" + path.dropFirst() }
                    tops.append(HubTopItem(path: path, label: f.label, bytes: bytes, tier: f.tier, category: f.category, ruleID: f.ruleID, idleDays: rng.int(0...120)))
                }
                if remaining > 0 { cats["globalCaches", default: 0] += Int64(remaining) }
                tops.sort { $0.bytes > $1.bytes }
                var skipped: [String: Int] = ["tierNeverRemoved": rng.int(1...6), "tooRecent": rng.int(0...8), "tooSmall": rng.int(0...20)]
                if a.dryRun { skipped["dryRun"] = nil }
                let report = HubHostReport(
                    host: name, platform: a.platform, roomyVersion: index % 7 == 3 ? "1.2.0" : "1.3.0", catalogVersion: "2026.10.27",
                    policyName: a.policy, edition: edition, org: org, tags: a.tags, runID: "demo-\(name)-\(runID)", startedAt: t,
                    durationSeconds: 4 + rng.unit() * 40, dryRun: a.dryRun, succeeded: failures == 0, intervalSeconds: Int(interval),
                    findings: tops.count + rng.int(10...300), reclaimableBytes: Int64(reclaimable),
                    bytesByTier: ["safe": Int64(safe), "caution": Int64(caution), "warning": Int64(max(0, warning))], bytesByCategory: cats,
                    plannedItems: items, plannedBytes: Int64(disposed), disposedItems: max(0, items - failures), disposedBytes: Int64(disposed),
                    failures: failures, purgedItems: rng.int(0...6), purgedBytes: Int64(rng.unit() * disposed), skippedByReason: skipped,
                    disposedBytesTotal: Int64(disposedTotal), disposedItemsTotal: runsTotal * 6 + runID * 3, failuresTotal: failing ? rng.int(3...9) : rng.int(0...2),
                    runsTotal: runsTotal + runID, quarantineBytes: a.dryRun ? 0 : Int64(disposed * 0.7 + rng.unit() * 2 * GB), quarantineItems: items,
                    volumeTotalBytes: volume, volumeAvailableBytes: Int64(max(Double(volume) * 0.02, free)),
                    auditSeq: seq, auditHeadHash: String(format: "%016llx%016llx%016llx%016llx", rng.next(), rng.next(), rng.next(), rng.next()),
                    licenseExpiresAt: edition == "fleet" ? now.addingTimeInterval(200 * 86_400) : nil, topItems: Array(tops.prefix(25)))
                try store.ingest(report, receivedAt: t.addingTimeInterval(report.durationSeconds), hostLimit: nil)
                lastReport = report
                t = t.addingTimeInterval(interval * (0.9 + rng.unit() * 0.2))
            }
            _ = lastReport
            names.append(name)
        }
        return names
    }
}

extension Array {
    func shuffled(using rng: inout HubDemo.RNG) -> [Element] {
        var copy = self
        guard copy.count > 1 else { return copy }
        for i in stride(from: copy.count - 1, to: 0, by: -1) {
            let j = rng.int(0...i)
            if i != j { copy.swapAt(i, j) }
        }
        return copy
    }
}
