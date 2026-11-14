import Foundation
import Testing
@testable import RoomyCore

struct SnapshotTests {
    static let MB: Int64 = 1_048_576
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func item(_ path: String, _ mb: Int64, category: String = "globalCaches", tier: ArtifactSafetyTier = .safe) -> DiskSnapshot.Item {
        .init(id: StableID.make(path), path: path, label: (path as NSString).lastPathComponent, bytes: mb * MB, tier: tier, category: category, ruleID: nil)
    }

    static func snapshot(at: Date, freeMB: Int64, items: [DiskSnapshot.Item], dirs: [DiskSnapshot.Dir]? = nil) -> DiskSnapshot {
        DiskSnapshot(takenAt: at, host: "box", platform: .linux, home: "/home/u", scanRoot: "/home/u",
                     volume: .init(totalBytes: 100_000 * MB, availableBytes: freeMB * MB), items: items, dirs: dirs,
                     dirMinBytes: DirectorySizeSurvey.defaultMinBytes)
    }

    @Test func growthClassifiesAndSortsItems() throws {
        let a = Self.snapshot(at: Self.t0, freeMB: 50_000, items: [
            Self.item("/home/u/.cache/uv", 100),
            Self.item("/home/u/.cache/pip", 500),
            Self.item("/home/u/app/node_modules", 300, category: "project"),
            Self.item("/home/u/.cache/steady", 40),
        ])
        let b = Self.snapshot(at: Self.t0.addingTimeInterval(7 * 86_400), freeMB: 47_000, items: [
            Self.item("/home/u/.cache/uv", 1_100),                              // grew 1000
            Self.item("/home/u/.cache/pip", 200),                               // shrank 300
            Self.item("/home/u/.ollama/models", 700, category: "aiTools"),      // new
            Self.item("/home/u/.cache/steady", 40),                             // unchanged, left out
        ])
        let g = GrowthReport(from: a, to: b)

        #expect(g.seconds == 7 * 86_400)
        #expect(g.items.map(\.path) == ["/home/u/.cache/uv", "/home/u/.ollama/models", "/home/u/.cache/pip", "/home/u/app/node_modules"])
        #expect(g.items.map(\.status) == [.grew, .new, .shrank, .gone])
        #expect(g.items.map(\.deltaBytes) == [1000, 700, -300, -300].map { $0 * Self.MB })
        #expect(g.reclaimable.deltaBytes == 1_100 * Self.MB)
        #expect(g.volume?.usedDeltaBytes == 3_000 * Self.MB)
        // 3000 MB more in use, 1100 MB of it is findings: 1900 MB is something Roomy does not track.
        #expect(g.untrackedDeltaBytes == 1_900 * Self.MB)
        #expect(g.categories.map(\.category) == ["aiTools", "globalCaches", "project"])
        #expect(g.categories.map(\.deltaBytes) == [700, 700, -300].map { $0 * Self.MB })
        #expect(g.dirs == nil)
        #expect(g.warnings.isEmpty)

        // The JSON carries the computed delta and survives a round trip.
        let json = String(decoding: try g.encoded(), as: UTF8.self)
        #expect(json.contains("\"deltaBytes\""))
        #expect(try ScanReport.decoder.decode(GrowthReport.self, from: g.encoded()) == g)
    }

    @Test func growthSplitsDirectoryGrowthIntoTrackedAndUntracked() {
        let a = Self.snapshot(at: Self.t0, freeMB: 50_000, items: [Self.item("/home/u/.cache/uv", 100)], dirs: [
            .init(path: "/home/u", bytes: 1_000 * Self.MB, depth: 0),
            .init(path: "/home/u/.cache", bytes: 300 * Self.MB, depth: 1),
            .init(path: "/home/u/.cache/uv", bytes: 100 * Self.MB, depth: 2),
            .init(path: "/home/u/Videos", bytes: 200 * Self.MB, depth: 1),
        ])
        let b = Self.snapshot(at: Self.t0.addingTimeInterval(86_400), freeMB: 45_000, items: [Self.item("/home/u/.cache/uv", 600)], dirs: [
            .init(path: "/home/u", bytes: 6_000 * Self.MB, depth: 0),
            .init(path: "/home/u/.cache", bytes: 900 * Self.MB, depth: 1),
            .init(path: "/home/u/.cache/uv", bytes: 600 * Self.MB, depth: 2),
            .init(path: "/home/u/Videos", bytes: 4_200 * Self.MB, depth: 1),
            .init(path: "/home/u/dumps", bytes: 400 * Self.MB, depth: 1),
        ])
        let dirs = GrowthReport(from: a, to: b).dirs ?? []
        let by = Dictionary(uniqueKeysWithValues: dirs.map { ($0.path, $0) })
        #expect(dirs.first?.path == "/home/u")
        #expect(by["/home/u/Videos"]?.deltaBytes == 4_000 * Self.MB)
        #expect(by["/home/u/Videos"]?.reclaimableDeltaBytes == 0)            // nothing Roomy could clean
        #expect(by["/home/u/.cache"]?.deltaBytes == 600 * Self.MB)
        #expect(by["/home/u/.cache"]?.reclaimableDeltaBytes == 500 * Self.MB) // the uv cache accounts for most of it
        #expect(by["/home/u/.cache/uv"]?.reclaimableDeltaBytes == 500 * Self.MB)
        #expect(by["/home/u/dumps"]?.status == .new)
    }

