//
//  Clean.swift
//  roomy
//

import ArgumentParser
import Foundation
import RoomyCore
import RoomyFleet

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove exactly what a plan file lists. Refuses anything above the allowed safety tier.",
        discussion: """
        A plan comes from `roomy scan --plan`, `roomy fleet policy check`, or any tool that writes the plan
        schema. Items that no longer exist are skipped. By default only `safe` items are removed; pass
        --allow-caution for review-tier items and --allow-irreversible for session history and other
        non-regenerable data. Every removal is appended to the audit log (default ~/.roomy/audit.jsonl).
        """
    )

    @Option(name: .long, help: "Plan file written by `roomy scan --plan`.")
    var plan: String

    @Option(name: .long, help: "Override the plan's disposal method: trash, quarantine, delete.")
    var method: DisposalMethod?

    @Flag(name: .long, help: "Allow review-tier (caution) items.")
    var allowCaution = false

    @Flag(name: .long, help: "Allow irreversible (warning) items. Session history, archives, volumes.")
    var allowIrreversible = false

    @Flag(name: .long, help: "Show what would happen; touch nothing.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation. Required when stdin is not a terminal.")
    var yes = false

    @Flag(name: .long, help: "JSON summary on stdout.")
    var json = false

    @Option(name: .long, help: "Audit log path (JSON Lines). Default ~/.roomy/audit.jsonl.")
    var audit: String?

    @Option(name: .long, help: "Quarantine directory (quarantine method). Default ~/.roomy/quarantine or $ROOMY_QUARANTINE_DIR.")
    var quarantineDir: String?

    @Option(name: .long, help: "Quarantine retention in days, recorded for `roomy purge`.")
    var retentionDays: Int = 7

    @Option(name: .long, help: "Actor name recorded in the audit log (e.g. the agent calling roomy).")
    var actor: String = "roomy-cli"

    struct Summary: Encodable {
        var plan: String
        var method: DisposalMethod
        var dryRun: Bool
        var removed: Int
        var removedBytes: Int64
        var failed: [RoomyDeletionFailure]
        var skippedMissing: [String]
        var refused: [CleanupPlan.Item]
    }

    func run() async throws {
        let planURL = URL(fileURLWithPath: (plan as NSString).expandingTildeInPath)
        let plan = try CleanupPlan.load(from: planURL)
        let method = self.method ?? plan.method
        var maxTier: ArtifactSafetyTier = .safe
        if allowCaution { maxTier = .caution }
        if allowIrreversible { maxTier = .warning }

        let refused = plan.items.filter { $0.tier > maxTier }
        if !refused.isEmpty {
            Output.warn("refusing \(refused.count) item(s) above tier '\(Output.tierLabel(maxTier))':")
            for r in refused.prefix(10) { Output.warn("  \(Output.tierLabel(r.tier))  \(r.path)  (\(r.label))") }
            if refused.count > 10 { Output.warn("  … \(refused.count - 10) more") }
            Output.warn(refused.contains { $0.tier == .warning }
                        ? "pass --allow-irreversible to include irreversible items, or rewrite the plan without them"
                        : "pass --allow-caution to include review-tier items")
            if json { Output.printJSON(Summary(plan: planURL.path, method: method, dryRun: dryRun, removed: 0, removedBytes: 0, failed: [], skippedMissing: [], refused: refused)) }
            throw ExitCode(ExitCodes.refusedByTier)
        }

        let missing = Set(plan.missingItems().map(\.path))
        let items = plan.items.filter { !missing.contains($0.path) }
        for m in missing { Output.warn("skipping missing: \(m)") }

        if items.isEmpty {
            Output.status("nothing to do", quiet: false)
            if json { Output.printJSON(Summary(plan: planURL.path, method: method, dryRun: dryRun, removed: 0, removedBytes: 0, failed: [], skippedMissing: Array(missing), refused: [])) }
            return
        }

        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        if !dryRun && !yes {
            guard Output.isTTY else {
                Output.warn("stdin is not a terminal; pass --yes to proceed without confirmation (or --dry-run)")
                throw ExitCode(ExitCodes.error)
            }
            print("About to \(method.displayLabel.lowercased()) \(items.count) items, \(ByteFormatting.format(total)):")
            for i in items.prefix(15) { print("  \(ByteFormatting.format(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(Output.tierLabel(i.tier).padding(toLength: 12, withPad: " ", startingAt: 0)) \(i.path)") }
            if items.count > 15 { print("  … \(items.count - 15) more") }
            guard Output.confirm("Proceed?") else { Output.warn("aborted"); throw ExitCode(ExitCodes.error) }
        }

        let home = RoomyHost.homeDirectory
        let qdir = quarantineDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? QuarantineConfig.default(home: home).directory
        let quarantine = QuarantineConfig(directory: qdir, retentionDays: retentionDays)

        let outcome = await RoomyDeletionService.dispose(paths: items.map(\.path), method: method, quarantine: quarantine, dryRun: dryRun)

        // Audit
        let auditURL = audit.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? home.appendingPathComponent(".roomy/audit.jsonl")
        if let log = try? AuditLog(url: auditURL) {
            let runID = UUID().uuidString.lowercased()
            let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
            for r in outcome.receipts {
                let item = byPath[r.path]
                _ = try? log.append { seq, prev in
                    var rec = AuditRecord(seq: seq, runID: runID, event: .disposed, actor: actor, edition: "community",
                                          policy: plan.reason, prevHash: prev)
                    rec.path = r.path; rec.bytes = r.bytes ?? item?.bytes; rec.tier = item?.tier; rec.category = item?.category
                    rec.ruleID = item?.ruleID; rec.method = r.method; rec.destination = r.destination; rec.message = dryRun ? "dry run" : nil
                    return rec
                }
            }
            for f in outcome.failures {
                _ = try? log.append { seq, prev in
                    var rec = AuditRecord(seq: seq, runID: runID, event: .disposeFailed, actor: actor, edition: "community", policy: plan.reason, prevHash: prev)
                    rec.path = f.path; rec.message = f.message; rec.tier = byPath[f.path]?.tier
                    return rec
                }
            }
        }

        let removedBytes = outcome.receipts.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        if json {
            Output.printJSON(Summary(plan: planURL.path, method: method, dryRun: dryRun, removed: outcome.receipts.count,
                                     removedBytes: removedBytes, failed: outcome.failures, skippedMissing: Array(missing), refused: []))
        } else {
            let verb = dryRun ? "would \(method.rawValue)" : (method == .delete ? "deleted" : "moved to \(method.rawValue)")
            print("\(verb): \(outcome.receipts.count) items, \(ByteFormatting.format(removedBytes))")
            if method == .quarantine && !dryRun { print("quarantine: \(qdir.path) · purge after \(retentionDays) days with `roomy purge`") }
            for f in outcome.failures { print("FAILED \(f.path): \(f.message)") }
        }
        if !outcome.failures.isEmpty { throw ExitCode(ExitCodes.partialFailure) }
    }
}
