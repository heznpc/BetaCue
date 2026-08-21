import Foundation

/// Normalized app state. Apple's responses never reach the UI unchanged. (spec §18, §19)
struct AppSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var bundleID: String
    var groups: [GroupSnapshot]
    var builds: [BuildSnapshot]
    var fetchedAt: Date
    /// Secondary fetches that failed while reading this app. One failure does not stop the others.
    var partialErrors: [String] = []

    /// State is recomputed rather than stored, so changing the wording never touches the database.
    var status: AppStatus { RuleEngine.resolve(groups: groups, builds: builds) }

    var latestBuild: BuildSnapshot? { builds.first }
    var isPartial: Bool { !partialErrors.isEmpty }

    var appStoreConnectURL: URL? {
        URL(string: "https://appstoreconnect.apple.com/apps/\(id)/testflight/ios")
    }
}

/// The two questions users actually ask are different questions, so state has two axes.
///
///   "Did the new one land?"       → `state`    (latest upload)
///   "Can testers install now?"    → `testable` (the build actually serving)
///
/// While the newest build processes, the previous one usually still installs. Merging both loses that.
struct AppStatus: Sendable {
    var state: AppStateDefinition
    /// The installable build. May be the newest, an older one, or none.
    var testable: BuildSnapshot?
    /// Who can install that build. Structured so tests don't depend on the running language.
    var audience: Audience?

    /// One line describing the audience, localized.
    var audienceDescription: String? { audience?.description }

    /// The newest build has not shipped while an older one is still serving.
    var hasOlderTestableBuild: Bool {
        guard let testable, let latestID = state.rawEvidence["buildID"] else { return false }
        return testable.id != latestID
    }
}

/// A fact that a fetch may have failed to establish.
///
/// The whole product rests on not confusing "no testers" with "couldn't read the testers".
/// Modelling the second as `0` is what made a transient API error look like a real blocker.
enum Reachability: Equatable, Sendable {
    case reachable
    case unreachable
    case unknown
}

/// Who can install a given build **right now**, counted by channel.
///
/// Only channels that can actually install are counted. An external group of 100 attached to a
/// build still waiting on beta review reaches nobody today, and saying "100 external" would be
/// a confident wrong answer.
struct Audience: Equatable, Sendable {
    var internalTesters = 0
    var externalTesters = 0
    var individualTesters = 0
    var hasPublicLink = false

    var isEmpty: Bool {
        internalTesters == 0 && externalTesters == 0
            && individualTesters == 0 && !hasPublicLink
    }

    /// Rendering lives here so the counts stay assertable without a locale.
    var description: String {
        var parts: [String] = []
        if internalTesters > 0 { parts.append(String(localized: "\(internalTesters) internal")) }
        if externalTesters > 0 { parts.append(String(localized: "\(externalTesters) external")) }
        if individualTesters > 0 { parts.append(String(localized: "\(individualTesters) individual")) }
        if hasPublicLink { parts.append(String(localized: "public link")) }
        return parts.isEmpty ? String(localized: "no audience") : parts.joined(separator: " · ")
    }
}

struct GroupSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var isInternal: Bool
    /// `nil` means the tester list could not be read — not that the group is empty.
    var testerCount: Int?
    var autoDistributes: Bool
    var publicLinkEnabled: Bool
    var publicLink: String?

    /// Can anyone receive the app through this group?
    ///
    /// A public link can reach people at zero enrolled testers. An unreadable tester list
    /// is `unknown`, never `unreachable`.
    var reachability: Reachability {
        if publicLinkEnabled { return .reachable }
        guard let testerCount else { return .unknown }
        return testerCount > 0 ? .reachable : .unreachable
    }
}

struct BuildSnapshot: Identifiable, Sendable, Codable {
    var id: String
    /// What Apple calls "version" — really the build number.
    var number: String
    var marketingVersion: String?
    var platform: String?
    var processingState: String
    var internalState: String?
    var externalState: String?
    /// False when `buildBetaDetail` could not be read, so the two states above mean nothing.
    var betaStateIsKnown: Bool = true
    var uploadedAt: Date?
    var expiresAt: Date?
    var isExpired: Bool
    /// Beta groups this build is attached to. `nil` means the attachments could not be read.
    var assignedGroupIDs: [String]?
    /// Testers invited directly to this build without a group. `nil` means unread.
    var individualTesterCount: Int?

    var processingSucceeded: Bool { processingState == "VALID" && !isExpired }

    /// Apple says this build is live for internal testers.
    var isLiveInternally: Bool { betaStateIsKnown && internalState == "IN_BETA_TESTING" }

    /// Apple says this build cleared external beta review and is live for external testers.
    var isLiveExternally: Bool {
        betaStateIsKnown && (externalState == "IN_BETA_TESTING" || externalState == "BETA_APPROVED")
    }

    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// Groups this build is attached to that can reach someone.
    func reachableGroups(among groups: [GroupSnapshot]) -> [GroupSnapshot] {
        guard let assignedGroupIDs else { return [] }
        return groups.filter { assignedGroupIDs.contains($0.id) && $0.reachability == .reachable }
    }

    /// Is there an audience configured for this build at all?
    ///
    /// This asks about **attachment**, not installability. A build can have an audience
    /// configured and still be uninstallable because Apple has not finished with it.
    func hasAssignedAudience(among groups: [GroupSnapshot]) -> Reachability {
        guard let assignedGroupIDs, let individualTesterCount else { return .unknown }
        if individualTesterCount > 0 { return .reachable }

        let attached = groups.filter { assignedGroupIDs.contains($0.id) }
        if attached.contains(where: { $0.reachability == .reachable }) { return .reachable }
        if attached.contains(where: { $0.reachability == .unknown }) { return .unknown }
        return .unreachable
    }

    /// Who can install this build right now, honouring Apple's beta states.
    func installableAudience(among groups: [GroupSnapshot]) -> Audience? {
        guard betaStateIsKnown else { return nil }
        var audience = Audience()

        if isLiveInternally {
            let reachable = reachableGroups(among: groups).filter(\.isInternal)
            audience.internalTesters = reachable.reduce(0) { $0 + ($1.testerCount ?? 0) }
            audience.individualTesters = individualTesterCount ?? 0
        }
        if isLiveExternally {
            let reachable = reachableGroups(among: groups).filter { !$0.isInternal }
            audience.externalTesters = reachable.reduce(0) { $0 + ($1.testerCount ?? 0) }
            audience.hasPublicLink = reachable.contains(where: \.publicLinkEnabled)
        }
        return audience.isEmpty ? nil : audience
    }

    /// One line for the history list.
    var humanState: String {
        if isExpired { return String(localized: "Expired") }
        guard betaStateIsKnown else { return String(localized: "Unknown") }
        switch processingState {
        case "PROCESSING": return String(localized: "Checking")
        case "FAILED", "INVALID": return String(localized: "Rejected")
        case "VALID":
            if isLiveExternally { return String(localized: "Internal and external testing") }
            if isLiveInternally { return String(localized: "Ready to test") }
            return String(localized: "Not distributed")
        default: return processingState
        }
    }

    var displayVersion: String {
        guard let marketingVersion else { return String(localized: "build \(number)") }
        return "\(marketingVersion) (\(number))"
    }
}

struct CertificateSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var type: String
    var expiresAt: Date?

    var daysLeft: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// Within 60 days is worth notifying. (spec §12)
    var isExpiringSoon: Bool {
        guard let days = daysLeft else { return false }
        return days <= 60
    }
}
