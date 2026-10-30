import XCTest
@testable import PRayerCore

final class PRChangeDetectorTests: XCTestCase {
    private let threshold: (PullRequestInfo) -> Int = { _ in 3 }

    private func detect(previous: [PullRequestInfo], current: [PullRequestInfo]) -> [PRChangeSet] {
        PRChangeDetector.changes(previous: PRChangeDetector.snapshots(previous),
                                 current: current,
                                 approvalThreshold: threshold)
    }

    func testNewPRWithReviewRequest() {
        let pr = Fixtures.pr(viewerHasReviewRequest: true)
        let changes = detect(previous: [], current: [pr])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].changes, [.appeared(reviewRequested: true)])
    }

    func testNewPRWithoutReviewRequest() {
        let changes = detect(previous: [], current: [Fixtures.pr(viewerHasReviewRequest: false)])
        XCTAssertEqual(changes[0].changes, [.appeared(reviewRequested: false)])
    }

    /// 내가 만든 PR 이 새로 보이는 건 알릴 일이 아니다.
    func testOwnNewPRIsNotAnnounced() {
        XCTAssertTrue(detect(previous: [], current: [Fixtures.pr(viewerDidAuthor: true)]).isEmpty)
    }

    /// 이미 닫힌 PR 이 뒤늦게 목록에 들어와도 "새 PR" 이 아니다.
    func testClosedPRAppearingIsIgnored() {
        XCTAssertTrue(detect(previous: [], current: [Fixtures.pr(state: "MERGED")]).isEmpty)
    }

    func testReviewRequestArrivesLater() {
        let before = Fixtures.pr(viewerHasReviewRequest: false)
        let after = Fixtures.pr(viewerHasReviewRequest: true)
        XCTAssertEqual(detect(previous: [before], current: [after])[0].changes, [.reviewRequested])
    }

    /// 내가 리뷰를 냈던 PR 에 다시 요청이 오면 재리뷰로 구분한다.
    func testReReviewRequest() {
        let before = Fixtures.pr(viewerHasReviewRequest: false, viewerLatestReviewState: "APPROVED")
        let after = Fixtures.pr(viewerHasReviewRequest: true, viewerLatestReviewState: "APPROVED")
        XCTAssertEqual(detect(previous: [before], current: [after])[0].changes, [.reReviewRequested])
    }

    func testMyPRGetsCommentsAndApprovals() {
        let before = Fixtures.pr(approvals: ["a"], viewerDidAuthor: true)
        var after = Fixtures.pr(approvals: ["a", "b", "c"], viewerDidAuthor: true)
        after.threads = [PRReviewThread(id: "t1", path: "A.swift", line: 1,
                                        isResolved: false, isOutdated: false, comments: [])]
        let changes = detect(previous: [before], current: [after])[0].changes
        XCTAssertTrue(changes.contains(PRChange.commentsOnMyPR(added: 1)))
        XCTAssertTrue(changes.contains(PRChange.approvalsReached(count: 3)))
    }

    func testApprovalThresholdOnlyFiresOnce() {
        let before = Fixtures.pr(approvals: ["a", "b", "c"], viewerDidAuthor: true)
        let after = Fixtures.pr(approvals: ["a", "b", "c", "d"], viewerDidAuthor: true)
        let changes = detect(previous: [before], current: [after])
        XCTAssertTrue(changes.isEmpty, "이미 임계값을 넘긴 뒤에는 다시 알리지 않는다")
    }

    func testMyPRChecksAndConflict() {
        let before = Fixtures.pr(viewerDidAuthor: true)
        var after = Fixtures.pr(mergeable: .conflicting, viewerDidAuthor: true)
        after.checkState = "FAILURE"
        let changes = detect(previous: [before], current: [after])[0].changes
        XCTAssertTrue(changes.contains(PRChange.checksFailed))
        XCTAssertTrue(changes.contains(PRChange.conflictAppeared))
    }

    func testNewCommitsOnReviewedPR() {
        let before = Fixtures.pr(viewerLatestReviewState: "APPROVED", headRefOid: "old")
        let after = Fixtures.pr(viewerLatestReviewState: "APPROVED", headRefOid: "new")
        XCTAssertEqual(detect(previous: [before], current: [after])[0].changes, [.newCommitsOnReviewed])
    }

    func testMergedNotification() {
        let before = Fixtures.pr(viewerDidAuthor: true)
        let after = Fixtures.pr(state: "MERGED", viewerDidAuthor: true)
        XCTAssertEqual(detect(previous: [before], current: [after])[0].changes, [.merged])
    }

    func testNoChangeProducesNothing() {
        let pr = Fixtures.pr()
        XCTAssertTrue(detect(previous: [pr], current: [pr]).isEmpty)
    }
}

