import XCTest
@testable import PRayerCore

/// 승인한 PR 이 다시 떴을 때 배지가 **왜** 다시 떴는지 말하는가.
///
/// 배경: 승인한 PR 은 리뷰 대기에서 빠지는데, 재요청이나 새 커밋이 오면 돌아온다. 그때 배지가 Approved 만
/// 말하면 "승인했는데 왜 또 떴지?" 가 된다. Approved 는 그 자리에 두고(화면은 흐리게) 이유를 덧붙인다.
final class BadgeFollowUpTests: XCTestCase {
    private let old = "old0000000000"
    private let mid = "mid0000000000"
    private let head = "head000000000"
    private let postedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func commit(_ oid: String) -> PRCommit {
        PRCommit(oid: oid, abbreviatedOid: String(oid.prefix(7)), messageHeadline: "m",
                 committedDate: Date(timeIntervalSince1970: 1_780_000_000), author: "riley-park-acme")
    }

    /// 웹에서 `reviewState` 로 `reviewCommit` 을 리뷰했다. 커밋은 old → mid → head 순으로 올라왔다.
    private func pr(reviewState: String? = "APPROVED", reviewCommit: String?, requested: Bool = false,
                    reviewedAt: Date? = nil, state: String = "OPEN") -> PullRequestInfo {
        var pr = Fixtures.pr(state: state, viewerHasReviewRequest: requested,
                             viewerLatestReviewState: reviewState, headRefOid: head)
        pr.viewerLatestReviewCommit = reviewCommit
        pr.viewerLatestReviewAt = reviewedAt
        pr.commits = [commit(old), commit(mid), commit(head)]
        return pr
    }

    private func resolve(_ pr: PullRequestInfo, record: ReviewRecord? = nil) -> BadgeResult {
        BadgeResolver.resolve(pr: pr, isRunning: false, record: record, skipReason: nil)
    }

    /// 이 앱으로 `event` 를 `recordHead` 에 올린 기록.
    private func posted(_ event: String, pr: PullRequestInfo, recordHead: String) -> ReviewRecord {
        Fixtures.record(pr: pr, output: Fixtures.output(),
                        posted: PostedInfo(reviewID: 1, htmlURL: "u", event: event, postedAt: postedAt, commentCount: 0),
                        headSha: recordHead)
    }

    // MARK: - 웹에서 낸 리뷰

    func testApprovedAtHeadHasNoFollowUp() {
        let result = resolve(pr(reviewCommit: head))
        XCTAssertEqual(result.badge, .approved)
        XCTAssertNil(result.followUp)
    }

    func testApprovedThenReRequested() {
        let result = resolve(pr(reviewCommit: head, requested: true))
        XCTAssertEqual(result.badge, .approved, "Approved 는 그 자리에 남는다")
        XCTAssertEqual(result.followUp, .reRequested)
    }

    func testApprovedThenNewCommitsCountsThem() {
        XCTAssertEqual(resolve(pr(reviewCommit: old)).followUp, .newCommits(2))
        XCTAssertEqual(resolve(pr(reviewCommit: mid)).followUp, .newCommits(1))
    }

    /// 승인한 커밋이 받아 둔 목록(최근 30개)에 없으면 개수를 지어내지 않는다.
    func testNewCommitsWithoutKnownCountSaysSo() {
        XCTAssertEqual(resolve(pr(reviewCommit: "gone000000000")).followUp, .newCommits(nil))
    }

    /// 재요청은 사람이 직접 한 말이라 새 커밋보다 앞선다.
    func testReRequestBeatsNewCommits() {
        XCTAssertEqual(resolve(pr(reviewCommit: old, requested: true)).followUp, .reRequested)
    }

    /// 코멘트·변경 요청은 리뷰 대기에서 빠진 적이 없다 — 새 커밋이 와도 배지 하나 그대로(사용자 결정).
    func testNonApprovalIgnoresNewCommits() {
        let commented = resolve(pr(reviewState: "COMMENTED", reviewCommit: old))
        XCTAssertEqual(commented.badge, .commented)
        XCTAssertNil(commented.followUp)
        let changes = resolve(pr(reviewState: "CHANGES_REQUESTED", reviewCommit: old))
        XCTAssertEqual(changes.badge, .changesRequested)
        XCTAssertNil(changes.followUp)
    }

    func testNonApprovalReRequestedIsSingleBadge() {
        let result = resolve(pr(reviewState: "COMMENTED", reviewCommit: head, requested: true))
        XCTAssertEqual(result.badge, .reRequested)
        XCTAssertNil(result.followUp)
    }

