import XCTest
@testable import PRayerCore

/// 승인·게시한 PR 을 유예가 끝나면 바로 빼는 규칙.
///
/// 배경: 게시 직후에는 GitHub 이 아직 예전 상태를 돌려주는 창이 있어, 필터에게 다시
/// 판단하게 두면 처리한 PR 이 다음 폴링까지 목록에 남는다. 그래서 "내가 한 일" 은
/// GitHub 에 묻지 않고 뺀다.
final class DismissalTests: XCTestCase {
    private let head = "aaaaaaaaaaaa1111"
    private let postedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func dismissal(_ oid: String? = nil) -> PRDismissal {
        PRDismissal(head: oid ?? head, reviewedAt: postedAt)
    }

    func testDismissedWhenHeadMatches() {
        let pr = Fixtures.pr(number: 42, headRefOid: head)
        XCTAssertTrue(PRVisibility.isDismissed(pr: pr, dismissals: [pr.id: dismissal()]))
    }

    func testNotDismissedWhenEmpty() {
        let pr = Fixtures.pr(number: 42, headRefOid: head)
        XCTAssertFalse(PRVisibility.isDismissed(pr: pr, dismissals: [:]))
    }

    /// 새 커밋이 올라왔으면 다시 봐야 한다. 같은 PR 이라고 계속 숨기면 안 된다.
    func testNewCommitIsVisibleAgain() {
        let pr = Fixtures.pr(number: 42, headRefOid: "bbbbbbbbbbbb2222")
        XCTAssertFalse(PRVisibility.isDismissed(pr: pr, dismissals: [pr.id: dismissal()]))
    }

    /// 다른 PR 의 숨김이 흘러 넘치지 않는다.
    func testDismissalIsPerPR() {
        let other = Fixtures.pr(number: 43, headRefOid: head)
        let dismissals = [Fixtures.pr(number: 42, headRefOid: head).id: dismissal()]
        XCTAssertFalse(PRVisibility.isDismissed(pr: other, dismissals: dismissals))
    }

    func testPruneDropsDismissalAfterNewCommit() {
        let pr = Fixtures.pr(number: 42, headRefOid: "bbbbbbbbbbbb2222")
        let pruned = PRVisibility.prunedDismissals([pr.id: dismissal()], prs: [pr])
        XCTAssertTrue(pruned.isEmpty)
    }

    func testPruneKeepsDismissalWhenHeadUnchanged() {
        let pr = Fixtures.pr(number: 42, headRefOid: head)
        let pruned = PRVisibility.prunedDismissals([pr.id: dismissal()], prs: [pr])
        XCTAssertEqual(pruned, [pr.id: dismissal()])
    }

    /// 탭을 옮기면 `prs` 에서 잠깐 빠진다. 그때 숨김까지 지우면 돌아오자마자 다시 튀어나온다.
    func testPruneKeepsDismissalForPRNotInList() {
        let key = Fixtures.pr(number: 42, headRefOid: head).id
        let pruned = PRVisibility.prunedDismissals([key: dismissal()], prs: [])
        XCTAssertEqual(pruned, [key: dismissal()])
    }

    func testPruneOnEmptyIsCheapAndStable() {
        XCTAssertTrue(PRVisibility.prunedDismissals([:], prs: [Fixtures.pr()]).isEmpty)
    }

    /// 승인 직후 GitHub 은 잠깐 옛 상태(리뷰 요청이 남아 있음)를 돌려준다.
    /// 그대로 두면 방금 처리한 PR 이 목록에 다시 뜬다 — 숨김이 이겨야 한다.
    func testStaleDataStillLooksLikeMyTurn() {
        let stale = Fixtures.pr(number: 42, viewerHasReviewRequest: true, headRefOid: head)
        XCTAssertTrue(stale.viewerHasReviewRequest, "게시 직후 GitHub 이 돌려주는 옛 상태")
        XCTAssertTrue(PRVisibility.isDismissed(pr: stale, dismissals: [stale.id: dismissal()]),
                      "그래도 숨김이 이기고 목록에서 빠져야 한다")
        // 그 전에 낸 리뷰가 있어 "리뷰 + 요청" 처럼 보여도, GitHub 이 아는 리뷰가 이번 게시보다 오래됐으면 옛 상태다.
        var earlier = Fixtures.pr(number: 42, viewerHasReviewRequest: true, viewerLatestReviewState: "COMMENTED",
                                  headRefOid: head)
        earlier.viewerLatestReviewAt = postedAt.addingTimeInterval(-3600)
        XCTAssertTrue(PRVisibility.isDismissed(pr: earlier, dismissals: [earlier.id: dismissal()]))
    }

    /// 뺀 뒤 다시 리뷰 요청이 왔으면 새 커밋처럼 다시 볼 일이 생긴 것이다.
    func testReRequestAfterDismissalShowsAgain() {
        var reRequested = Fixtures.pr(number: 42, viewerHasReviewRequest: true, viewerLatestReviewState: "APPROVED",
                                      headRefOid: head)
        reRequested.viewerLatestReviewAt = postedAt.addingTimeInterval(-1)
        XCTAssertFalse(PRVisibility.isDismissed(pr: reRequested, dismissals: [reRequested.id: dismissal()]))
        // 숨김은 남겨 둔다 — 다시 리뷰해서 요청이 걷히면 도로 빠져야 한다.
        XCTAssertEqual(PRVisibility.prunedDismissals([reRequested.id: dismissal()], prs: [reRequested]),
                       [reRequested.id: dismissal()])
        var reviewedAgain = reRequested
        reviewedAgain.viewerHasReviewRequest = false
        reviewedAgain.viewerLatestReviewAt = postedAt.addingTimeInterval(600)
        XCTAssertTrue(PRVisibility.isDismissed(pr: reviewedAgain, dismissals: [reviewedAgain.id: dismissal()]))
    }

