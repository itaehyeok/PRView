import XCTest
@testable import PRayerCore

final class RelatedDiscussionTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let anchor = ".sink { [weak self] _ in self?.reloadHeaderView() }"

    private func iso(_ offsetHours: Double) -> String {
        now.addingTimeInterval(offsetHours * 3600).ISO8601Format()
    }

    private func pr(threads: [PRReviewThread] = [],
                    issueComments: [PRIssueComment] = [],
                    reviewEvents: [PRReviewEvent] = []) -> PullRequestInfo {
        PullRequestInfo(repo: repo, number: 133, nodeID: "n", title: "제목", bodyText: "",
                        author: "rio", isDraft: false, state: "OPEN",
                        createdAt: now, updatedAt: now, headRefOid: "abc", headRefName: "f",
                        baseRefName: "main", additions: 32, deletions: 0, changedFiles: 1,
                        mergeable: .mergeable, mergeStateStatus: nil, reviewDecision: nil,
                        approvals: [], labels: [], viewerDidAuthor: false,
                        viewerHasReviewRequest: true, viewerLatestReviewState: nil,
                        viewerLatestReviewCommit: nil, checkState: nil,
                        threads: threads, commits: [],
                        reviewEvents: reviewEvents, issueComments: issueComments,
                        mergedAt: nil, mergedBy: nil, closedAt: nil)
    }

    private func thread(id: String, line: Int?, path: String? = "Feed.swift",
                        resolved: Bool = false, outdated: Bool = false,
                        comments: [ReviewThreadComment]) -> PRReviewThread {
        PRReviewThread(id: id, path: path, line: line,
                       isResolved: resolved, isOutdated: outdated, comments: comments)
    }

    private func build(_ info: PullRequestInfo, line: Int? = 267) -> RelatedDiscussion {
        RelatedDiscussionBuilder.build(pr: info, path: "Feed.swift", line: line,
                                       anchorText: anchor, prAuthor: "rio")
    }

    // MARK: - 무엇을 끌어오는가

    func testSameLineThreadIsFoundAndKeptWhole() {
        // 지적과 무관해 보이는 답글까지 통째로 가져와야 맥락이 읽힌다.
        let info = pr(threads: [
            thread(id: "t1", line: 267, comments: [
                ReviewThreadComment(author: "claude[bot]", body: ".sink 결과를 저장하지 않습니다", createdAt: iso(-5)),
                ReviewThreadComment(author: "kai", body: "저도 같은 생각입니다", createdAt: iso(-4)),
            ]),
        ])
        let result = build(info)
        XCTAssertEqual(result.threads.count, 1)
        XCTAssertEqual(result.threads[0].relevance, .sameLine)
        XCTAssertEqual(result.threads[0].messages.count, 2, "본문이 안 겹치는 답글도 맥락으로 남긴다")
    }

    func testThreadMessagesAreOldestFirst() {
        let info = pr(threads: [
            thread(id: "t1", line: 267, comments: [
                ReviewThreadComment(author: "kai", body: "나중 글", createdAt: iso(-1)),
                ReviewThreadComment(author: "claude[bot]", body: "먼저 글", createdAt: iso(-9)),
            ]),
        ])
        XCTAssertEqual(build(info).threads[0].messages.map(\.body), ["먼저 글", "나중 글"])
    }

    /// 같은 파일의 스레드는 다 가져오되, 왜 가져왔는지가 등급으로 구분돼야 한다.
    /// 자리로만 걸러 내면 GitHub 이 line 을 null 로 주는 outdated 스레드가 통째로 빠진다(실측).
    func testSameFileThreadsAreRankedNotDropped() {
        let info = pr(threads: [
            thread(id: "far", line: 900, comments: [ReviewThreadComment(author: "kai", body: "먼 곳", createdAt: iso(-2))]),
            thread(id: "near", line: 270, comments: [ReviewThreadComment(author: "kai", body: "근처", createdAt: iso(-2))]),
        ])
        let result = build(info)
        XCTAssertEqual(result.threads.map(\.id), ["near", "far"], "관련이 확실한 것이 먼저")
        XCTAssertEqual(result.threads.map(\.relevance), [.nearby, .sameFile])
    }

    func testThreadOnAnotherFileIsExcluded() {
        let info = pr(threads: [
            thread(id: "other", line: 267, path: "Other.swift",
                   comments: [ReviewThreadComment(author: "kai", body: "다른 파일", createdAt: iso(-2))]),
        ])
        XCTAssertTrue(build(info).isEmpty)
    }

    /// 줄 정보가 없는(outdated) 스레드도 같은 파일이면 맥락으로 남는다.
    func testThreadWithNoLineSurvives() {
        let info = pr(threads: [
            thread(id: "noline", line: nil, outdated: true,
                   comments: [ReviewThreadComment(author: "kai", body: "줄이 밀린 지적", createdAt: iso(-30))]),
        ])
        let result = build(info)
        XCTAssertEqual(result.threads.map(\.id), ["noline"])
        XCTAssertEqual(result.threads[0].relevance, .sameFile)
        XCTAssertFalse(result.hasDirectMatch, "같은 파일 맥락뿐이면 '바로 그 얘기' 라고 하지 않는다")
    }

    func testOutdatedThreadIsFoundByWordingWhenLineMoved() {
        // 커밋이 쌓이면 줄 번호가 밀린다. 문구가 겹치면 자리와 무관하게 끌어온다.
        let info = pr(threads: [
            thread(id: "moved", line: 12, outdated: true, comments: [
                ReviewThreadComment(author: "claude[bot]",
                                    body: "reloadHeaderView 가 호출되지 않습니다", createdAt: iso(-20)),
            ]),
        ])
        let result = build(info)
        XCTAssertEqual(result.threads.map(\.id), ["moved"])
        XCTAssertEqual(result.threads[0].relevance, .wording)
        XCTAssertTrue(result.threads[0].isOutdated)
        XCTAssertTrue(result.hasDirectMatch)
    }

    func testSameLineThreadsComeFirst() {
        let info = pr(threads: [
            thread(id: "near", line: 265, comments: [ReviewThreadComment(author: "kai", body: "근처", createdAt: iso(-2))]),
            thread(id: "exact", line: 267, comments: [ReviewThreadComment(author: "kai", body: "그 줄", createdAt: iso(-2))]),
        ])
        XCTAssertEqual(build(info).threads.map(\.id), ["exact", "near"])
    }

    func testUnrelatedConversationIsNotDraggedIn() {
        // 자리 없는 코멘트는 문구가 겹칠 때만 가져온다. 아니면 PR 대화가 통째로 딸려 온다.
        let info = pr(issueComments: [
            PRIssueComment(author: "sage", body: "QA 통과했습니다", createdAt: now.addingTimeInterval(-3600)),
            PRIssueComment(author: "kai", body: "reloadHeaderView 쪽은 확인했나요?", createdAt: now.addingTimeInterval(-1800)),
        ])
        let result = build(info)
        XCTAssertEqual(result.comments.map(\.author), ["kai"])
    }

    /// 이 파일에 오간 이야기가 없고 문구도 안 겹치면 아무것도 없다고 말한다.
    /// (같은 파일의 다른 줄 스레드는 맥락으로 남는다 — testSameFileThreadsAreRankedNotDropped)
    func testEmptyWhenNothingOnThisFile() {
        let info = pr(threads: [
            thread(id: "t1", line: 900, path: "Other.swift",
                   comments: [ReviewThreadComment(author: "kai", body: "다른 얘기", createdAt: iso(-2))]),
        ], issueComments: [
            PRIssueComment(author: "sage", body: "QA 통과", createdAt: now.addingTimeInterval(-60)),
        ])
        XCTAssertTrue(build(info).isEmpty)
    }

    // MARK: - 작성자 답변

    func testAuthorReplyIsMarked() {
        let info = pr(threads: [
            thread(id: "t1", line: 267, comments: [
                ReviewThreadComment(author: "claude[bot]", body: ".sink 결과 미저장", createdAt: iso(-5)),
                ReviewThreadComment(author: "rio", body: "다음 커밋에서 store 붙였습니다", createdAt: iso(-1)),
            ]),
        ])
        let result = build(info)
        XCTAssertEqual(result.threads[0].messages.map(\.isAuthorReply), [false, true])
        XCTAssertTrue(result.hasAuthorReply)
    }

    func testAuthorMatchIgnoresCase() {
        let info = pr(threads: [
            thread(id: "t1", line: 267, comments: [ReviewThreadComment(author: "RIO", body: "고쳤습니다", createdAt: iso(-1))]),
        ])
        XCTAssertTrue(build(info).threads[0].messages[0].isAuthorReply)
    }

    // MARK: - 강조할 문구

    func testQuotedAnchorIsHighlightedVerbatim() {
        let body = "여기 `\(anchor)` 의 결과가 버려집니다"
        let tokens = RelatedDiscussionBuilder.distinctiveTokens(anchor)
        XCTAssertEqual(RelatedDiscussionBuilder.highlights(in: body, anchorText: anchor, tokens: tokens),
                       [anchor], "코드가 통째로 인용됐으면 그것만 집어 준다")
    }

    func testIdentifiersAreHighlightedWhenCodeIsNotQuoted() {
        let tokens = RelatedDiscussionBuilder.distinctiveTokens(anchor)
        let found = RelatedDiscussionBuilder.highlights(in: "reloadHeaderView 가 안 불립니다",
                                                        anchorText: anchor, tokens: tokens)
        XCTAssertEqual(found, ["reloadHeaderView"])
    }

    func testCommonKeywordsAreNotTokens() {
        // self·weak·return 같은 낱말을 강조하면 본문이 온통 색칠된다.
        let tokens = RelatedDiscussionBuilder.distinctiveTokens(anchor)
        XCTAssertFalse(tokens.contains("self"))
        XCTAssertFalse(tokens.contains("weak"))
        XCTAssertTrue(tokens.contains("sink"))
        XCTAssertTrue(tokens.contains("reloadHeaderView"))
    }

    func testShortAnchorDoesNotMatchEverything() {
        let tokens = RelatedDiscussionBuilder.distinctiveTokens("x = 1")
        XCTAssertTrue(tokens.isEmpty)
        XCTAssertFalse(RelatedDiscussionBuilder.matches(body: "아무 말", anchorText: "x = 1", tokens: tokens))
    }

    // MARK: - 실측에서 나온 함정

    /// 모델이 주는 anchor_text 가 `}` 한 글자인 초안이 실제로 있었다.
    /// 그것만 보면 강조할 문구도, 걸릴 코멘트도 0건이 된다. 초안 본문의 백틱 코드를 함께 봐야 한다.
    func testTokensComeFromCommentBodyWhenAnchorIsUseless() {
        let body = "위 `.sink { [weak self] _ in self?.reloadHeaderView() }` 의 결과가 저장되지 않습니다. "
            + "`.store(in: &cancellables)` 를 붙여야 합니다."
        XCTAssertTrue(RelatedDiscussionBuilder.distinctiveTokens("}").isEmpty, "앵커만으로는 아무것도 못 뽑는다")
        let tokens = RelatedDiscussionBuilder.distinctiveTokens("}", commentBody: body)
        XCTAssertTrue(tokens.contains("reloadHeaderView"))
        XCTAssertTrue(tokens.contains("cancellables"))
        XCTAssertTrue(tokens.contains("sink"))
    }

    /// 그 지적이 인라인 스레드가 아니라 PR 대화 코멘트에 있는 경우(claude[bot] 의 리뷰 총평).
    /// 작성자의 답변도 같은 방식으로 걸려야 한다.
    func testFindsBotReviewAndAuthorReplyInIssueComments() {
        let body = "위 `.sink` 결과인 AnyCancellable 이 저장되지 않습니다. `.store(in: &cancellables)` 를 붙여야 합니다."
        let info = pr(issueComments: [
            PRIssueComment(author: "claude", body: "Critical: sink 결과 미저장 — cancellables 에 담아야 합니다",
                           createdAt: now.addingTimeInterval(-7200)),
            PRIssueComment(author: "sage-h", body: "QA 통과했습니다", createdAt: now.addingTimeInterval(-3600)),
            PRIssueComment(author: "rio", body: "cancellables 에 담도록 고쳤습니다", createdAt: now.addingTimeInterval(-600)),
        ])
        let result = RelatedDiscussionBuilder.build(pr: info, path: "Feed.swift", line: 267,
                                                    anchorText: "}", commentBody: body, prAuthor: "rio")
        XCTAssertEqual(result.comments.map(\.author), ["claude", "rio"], "관계없는 QA 코멘트는 빼고 순서대로")
        XCTAssertEqual(result.comments.map(\.isAuthorReply), [false, true])
        XCTAssertTrue(result.comments[0].highlights.contains("cancellables"))
    }
}

