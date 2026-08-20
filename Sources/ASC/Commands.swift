import Foundation

/// 조작 계층. 조회(`Collector`)와 분리한다. (명세 §25)
///
/// UI 버튼은 API 경로를 직접 부르지 않고 여기의 명령을 실행한다.
enum Commands {
    /// 빌드를 베타 그룹에 연결한다 — 이 앱에서 사용자가 실제로 수행하는 유일한 쓰기 동작이다.
    ///
    /// 성공 응답이 204 No Content라 일반 `post`로 부르면 성공해도 디코딩에서 실패한다.
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
