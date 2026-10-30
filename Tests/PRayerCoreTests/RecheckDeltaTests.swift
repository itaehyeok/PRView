import XCTest
@testable import PRayerCore

/// "리뷰한 뒤로 무엇이 올라왔나" 를 세는 규칙. 여기서 놓치면 다시 확인이 통째로 헛돈다.
final class RecheckDeltaTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")
    private let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let reviewedSha = "aaaa111"

    private func commit(_ oid: String, _ offsetHours: Double, author: String = "rio") -> PRCommit {
        PRCommit(oid: oid, abbreviatedOid: String(oid.prefix(7)),
                 messageHeadline: "커밋 \(oid)",
                 committedDate: reviewedAt.addingTimeInterval(offsetHours * 3600),
                 author: author)
    }

    private func pr(commits: [PRCommit] = [],
                    issueComments: [PRIssueComment] = [],
                    reviewEvents: [PRReviewEvent] = [],
                    threads: [PRReviewThread] = [],
                    head: String = "bbbb222") -> PullRequestInfo {
        PullRequestInfo(repo: repo, number: 133, nodeID: "n", title: "제목", bodyText: "",
                        author: "rio", isDraft: false, state: "OPEN",
                        createdAt: reviewedAt, updatedAt: reviewedAt, headRefOid: head,
                        headRefName: "f", baseRefName: "main", additions: 1, deletions: 0,
                        changedFiles: 1, mergeable: .mergeable, mergeStateStatus: nil,
                        reviewDecision: nil, approvals: [], labels: [], viewerDidAuthor: false,
                        viewerHasReviewRequest: true, viewerLatestReviewState: nil,
                        viewerLatestReviewCommit: nil, checkState: nil, threads: threads,
                        commits: commits, reviewEvents: reviewEvents, issueComments: issueComments,
                        mergedAt: nil, mergedBy: nil, closedAt: nil)
    }

    private func record(_ info: PullRequestInfo) -> ReviewRecord {
        var draft = Fixtures.record(pr: info,
                                    output: ReviewOutput(verdict: .comment, summaryKo: "요약",
                                                         concerns: [], strengths: [],
                                                         draftComments: []),
                                    headSha: reviewedSha)
        // Fixtures 는 지금 시각을 넣는다. "리뷰한 시각" 을 고정해야 전후를 가릴 수 있다.
        draft.createdAt = reviewedAt
        return draft
    }

    // MARK: - 커밋 경계

    /// 커밋을 시각으로 자르면 리베이스·체리픽처럼 **작성 시각이 과거인** 커밋이 통째로 빠진다.
    /// 해시로 잘라야 한다.
    func testNewCommitsUseShaBoundaryNotTimestamps() {
        let info = pr(commits: [commit(reviewedSha, 0), commit("cccc333", -50)])
        let delta = RecheckDeltaBuilder.compute(pr: info, record: record(info))
        // cccc333 은 committedDate 가 리뷰보다 과거지만 목록에서 reviewedSha 뒤에 있지 않다.
        // 정렬은 시각 순이므로 cccc333 이 앞, reviewedSha 가 뒤 → 새 커밋은 없다.
        XCTAssertTrue(delta.newCommits.isEmpty)
        XCTAssertTrue(delta.commitBoundaryExact)
    }

    func testCommitsAfterTheReviewedOneAreNew() {
        let info = pr(commits: [commit(reviewedSha, 0), commit("cccc333", 1), commit("dddd444", 2)])
        let delta = RecheckDeltaBuilder.compute(pr: info, record: record(info))
        XCTAssertEqual(delta.newCommits.map(\.oid), ["cccc333", "dddd444"])
        XCTAssertTrue(delta.commitBoundaryExact)
    }

    /// 리뷰한 커밋이 목록에 없으면(force-push, 30개 밖으로 밀림) 시각으로 어림잡되
    /// **어림잡았다고 말해야** 한다. 모델이 없는 확신을 갖지 않게.
    func testMissingBoundaryFallsBackToTimeAndSaysSo() {
        let info = pr(commits: [commit("cccc333", 1)])
        let delta = RecheckDeltaBuilder.compute(pr: info, record: record(info))
        XCTAssertEqual(delta.newCommits.map(\.oid), ["cccc333"])
        XCTAssertFalse(delta.commitBoundaryExact)
    }

    // MARK: - 코멘트

    func testOnlyCommentsAfterTheReviewCount() {
        let info = pr(issueComments: [
            PRIssueComment(author: "kai", body: "리뷰 전 말", createdAt: reviewedAt.addingTimeInterval(-60)),
            PRIssueComment(author: "sage", body: "리뷰 후 말", createdAt: reviewedAt.addingTimeInterval(60)),
        ])
        let delta = RecheckDeltaBuilder.compute(pr: info, record: record(info))
        XCTAssertEqual(delta.newComments.map(\.author), ["sage"])
    }

    /// 오래된 스레드에 새 답글이 달린 경우. 스레드 시작 시각으로 판단하면 놓친다.
    func testNewReplyOnOldThreadIsDetected() {
        let old = reviewedAt.addingTimeInterval(-7200).ISO8601Format()
        let fresh = reviewedAt.addingTimeInterval(600).ISO8601Format()
        let info = pr(threads: [
            PRReviewThread(id: "t1", path: "A.swift", line: 10, isResolved: false, isOutdated: false,
                           comments: [ReviewThreadComment(author: "kai", body: "옛 지적", createdAt: old),
                                      ReviewThreadComment(author: "rio", body: "고쳤습니다", createdAt: fresh)]),
        ])
        let delta = RecheckDeltaBuilder.compute(pr: info, record: record(info))
        XCTAssertEqual(delta.newComments.map(\.author), ["rio"])
        XCTAssertEqual(delta.newComments.first?.path, "A.swift")
        XCTAssertEqual(delta.newComments.first?.line, 10)
    }

    /// 시각을 못 읽는 답글을 0 으로 두면 전부 "리뷰 이전" 으로 몰려 조용히 사라진다. 버려야 한다.
    func testUnparsableTimestampIsExcludedNotBucketedAsAncient() {
        let info = pr(threads: [
            PRReviewThread(id: "t1", path: "A.swift", line: 10, isResolved: false, isOutdated: false,
                           comments: [ReviewThreadComment(author: "kai", body: "언제인지 모름", createdAt: "")]),
        ])
        XCTAssertTrue(RecheckDeltaBuilder.compute(pr: info, record: record(info)).newComments.isEmpty)
    }

    /// 우리가 올린 리뷰를 "새 코멘트" 로 도로 읽으면 자기 말을 근거로 판단하게 된다.
    func testOurOwnPostedReviewIsExcluded() {
        let marker = "<!-- \(AppInfo.markerPrefix):\(AppInfo.markerVersion):abc123def456 -->"
        let info = pr(issueComments: [
            PRIssueComment(author: "alex-kim", body: "요약입니다\n\(marker)",
                           createdAt: reviewedAt.addingTimeInterval(60)),
            PRIssueComment(author: "kai", body: "사람이 쓴 말", createdAt: reviewedAt.addingTimeInterval(120)),
        ])
        let delta = RecheckDeltaBuilder.compute(pr: info, record: record(info))
        XCTAssertEqual(delta.newComments.map(\.author), ["kai"])
    }

    func testEmptyReviewBodiesAreNotCounted() {
        let info = pr(reviewEvents: [
            PRReviewEvent(author: "sage", state: "APPROVED", submittedAt: reviewedAt.addingTimeInterval(60), body: "   "),
        ])
        XCTAssertTrue(RecheckDeltaBuilder.compute(pr: info, record: record(info)).newComments.isEmpty)
    }

    /// 이게 참이면 화면은 버튼을 내지 않고 모델도 부르지 않는다.
    func testEmptyDeltaWhenNothingChanged() {
        let info = pr(commits: [commit(reviewedSha, 0)])
        XCTAssertTrue(RecheckDeltaBuilder.compute(pr: info, record: record(info)).isEmpty)
    }

    func testCommentsAreOldestFirst() {
        let info = pr(issueComments: [
            PRIssueComment(author: "late", body: "나중", createdAt: reviewedAt.addingTimeInterval(600)),
            PRIssueComment(author: "early", body: "먼저", createdAt: reviewedAt.addingTimeInterval(60)),
        ])
        XCTAssertEqual(RecheckDeltaBuilder.compute(pr: info, record: record(info)).newComments.map(\.author),
                       ["early", "late"])
    }

    // MARK: - 적대적 리뷰에서 나온 회귀 (2026-09-09)

    /// 리뷰가 도는 몇 분 사이에 달린 코멘트. 리뷰 입력(스냅샷)에도 없고, 로컬 시계로 찍힌
    /// record.createdAt 보다도 이르다. 경계를 스냅샷 시각으로 잡지 않으면 영영 안 보인다.
    func testCommentDuringTheReviewRunIsStillNew() {
        let info = pr(issueComments: [
            PRIssueComment(author: "rio", body: "이건 이런 이유로 이렇게 했습니다",
                           createdAt: reviewedAt.addingTimeInterval(120)),
        ])
        var draft = record(info)
        draft.snapshotUpdatedAt = reviewedAt          // 리뷰가 본 스냅샷
        draft.createdAt = reviewedAt.addingTimeInterval(240)   // 모델이 끝난 시각
        let delta = RecheckDeltaBuilder.compute(pr: info, record: draft)
        XCTAssertEqual(delta.newComments.map(\.author), ["rio"])
    }

    /// 옛 기록에는 스냅샷 시각이 없다. 그때는 예전처럼 createdAt 으로 잡는다.
    func testFallsBackToCreatedAtWhenSnapshotTimeIsMissing() {
        let info = pr(issueComments: [
            PRIssueComment(author: "kai", body: "말", createdAt: reviewedAt.addingTimeInterval(60)),
        ])
        var draft = record(info)
        draft.snapshotUpdatedAt = nil
        XCTAssertEqual(RecheckDeltaBuilder.compute(pr: info, record: draft).newComments.count, 1)
    }

    /// 표기를 꺼도 마커가 붙으므로 우리가 올린 글은 계속 걸러진다.
    func testOurOwnPostIsExcludedEvenWithoutVisibleAttribution() {
        let body = PostBuilder.decorate("우리가 올린 리뷰 총평")
        let info = pr(issueComments: [
            PRIssueComment(author: "alex-kim", body: body, createdAt: reviewedAt.addingTimeInterval(60)),
        ])
        XCTAssertTrue(RecheckDeltaBuilder.compute(pr: info, record: record(info)).newComments.isEmpty)
    }
}
