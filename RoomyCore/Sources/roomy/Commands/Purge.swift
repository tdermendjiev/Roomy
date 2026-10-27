//
//  Purge.swift
//  roomy
//

import ArgumentParser
import Foundation
import RoomyCore

struct Purge: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Permanently remove expired items from Roomy's quarantine (and, on Linux, from the freedesktop Trash).",
        discussion: "Quarantined items keep a manifest with their original path. Nothing younger than --older-than is touched."
    )

    @Option(name: .long, help: "Quarantine directory. Default ~/.roomy/quarantine or $ROOMY_QUARANTINE_DIR.")
    var quarantineDir: String?

    @Option(name: .long, help: "Only purge items quarantined at least this many days ago.")
    var olderThan: Int = 7

    @Flag(name: .long, help: "Also purge the user's freedesktop Trash (Linux only).")
    var trash = false

    @Flag(name: .long, help: "List what would be purged; touch nothing.")
    var dryRun = false

    @Flag(name: .long, help: "JSON output.")
    var json = false

    struct Summary: Encodable {
        var quarantineDir: String
        var purged: [DisposalReceipt]
        var failed: [RoomyDeletionFailure]
        var remaining: Int
        var remainingBytes: Int64
    }

    func run() throws {
        let home = RoomyHost.homeDirectory
        let dir = quarantineDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? QuarantineConfig.default(home: home).directory
        let q = QuarantineDisposer(config: QuarantineConfig(directory: dir, retentionDays: olderThan))

        var outcome = DisposalOutcome()
        if dryRun {
            let cutoff = Date().addingTimeInterval(-Double(olderThan) * 86_400)
            for e in q.entries() where e.manifest.quarantinedAt < cutoff {
                outcome.receipts.append(DisposalReceipt(path: e.manifest.originalPath, method: .delete, destination: e.url.path, bytes: e.manifest.bytes))
            }
        } else {
            outcome = q.purge(olderThanDays: olderThan)
        }

        if trash {
            #if os(Linux)
            if let loc = try? FreedesktopTrash.location(for: home, home: home) {
                if dryRun {
                    Output.warn("trash: \(ByteFormatting.format(FreedesktopTrash.bytes(in: loc))) currently in \(loc.files.path)")
                } else {
                    let t = FreedesktopTrash.purge(location: loc, olderThanDays: olderThan)
                    outcome.receipts += t.receipts; outcome.failures += t.failures
                }
            }
            #else
            Output.warn("--trash only applies on Linux; on macOS empty the Trash from Finder")
            #endif
        }

        let bytes = outcome.receipts.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        if json {
            Output.printJSON(Summary(quarantineDir: dir.path, purged: outcome.receipts, failed: outcome.failures, remaining: q.entries().count, remainingBytes: q.totalBytes))
        } else {
            print("\(dryRun ? "would purge" : "purged") \(outcome.receipts.count) items, \(ByteFormatting.format(bytes)) · \(q.entries().count) items (\(ByteFormatting.format(q.totalBytes))) remain in \(dir.path)")
            for f in outcome.failures { print("FAILED \(f.path): \(f.message)") }
        }
        if !outcome.failures.isEmpty { throw ExitCode(ExitCodes.partialFailure) }
    }
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move a quarantined item back to where it came from, or list the quarantine.")

    @Argument(help: "Original path (or a unique suffix of it) of the item to restore. Omit to list.")
    var path: String?

    @Option(name: .long, help: "Quarantine directory.")
    var quarantineDir: String?

    @Flag(name: .long, help: "JSON output.")
    var json = false

    func run() throws {
        let home = RoomyHost.homeDirectory
        let dir = quarantineDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? QuarantineConfig.default(home: home).directory
        let q = QuarantineDisposer(config: QuarantineConfig(directory: dir))
        let entries = q.entries()

        guard let path else {
            if json {
                Output.printJSON(entries.map(\.manifest))
            } else if entries.isEmpty {
                print("quarantine is empty (\(dir.path))")
            } else {
                let rows = entries.map { [ByteFormatting.format($0.manifest.bytes ?? 0), ISO8601DateFormatter().string(from: $0.manifest.quarantinedAt), $0.manifest.originalPath] }
                print(Output.table(rows, header: ["SIZE", "QUARANTINED", "ORIGINAL PATH"]))
            }
            return
        }
        let expanded = (path as NSString).expandingTildeInPath
        let matches = entries.filter { $0.manifest.originalPath == expanded || $0.manifest.originalPath.hasSuffix(expanded) }
        guard matches.count == 1, let entry = matches.first else {
            Output.warn(matches.isEmpty ? "no quarantined item matches \(path)" : "\(matches.count) items match \(path); be more specific")
            throw ExitCode(ExitCodes.error)
        }
        try q.restore(entry: entry)
        print("restored \(entry.manifest.originalPath)")
    }
}
