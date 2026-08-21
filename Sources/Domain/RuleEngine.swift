import Foundation

/// Deterministic state resolution. No LLM is involved. (spec §2.1, §23)
///
/// The same input must always produce the same output. Inference here would be a design failure.
/// `now` is injected rather than read, so "same input, same output" is literally true.
enum RuleEngine {
    /// Only values Apple actually sends are accepted; anything else resolves to UNKNOWN. (spec §29)
    private static let knownProcessingStates: Set<String> =
        ["PROCESSING", "FAILED", "INVALID", "VALID"]
    private static let knownInternalStates: Set<String> =
        ["PROCESSING", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE",
         "READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "EXPIRED",
         "IN_EXPORT_COMPLIANCE_REVIEW"]
    private static let knownExternalStates: Set<String> =
        ["PROCESSING", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE",
         "READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "EXPIRED",
         "READY_FOR_BETA_SUBMISSION", "IN_EXPORT_COMPLIANCE_REVIEW",
         "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_REJECTED",
         "BETA_APPROVED"]

    static func resolve(groups: [GroupSnapshot], builds: [BuildSnapshot],
                        now: Date = Date()) -> AppStatus
    {
        let testable = currentlyTestable(groups: groups, builds: builds)
        return AppStatus(
            state: latestUploadState(groups: groups, builds: builds, now: now),
            testable: testable,
            audience: testable?.installableAudience(among: groups))
    }

    /// The build a tester can install right now, which may not be the newest one.
    ///
    /// Processing succeeding is not the same as being installable. Apple has to have finished
    /// beta processing *and* the build has to reach someone through a channel that is actually
    /// open — an external group behind an unfinished review reaches nobody today.
    static func currentlyTestable(groups: [GroupSnapshot], builds: [BuildSnapshot])
        -> BuildSnapshot?
    {
        builds.first { build in
            build.processingSucceeded && build.installableAudience(among: groups) != nil
        }
    }

    // MARK: - Latest upload

