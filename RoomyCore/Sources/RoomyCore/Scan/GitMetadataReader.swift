//
//  GitMetadataReader.swift
//  RoomyCore
//
//  Real git + disk metadata for a project folder.
//

import Foundation

public enum RoomyGitMetadataReader {
    private static let gitTimeout: TimeInterval = 8
    private static let duTimeout: TimeInterval = 20

    private static let gitPath: String? = {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ProcessRunner.which("git")
    }()

    public static var isGitAvailable: Bool { gitPath != nil }

    /// Reads `.git`, last commit, status, and folder size for a project directory.
    public static func metadata(forProjectPath displayPath: String, recoverableArtifactBytes: Int64) async -> ProjectGitMetadata {
        await Task.detached(priority: .utility) {
            metadataSync(forProjectPath: displayPath, recoverableArtifactBytes: recoverableArtifactBytes)
        }.value
    }

    public static func metadataSync(forProjectPath displayPath: String, recoverableArtifactBytes: Int64) -> ProjectGitMetadata {
        let expanded = (displayPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let folderURL = URL(fileURLWithPath: expanded, isDirectory: true)
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return nonRepoMetadata(recoverableArtifactBytes: recoverableArtifactBytes, folderURL: folderURL)
        }

        let gitMarker = folderURL.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitMarker), gitPath != nil else {
            return nonRepoMetadata(recoverableArtifactBytes: recoverableArtifactBytes, folderURL: folderURL)
        }

        let duTotal = RoomyDirectorySizeReader.bytes(at: folderURL, timeout: duTimeout) ?? max(recoverableArtifactBytes, 0)
        let totalProject = max(duTotal, recoverableArtifactBytes)
        let status = porcelainStatus(in: folderURL)

        guard let commit = lastCommit(in: folderURL) else {
            return ProjectGitMetadata(
                isGitRepo: true, lastCommitDate: nil, commitSubject: "",
                isClean: status.isClean, gitStatusLine: status.summaryLine,
                totalProjectSizeBytes: totalProject, lastModified: nil
            )
        }
        return ProjectGitMetadata(
            isGitRepo: true, lastCommitDate: commit.date, commitSubject: commit.subject,
            isClean: status.isClean, gitStatusLine: status.summaryLine,
            totalProjectSizeBytes: totalProject, lastModified: nil
        )
    }

    /// Last commit date only, cheap enough to call per project during a CLI scan.
    public static func lastCommitDate(in workTree: URL) -> Date? {
        guard FileManager.default.fileExists(atPath: workTree.appendingPathComponent(".git").path) else { return nil }
        return lastCommit(in: workTree)?.date
    }

    private static func nonRepoMetadata(recoverableArtifactBytes: Int64, folderURL: URL) -> ProjectGitMetadata {
        let duTotal = RoomyDirectorySizeReader.bytes(at: folderURL, timeout: duTimeout) ?? max(recoverableArtifactBytes, 0)
        let mtime = RoomyDirectorySizeReader.modificationDate(at: folderURL)
        return ProjectGitMetadata(
            isGitRepo: false, lastCommitDate: nil, commitSubject: "", isClean: false, gitStatusLine: "",
            totalProjectSizeBytes: max(duTotal, recoverableArtifactBytes), lastModified: mtime
        )
    }

    private struct ParsedCommit { var date: Date; var subject: String }

    private static func lastCommit(in workTree: URL) -> ParsedCommit? {
        guard let out = runGit(["log", "-1", "--pretty=format:%ct\u{1C}%s"], cwd: workTree), !out.isEmpty else { return nil }
        let parts = out.split(separator: "\u{1C}", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tsPart = parts.first, let ts = TimeInterval(String(tsPart)) else { return nil }
        let subject = parts.count > 1 ? String(parts[1]) : ""
        return ParsedCommit(date: Date(timeIntervalSince1970: ts), subject: subject)
    }

    private struct PorcelainStatus { var isClean: Bool; var summaryLine: String }

    private static func porcelainStatus(in workTree: URL) -> PorcelainStatus {
        guard let raw = runGit(["status", "--porcelain=v1"], cwd: workTree) else {
            return PorcelainStatus(isClean: true, summaryLine: "Unable to read git status")
        }
        let lines = raw.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        if lines.isEmpty { return PorcelainStatus(isClean: true, summaryLine: "Clean (no uncommitted changes)") }
        let n = lines.count
        return PorcelainStatus(isClean: false, summaryLine: n == 1 ? "1 uncommitted change" : "\(n) uncommitted changes")
    }

    private static func runGit(_ arguments: [String], cwd: URL) -> String? {
        guard let git = gitPath else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "1"
        return ProcessRunner.output(executable: git, arguments: arguments, currentDirectory: cwd, environment: env, timeout: gitTimeout)
    }
}
