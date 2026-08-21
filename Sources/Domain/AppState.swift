import Foundation

/// Internal domain state — the layer that keeps Apple's API objects from reaching the UI. (spec §16)
///
/// The wording defined here is the product. Apple hands you `processingState`,
/// `internalBuildState` and `externalBuildState` separately and never says what the combination means.
enum AppStateID: String, Codable, Sendable, CaseIterable {
    case noBuild = "NO_BUILD"
    case buildProcessing = "BUILD_PROCESSING"
    case buildInvalid = "BUILD_INVALID"
    case buildReadyNotDistributed = "BUILD_READY_NOT_DISTRIBUTED"
    /// Attached to an audience that can be reached, but Apple has not opened it yet.
    case awaitingRelease = "AWAITING_RELEASE"
    case internalTestingReady = "INTERNAL_TESTING_READY"
    case externalReviewRequired = "EXTERNAL_REVIEW_REQUIRED"
    case externalReviewPending = "EXTERNAL_REVIEW_PENDING"
    case externalTestingReady = "EXTERNAL_TESTING_READY"
    case actionRequired = "ACTION_REQUIRED"
    case unknown = "UNKNOWN"
}

/// Why a state is what it is, when the state ID alone doesn't say.
///
/// This was a free-form string, and that made one policy question unanswerable: `UNKNOWN`
/// covers both "Apple sent a value this version has never seen" and "a fetch came back
/// empty", which are opposite kinds of event wearing the same badge. The first is news about
/// the app. The second is a blind spot of our own, and announcing it turns every network
/// blip into "needs attention". A closed set puts that distinction in the type instead of in
/// whoever remembers to check the spelling of a string.
enum StateReason: String, Codable, Sendable, CaseIterable {
    // Apple reached a verdict about the build.
    case rejectedByApple = "REJECTED_BY_APPLE"
    case missingExportCompliance = "MISSING_EXPORT_COMPLIANCE"
    case expired = "EXPIRED"
    case betaRejected = "BETA_REJECTED"
    case processingException = "PROCESSING_EXCEPTION"

    // The build is fine and reaches nobody. These say which way.
    case noGroups = "NO_GROUPS"
    case buildNotAssigned = "BUILD_NOT_ASSIGNED"
    case groupsEmpty = "GROUPS_EMPTY"
    case notYetLive = "NOT_YET_LIVE"

    // Apple sent a value this version does not recognize. Worth telling someone about.
    case unrecognizedProcessingState = "UNRECOGNIZED_PROCESSING_STATE"
    case unrecognizedInternalState = "UNRECOGNIZED_INTERNAL_STATE"
    case unrecognizedExternalState = "UNRECOGNIZED_EXTERNAL_STATE"

    // A fetch failed or was truncated. Says nothing about the app.
    case betaStateUnread = "BETA_STATE_UNREAD"
    case audienceUnread = "AUDIENCE_UNREAD"

    /// Does this reason describe a failed observation rather than a fact about the app?
    ///
    /// Everything downstream keys on this: no banner, and no entry in the timeline either.
    /// READY → UNKNOWN → READY round trips describe the network, not the app.
    var isObservationFailure: Bool {
        switch self {
        case .betaStateUnread, .audienceUnread: return true
        default: return false
        }
    }
}

enum Severity: Int, Codable, Comparable, Sendable {
    case warning = 0, info = 1, success = 2, idle = 3

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "clock.fill"
        case .success: return "checkmark.circle.fill"
        case .idle:    return "circle.dashed"
        }
    }

    /// Compact glyph for the menu bar. (spec §14)
    var glyph: String {
        switch self {
        case .warning: return "⚠"
        case .info:    return "◷"
        case .success: return "●"
        case .idle:    return "○"
        }
    }
}

/// When to notify. (spec §16, §12)
enum NotificationPolicy: String, Codable, Sendable {
    /// Notify on leaving this state (processing → ready, for example).
    case notifyWhenLeaving
    /// Notify on entering this state (a build stranded with no audience, for example).
    case notifyWhenEntering
    /// Never notify.
    case silent
}

/// What the user can actually press. v0 has exactly two. (spec §26)
///
/// Upload automation, tester CRUD and public-link settings are out of v0 per §27.
enum NextAction: String, Codable, Sendable, Identifiable {
    case assignBuildToGroup = "ASSIGN_BUILD_TO_GROUP"
    case openInAppStoreConnect = "OPEN_IN_APP_STORE_CONNECT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assignBuildToGroup:    return String(localized: "Distribute to testers")
        case .openInAppStoreConnect: return String(localized: "Open in App Store Connect")
        }
    }

    var symbol: String {
        switch self {
        case .assignBuildToGroup:    return "person.2.badge.plus"
        case .openInAppStoreConnect: return "arrow.up.forward.app"
        }
    }
}

/// The complete definition of one state. (structure from spec §16)
struct AppStateDefinition: Sendable, Equatable {
    var id: AppStateID
    /// Distinguishes different causes inside one state.
    ///
    /// `ACTION_REQUIRED` alone covers missing export compliance, expiry and beta rejection.
    /// Without this a change of cause looks like no transition at all, and nothing notifies.
    var reason: StateReason?
    var severity: Severity
    var headline: String
    var description: String
    /// What is blocking progress, or nil.
    var blocker: String?
    /// The single most appropriate action right now — never a menu of them. (spec §11)
    var nextAction: NextAction?
    var notificationPolicy: NotificationPolicy
    /// The raw Apple values the decision rests on. (spec §15, §29)
    var rawEvidence: [String: String]

