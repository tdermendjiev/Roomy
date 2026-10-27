//
//  DirectorySizeReader.swift
//  RoomyCore
//
//  Directory sizes via `du -sk` (fast, follows the platform's block accounting) with a
//  pure-Foundation fallback when `du` is unavailable.
//

import Foundation

public enum RoomyDirectorySizeReader {
    public static let defaultTimeout: TimeInterval = 20
    /// Findings smaller than this are dropped by system probes.
    public static let minimumBytes: Int64 = 1_048_576 // 1 MB

    private static let duPath: String? = {
        ["/usr/bin/du", "/bin/du"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Returns size in bytes, or nil on failure.
    public static func bytes(at url: URL, timeout: TimeInterval = defaultTimeout) -> Int64? {
        if let du = duPath,
           let out = ProcessRunner.output(executable: du, arguments: ["-sk", url.path], timeout: timeout),
           let first = out.split(whereSeparator: \.isWhitespace).first,
           let kb = Int64(first) {
            return kb * 1024
        }
        return enumeratedBytes(at: url)
    }

    /// Apparent size of a single file.
    public static func fileBytes(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    /// Foundation-only size (sum of regular file sizes). Used when `du` is missing.
    public static func enumeratedBytes(at root: URL) -> Int64? {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsPackageDescendants]) else { return nil }
        while let fileURL = enumerator.nextObject() as? URL {
            if let v = try? fileURL.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    /// Sizes multiple paths concurrently (max 8 at a time). Drops results under `minimumBytes`.
    public static func bytesConcurrently(
        urls: [URL],
        maxConcurrent: Int = 8,
        timeout: TimeInterval = defaultTimeout,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async -> [URL: Int64] {
        await withTaskGroup(of: (URL, Int64?).self) { group in
            var results: [URL: Int64] = [:]
            var index = 0
            var inFlight = 0

            func enqueueNext() {
                while inFlight < maxConcurrent, index < urls.count {
                    if shouldCancel() { return }
                    let url = urls[index]
                    index += 1
                    inFlight += 1
                    group.addTask {
                        let size = await Task.detached { bytes(at: url, timeout: timeout) }.value
                        return (url, size)
                    }
                }
            }

            enqueueNext()
            for await (url, size) in group {
                inFlight -= 1
                if let size, size >= minimumBytes { results[url] = size }
                if shouldCancel() { break }
                enqueueNext()
            }
            return results
        }
    }

    public static func modificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Newest modification date among the item itself and its direct children.
    /// Non-recursive on purpose: session folders can hold thousands of files.
    public static func newestModificationDate(in dir: URL) -> Date? {
        var newest = modificationDate(at: dir)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return newest }
        for child in children {
            if let d = modificationDate(at: child), newest == nil || d > newest! { newest = d }
        }
        return newest
    }
}
