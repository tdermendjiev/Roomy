//
//  FleetRunner.swift
//  RoomyFleet
//
//  One unattended run: lock → scan → evaluate → dispose → purge → audit → metrics.
//  Every step is recorded; nothing outside the plan is ever touched.
//

import Foundation
import RoomyCore

public struct FleetRunResult: Sendable {
    public let runID: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let report: ScanReport
    public let decision: PolicyDecision
    public let disposal: DisposalOutcome
    public let purged: DisposalOutcome
    public let license: LicenseStatus
    public let metricsText: String
    public let dryRun: Bool
    /// Set when the policy names a hub: the hub's acknowledgement, or nil if the post failed (see `hubError`).
    public var hubAck: HubAck?
    public var hubError: String?

    public var succeeded: Bool { disposal.failures.isEmpty && purged.failures.isEmpty }
    public var disposedBytes: Int64 { disposal.receipts.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

public enum FleetRunError: Error, LocalizedError {
    case locked(String)
    case noRoots

    public var errorDescription: String? {
        switch self {
        case .locked(let why): return "run skipped: \(why)"
        case .noRoots: return "policy resolves to no scan roots and no categories"
        }
    }
}

public struct FleetRunner {
    public let policy: FleetPolicy
    public let roomyVersion: String
    public let actor: String
    /// Seconds between runs when driven by `fleet serve` or a timer; reported to the hub for staleness detection.
    public var intervalSeconds: Int?
    public var log: (String) -> Void

    public init(policy: FleetPolicy, roomyVersion: String = RoomyCoreInfo.version, actor: String = "roomy-fleet",
                intervalSeconds: Int? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.policy = policy
        self.roomyVersion = roomyVersion
        self.actor = actor
        self.intervalSeconds = intervalSeconds ?? policy.hub.intervalSeconds
        self.log = log
    }

    /// Scans and evaluates only. Used by `policy check` and `serve` previews.
    public func plan(dryRunOverride: Bool? = nil) async throws -> (ScanReport, PolicyDecision, LicenseStatus) {
        let license = LicenseVerifier.status(token: policy.resolvedLicenseKey())
        let report = try await scan()
        let decision = PolicyEvaluator.evaluate(report: report, policy: policy)
        return (report, decision, license)
    }

    public func run(dryRunOverride: Bool? = nil, now: Date = Date()) async throws -> FleetRunResult {
        let dryRun = dryRunOverride ?? policy.dryRun
        let lock = RunLock(url: policy.resolvedLockPath)
        do { try lock.acquire() } catch { throw FleetRunError.locked(error.localizedDescription) }
        defer { lock.release() }

        let runID = UUID().uuidString.lowercased()
        let started = now
        let license = LicenseVerifier.status(token: policy.resolvedLicenseKey())
        let audit = try AuditLog(url: policy.resolvedAuditPath)
        let edition = license.edition.rawValue

        func record(_ event: AuditRecord.Event, _ fill: (inout AuditRecord) -> Void = { _ in }) {
            _ = try? audit.append { seq, prev in
                var r = AuditRecord(seq: seq, runID: runID, event: event, actor: actor, edition: edition, policy: policy.name,
                                    dryRun: dryRun ? true : nil, prevHash: prev)
                fill(&r)
                return r
            }
        }

        record(.runStarted) { $0.message = dryRun ? "dry run" : nil }
        record(.licenseChecked) { $0.message = license.summary }
        log("run \(runID.prefix(8)) started · license: \(license.summary)\(dryRun ? " · DRY RUN" : "")")

        let report: ScanReport
        do {
            report = try await scan()
        } catch {
            record(.error) { $0.message = "scan failed: \(error.localizedDescription)" }
            throw error
        }
        record(.scanCompleted) { $0.bytes = report.totalBytes; $0.message = "\(report.items.count) findings in \(String(format: "%.1f", report.durationSeconds))s" }
        log("scan: \(report.items.count) findings, \(ByteFormatting.format(report.totalBytes)) reclaimable")

        let decision = PolicyEvaluator.evaluate(report: report, policy: policy, now: now)
        record(.planned) { $0.bytes = decision.selectedBytes; $0.message = "\(decision.selected.count) selected, \(decision.skipped.count) skipped" }
        for s in decision.skipped where s.item.tier != .warning || s.reason != .tierNeverRemoved {
            // Warning-tier skips are the expected default; log the others so operators can tune the policy.
            record(.skipped) { r in
                r.path = s.item.path; r.bytes = s.item.bytes; r.tier = s.item.tier; r.category = s.item.category
                r.ruleID = s.item.ruleID; r.reason = s.reason.rawValue
            }
        }
        log("policy: \(decision.selected.count) items / \(ByteFormatting.format(decision.selectedBytes)) selected")

        var disposal = DisposalOutcome()
        if !decision.plan.items.isEmpty {
            disposal = await RoomyDeletionService.dispose(
                paths: decision.plan.items.map(\.path),
                method: policy.disposal.method,
                quarantine: policy.resolvedQuarantine,
                dryRun: dryRun
            )
            let byPath = Dictionary(uniqueKeysWithValues: decision.plan.items.map { ($0.path, $0) })
            for receipt in disposal.receipts {
                let item = byPath[receipt.path] ?? byPath.values.first { ($0.path as NSString).expandingTildeInPath == receipt.path }
                record(.disposed) { r in
                    r.path = receipt.path; r.bytes = receipt.bytes ?? item?.bytes; r.tier = item?.tier; r.category = item?.category
                    r.ruleID = item?.ruleID; r.method = receipt.method; r.destination = receipt.destination
                    r.message = dryRun ? "dry run" : nil
                }
            }
            for failure in disposal.failures {
                let item = byPath[failure.path]
                record(.disposeFailed) { r in
                    r.path = failure.path; r.bytes = item?.bytes; r.tier = item?.tier; r.category = item?.category; r.message = failure.message
                }
            }
            log("disposed: \(disposal.receipts.count) ok, \(disposal.failures.count) failed")
        }

        var purged = DisposalOutcome()
        if policy.disposal.purgeOnRun && !dryRun {
            let q = QuarantineDisposer(config: policy.resolvedQuarantine)
            purged = q.purge(now: now)
            #if os(Linux)
            if policy.disposal.method == .trash,
               let loc = try? FreedesktopTrash.location(for: policy.resolvedHome, home: policy.resolvedHome) {
                let t = FreedesktopTrash.purge(location: loc, olderThanDays: policy.disposal.retentionDays, now: now)
                purged.receipts += t.receipts
                purged.failures += t.failures
            }
            #endif
            for r in purged.receipts { record(.purged) { $0.path = r.path; $0.bytes = r.bytes; $0.destination = r.destination } }
            for f in purged.failures { record(.error) { $0.path = f.path; $0.message = "purge failed: \(f.message)" } }
            if !purged.receipts.isEmpty { log("purged \(purged.receipts.count) expired quarantine items") }
        }

        let duration = Date().timeIntervalSince(started)
        record(.runFinished) { $0.message = String(format: "%.1fs", duration); $0.bytes = disposal.receipts.reduce(0) { $0 + ($1.bytes ?? 0) } }

        let totals = AuditLog.totals(from: policy.resolvedAuditPath)
        let q = QuarantineDisposer(config: policy.resolvedQuarantine)
        let snapshot = FleetMetricsSnapshot(
            host: report.host, edition: edition, org: license.payload?.org, version: roomyVersion, catalogVersion: report.catalogVersion,
            policyName: policy.name, reclaimableBytesByTier: report.bytesByTier, reclaimableBytesByCategory: report.bytesByCategory,
            reclaimableItems: report.items.count, plannedBytes: decision.selectedBytes, plannedItems: decision.selected.count,
            disposedBytesThisRun: disposal.receipts.reduce(0) { $0 + ($1.bytes ?? 0) }, disposedItemsThisRun: disposal.receipts.count,
            failuresThisRun: disposal.failures.count, disposedBytesTotal: totals.disposedBytes, disposedItemsTotal: totals.disposedItems,
            failuresTotal: totals.failures, purgedBytesTotal: totals.purgedBytes, runsTotal: totals.runs,
            lastRunStart: started, lastRunDurationSeconds: duration, lastRunSucceeded: disposal.failures.isEmpty, dryRun: dryRun,
            quarantineBytes: q.totalBytes, quarantineItems: q.entries().count,
            volumeTotalBytes: report.volume?.totalBytes, volumeAvailableBytes: report.volume?.availableBytes,
            licenseExpiresAt: license.payload?.expiresAt
        )
        let metricsText = PrometheusRenderer.render(snapshot)
        if let textfile = policy.resolvedMetricsTextfile {
            do { try PrometheusRenderer.write(metricsText, to: textfile) } catch {
                record(.error) { $0.message = "metrics textfile: \(error.localizedDescription)" }
                log("warning: could not write metrics textfile \(textfile.path): \(error.localizedDescription)")
            }
        }

        var result = FleetRunResult(runID: runID, startedAt: started, duration: duration, report: report, decision: decision,
                                    disposal: disposal, purged: purged, license: license, metricsText: metricsText, dryRun: dryRun)

        if let hubURL = policy.resolvedHubURL {
            let hubReport = HubHostReport(result: result, policy: policy, roomyVersion: roomyVersion, intervalSeconds: intervalSeconds, topItems: policy.hub.topItems)
            let client = HubClient(baseURL: hubURL, token: policy.resolvedHubToken())
            do {
                let ack = try await client.postReport(hubReport)
                result.hubAck = ack
                record(.hubReported) { $0.message = "\(hubURL.absoluteString) · \(ack.hostsKnown)/\(ack.hostLimit) hosts" }
                log("hub: reported to \(hubURL.host ?? hubURL.absoluteString) (\(ack.hostsKnown) hosts known)")
            } catch {
                result.hubError = error.localizedDescription
                record(.error) { $0.message = "hub: \(error.localizedDescription)" }
                log("warning: hub report failed: \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: Scan

    public func scan() async throws -> ScanReport {
        let started = Date()
        let home = policy.resolvedHome
        let catalog = try policy.resolvedCatalog()
        let ecosystems = policy.scan.ecosystems.map(Set.init) ?? RoomySettingsEcosystems.allKeys
        let categories = policy.scan.categories.map(Set.init) ?? Set(RoomySystemScanCategories.available.map(\.key))
        let exclusions = RoomyScanExclusionFilter(rawExclusions: policy.scan.exclude, homeDirectory: home)
        let roots = policy.resolvedRoots()
        if roots.isEmpty && categories.isEmpty { throw FleetRunError.noRoots }

        var projectAggregate = ScanAggregate.empty
        for root in roots {
            let agg = await FilesystemArtifactScanner.scan(root: root, homeDirectory: home, enabledEcosystemTags: ecosystems,
                                                           exclusionFilter: exclusions, catalog: catalog, shouldCancel: { false }, onProgress: { _ in })
            projectAggregate = ScanAggregate.merge(projectAggregate, agg)
        }
        let systemAggregate = await SystemArtifactScanner.scan(
            homeDirectory: home, enabledCategories: categories, enabledEcosystemTags: ecosystems, exclusionFilter: exclusions,
            projectAggregate: projectAggregate, catalog: catalog, shouldCancel: { false }, onProgress: { _ in }
        )
        let merged = ScanAggregate.merge(projectAggregate, systemAggregate)
        return ScanReport(aggregate: merged, scanRoot: roots.first ?? home, home: home,
                          durationSeconds: Date().timeIntervalSince(started), partial: false,
                          roomyVersion: roomyVersion, catalogVersion: catalog.catalogVersion,
                          dormantMonths: policy.dormantMonths, inactiveMonths: policy.inactiveMonths)
    }
}
