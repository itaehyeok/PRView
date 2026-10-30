import XCTest
@testable import PRayerCore

final class MyPRReviewSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pr(approvals: [ApprovalInfo] = [],
                    reviewEvents: [PRReviewEvent] = [],
                    issueComments: [PRIssueComment] = [],
                    threads: [PRReviewThread] = [],
                    pending: [String] = []) -> PullRequestInfo {
        var info = PullRequestInfo(repo: RepoID(owner: "acme", name: "sample-ios"),
                                   number: 1, nodeID: "n", title: "t", bodyText: "", author: "alex-kim",
                                   isDraft: false, state: "OPEN", createdAt: now.addingTimeInterval(-86_400),
                                   updatedAt: now, headRefOid: "head", headRefName: "f", baseRefName: "develop",
                                   additions: 1, deletions: 0, changedFiles: 1, mergeable: .mergeable,
                                   mergeStateStatus: nil, reviewDecision: nil, approvals: approvals, labels: [],
                                   viewerDidAuthor: true, viewerHasReviewRequest: false,
                                   viewerLatestReviewState: nil, viewerLatestReviewCommit: nil,
                                   checkState: nil, threads: threads,
                                   reviewEvents: reviewEvents, issueComments: issueComments)
        info.pendingReviewers = pending
        return info
    }

    private func event(_ author: String, _ state: String, minutesAgo: Double, body: String = "") -> PRReviewEvent {
        PRReviewEvent(author: author, state: state, submittedAt: now.addingTimeInterval(-minutesAgo * 60), body: body)
    }

    private func thread(resolved: Bool = false, outdated: Bool = false, by authors: [String]) -> PRReviewThread {
        PRReviewThread(id: UUID().uuidString, path: "a.swift", line: 1, isResolved: resolved, isOutdated: outdated,
                       comments: authors.map { ReviewThreadComment(author: $0, body: "c", createdAt: "2027-01-15T08:00:00Z") })
    }

    /// 지금 코드에 한 승인이 먼저, 같은 무리 안에서는 최근 승인이 먼저.
    func testFreshApproversFirstThenStale() {
        let info = pr(approvals: [ApprovalInfo(login: "old", commitOid: "before"),
                                  ApprovalInfo(login: "a", commitOid: "head"),
                                  ApprovalInfo(login: "b", commitOid: "head")],
                      reviewEvents: [event("a", "APPROVED", minutesAgo: 300),
                                     event("b", "APPROVED", minutesAgo: 60),
                                     event("old", "APPROVED", minutesAgo: 10)])
        let summary = MyPRReviewSummary(pr: info)
        XCTAssertEqual(summary.approvers.map(\.login), ["b", "a", "old"])
        XCTAssertEqual(summary.approvers.map(\.isStale), [false, false, true])
    }

    func testApprovalWithoutCommitIsNotStale() {
        let info = pr(approvals: [ApprovalInfo(login: "a", commitOid: nil)])
        XCTAssertEqual(MyPRReviewSummary(pr: info).approvers.first?.isStale, false)
    }

    /// 승인 여부는 approvals 를 따른다 — 이력에 APPROVED 가 있어도 그 뒤에 변경 요청했으면 변경 요청이다.
    func testLastOpinionDecidesChangesRequested() {
        let info = pr(reviewEvents: [event("a", "APPROVED", minutesAgo: 600),
                                     event("a", "CHANGES_REQUESTED", minutesAgo: 60),
                                     event("b", "CHANGES_REQUESTED", minutesAgo: 600),
                                     event("b", "DISMISSED", minutesAgo: 30),
                                     event("c", "CHANGES_REQUESTED", minutesAgo: 90),
                                     event("c", "COMMENTED", minutesAgo: 5)])
        XCTAssertEqual(MyPRReviewSummary(pr: info).changesRequestedBy, ["a", "c"])
    }

    /// 대화 코멘트 + 코드 코멘트 + 본문 있는 리뷰. 작성자 본인 것·승인 본문·빈 리뷰 본문은 세지 않는다.
    func testCommentCount() {
        let info = pr(reviewEvents: [event("a", "COMMENTED", minutesAgo: 10),
                                     event("b", "COMMENTED", minutesAgo: 10, body: "전체 의견"),
                                     event("c", "APPROVED", minutesAgo: 10, body: "LGTM"),
                                     event("alex-kim", "COMMENTED", minutesAgo: 5, body: "답변")],
                      issueComments: [PRIssueComment(author: "bot", body: "CI", createdAt: now),
                                      PRIssueComment(author: "Alex-Kim", body: "답", createdAt: now)],
                      threads: [thread(by: ["a", "alex-kim", "a"]), thread(resolved: true, by: ["b"])])
        let summary = MyPRReviewSummary(pr: info)
        XCTAssertEqual(summary.commentCount, 5)
        XCTAssertEqual(summary.unresolvedThreadCount, 1)
    }

    /// 다시 요청받은 사람은 승인·변경 요청 쪽이 말하므로 미응답에 또 넣지 않는다. 작성자·중복도 뺀다.
    func testPendingSkipsPeopleAlreadyCounted() {
        let info = pr(approvals: [ApprovalInfo(login: "a", commitOid: "head")],
                      reviewEvents: [event("c", "CHANGES_REQUESTED", minutesAgo: 10)],
                      pending: ["A", "b", "c", "ios-team", "b", "alex-kim"])
        XCTAssertEqual(MyPRReviewSummary(pr: info).pending, ["b", "ios-team"])
    }

    func testEmpty() {
        XCTAssertTrue(MyPRReviewSummary(pr: pr()).isEmpty)
    }
}
