import XCTest
@testable import PRayerCore

final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompactBuckets() {
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(-60), now: now), "1m")
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(-12 * 60), now: now), "12m")
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(-2 * 3600), now: now), "2h")
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(-3 * 86_400), now: now), "3d")
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(-14 * 86_400), now: now), "2w")
    }

    func testFutureDatesClampToNow() {
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(600), now: now), "now")
    }

    func testAgoSuffix() {
        XCTAssertEqual(RelativeTime.ago(now.addingTimeInterval(-4 * 60), now: now), "4m ago")
        XCTAssertEqual(RelativeTime.ago(now.addingTimeInterval(-10), now: now), "just now")
    }
}

final class PRActivityBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pr(reviewEvents: [PRReviewEvent] = [],
                    issueComments: [PRIssueComment] = [],
                    threads: [PRReviewThread] = [],
                    commits: [PRCommit] = [],
                    mergedAt: Date? = nil,
                    closedAt: Date? = nil) -> PullRequestInfo {
        PullRequestInfo(repo: RepoID(owner: "acme", name: "sample-ios"),
                        number: 1, nodeID: "n", title: "t", bodyText: "", author: "riley-park-acme",
                        isDraft: false, state: "OPEN", createdAt: now.addingTimeInterval(-86_400),
                        updatedAt: now, headRefOid: "abc", headRefName: "f", baseRefName: "develop",
                        additions: 1, deletions: 0, changedFiles: 1, mergeable: .mergeable,
                        mergeStateStatus: nil, reviewDecision: nil, approvals: [], labels: [],
                        viewerDidAuthor: false, viewerHasReviewRequest: true,
                        viewerLatestReviewState: nil, viewerLatestReviewCommit: nil,
                        checkState: nil, threads: threads, commits: commits,
                        reviewEvents: reviewEvents, issueComments: issueComments,
                        mergedAt: mergedAt, closedAt: closedAt)
    }

    func testNewestFirstAndLimited() {
        let info = pr(reviewEvents: [
            PRReviewEvent(author: "a", state: "APPROVED", submittedAt: now.addingTimeInterval(-720), body: ""),
            PRReviewEvent(author: "b", state: "COMMENTED", submittedAt: now.addingTimeInterval(-60), body: "nit"),
            PRReviewEvent(author: "c", state: "CHANGES_REQUESTED", submittedAt: now.addingTimeInterval(-1_440), body: "no"),
            PRReviewEvent(author: "d", state: "APPROVED", submittedAt: now.addingTimeInterval(-9_999), body: ""),
        ])
        let result = PRActivityBuilder.build(from: info, limit: 3, now: now)
        XCTAssertEqual(result.map(\.actor), ["b", "a", "c"])
        XCTAssertEqual(result.map(\.kind), [.commented, .approved, .changesRequested])
        XCTAssertEqual(result[0].excerpt, "nit")
    }

    func testPendingReviewIsNotAnActivity() {
        let info = pr(reviewEvents: [
            PRReviewEvent(author: "a", state: "PENDING", submittedAt: now.addingTimeInterval(-60), body: "draft"),
        ])
        XCTAssertTrue(PRActivityBuilder.build(from: info, now: now).isEmpty)
    }

    func testInlineCommentFillsEmptyReviewBodyInsteadOfAddingARow() {
        let at = now.addingTimeInterval(-120)
        let iso = ISO8601DateFormatter().string(from: at)
        let info = pr(reviewEvents: [
            PRReviewEvent(author: "rio", state: "COMMENTED", submittedAt: at, body: ""),
        ], threads: [
            PRReviewThread(id: "t1", path: "A.swift", line: 3, isResolved: false, isOutdated: false,
                           comments: [ReviewThreadComment(author: "rio",
                                                          body: "Could we make this optional?",
                                                          createdAt: iso)]),
        ])
        let result = PRActivityBuilder.build(from: info, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].excerpt, "Could we make this optional?")
    }

    func testStandaloneInlineCommentBecomesItsOwnRow() {
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let info = pr(threads: [
            PRReviewThread(id: "t1", path: "A.swift", line: 3, isResolved: false, isOutdated: false,
                           comments: [ReviewThreadComment(author: "liam", body: "ping", createdAt: iso)]),
        ])
        let result = PRActivityBuilder.build(from: info, now: now)
        XCTAssertEqual(result.map(\.actor), ["liam"])
        XCTAssertEqual(result[0].kind, .commented)
    }

    func testOnlyTheNewestCommitCountsAsOnePush() {
        let info = pr(commits: [
            PRCommit(oid: "1", abbreviatedOid: "1", messageHeadline: "a",
                     committedDate: now.addingTimeInterval(-600), author: "riley"),
            PRCommit(oid: "2", abbreviatedOid: "2", messageHeadline: "b",
                     committedDate: now.addingTimeInterval(-300), author: "riley"),
        ])
        let result = PRActivityBuilder.build(from: info, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .pushed)
        XCTAssertEqual(result[0].at, now.addingTimeInterval(-300))
    }

    func testMergedWinsOverClosedAndCIIsNeverIncluded() {
        let info = pr(mergedAt: now.addingTimeInterval(-30), closedAt: now.addingTimeInterval(-30))
        let result = PRActivityBuilder.build(from: info, now: now)
        XCTAssertEqual(result.map(\.kind), [.merged])
    }

    func testExcerptCollapsesNewlinesAndTruncates() {
        XCTAssertEqual(PRActivityBuilder.excerpt("  hello \n\n world "), "hello world")
        XCTAssertNil(PRActivityBuilder.excerpt("   \n  "))
        let long = String(repeating: "x", count: 200)
        let cut = PRActivityBuilder.excerpt(long, limit: 20)
        XCTAssertEqual(cut, String(repeating: "x", count: 20) + "…")
    }

    func testLabelsAreEnglishAndShort() {
        XCTAssertEqual(PRActivity.Kind.changesRequested.label, "Requested changes")
        XCTAssertEqual(PRActivity.Kind.commented.label, "Commented")
        for kind in PRActivity.Kind.allCases {
            XCTAssertLessThanOrEqual(kind.label.count, 20, "\(kind) label too long for the list")
            XCTAssertFalse(kind.symbolName.isEmpty)
        }
    }

    /// limit: nil 이면 전부 돌려준다. "늘리기" 가 이걸 쓴다.
    func testNoLimitReturnsEverything() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let commits = (0..<6).map {
            PRCommit(oid: "sha\($0)", abbreviatedOid: "sha\($0)",
                     messageHeadline: "커밋 \($0)",
                     committedDate: now.addingTimeInterval(Double(-$0) * 3600),
                     author: "rio")
        }
        let info = pr(commits: commits)
        let capped = PRActivityBuilder.build(from: info, limit: 3, now: now)
        let full = PRActivityBuilder.build(from: info, limit: nil, collapseCommits: false, now: now)
        XCTAssertEqual(capped.count, 1, "커밋을 접으면 푸시는 1건이다")
        XCTAssertEqual(full.count, 6, "펴면 커밋마다 1건이다")
        XCTAssertEqual(Set(full.map(\.id)).count, 6, "같은 사람의 커밋들도 서로 구분돼야 한다")
        XCTAssertEqual(full.first?.excerpt, "커밋 0", "가장 최근 커밋이 맨 위, 제목이 붙는다")
    }

    // MARK: - 같은 상태의 리뷰 중복 (실측)

    private func review(_ author: String, _ state: String, _ offsetSeconds: Double,
                        body: String = "") -> PRReviewEvent {
        PRReviewEvent(author: author, state: state,
                      submittedAt: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(offsetSeconds),
                      body: body)
    }

    /// 같은 사람이 몇 초 사이에 Approve 를 두 번 냈다. 목록에 같은 줄이 두 번 떠서는 안 된다.
    func testRepeatedApprovalFromSamePersonCollapses() {
        let now = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(100)
        let info = pr(reviewEvents: [review("sage", "APPROVED", -60), review("sage", "APPROVED", -52)])
        let result = PRActivityBuilder.build(from: info, limit: nil, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].at.timeIntervalSince1970, 1_800_000_000 - 52, "가장 최근 것을 남긴다")
        XCTAssertEqual(result[0].excerpt, "같은 상태의 리뷰 2건을 하나로 묶었습니다.", "조용히 지우지 않는다")
    }

    func testDifferentPeopleAreNotCollapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(100)
        let info = pr(reviewEvents: [review("sage", "APPROVED", -60), review("lena", "APPROVED", -50)])
        XCTAssertEqual(PRActivityBuilder.build(from: info, limit: nil, now: now).count, 2)
    }

    /// 같은 사람이라도 상태가 다르면 서로 다른 이야기다.
    func testDifferentStatesFromSamePersonAreKept() {
        let now = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(100)
        let info = pr(reviewEvents: [review("sage", "CHANGES_REQUESTED", -600), review("sage", "APPROVED", -50)])
        let result = PRActivityBuilder.build(from: info, limit: nil, now: now)
        XCTAssertEqual(result.map(\.kind), [.approved, .changesRequested])
    }

    /// 코멘트는 묶지 않는다 — 두 번 코멘트한 것은 실제로 두 번 말한 것이다.
    func testCommentsAreNotCollapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(100)
        let info = pr(reviewEvents: [review("sage", "COMMENTED", -60, body: "첫 말"),
                                     review("sage", "COMMENTED", -50, body: "둘째 말")])
        XCTAssertEqual(PRActivityBuilder.build(from: info, limit: nil, now: now).count, 2)
    }
}
