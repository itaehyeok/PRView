import XCTest
@testable import PRayerCore

/// 내가 올린 PR 그룹이 쓰는 데이터 — "아직 안 본 사람".
final class PendingReviewerTests: XCTestCase {
    /// GitHub 은 리뷰를 **제출하면 요청 목록에서 지운다.** 그래서 남아 있는 것이 곧 미응답자다.
    /// 이 전제가 깨지면 "riley 미응답" 이 거짓말이 되므로 계약으로 잠근다.
    func testPendingReviewersAreThoseWhoHaveNotSubmitted() {
        let pr = Fixtures.pr(number: 42)
        XCTAssertTrue(pr.pendingReviewers.isEmpty, "기본값은 비어 있다")

        var withPending = pr
        withPending.pendingReviewers = ["riley-acme", "ios-reviewers"]
        XCTAssertEqual(withPending.pendingReviewers.count, 2)
    }

    /// 팀으로 요청된 것은 팀 이름(slug)으로 온다 — 사람 이름만 기대하면 안 된다.
    func testTeamRequestsArriveAsSlugs() {
        var pr = Fixtures.pr()
        pr.pendingReviewers = ["ios-reviewers"]
        XCTAssertEqual(pr.pendingReviewers.first, "ios-reviewers")
    }

    /// 승인 수와 미응답자는 서로 독립이다. 둘 다 있어야 "2/3 · riley 미응답" 을 만들 수 있다.
    func testApprovalCountAndPendingAreIndependent() {
        var pr = Fixtures.pr(approvals: ["jamie-acme", "riley-acme"])
        pr.pendingReviewers = ["sam-acme"]
        XCTAssertEqual(pr.approvalCount, 2)
        XCTAssertEqual(pr.pendingReviewers, ["sam-acme"])
    }
}