    private static func latestUploadState(groups: [GroupSnapshot], builds: [BuildSnapshot],
                                          now: Date) -> AppStateDefinition
    {
        guard let latest = builds.first else { return .make(.noBuild) }

        var evidence: [String: String] = [
            "buildID": latest.id,
            "build": latest.number,
            "processingState": latest.processingState,
        ]
        if let s = latest.platform { evidence["platform"] = s }
        if let s = latest.internalState { evidence["internalBuildState"] = s }
        if let s = latest.externalState { evidence["externalBuildState"] = s }
        if let d = latest.uploadedAt {
            evidence["uploadedDate"] = ISO8601DateFormatter().string(from: d)
        }
        evidence["assignedGroups"] = latest.assignedGroupIDs.map { String($0.count) } ?? "unread"
        evidence["individualTesters"] = latest.individualTesterCount.map(String.init) ?? "unread"
        evidence["betaStateIsKnown"] = String(latest.betaStateIsKnown)

        // A single unrecognized value is enough to stop guessing.
        guard knownProcessingStates.contains(latest.processingState) else {
            return .make(.unknown, evidence: evidence)
        }
        if let s = latest.internalState, !knownInternalStates.contains(s) {
            return .make(.unknown, evidence: evidence)
        }
        if let s = latest.externalState, !knownExternalStates.contains(s) {
            return .make(.unknown, evidence: evidence)
        }

        switch latest.processingState {
        case "PROCESSING":
            return .make(.buildProcessing, evidence: evidence,
                         detail: processingDetail(since: latest.uploadedAt, now: now))
        case "FAILED", "INVALID":
            return .make(.buildInvalid, evidence: evidence, reason: "REJECTED_BY_APPLE",
                         detail: String(localized: "Apple rejected build \(latest.number). You'll need to upload a new one."))
        case "VALID":
            break
        default:
            return .make(.unknown, evidence: evidence)
        }

        // Processing finished, but the beta state is what decides everything below. If the fetch
        // that carries it failed, say so instead of falling through to a confident verdict.
        guard latest.betaStateIsKnown else {
            return .make(.unknown, evidence: evidence, reason: "BETA_STATE_UNREAD")
        }

        // Unanswered export compliance blocks distribution even after processing. Common, and invisible.
        if latest.internalState == "MISSING_EXPORT_COMPLIANCE"
            || latest.externalState == "MISSING_EXPORT_COMPLIANCE"
        {
            return .make(.actionRequired, evidence: evidence, reason: "MISSING_EXPORT_COMPLIANCE",
                         detail: String(localized: "Distribution waits on the export compliance question. Answer it once in App Store Connect."))
        }

        if latest.isExpired || latest.internalState == "EXPIRED" {
            return .make(.actionRequired, evidence: evidence, reason: "EXPIRED",
                         detail: String(localized: "This build expired. TestFlight builds stop installing 90 days after upload."))
        }

        if latest.externalState == "BETA_REJECTED" {
            return .make(.actionRequired, evidence: evidence, reason: "BETA_REJECTED",
                         detail: String(localized: "Apple turned down external testing. The reason is in App Store Connect."))
        }

        if latest.internalState == "PROCESSING_EXCEPTION"
            || latest.externalState == "PROCESSING_EXCEPTION"
        {
            return .make(.actionRequired, evidence: evidence, reason: "PROCESSING_EXCEPTION",
                         detail: String(localized: "Apple hit a problem processing this build. The details are in App Store Connect."))
        }

        // Apple is still working, even though the upload itself is done.
        if latest.internalState == "PROCESSING"
            || latest.internalState == "IN_EXPORT_COMPLIANCE_REVIEW"
        {
            return .make(.buildProcessing, evidence: evidence,
                         detail: processingDetail(since: latest.uploadedAt, now: now))
        }

        // This is where things fail silently: the build is fine and reaches nobody.
        //
        // What matters is not whether the app has groups but whether **a group attached to this
        // build** can reach someone. An unreadable attachment is unknown, never "not attached".
        switch latest.hasAssignedAudience(among: groups) {
        case .unknown:
            return .make(.unknown, evidence: evidence, reason: "AUDIENCE_UNREAD")
        case .unreachable:
            return .make(.buildReadyNotDistributed, evidence: evidence,
                         reason: strandedReason(latest, among: groups),
                         detail: strandedDetail(latest, among: groups))
        case .reachable:
            break
        }

        // An audience is configured. What Apple has opened decides the rest.
        if latest.isLiveExternally { return .make(.externalTestingReady, evidence: evidence) }

        switch latest.externalState {
        case "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW":
            return .make(.externalReviewPending, evidence: evidence)
        case "READY_FOR_BETA_SUBMISSION":
            return latest.isLiveInternally
                ? .make(.externalReviewRequired, evidence: evidence)
                : .make(.buildReadyNotDistributed, evidence: evidence,
                        reason: "NOT_YET_LIVE",
                        detail: String(localized: "Apple has not released this build to testers yet."))
        default:
            return latest.isLiveInternally
                ? .make(.internalTestingReady, evidence: evidence)
                : .make(.buildReadyNotDistributed, evidence: evidence,
                        reason: "NOT_YET_LIVE",
                        detail: String(localized: "Apple has not released this build to testers yet."))
        }
    }

    private static func strandedReason(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        if groups.isEmpty { return "NO_GROUPS" }
        if build.assignedGroupIDs?.isEmpty ?? true { return "BUILD_NOT_ASSIGNED" }
        return "GROUPS_EMPTY"
    }

    private static func strandedDetail(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        if groups.isEmpty {
            return String(localized: "There is no tester group.")
        }
        if build.assignedGroupIDs?.isEmpty ?? true {
            return String(localized: "This build is attached to no group.")
        }
        return String(localized: "The attached groups have no testers and no public link.")
    }

    /// Say so when processing runs long, so nobody has to ask "is it still going?". (spec UC-02)
    private static func processingDetail(since: Date?, now: Date) -> String? {
        guard let since else { return nil }
        let minutes = Int(now.timeIntervalSince(since) / 60)
        guard minutes >= 1 else { return nil }
        let elapsed = minutes < 60
            ? String(localized: "uploaded \(minutes) minutes ago")
            : String(localized: "uploaded \(minutes / 60) hours ago")
        if minutes >= 30 {
            return String(localized: "\(elapsed). Taking longer than usual, but there is nothing to do.")
        }
        return String(localized: "\(elapsed). You'll get a notification when it finishes.")
    }
}