    /// Apple's own term, shown beside the headline.
    ///
    /// Spec §9 forbids showing the raw term **alone**, not showing it at all.
    /// Next to the plain sentence it stays usable for searching Apple's docs or asking elsewhere.
    var appleTerm: String? {
        let inner = rawEvidence["internalBuildState"]
        let outer = rawEvidence["externalBuildState"]
        switch (inner, outer) {
        case let (i?, o?): return i == o ? i : "\(i) / \(o)"
        case let (i?, nil): return i
        case let (nil, o?): return o
        default: return rawEvidence["processingState"]
        }
    }

    /// Fingerprint for transition detection. The state ID alone misses a change of cause.
    var fingerprint: String {
        [id.rawValue, reason?.rawValue ?? "-", rawEvidence["buildID"] ?? "-"]
            .joined(separator: "|")
    }

    static func == (a: AppStateDefinition, b: AppStateDefinition) -> Bool {
        a.fingerprint == b.fingerprint
    }
}

// MARK: - State dictionary

extension AppStateDefinition {
    /// Builds a state definition from evidence. Every user-facing string lives here and nowhere else.
    static func make(_ id: AppStateID, evidence: [String: String] = [:],
                     reason: StateReason? = nil, detail: String? = nil) -> AppStateDefinition
    {
        var made = build(id, evidence: evidence, detail: detail)
        made.reason = reason
        // A state that only means "the fetch failed" is not something to wake anyone for.
        // The policy belongs to the reason, not to the state that happens to carry it.
        if reason?.isObservationFailure == true { made.notificationPolicy = .silent }
        return made
    }

    private static func build(_ id: AppStateID, evidence: [String: String],
                              detail: String?) -> AppStateDefinition
    {
        switch id {
        case .noBuild:
            return .init(id: id, reason: nil, severity: .idle,
                         headline: String(localized: "No build uploaded"),
                         description: String(localized: "There is an App Store Connect record but no build has ever been sent."),
                         blocker: nil, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .buildProcessing:
            return .init(id: id, reason: nil, severity: .info,
                         headline: String(localized: "Apple is processing"),
                         description: detail
                            ?? String(localized: "The upload finished. Once processing completes you can test it. Nothing to do right now."),
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .notifyWhenLeaving, rawEvidence: evidence)

        case .buildInvalid:
            return .init(id: id, reason: nil, severity: .warning,
                         headline: String(localized: "Build rejected"),
                         description: detail ?? String(localized: "Apple rejected this build. You'll need to upload a new one."),
                         blocker: String(localized: "Apple rejected this build."),
                         nextAction: .openInAppStoreConnect,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)

        case .buildReadyNotDistributed:
            return .init(id: id, reason: nil, severity: .warning,
                         headline: String(localized: "Reaches nobody"),
                         description: String(localized: "The build is fine but no tester is connected to it. In this state it appears on no device."),
                         blocker: detail ?? String(localized: "No test audience is connected."),
                         nextAction: .assignBuildToGroup,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)

        case .awaitingRelease:
            // Reached only once an audience is confirmed reachable, so "Reaches nobody" —
            // with a button offering to attach the build again — was both wrong and an
            // invitation to send a redundant write.
            return .init(id: id, reason: nil, severity: .info,
                         headline: String(localized: "Waiting on Apple to open it"),
                         description: detail
                            ?? String(localized: "Testers are attached and Apple has not released the build to them yet. Nothing to do right now."),
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .notifyWhenLeaving, rawEvidence: evidence)

        case .internalTestingReady:
            return .init(id: id, reason: nil, severity: .success,
                         headline: String(localized: "Ready to test"),
                         description: String(localized: "You can install it from TestFlight on your iPhone right now."),
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .externalReviewRequired:
            return .init(id: id, reason: nil, severity: .info,
                         headline: String(localized: "Internal testing only"),
                         description: String(localized: "You can install it yourself. Sending it to external testers takes one Apple review."),
                         blocker: nil, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .externalReviewPending:
            return .init(id: id, reason: nil, severity: .info,
                         headline: String(localized: "In external beta review"),
                         description: String(localized: "External testers get it once review finishes, usually within a day. Nothing to do right now."),
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .notifyWhenLeaving, rawEvidence: evidence)

        case .externalTestingReady:
            return .init(id: id, reason: nil, severity: .success,
                         headline: String(localized: "Internal and external testing"),
                         description: String(localized: "Internal testers and the external testers you invited can all install it."),
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .actionRequired:
            return .init(id: id, reason: nil, severity: .warning,
                         headline: String(localized: "Needs attention"),
                         description: detail ?? String(localized: "Something is blocking progress."),
                         blocker: detail, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)

        case .unknown:
            // Spec §29 — never guess. Show the raw payload and hand off to Apple.
            return .init(id: id, reason: nil, severity: .warning,
                         headline: String(localized: "Could not determine state"),
                         description: String(localized: "Apple returned a value BetaCue doesn't recognize. Check the raw payload below or look in App Store Connect."),
                         blocker: nil, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)
        }
    }
}
