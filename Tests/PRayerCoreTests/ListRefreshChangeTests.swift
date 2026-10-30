import XCTest
@testable import PRayerCore

/// 목록을 새로 받을 때 무엇이 빠지고 들어오는지, 빠지는 PR 이 어느 탭으로 날아가는지.
final class ListRefreshChangeTests: XCTestCase {
    private let open = PRListScope.open

    private func approvedAtHead(reRequested: Bool = false) -> PullRequestInfo {
        var pr = Fixtures.pr(viewerHasReviewRequest: reRequested, viewerLatestReviewState: "APPROVED")
        pr.viewerLatestReviewCommit = pr.headRefOid
        return pr
    }

    // MARK: 바뀐 행

    /// 빠지는 것·들어오는 것 모두 화면 순서(위에서부터)를 지킨다 — 그 순서대로 하나씩 움직인다.
    func testChangeKeepsScreenOrder() {
        let change = ListRefreshChange(before: ["a", "b", "c", "d"], after: ["e", "a", "f", "c"])
        XCTAssertEqual(change.departures, ["b", "d"])
        XCTAssertEqual(change.arrivals, ["e", "f"])
        XCTAssertFalse(change.isEmpty)
    }

    /// 자리만 바뀐 것은 빠진 것도 들어온 것도 아니다.
    func testReorderIsNoChange() {
        XCTAssertTrue(ListRefreshChange(before: ["a", "b"], after: ["b", "a"]).isEmpty)
    }

    /// 5건까지는 하나씩, 넘으면 빠지는 칩을 묶는다.
    func testLargeAboveStepLimit() {
        XCTAssertFalse(ListRefreshChange(before: ["a", "b", "c"], after: ["c", "x", "y", "z"]).isLarge)
        XCTAssertTrue(ListRefreshChange(before: ["a", "b", "c"], after: ["x", "y", "z"]).isLarge)
    }

    /// 새 행은 많아도 한꺼번에 들이지 않는다 — 간격을 줄이고 화면에 들 만큼만 차례로 펼친다.
    func testArrivalCadence() {
        XCTAssertEqual(ListRefreshChange.arrivalCadence(count: 0).steps, 0)
        XCTAssertEqual(ListRefreshChange.arrivalCadence(count: 3).interval, 0.14)
        XCTAssertEqual(ListRefreshChange.arrivalCadence(count: 3).steps, 3)
        XCTAssertEqual(ListRefreshChange.arrivalCadence(count: 6).steps, 6)
        XCTAssertLessThan(ListRefreshChange.arrivalCadence(count: 6).interval, 0.14)
        // 30행을 처음 채워도 1초 안에 끝난다.
        let many = ListRefreshChange.arrivalCadence(count: 30)
        XCTAssertEqual(many.steps, 8)
        XCTAssertLessThan(many.interval * Double(many.steps - 1), 1)
    }

    // MARK: 갈 탭

    /// 받은 목록에서 없어졌다 = 머지·닫힘. 전체 PR 탭에 있다.
    func testGoneGoesToAllPRs() {
        XCTAssertEqual(ListRefreshChange.destination(of: nil, leaving: open), .recentAll)
    }

    func testClosedAndDraftGoToAllPRs() {
        XCTAssertEqual(ListRefreshChange.destination(of: Fixtures.pr(state: "MERGED"), leaving: open), .recentAll)
        XCTAssertEqual(ListRefreshChange.destination(of: Fixtures.pr(isDraft: true), leaving: open), .recentAll)
    }

    /// 웹에서 Approve 한 PR 도 Approve 버튼으로 한 것처럼 Approved 탭으로 간다.
    func testApprovedGoesToApproved() {
        XCTAssertEqual(ListRefreshChange.destination(of: approvedAtHead(), leaving: open), .myApprovals)
    }

    /// 다시 봐 달라는 요청이 걸려 있으면 리뷰 대기에 남는 PR 이다 — 빠졌다면 다른 이유(숨김·필터)라 갈 탭이 없다.
    func testReRequestedApprovalHasNoTab() {
        XCTAssertNil(ListRefreshChange.destination(of: approvedAtHead(reRequested: true), leaving: open))
    }

    /// 탭 조건은 그대로 맞는데 빠졌다 = 숨김 라벨·사람 필터에 걸렸다. 그 PR 은 다른 탭으로 간 것이 아니다.
    func testFilteredHasNoTab() {
        XCTAssertNil(ListRefreshChange.destination(of: Fixtures.pr(), leaving: open))
    }

    /// 리뷰 대기가 아닌 탭에서 빠지는 것은 기간이 지난 것이라 날아갈 곳이 없다.
    func testOtherTabsHaveNoDestination() {
        XCTAssertNil(ListRefreshChange.destination(of: nil, leaving: .recentAll(.day)))
        XCTAssertNil(ListRefreshChange.destination(of: approvedAtHead(), leaving: .myApprovals(.day)))
    }
}