    @Test func growthWarnsWhenOnlyOneSideHasDirectories() {
        let a = Self.snapshot(at: Self.t0, freeMB: 1, items: [])
        let b = Self.snapshot(at: Self.t0.addingTimeInterval(60), freeMB: 1, items: [], dirs: [.init(path: "/home/u", bytes: 1, depth: 0)])
        let g = GrowthReport(from: a, to: b)
        #expect(g.dirs == nil)
        #expect(g.warnings.count == 1)
    }

    @Test func storeSavesListsAndPicksTheClosestBaseline() throws {
        let dir = try TestFS.makeTempDir("roomy-snap"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir.appendingPathComponent("snapshots"))
        #expect(store.list().isEmpty)
        for d in [0, 1, 6, 8] {
            try store.save(Self.snapshot(at: Self.t0.addingTimeInterval(Double(d) * 86_400), freeMB: 1, items: [Self.item("/home/u/x", Int64(d + 1))]))
        }
        try Data("{}".utf8).write(to: store.directory.appendingPathComponent("notes.json"))   // ignored
        let entries = store.list()
        #expect(entries.count == 4)
        #expect(entries.map(\.takenAt) == entries.map(\.takenAt).sorted())
        let newest = try #require(store.latest())
        #expect(try DiskSnapshot.load(from: newest.url).items.first?.bytes == 9 * Self.MB)
        // A week before day 8 is day 1.
        #expect(store.closest(to: newest.takenAt.addingTimeInterval(-7 * 86_400), before: newest.takenAt)?.takenAt == Self.t0.addingTimeInterval(86_400))
        // Asking for longer than the history gives the oldest, never the newest itself.
        #expect(store.closest(to: newest.takenAt.addingTimeInterval(-90 * 86_400), before: newest.takenAt)?.takenAt == Self.t0)
    }

    @Test func pruneKeepsRecentThenOnePerWeekThenNothing() throws {
        let dir = try TestFS.makeTempDir("roomy-prune"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        let now = Self.t0
        // One snapshot a day for 60 days, plus one that is two years old.
        for d in 0..<60 { try store.save(Self.snapshot(at: now.addingTimeInterval(-Double(d) * 86_400), freeMB: 1, items: [])) }
        try store.save(Self.snapshot(at: now.addingTimeInterval(-730 * 86_400), freeMB: 1, items: []))
        store.prune(now: now)

        let ages = store.list().map { now.timeIntervalSince($0.takenAt) / 86_400 }
        #expect(ages.filter { $0 <= 14 }.count == 15)          // every recent one
        let old = ages.filter { $0 > 14 }
        #expect(old.allSatisfy { $0 < 365 })                   // the two-year-old one is gone
        #expect((6...8).contains(old.count))                   // 45 days thinned to about one a week
        let weeks = Set(store.list().filter { now.timeIntervalSince($0.takenAt) > 14 * 86_400 }
            .map { Int(($0.takenAt.timeIntervalSince1970 / 604_800).rounded(.down)) })
        #expect(weeks.count == old.count)                      // no two from the same week
        // Pruning again a day later with nothing new must not thin further within the weekly range.
        let before = store.list().count
        #expect(store.prune(now: now).isEmpty)
        #expect(store.list().count == before)
    }

    @Test func directorySurveySumsDescendantsIntoAncestors() throws {
        let root = try TestFS.makeTempDir("roomy-dirs"); defer { try? FileManager.default.removeItem(at: root) }
        try TestFS.writeFile(at: root.appendingPathComponent("top.bin"), bytes: 1_000)
        try TestFS.writeFile(at: root.appendingPathComponent("a/one.bin"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: root.appendingPathComponent("a/b/two.bin"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: root.appendingPathComponent("a/b/c/deep.bin"), bytes: TestFS.twoMB)
        try TestFS.writeFile(at: root.appendingPathComponent("small/s.bin"), bytes: 10)
        try TestFS.writeFile(at: root.appendingPathComponent("z/last.bin"), bytes: TestFS.twoMB)

        let dirs = DirectorySizeSurvey.survey(roots: [root, root], depth: 2)   // a repeated root is surveyed once
        let by = Dictionary(uniqueKeysWithValues: dirs.map { ($0.path, $0) })
        let two = Int64(TestFS.twoMB)
        #expect(dirs.first?.path == root.path)
        #expect(by[root.path]?.bytes == 4 * two + 1_010)
        #expect(by[root.path]?.depth == 0)
        #expect(by[root.appendingPathComponent("a").path]?.bytes == 3 * two)
        #expect(by[root.appendingPathComponent("a/b").path]?.bytes == 2 * two)   // includes the file below the depth limit
        #expect(by[root.appendingPathComponent("a/b").path]?.depth == 2)
        #expect(by[root.appendingPathComponent("a/b/c").path] == nil)            // deeper than --dirs-depth
        #expect(by[root.appendingPathComponent("small").path] == nil)            // under the size floor
        #expect(by[root.appendingPathComponent("z").path]?.bytes == two)          // a sibling after a deep subtree
        #expect(DirectorySizeSurvey.survey(roots: [root.appendingPathComponent("missing")]).isEmpty)
    }
}
