import XCTest
@testable import PRayerCore

/// PR 머리 줄 받는 쪽 칩의 base 바꾸기 — GitHub 응답 해석과 바꿀 수 있는지 가르기.
final class BaseChangeTests: XCTestCase {
    func testSuccessResponseGivesNewBase() {
        let parsed = GitHubClient.parseBaseChange(#"{"number": 7, "base": {"ref": "release", "sha": "abc"}}"#)
        XCTAssertEqual(parsed?.ref, "release")
    }

    /// 422 의 `message` 는 "Validation Failed" 뿐이다. 사람이 읽을 이유는 `errors[].message` 에 있다.
    func testValidationFailureReadsErrorDetails() {
        let json = """
        {"message": "Validation Failed",
         "errors": [{"resource": "PullRequest", "code": "custom",
                     "message": "Proposed base branch 'nope' was not found"}]}
        """
        let parsed = GitHubClient.parseBaseChange(json)
        XCTAssertNil(parsed?.ref)
        XCTAssertEqual(parsed?.reason, "Proposed base branch 'nope' was not found")
        XCTAssertEqual(BaseChangeError(githubMessage: parsed?.reason ?? ""),
                       .rejected("Proposed base branch 'nope' was not found"))
    }

    func testNoNewCommitsIsNamed() {
        let json = """
        {"message": "Validation Failed",
         "errors": [{"message": "There are no new commits between base branch 'main' and head branch 'feature/x'"}]}
        """
        let reason = GitHubClient.parseBaseChange(json)?.reason ?? ""
        XCTAssertEqual(BaseChangeError(githubMessage: reason), .noNewCommits)
    }

    func testPlainMessageWithoutDetails() {
        let parsed = GitHubClient.parseBaseChange(#"{"message": "Cannot change the base branch of a closed pull request."}"#)
        XCTAssertEqual(parsed?.reason, "Cannot change the base branch of a closed pull request.")
    }

    func testNonJSONIsNil() {
        XCTAssertNil(GitHubClient.parseBaseChange("gh: Not Found (HTTP 404)"))
    }

    /// 바꿀 권한은 GraphQL `viewerCanUpdate` 로 받는다. 옛 캐시(값 없음)·닫힌 PR 은 칩을 누를 수 없다.
    func testCanChangeBaseNeedsOpenAndPermission() throws {
        func info(_ extra: String) throws -> PullRequestInfo? {
            let json = """
            {"id": "PR_1", "number": 1, "repository": {"name": "app", "owner": {"login": "acme"}}, \(extra)}
            """
            return try JSONDecoder().decode(PRNodeDTO.self, from: Data(json.utf8)).toInfo()
        }
        XCTAssertEqual(try info(#""state": "OPEN", "viewerCanUpdate": true"#)?.canChangeBase, true)
        XCTAssertEqual(try info(#""state": "OPEN", "viewerCanUpdate": false"#)?.canChangeBase, false)
        XCTAssertEqual(try info(#""state": "CLOSED", "viewerCanUpdate": true"#)?.canChangeBase, false)
        XCTAssertEqual(try info(#""state": "MERGED", "viewerCanUpdate": true"#)?.canChangeBase, false)
        let unknown = try info(#""state": "OPEN""#)
        XCTAssertNil(unknown?.viewerCanUpdate)
        XCTAssertEqual(unknown?.canChangeBase, false)
    }

    /// 이 필드가 생기기 전에 저장한 PR 캐시도 그대로 읽힌다.
    func testOldCacheWithoutPermissionStillDecodes() throws {
        let fresh = try XCTUnwrap(JSONDecoder().decode(PRNodeDTO.self, from: Data("""
            {"id": "PR_1", "number": 1, "state": "OPEN", "viewerCanUpdate": true,
             "repository": {"name": "app", "owner": {"login": "acme"}}}
            """.utf8)).toInfo())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        XCTAssertEqual(object["viewerCanUpdate"] as? Bool, true)
        object.removeValue(forKey: "viewerCanUpdate")
        let old = try JSONDecoder().decode(PullRequestInfo.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.viewerCanUpdate)
        XCTAssertFalse(old.canChangeBase)
    }
}
