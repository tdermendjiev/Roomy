//
//  Roomy.swift
//  roomy
//
//  The CLI. Same core as the Mac app, built for macOS and Linux. Designed to be called by
//  humans and by agents: stable JSON, dry-run by default where it matters, plan-file deletion.
//

import ArgumentParser
import Foundation
import RoomyCore
import RoomyFleet

@main
struct RoomyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roomy",
        abstract: "Finds and removes regenerable developer and AI-agent artifacts: node_modules, venvs, build caches, model stores, agent leftovers.",
        discussion: """
        Typical flow:
          roomy scan --json                 # what could be reclaimed, as data
          roomy scan --plan plan.json       # write a plan (safe tier by default)
          roomy clean --plan plan.json      # remove exactly what the plan lists

        Exit codes: 0 ok · 1 error · 3 some items failed · 4 another run holds the lock · 5 refused by safety tier · 64 usage.
        """,
        version: RoomyCoreInfo.version,
        subcommands: [Scan.self, Clean.self, Purge.self, Restore.self, Rules.self, Doctor.self, Fleet.self, Hub.self, Version.self],
        defaultSubcommand: nil
    )
}

enum ExitCodes {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let partialFailure: Int32 = 3
    static let locked: Int32 = 4
    static let refusedByTier: Int32 = 5
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print version, platform and catalog version.")

    @Flag(name: .long, help: "JSON output.") var json = false

    func run() throws {
        let info: [String: String] = [
            "version": RoomyCoreInfo.version,
            "platform": RoomyPlatform.current.rawValue,
            "catalogVersion": RuleCatalog.builtin.catalogVersion,
            "reportSchema": "\(RoomyReportSchema.version)",
            "policySchema": "\(FleetPolicy.supportedSchemaVersion)",
        ]
        if json {
            Output.printJSON(info)
        } else {
            print("roomy \(RoomyCoreInfo.version) (\(RoomyPlatform.current.displayName)) · rule catalog \(RuleCatalog.builtin.catalogVersion) · report schema \(RoomyReportSchema.version)")
        }
    }
}