    /// 게시 직후 GitHub 이 **리뷰는 알면서 요청은 아직 안 지운** 상태를 돌려줄 때.
    /// 걸려 있는 요청이 내 리뷰보다 먼저 걸린 것이면 지워지기 전의 옛 요청이다 — 숨김이 이겨야 한다.
    /// (예전에는 이걸 재요청으로 읽어, 흐려지던 행이 유예가 끝나자 도로 또렷해져 다음 폴링까지 남았다.)
    func testRequestNotYetClearedAfterPostStaysDismissed() {
        var halfFresh = Fixtures.pr(number: 42, viewerHasReviewRequest: true, viewerLatestReviewState: "APPROVED",
                                    headRefOid: head)
        halfFresh.viewerLatestReviewAt = postedAt.addingTimeInterval(1)
        halfFresh.viewerReviewRequestedAt = postedAt.addingTimeInterval(-18 * 3600)
        XCTAssertFalse(halfFresh.isReRequested(postedAt: postedAt))
        XCTAssertTrue(PRVisibility.isDismissed(pr: halfFresh, dismissals: [halfFresh.id: dismissal()]))
    }

    /// 요청이 내 리뷰 **뒤에** 걸렸으면 진짜 재요청이다 — 숨김을 뚫고 다시 보여야 한다.
    func testRequestAfterMyReviewIsReRequest() {
        var reRequested = Fixtures.pr(number: 42, viewerHasReviewRequest: true, viewerLatestReviewState: "APPROVED",
                                      headRefOid: head)
        reRequested.viewerLatestReviewAt = postedAt.addingTimeInterval(1)
        reRequested.viewerReviewRequestedAt = postedAt.addingTimeInterval(300)
        XCTAssertTrue(reRequested.isReRequested(postedAt: postedAt))
        XCTAssertFalse(PRVisibility.isDismissed(pr: reRequested, dismissals: [reRequested.id: dismissal()]))
        // 이 앱으로 게시한 리뷰가 아니어도(배지의 `isReRequested()`) 같은 기준이다.
        XCTAssertTrue(reRequested.isReRequested())
        var stale = reRequested
        stale.viewerReviewRequestedAt = postedAt.addingTimeInterval(-60)
        XCTAssertFalse(stale.isReRequested())
    }

    /// 요청 시각은 타임라인의 리뷰 요청 사건에서 **나**(또는 팀)에게 온 것 중 마지막 것이다.
    func testRequestedAtComesFromViewerAndTeamEvents() throws {
        func info(_ events: String) throws -> PullRequestInfo? {
            let json = """
            {"id": "PR_1", "number": 42, "repository": {"name": "app", "owner": {"login": "acme"}},
             "viewerLatestReviewRequest": {"id": "RR_1"},
             "reviewRequestEvents": {"nodes": [\(events)]}}
            """
            return try JSONDecoder().decode(PRNodeDTO.self, from: Data(json.utf8)).toInfo()
        }
        let viewer = #"{"createdAt": "2026-10-14T07:02:18Z", "requestedReviewer": {"__typename": "User", "isViewer": true}}"#
        let other = #"{"createdAt": "2026-10-15T09:00:00Z", "requestedReviewer": {"__typename": "User", "isViewer": false}}"#
        let team = #"{"createdAt": "2026-10-14T08:00:00Z", "requestedReviewer": {"__typename": "Team"}}"#
        // 다른 종류의 타임라인 항목은 빈 객체로 온다.
        let unrelated = "{}"

        let iso = { (text: String) in try Date(text, strategy: .iso8601) }
        XCTAssertEqual(try info([viewer, other].joined(separator: ","))?.viewerReviewRequestedAt,
                       try iso("2026-10-14T07:02:18Z"), "남에게 온 요청은 세지 않는다")
        XCTAssertEqual(try info([viewer, team, other, unrelated].joined(separator: ","))?.viewerReviewRequestedAt,
                       try iso("2026-10-14T08:00:00Z"), "팀 요청은 나에게 온 것으로 친다")
        XCTAssertNil(try info(other)?.viewerReviewRequestedAt, "나에게 온 사건이 없으면 모른다")
    }

    /// 나에게 걸린 요청이 CODEOWNERS 로 걸린 것인지(`asCodeOwner`)를 그대로 받는다 — 목록의 "Requested" 는
    /// 직접 지정한 요청에만 붙는다. 값이 없으면(옛 응답·캐시) nil, 곧 모름이다.
    func testRequestAsCodeOwnerIsRead() throws {
        func info(_ request: String) throws -> PullRequestInfo? {
            let json = """
            {"id": "PR_1", "number": 42, "repository": {"name": "app", "owner": {"login": "acme"}},
             "viewerLatestReviewRequest": \(request)}
            """
            return try JSONDecoder().decode(PRNodeDTO.self, from: Data(json.utf8)).toInfo()
        }
        XCTAssertEqual(try info(#"{"id": "RR_1", "asCodeOwner": true}"#)?.viewerRequestedAsCodeOwner, true)
        XCTAssertEqual(try info(#"{"id": "RR_1", "asCodeOwner": false}"#)?.viewerRequestedAsCodeOwner, false)
        XCTAssertNil(try info(#"{"id": "RR_1"}"#)?.viewerRequestedAsCodeOwner)
        XCTAssertNil(try info("null")?.viewerRequestedAsCodeOwner)
    }
}
