//
//  Growth.swift
//  roomy
//

import ArgumentParser
import Foundation
import RoomyCore

struct Growth: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what grew on disk between two snapshots. Never deletes anything.",
        discussion: """
        Snapshots come from `roomy scan --snapshot`, usually on a timer. By default the two most recent
        are compared; --since picks the snapshot closest to that long before the newest one.

          roomy growth                      # since the previous snapshot
          roomy growth --since 7d           # over about a week
          roomy growth --list               # which snapshots exist

        Findings are compared by path. Directories are compared too when both snapshots were taken
        with --dirs; that is what shows growth outside Roomy's rules.
        """
    )

    @Option(name: .long, help: "Compare against the snapshot closest to this long before the newest one, e.g. 12h, 7d, 4w.")
    var since: String?

    @Option(name: .long, help: "Earlier snapshot file. Overrides --since.")
    var from: String?

    @Option(name: .long, help: "Later snapshot file. Default: the newest snapshot.")
    var to: String?

    @Option(name: .long, help: "Where snapshots live. Default ~/.roomy/snapshots or $ROOMY_SNAPSHOT_DIR.")
    var snapshotDir: String?

    @Option(name: .long, help: "Ignore changes smaller than this many megabytes.")
    var minDeltaMb: Int = 1

    @Option(name: .long, help: "Rows to show per table.")
    var top: Int = 15

    @Flag(name: .long, help: "List the snapshots instead of comparing.")
    var list = false

    @Flag(name: .long, help: "JSON output.")
    var json = false

    static func snapshotDirectory(_ option: String?) -> URL {
        option.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? SnapshotStore.defaultDirectory()
    }

    struct Listing: Encodable {
        var takenAt: Date
        var path: String
    }

    func run() throws {
        let store = SnapshotStore(directory: Self.snapshotDirectory(snapshotDir))
        let entries = store.list()

        if list {
            if json {
                Output.printJSON(entries.map { Listing(takenAt: $0.takenAt, path: $0.url.path) })
            } else if entries.isEmpty {
                print("no snapshots in \(store.directory.path). Take one with: roomy scan --snapshot")
            } else {
                print(Output.table(entries.map { [Self.stamp($0.takenAt), $0.url.path] }, header: ["TAKEN", "FILE"]))
            }
            return
        }

        func file(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        let toURL: URL
        let toDate: Date
        if let to {
            toURL = file(to)
            toDate = try DiskSnapshot.load(from: toURL).takenAt
        } else if let last = entries.last {
            toURL = last.url; toDate = last.takenAt
        } else {
            throw ValidationError("No snapshots in \(store.directory.path). Take one with: roomy scan --snapshot")
        }

        let fromURL: URL
        if let from {
            fromURL = file(from)
        } else {
            let older = entries.filter { $0.takenAt < toDate }
            guard let previous = older.last else {
                throw ValidationError("Only one snapshot so far (\(Self.stamp(toDate))). Growth needs two: run `roomy scan --snapshot` again later, or on a timer.")
            }
            if let since {
                guard let span = Output.parseDuration(since), span > 0 else { throw ValidationError("--since takes a duration such as 12h, 7d or 4w.") }
                fromURL = store.closest(to: toDate.addingTimeInterval(-span), before: toDate)?.url ?? previous.url
            } else {
                fromURL = previous.url
            }
        }

        let a = try DiskSnapshot.load(from: fromURL), b = try DiskSnapshot.load(from: toURL)
        guard a.takenAt < b.takenAt else { throw ValidationError("--from must be older than --to.") }
        let report = GrowthReport(from: a, to: b, minDeltaBytes: Int64(max(0, minDeltaMb)) * 1_048_576)
        if json {
            Output.printJSONData(try report.encoded())
        } else {
            printReport(report, requested: since.flatMap(Output.parseDuration))
        }
    }

    // MARK: - Table output

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func span(_ seconds: Double) -> String {
        if seconds < 2 * 3600 { return "\(Int((seconds / 60).rounded())) min" }
        if seconds < 2 * 86_400 { return String(format: "%.1f hours", seconds / 3600) }
        return String(format: "%.1f days", seconds / 86_400)
    }

    /// "+1.2 GB", "-300 MB", "0".
    static func signed(_ bytes: Int64) -> String {
        if bytes == 0 { return "0" }
        return (bytes > 0 ? "+" : "-") + ByteFormatting.format(abs(bytes))
    }

    private func printReport(_ r: GrowthReport, requested: TimeInterval?) {
        let resolver = RoomyPathResolver(home: URL(fileURLWithPath: r.home))
        print("roomy growth · \(r.host) · \(Self.stamp(r.from)) → \(Self.stamp(r.to)) (\(Self.span(r.seconds)))")
        if let requested, abs(r.seconds - requested) > max(3600, requested * 0.25) {
            print("Note: asked for \(Self.span(requested)); the closest snapshot gives \(Self.span(r.seconds)).")
        }
        for w in r.warnings { print("Note: \(w).") }
        if let v = r.volume {
            print("Disk: \(ByteFormatting.format(v.fromAvailableBytes)) free → \(ByteFormatting.format(v.toAvailableBytes)) free (used \(Self.signed(v.usedDeltaBytes)))")
        }
        print("Roomy targets: \(ByteFormatting.format(r.reclaimable.fromBytes)) → \(ByteFormatting.format(r.reclaimable.toBytes)) (\(Self.signed(r.reclaimable.deltaBytes)))")
        if let u = r.untrackedDeltaBytes, abs(u) >= r.minDeltaBytes {
            let hint = r.dirs == nil ? " Snapshots taken with --dirs show where." : ""
            print("Outside Roomy targets: \(Self.signed(u)).\(hint)")
        }

        if !r.categories.isEmpty {
            print("\nBy category")
            print(Output.table(r.categories.map { [Self.signed($0.deltaBytes), ByteFormatting.format($0.toBytes), $0.category] },
                               header: ["CHANGE", "NOW", "CATEGORY"]))
        }

        if r.items.isEmpty {
            print("\nNo finding changed by more than \(ByteFormatting.format(r.minDeltaBytes)).")
        } else {
            let growers = r.items.filter { $0.deltaBytes > 0 }, shrinkers = r.items.filter { $0.deltaBytes < 0 }.reversed()
            func rows(_ items: some Sequence<GrowthReport.ItemChange>) -> [[String]] {
                items.prefix(top).map { i in
                    [Self.signed(i.deltaBytes), i.status == .gone ? "-" : ByteFormatting.format(i.toBytes), i.status.rawValue, i.category,
                     Output.truncateMiddle(resolver.display(i.path), max: 60), i.label]
                }
            }
            let header = ["CHANGE", "NOW", "STATUS", "CATEGORY", "PATH", "LABEL"]
            if !growers.isEmpty {
                print("\nGrew (\(growers.count))")
                print(Output.table(rows(growers), header: header))
                if growers.count > top { print("… \(growers.count - top) more. Use --top N or --json.") }
            }
            if !shrinkers.isEmpty {
                print("\nShrank or gone (\(shrinkers.count))")
                print(Output.table(rows(shrinkers), header: header))
                if shrinkers.count > top { print("… \(shrinkers.count - top) more. Use --top N or --json.") }
            }
        }

        if let dirs = r.dirs {
            let growing = dirs.filter { $0.deltaBytes > 0 && $0.depth > 0 }
            if growing.isEmpty {
                print("\nNo directory grew by more than \(ByteFormatting.format(r.minDeltaBytes)).")
            } else {
                // A parent's growth includes its children's, so children are listed under their parent.
                print("\nDirectories that grew · OUTSIDE is the part that is not a Roomy target")
                var rows: [[String]] = []
                let tops = growing.filter { $0.depth == 1 }
                let orphans = growing.filter { d in d.depth > 1 && !tops.contains { d.path.hasPrefix($0.path + "/") } }
                func row(_ d: GrowthReport.DirChange, indent: String) -> [String] {
                    [Self.signed(d.deltaBytes), ByteFormatting.format(d.toBytes), Self.signed(d.deltaBytes - d.reclaimableDeltaBytes),
                     indent + Output.truncateMiddle(resolver.display(d.path), max: 70)]
                }
                for t in tops.prefix(top) {
                    rows.append(row(t, indent: ""))
                    for c in growing.filter({ $0.depth > 1 && $0.path.hasPrefix(t.path + "/") }).prefix(5) { rows.append(row(c, indent: "  ")) }
                }
                for o in orphans.prefix(top) { rows.append(row(o, indent: "")) }
                print(Output.table(rows, header: ["CHANGE", "NOW", "OUTSIDE", "PATH"]))
                if tops.count > top { print("… \(tops.count - top) more. Use --top N or --json.") }
            }
        }
    }
}