final class PRChangePrefsTests: XCTestCase {
    func testDefaultsFocusOnWhatINeedToAct() {
        let prefs = PRChangeNotificationPrefs.default
        XCTAssertTrue(prefs.allows(.appeared(reviewRequested: true)))
        XCTAssertFalse(prefs.allows(.appeared(reviewRequested: false)),
                       "기본값은 나에게 요청된 PR 만 알린다")
        XCTAssertTrue(prefs.allows(.commentsOnMyPR(added: 1)))
        XCTAssertTrue(prefs.allows(.approvalsReached(count: 2)))
        XCTAssertTrue(prefs.allows(.conflictAppeared))
        // 켤 수는 있지만 기본으로는 오지 않는 것(사용자 결정, 2026-10-30).
        XCTAssertFalse(prefs.allows(.reviewRequested))
        XCTAssertFalse(prefs.allows(.reReviewRequested))
        XCTAssertFalse(prefs.allows(.checksFailed))
        XCTAssertFalse(prefs.allows(.newCommitsOnReviewed))
        XCTAssertFalse(prefs.allows(.merged))
    }

    func testTurningOffNewPRSilencesBoth() {
        var prefs = PRChangeNotificationPrefs.default
        prefs.newPR = false
        XCTAssertFalse(prefs.allows(.appeared(reviewRequested: true)))
        XCTAssertFalse(prefs.allows(.appeared(reviewRequested: false)))
    }

    func testAllNewPRsWhenNarrowingIsOff() {
        var prefs = PRChangeNotificationPrefs.default
        prefs.newPROnlyWhenReviewRequested = false
        XCTAssertTrue(prefs.allows(.appeared(reviewRequested: false)))
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let prefs = try JSONDecoder().decode(PRChangeNotificationPrefs.self,
                                             from: Data("{\"newPR\": false}".utf8))
        XCTAssertFalse(prefs.newPR)
        XCTAssertTrue(prefs.conflict, "나머지는 기본값")
        XCTAssertFalse(prefs.checksFailed, "나머지는 기본값")
    }
}

final class DuplicatePRSnapshotTests: XCTestCase {
    func testSnapshotsSurviveDuplicateIDs() {
        // 검색 페이지네이션이 같은 PR 을 두 번 돌려줘도 크래시하면 안 된다.
        let pr = PullRequestInfo(repo: RepoID(owner: "o", name: "r"), number: 1, nodeID: "n",
                                 title: "t", bodyText: "", author: "a", isDraft: false, state: "OPEN",
                                 createdAt: Date(), updatedAt: Date(), headRefOid: "abc",
                                 headRefName: "f", baseRefName: "develop", additions: 1, deletions: 0,
                                 changedFiles: 1, mergeable: .mergeable, mergeStateStatus: nil,
                                 reviewDecision: nil, approvals: [], labels: [], viewerDidAuthor: false,
                                 viewerHasReviewRequest: true, viewerLatestReviewState: nil,
                                 viewerLatestReviewCommit: nil, checkState: nil, threads: [])
        let snapshots = PRChangeDetector.snapshots([pr, pr])
        XCTAssertEqual(snapshots.count, 1)
    }
}