    /// 닫힌 PR 은 다시 뜰 리뷰 대기에 없다. 머지된 PR 에 +2 commits 가 붙으면 할 일이 있는 것처럼 읽힌다.
    func testClosedPRHasNoFollowUp() {
        let merged = resolve(pr(reviewCommit: old, requested: true, state: "MERGED"))
        XCTAssertEqual(merged.badge, .approved)
        XCTAssertNil(merged.followUp)
    }

    // MARK: - 이 앱으로 올린 리뷰

    /// 게시 직후 GitHub 은 잠깐 옛 상태(리뷰를 내면 지워질 요청이 남은 상태)를 돌려준다.
    /// 그 요청을 재요청으로 읽으면 방금 승인한 PR 에 Re-requested 가 붙는다.
    func testStaleRequestRightAfterPostingIsIgnored() {
        let stale = pr(reviewState: nil, reviewCommit: nil, requested: true)
        let approved = resolve(stale, record: posted("APPROVE", pr: stale, recordHead: head))
        XCTAssertEqual(approved.badge, .approved)
        XCTAssertNil(approved.followUp)
        // 그 전에 남긴 코멘트가 있어도 마찬가지 — GitHub 이 아는 리뷰가 이번 게시보다 오래됐다.
        let earlier = pr(reviewState: "COMMENTED", reviewCommit: old, requested: true,
                         reviewedAt: postedAt.addingTimeInterval(-3600))
        XCTAssertEqual(resolve(earlier, record: posted("COMMENT", pr: earlier, recordHead: head)).badge, .commented)
        XCTAssertNil(resolve(earlier, record: posted("APPROVE", pr: earlier, recordHead: head)).followUp)
    }

    /// GitHub 이 게시한 리뷰를 안 뒤에 걸린 요청은 진짜 재요청이다. 예전에는 이 앱으로 올린 기록이 가렸다.
    func testRequestAfterGitHubKnowsThePostIsReRequest() {
        let fresh = pr(reviewCommit: head, requested: true, reviewedAt: postedAt.addingTimeInterval(-1))
        XCTAssertEqual(resolve(fresh, record: posted("APPROVE", pr: fresh, recordHead: head)).followUp, .reRequested)
        var commented = fresh
        commented.viewerLatestReviewState = "COMMENTED"
        XCTAssertEqual(resolve(commented, record: posted("COMMENT", pr: commented, recordHead: head)).badge, .reRequested)
    }

    /// 새 커밋은 GitHub 이 아직 게시를 몰라도 기록의 커밋으로 센다.
    func testPostedApprovalCountsCommitsAfterRecordHead() {
        let stale = pr(reviewState: nil, reviewCommit: nil)
        let result = resolve(stale, record: posted("APPROVE", pr: stale, recordHead: mid))
        XCTAssertEqual(result.badge, .approved)
        XCTAssertEqual(result.followUp, .newCommits(1))
        XCTAssertFalse(result.overlays.contains(.stale), "이유 칩이 새 커밋을 말하므로 오래됨 겹침은 뺀다")
    }

    /// 앱으로 승인한 뒤 웹에서 지금 커밋을 다시 승인했으면 새 커밋이 없다 — GitHub 이 아는 쪽이 더 새것이다.
    func testLaterWebApprovalAtHeadWins() {
        let reapproved = pr(reviewCommit: head, reviewedAt: postedAt.addingTimeInterval(600))
        XCTAssertNil(resolve(reapproved, record: posted("APPROVE", pr: reapproved, recordHead: old)).followUp)
    }

    // MARK: - 글자

    func testLabels() {
        XCTAssertEqual(PRBadge.changesRequested.label, "Changes requested")
        // 배지는 내 리뷰 상태라 누가 단 코멘트인지 이름에 넣는다(사용자 결정).
        XCTAssertEqual(PRBadge.commented.label, "You commented")
        XCTAssertEqual(PRBadge.blocker.label, "Blocker")
        XCTAssertEqual(PRBadge.nonBlocker.label, "Non-blocker")
        XCTAssertEqual(PRBadgeFollowUp.reRequested.label, "Re-requested")
        XCTAssertEqual(PRBadgeFollowUp.newCommits(1).label, "+1 commit")
        XCTAssertEqual(PRBadgeFollowUp.newCommits(3).label, "+3 commits")
        XCTAssertEqual(PRBadgeFollowUp.newCommits(nil).label, "New commits")
        XCTAssertNil(PRBadgeFollowUp.reRequested.shortLabel, "좁을 때는 아이콘만")
        XCTAssertEqual(PRBadgeFollowUp.newCommits(3).shortLabel, "+3")
    }

    func testCommitCountAfter() {
        let info = pr(reviewCommit: nil)
        XCTAssertEqual(info.commitCount(after: old), 2)
        XCTAssertNil(info.commitCount(after: head), "head 뒤로는 없다")
        XCTAssertNil(info.commitCount(after: "unknown00000"))
    }
}
