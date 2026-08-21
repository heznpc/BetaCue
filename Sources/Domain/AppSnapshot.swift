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
    /// Who can receive that build. Structured so tests don't depend on the running language.
    var audience: Audience?

    /// One line describing the audience, localized.
    var audienceDescription: String? { audience?.description }

    /// The newest build has not shipped while an older one is still serving.
    var hasOlderTestableBuild: Bool {
        guard let testable, let latestID = state.rawEvidence["buildID"] else { return false }
        return testable.id != latestID
    }
}

/// Who can install a given build, counted by channel.
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
    var testerCount: Int
    var autoDistributes: Bool
    var publicLinkEnabled: Bool
    var publicLink: String?
    /// Whether the tester count may be short because a page limit truncated it.
    var testerCountIsExact: Bool = true

    /// Is there anyone who can actually receive the app through this group?
    ///
    /// With a public link enabled, people can join even at zero enrolled testers.
    var canReachSomeone: Bool { testerCount > 0 || publicLinkEnabled }
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
    var uploadedAt: Date?
    var expiresAt: Date?
    var isExpired: Bool
    /// Beta groups this build is attached to. An app having groups is a different fact.
    var assignedGroupIDs: [String] = []
    /// Testers invited directly to this build without a group.
    var individualTesterCount: Int = 0

    var isValid: Bool { processingState == "VALID" && !isExpired }
    var isDistributedInternally: Bool { internalState == "IN_BETA_TESTING" }

    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// Is there anyone who can actually receive this build?
    func reachableAudience(among groups: [GroupSnapshot]) -> [GroupSnapshot] {
        groups.filter { assignedGroupIDs.contains($0.id) && $0.canReachSomeone }
    }

    func isReachable(among groups: [GroupSnapshot]) -> Bool {
        individualTesterCount > 0 || !reachableAudience(among: groups).isEmpty
    }

    /// One line for the history list.
    var humanState: String {
        if isExpired { return String(localized: "Expired") }
        switch processingState {
        case "PROCESSING": return String(localized: "Checking")
        case "FAILED", "INVALID": return String(localized: "Rejected")
        case "VALID": return isDistributedInternally ? String(localized: "Ready to test") : String(localized: "Not distributed")
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
