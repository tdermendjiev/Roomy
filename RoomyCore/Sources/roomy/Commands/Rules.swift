//
//  Rules.swift
//  roomy
//

import ArgumentParser
import Foundation
import RoomyCore

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the rule catalog: what Roomy looks for, where, and how safe it is to remove.")

    @Flag(name: .long, help: "Print the catalog as JSON (the same schema accepted by --rules files).")
    var json = false

    @Option(name: .long, help: "Only system rules in this category.")
    var category: String?

    @Option(name: .long, help: "Show paths for this platform (macos, linux). Default: current.")
    var platform: RoomyPlatform = .current

    @Option(name: .long, parsing: .upToNextOption, help: "Extra rule catalog files to merge before printing.")
    var rules: [String] = []

    func run() throws {
        var catalog = RuleCatalog.builtin
        for r in rules { catalog = catalog.merged(with: try RuleCatalog.load(from: URL(fileURLWithPath: (r as NSString).expandingTildeInPath))) }
        if json { Output.printJSONData(try catalog.encoded()); return }

        print("Rule catalog \(catalog.catalogVersion) · schema \(catalog.schemaVersion) · platform \(platform.displayName)\n")
        if category == nil {
            print("PROJECT FOLDERS (found while walking project trees)")
            let rows = catalog.projectRules(for: platform).map { r in
                [r.id, (r.parentName.map { "\($0)/" } ?? "") + r.folderName, r.ecosystem, Output.tierLabel(r.tier), r.restoreHint ?? ""]
            }
            print(Output.table(rows, header: ["ID", "FOLDER", "ECOSYSTEM", "TIER", "RESTORE"]))
            print("")
        }
        print("SYSTEM PATHS (tool-owned locations)")
        let sys = catalog.systemRules(for: platform, categories: category.map { [$0] })
        let rows = sys.map { r in
            [r.id, r.category, Output.tierLabel(r.tier), r.pathSpecs(for: platform).joined(separator: ", "), r.label]
        }
        print(Output.table(rows, header: ["ID", "CATEGORY", "TIER", "PATHS", "LABEL"]))
        print("\nCode-backed probes: Docker (CLI), Conda (CLI), pip orphans, global npm/yarn modules, Electron app caches, VS Code agent extensions, Claude Code per-project sessions, Cursor stale agent builds\(platform == .macOS ? ", Xcode archives, simulators, Homebrew prefix cache" : "").")
    }
}