final class HighlightedTextTests: XCTestCase {
    func testSplitsAroundTheQuote() {
        let result = HighlightedText.split("여기 sink 가 문제", quotes: ["sink"])
        XCTAssertEqual(result.segments.map(\.text), ["여기 ", "sink", " 가 문제"])
        XCTAssertEqual(result.segments.map(\.isHighlighted), [false, true, false])
    }

    func testFindsEveryOccurrence() {
        let result = HighlightedText.split("sink 와 sink", quotes: ["sink"])
        XCTAssertEqual(result.segments.filter(\.isHighlighted).count, 2)
    }

    func testMatchIgnoresCaseButKeepsOriginalLetters() {
        let result = HighlightedText.split("Sink 확인", quotes: ["sink"])
        XCTAssertEqual(result.segments.first?.text, "Sink", "본문 글자를 그대로 보여 준다")
        XCTAssertTrue(result.segments.first?.isHighlighted == true)
    }

    func testLongerQuoteWinsOverOverlappingShortOne() {
        // 짧은 조각이 먼저 칠하면 긴 인용이 두 동아리로 쪼개진다.
        let result = HighlightedText.split("store(in: &cancellables) 하세요",
                                           quotes: ["cancellables", "store(in: &cancellables)"])
        XCTAssertEqual(result.segments.first?.text, "store(in: &cancellables)")
        XCTAssertEqual(result.segments.filter(\.isHighlighted).count, 1)
    }

    func testNoQuotesGivesOneWholeSegment() {
        let result = HighlightedText.split("아무 말", quotes: [])
        XCTAssertEqual(result.segments.map(\.text), ["아무 말"])
        XCTAssertFalse(result.hasHighlight)
    }

    func testQuoteNotPresentLeavesBodyIntact() {
        let result = HighlightedText.split("아무 말", quotes: ["sink"])
        XCTAssertEqual(result.segments.map(\.text), ["아무 말"])
        XCTAssertFalse(result.hasHighlight)
    }

    func testEmptyBody() {
        XCTAssertTrue(HighlightedText.split("", quotes: ["sink"]).segments.isEmpty)
    }
}
