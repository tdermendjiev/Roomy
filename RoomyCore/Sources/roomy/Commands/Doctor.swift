//
//  Doctor.swift
//  roomy
//

import ArgumentParser
import Foundation
import RoomyCore
import RoomyFleet

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the environment: tools Roomy shells out to, disposal support, quarantine, license.")

    @Flag(name: .long, help: "JSON output.") var json = false
    @Option(name: .long, help: "Policy file to check the license from.") var policy: String?

    struct Check: Encodable { var name: String; var ok: Bool; var detail: String }

    func run() throws {
        var checks: [Check] = []
        let home = RoomyHost.homeDirectory
        checks.append(Check(name: "roomy", ok: true, detail: "\(RoomyCoreInfo.version) on \(RoomyPlatform.current.displayName), catalog \(RuleCatalog.builtin.catalogVersion)"))
        checks.append(Check(name: "home", ok: FileManager.default.isReadableFile(atPath: home.path), detail: home.path))
        let du = ["/usr/bin/du", "/bin/du"].first { FileManager.default.isExecutableFile(atPath: $0) }
        checks.append(Check(name: "du", ok: du != nil, detail: du ?? "missing (sizes fall back to a slower Foundation walk)"))
        checks.append(Check(name: "git", ok: RoomyGitMetadataReader.isGitAvailable, detail: RoomyGitMetadataReader.isGitAvailable ? "available" : "missing (project age uses folder mtimes only)"))
        let docker = DockerArtifactProbe.resolveDocker()
        checks.append(Check(name: "docker", ok: true, detail: docker ?? "not installed (Docker category skipped)"))
        checks.append(Check(name: "conda", ok: true, detail: ProcessRunner.which("conda") ?? "not installed (Conda probes skipped)"))
        #if os(macOS)
        checks.append(Check(name: "trash", ok: true, detail: "Finder Trash via FileManager"))
        #else
        let trashOK = (try? FreedesktopTrash.location(for: home, home: home)) != nil
        checks.append(Check(name: "trash", ok: trashOK, detail: trashOK ? "freedesktop Trash under $XDG_DATA_HOME (never emptied automatically on a headless host; prefer quarantine)" : "cannot create ~/.local/share/Trash"))
        #endif
        let q = QuarantineConfig.default(home: home)
        let qWritable: Bool = {
            do { try FileManager.default.createDirectory(at: q.directory, withIntermediateDirectories: true); return FileManager.default.isWritableFile(atPath: q.directory.path) } catch { return false }
        }()
        checks.append(Check(name: "quarantine", ok: qWritable, detail: q.directory.path))
        if let space = RoomyVolumeSpaceReader.space(forDirectory: home) {
            checks.append(Check(name: "volume", ok: true, detail: "\(ByteFormatting.format(space.availableBytes)) free of \(ByteFormatting.format(space.totalBytes))"))
        } else {
            checks.append(Check(name: "volume", ok: false, detail: "could not read volume capacity"))
        }
        var key: String? = ProcessInfo.processInfo.environment["ROOMY_LICENSE"]
        if let p = policy, let pol = try? FleetPolicy.load(from: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) {
            key = pol.resolvedLicenseKey()
        } else if key == nil {
            key = FleetPolicy().resolvedLicenseKey()
        }
        let status = LicenseVerifier.status(token: key)
        checks.append(Check(name: "license", ok: status.problem == nil, detail: status.summary))

        if json { Output.printJSON(checks); return }
        for c in checks { print("\(c.ok ? "ok  " : "warn") \(c.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(c.detail)") }
    }
}
