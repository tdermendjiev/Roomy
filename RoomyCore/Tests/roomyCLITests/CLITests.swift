import Foundation
import Testing

/// Runs the built `roomy` binary. Requires `swift build` to have produced it (swift test does).
struct CLITests {
    static let binary: URL = {
        // .build/<config>/roomy next to the test bundle's products dir
        let bundle = Bundle.main.bundleURL
        var dir = bundle
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("roomy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: ".build/debug/roomy")
    }()

    func roomy(_ args: [String], env: [String: String] = [:]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let o = Pipe(), er = Pipe()
        p.standardOutput = o; p.standardError = er
        try p.run()
        let out = o.fileHandleForReading.readDataToEndOfFile()
        let err = er.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    @Test func versionAndRules() throws {
        let v = try roomy(["version", "--json"])
        #expect(v.status == 0)
        #expect(v.out.contains("\"reportSchema\""))
        let r = try roomy(["rules", "--json"])
        #expect(r.status == 0)
        #expect(r.out.contains("\"projectRules\""))
        let h = try roomy(["--help"])
        #expect(h.status == 0 && h.out.contains("scan") && h.out.contains("clean"))
    }

    @Test func scanPlanCleanRoundTrip() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-cli-\(UUID().uuidString)")
        let home = sandbox.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let nm = home.appendingPathComponent("app/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: nm.appendingPathComponent("a.js"))
        let crush = home.appendingPathComponent("app/.crush")
        try FileManager.default.createDirectory(at: crush, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: crush.appendingPathComponent("db"))

        let plan = sandbox.appendingPathComponent("plan.json").path
        let scan = try roomy(["scan", home.path, "--home", home.path, "--no-system", "--json", "--plan", plan, "--plan-tier", "warning", "--quiet"])
        #expect(scan.status == 0, Comment(rawValue: scan.err))
        #expect(scan.out.contains("\"schemaVersion\" : 1"))
        #expect(scan.out.contains("node_modules"))
        #expect(FileManager.default.fileExists(atPath: plan))

        // Plan has a warning item → clean refuses with exit 5 by default
        let refused = try roomy(["clean", "--plan", plan, "--yes", "--dry-run", "--audit", sandbox.appendingPathComponent("a.jsonl").path])
        #expect(refused.status == 5)
        #expect(refused.err.contains("refusing"))

        // Non-TTY without --yes → exit 1
        let noYes = try roomy(["clean", "--plan", plan, "--allow-irreversible", "--audit", sandbox.appendingPathComponent("a.jsonl").path])
        #expect(noYes.status == 1)
        #expect(FileManager.default.fileExists(atPath: nm.path))

        // Quarantine both with --yes
        let q = sandbox.appendingPathComponent("q").path
        let clean = try roomy(["clean", "--plan", plan, "--allow-irreversible", "--yes", "--method", "quarantine", "--quarantine-dir", q,
                               "--audit", sandbox.appendingPathComponent("a.jsonl").path, "--json"])
        #expect(clean.status == 0, Comment(rawValue: clean.err))
        #expect(clean.out.contains("\"removed\" : 2"))
        #expect(!FileManager.default.fileExists(atPath: nm.path))

        // Restore one, purge nothing (too young), then purge with --older-than 0
        let list = try roomy(["restore", "--quarantine-dir", q])
        #expect(list.status == 0 && list.out.contains("node_modules"))
        let restore = try roomy(["restore", "app/node_modules", "--quarantine-dir", q])
        #expect(restore.status == 0, Comment(rawValue: restore.err))
        #expect(FileManager.default.fileExists(atPath: nm.appendingPathComponent("a.js").path))
        let purge = try roomy(["purge", "--quarantine-dir", q, "--older-than", "0", "--json"])
        #expect(purge.status == 0)
        #expect(purge.out.contains("\"remaining\" : 0"))

        // Audit log verifies
        let verify = try roomy(["fleet", "audit", "verify", "--path", sandbox.appendingPathComponent("a.jsonl").path])
        #expect(verify.status == 0, Comment(rawValue: verify.out + verify.err))
    }

    @Test func fleetPolicyInitAndCheck() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let pol = sandbox.appendingPathComponent("policy.json").path
        let initRes = try roomy(["fleet", "policy", "init", "--profile", "developer", "--output", pol])
        #expect(initRes.status == 0, Comment(rawValue: initRes.err))
        // Point it at an empty home so the check is fast and deterministic
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: pol))) as! [String: Any]
        let home = sandbox.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        var scan = json["scan"] as! [String: Any]
        scan["home"] = home; scan["roots"] = [home]; scan["categories"] = ["aiTools"]
        json["scan"] = scan
        json["audit"] = ["path": sandbox.appendingPathComponent("audit.jsonl").path]
        json["lockFile"] = sandbox.appendingPathComponent("lock").path
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: pol))
        let check = try roomy(["fleet", "policy", "check", "--policy", pol])
        #expect(check.status == 0, Comment(rawValue: check.err))
        #expect(check.out.contains("is valid"))
        let run = try roomy(["fleet", "run", "--policy", pol, "--dry-run", "--json"])
        #expect(run.status == 0, Comment(rawValue: run.err))
        #expect(run.out.contains("\"dryRun\" : true"))
        let doctor = try roomy(["doctor", "--json"])
        #expect(doctor.status == 0)
        #expect(doctor.out.contains("\"name\" : \"quarantine\""))
    }
}
