import Foundation

/// Deterministic state resolution. No LLM is involved. (spec §2.1, §23)
///
/// The same input must always produce the same output. Inference here would be a design failure.
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

    static func resolve(groups: [GroupSnapshot], builds: [BuildSnapshot]) -> AppStatus {
        let testable = currentlyTestable(groups: groups, builds: builds)
        let state = latestUploadState(groups: groups, builds: builds)
        return AppStatus(state: state,
                         testable: testable,
                         audience: testable.map { audience(for: $0, among: groups) })
    }

    /// The build installable right now, which may not be the newest one.
    ///
    /// Resolved separately from the latest-upload state so that "the previous build still works"
    /// does not get lost while the newest build is processing.
    static func currentlyTestable(groups: [GroupSnapshot], builds: [BuildSnapshot])
        -> BuildSnapshot?
    {
        builds.first { $0.isValid && $0.isReachable(among: groups) }
    }

    static func audience(for build: BuildSnapshot, among groups: [GroupSnapshot]) -> Audience {
        let reachable = build.reachableAudience(among: groups)
        return Audience(
            internalTesters: reachable.filter(\.isInternal).reduce(0) { $0 + $1.testerCount },
            externalTesters: reachable.filter { !$0.isInternal }.reduce(0) { $0 + $1.testerCount },
            individualTesters: build.individualTesterCount,
            hasPublicLink: reachable.contains { $0.publicLinkEnabled })
    }

    // MARK: - Latest upload

    private static func latestUploadState(groups: [GroupSnapshot], builds: [BuildSnapshot])
        -> AppStateDefinition
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
        evidence["assignedGroups"] = String(latest.assignedGroupIDs.count)
        evidence["individualTesters"] = String(latest.individualTesterCount)

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
                         detail: processingDetail(since: latest.uploadedAt))
        case "FAILED", "INVALID":
            return .make(.buildInvalid, evidence: evidence, reason: "REJECTED_BY_APPLE",
                         detail: String(localized: "Apple rejected build \(latest.number). You'll need to upload a new one."))
        case "VALID":
            break
        default:
            return .make(.unknown, evidence: evidence)
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

        // This is where things fail silently: the build is fine and reaches nobody.
        //
        // What matters is not whether the app has groups but whether **a group attached to this
        // build** can reach someone. Individual testers count even with no groups at all.
        if !latest.isReachable(among: groups) {
            return .make(.buildReadyNotDistributed, evidence: evidence,
                         reason: strandedReason(latest, among: groups),
                         detail: strandedDetail(latest, among: groups))
        }

        // Someone can receive it. External review progress decides the rest.
        switch latest.externalState {
        case "IN_BETA_TESTING", "BETA_APPROVED":
            return .make(.externalTestingReady, evidence: evidence)
        case "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW":
            return .make(.externalReviewPending, evidence: evidence)
        case "READY_FOR_BETA_SUBMISSION":
            return .make(.externalReviewRequired, evidence: evidence)
        default:
            return .make(.internalTestingReady, evidence: evidence)
        }
    }

    private static func strandedReason(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        if groups.isEmpty { return "NO_GROUPS" }
        if build.assignedGroupIDs.isEmpty { return "BUILD_NOT_ASSIGNED" }
        return "GROUPS_EMPTY"
    }

    private static func strandedDetail(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        if groups.isEmpty {
            return String(localized: "There is no tester group.")
        }
        if build.assignedGroupIDs.isEmpty {
            return String(localized: "This build is attached to no group.")
        }
        return String(localized: "The attached groups have no testers and no public link.")
    }

    /// Say so when processing runs long, so nobody has to ask "is it still going?". (spec UC-02)
    private static func processingDetail(since: Date?) -> String? {
        guard let since else { return nil }
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        guard minutes >= 1 else { return nil }
        let elapsed = minutes < 60 ? String(localized: "uploaded %lld minutes ago") : String(localized: "uploaded %lld hours ago")
        if minutes >= 30 {
            return String(localized: "\(elapsed). Taking longer than usual, but there is nothing to do.")
        }
        return String(localized: "\(elapsed). You'll get a notification when it finishes.")
    }
}
