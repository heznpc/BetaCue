import Foundation

/// Command layer, kept separate from reads (`Collector`). (spec §25)
///
/// UI buttons run commands from here rather than calling API paths directly.
enum Commands {
    /// Attach a build to beta groups — the only write the user performs in this app.
    ///
    /// Success answers 204 No Content, so a plain `post` would fail decoding a successful call.
    static func assign(build buildID: String, toGroups groupIDs: [String],
                       using client: ASCClient) async throws
    {
        guard !groupIDs.isEmpty else { return }
        let body = RelationshipBody(
            data: groupIDs.map { RelationshipBody.Ref(type: "betaGroups", id: $0) })
        try await client.postNoContent("/v1/builds/\(buildID)/relationships/betaGroups", body: body)
    }

    static func remove(build buildID: String, fromGroups groupIDs: [String],
                       using client: ASCClient) async throws
    {
        guard !groupIDs.isEmpty else { return }
        let body = RelationshipBody(
            data: groupIDs.map { RelationshipBody.Ref(type: "betaGroups", id: $0) })
        try await client.deleteNoContent("/v1/builds/\(buildID)/relationships/betaGroups", body: body)
    }

    private struct RelationshipBody: Encodable {
        struct Ref: Encodable {
            var type: String
            var id: String
        }
        var data: [Ref]
    }
}
