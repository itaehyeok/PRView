import XCTest
@testable import PRayerCore

/// 목록 머리 줄의 "All · @me · Replies"(PRWhoFilter) — 나에게 온 것만 골라 본다.
final class WhoFilterTests: XCTestCase {
    private let me = "sam-lee"
    private let other = "jamie-acme"
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func iso(_ minute: Int) -> String { base.addingTimeInterval(Double(minute) * 60).ISO8601Format() }

    private func thread(_ comments: [(String, String)]) -> PRReviewThread {
        PRReviewThread(id: "T1", path: "Sources/App/Feature.swift", line: 3, isResolved: false, isOutdated: false,
                       comments: comments.enumerated().map { index, comment in
                           ReviewThreadComment(author: comment.0, body: comment.1, createdAt: iso(index))
                       })
    }

    private func pr(body: String = "", comments: [PRIssueComment] = [], threads: [PRReviewThread] = [],
                    reviews: [PRReviewEvent] = []) -> PullRequestInfo {
        var pr = Fixtures.pr()
        pr.bodyText = body
        pr.issueComments = comments
        pr.threads = threads
        pr.reviewEvents = reviews
        return pr
    }

    private func hiding(_ pr: PullRequestInfo, _ who: PRWhoFilter, scope: PRListScope = .open) -> Set<PRFilterKind> {
        PRVisibility.hidingFilters(pr: pr, state: PRFilterState(who: who, viewer: me), scope: scope, hasHiddenLabel: false)
    }

    /// 본문·대화 코멘트·리뷰 본문·코드 코멘트 어디서 불렀든 "@me" 에 든다. 내가 쓴 글·코드 안의 것은 치지 않는다.
    func testMentionsAnywhere() {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(PRWhoFilter.mentions.matches(pr(body: "@sam-lee 봐 주세요"), viewer: me))
        XCTAssertTrue(PRWhoFilter.mentions.matches(
            pr(comments: [PRIssueComment(author: other, body: "확인 부탁 @sam-lee", createdAt: at)]), viewer: me))
        XCTAssertTrue(PRWhoFilter.mentions.matches(
            pr(reviews: [PRReviewEvent(author: other, state: "COMMENTED", submittedAt: at, body: "@sam-lee 님?")]), viewer: me))
        XCTAssertTrue(PRWhoFilter.mentions.matches(pr(threads: [thread([(other, "@sam-lee 이 부분요")])]), viewer: me))
        XCTAssertFalse(PRWhoFilter.mentions.matches(
            pr(comments: [PRIssueComment(author: me, body: "@sam-lee 메모", createdAt: at)]), viewer: me))
        XCTAssertFalse(PRWhoFilter.mentions.matches(pr(body: "`@sam-lee` 예시"), viewer: me))
        XCTAssertFalse(PRWhoFilter.mentions.matches(pr(body: "@sam-lee"), viewer: nil))
    }

    /// 답글은 목록의 답글 칩이 있는 PR 과 같다 — 내가 연 스레드에 남이 단 글.
    func testReplies() {
        XCTAssertTrue(PRWhoFilter.replies.matches(pr(threads: [thread([(me, "질문"), (other, "답")])]), viewer: me))
        XCTAssertFalse(PRWhoFilter.replies.matches(pr(threads: [thread([(me, "질문")])]), viewer: me))
        XCTAssertFalse(PRWhoFilter.replies.matches(pr(threads: [thread([(other, "글"), (other, "글")])]), viewer: me))
    }

    func testHidesAndIsActiveInEveryTab() {
        let plain = pr()
        for scope in [PRListScope.open, .myApprovals(.day), .recentAll(.week)] {
            XCTAssertEqual(hiding(plain, .mentions, scope: scope), [.who], "\(scope.kind)")
            XCTAssertEqual(PRFilterState(who: .replies).active(in: scope), [.who])
        }
        XCTAssertTrue(hiding(plain, .all).isEmpty)
        XCTAssertTrue(PRFilterState().active(in: .open).isEmpty)
    }
}
