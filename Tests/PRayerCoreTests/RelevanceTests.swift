import XCTest
@testable import PRayerCore

final class RelevanceTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    // MARK: - 후보 수집

    /// 낱말이 하나도 겹치지 않는 코멘트도 후보에는 들어가야 한다 —
    /// 그러지 않으면 모델이 볼 기회조차 없다(실측: 초안은 .sink, 스레드는 addSubview).
    func testCandidatesKeepMessagesWithNoSharedWords() {
        let info = pr(threads: [
            PRReviewThread(id: "t1", path: "Feed.swift", line: nil, isResolved: false, isOutdated: true,
                           comments: [ReviewThreadComment(author: "kai",
                                                          body: "addSubview 는 맨 위로 이동입니다",
                                                          createdAt: now.ISO8601Format())]),
        ], issueComments: [
            PRIssueComment(author: "sage", body: "QA 통과했습니다", createdAt: now),
        ])
        let candidates = RelatedDiscussionBuilder.candidates(pr: info, path: "Feed.swift",
                                                             line: 267, prAuthor: "rio")
        XCTAssertEqual(candidates.messageCount, 2, "낱말이 안 겹쳐도 후보에는 남는다")

        // 낱말 기반(build)은 같은 입력에서 PR 대화를 걸러 낸다 — 그래서 AI 판정이 필요하다.
        let keywordOnly = RelatedDiscussionBuilder.build(pr: info, path: "Feed.swift", line: 267,
                                                          anchorText: "}", commentBody: "`.sink` 결과",
                                                          prAuthor: "rio")
        XCTAssertTrue(keywordOnly.comments.isEmpty)
    }

    /// 프롬프트와 결과를 이어 주는 id 는 짧고, 같은 입력이면 늘 같아야 한다.
    func testCandidateIDsAreShortAndStable() {
        let info = pr(issueComments: [
            PRIssueComment(author: "a", body: "첫", createdAt: now.addingTimeInterval(-60)),
            PRIssueComment(author: "b", body: "둘", createdAt: now),
        ])
        let first = RelatedDiscussionBuilder.candidates(pr: info, path: "Feed.swift", line: 1, prAuthor: "rio")
        let second = RelatedDiscussionBuilder.candidates(pr: info, path: "Feed.swift", line: 1, prAuthor: "rio")
        XCTAssertEqual(first.comments.map(\.id), ["m1", "m2"])
        XCTAssertEqual(first.comments.map(\.id), second.comments.map(\.id))
        XCTAssertEqual(first.comments.map(\.body), ["첫", "둘"], "오래된 것부터 놓는다")
    }

    func testMessagesByIDCoversThreadsAndComments() {
        let info = pr(threads: [
            PRReviewThread(id: "t1", path: "Feed.swift", line: 10, isResolved: false, isOutdated: false,
                           comments: [ReviewThreadComment(author: "kai", body: "인라인", createdAt: now.ISO8601Format())]),
        ], issueComments: [PRIssueComment(author: "sage", body: "대화", createdAt: now)])
        let candidates = RelatedDiscussionBuilder.candidates(pr: info, path: "Feed.swift", line: 10, prAuthor: "rio")
        let map = RelatedDiscussionBuilder.messagesByID(candidates)
        XCTAssertEqual(Set(map.keys), ["m1", "m2"])
        XCTAssertEqual(map["m1"]?.body, "인라인")
    }

    // MARK: - 프롬프트

    func testPromptCarriesIDsAndAuthorFlag() {
        let info = pr(issueComments: [PRIssueComment(author: "rio", body: "고쳤습니다", createdAt: now)])
        let candidates = RelatedDiscussionBuilder.candidates(pr: info, path: "Feed.swift", line: 1, prAuthor: "rio")
        let prompt = RelevancePromptBuilder.build(
            pr: info,
            target: RelevancePromptBuilder.Target(path: "Feed.swift", line: 1, body: "초안 본문"),
            discussion: candidates)
        XCTAssertTrue(prompt.contains("id=\"m1\""))
        XCTAssertTrue(prompt.contains("author_is_pr_author=\"true\""))
        XCTAssertTrue(prompt.contains("<item path=\"Feed.swift\" line=\"1\">"))
    }

    func testEmptyDiscussionSaysSo() {
        let info = pr()
        let prompt = RelevancePromptBuilder.build(
            pr: info,
            target: RelevancePromptBuilder.Target(path: "Feed.swift", line: 1, body: "초안"),
            discussion: RelatedDiscussionBuilder.candidates(pr: info, path: "Feed.swift", line: 1, prAuthor: "rio"))
        XCTAssertTrue(prompt.contains("<messages>없음</messages>"))
    }

    /// 예산을 넘으면 오래된 것부터 버린다 — 결론은 대화 끝에 나온다.
    func testOldestMessagesAreDroppedFirst() {
        let long = String(repeating: "가", count: RelevancePromptBuilder.maxBodyChars)
        let comments = (0..<20).map {
            PRIssueComment(author: "a", body: "\($0)-" + long, createdAt: now.addingTimeInterval(Double($0)))
        }
        let info = pr(issueComments: comments)
        let candidates = RelatedDiscussionBuilder.candidates(pr: info, path: "P.swift", line: 1, prAuthor: "x")
        let block = RelevancePromptBuilder.messagesBlock(discussion: candidates, prAuthor: "x")
        XCTAssertLessThanOrEqual(block.count, RelevancePromptBuilder.maxTotalChars + 2_000)
        XCTAssertTrue(block.contains("19-"), "가장 최근 것은 남는다")
        XCTAssertFalse(block.contains("0-"), "가장 오래된 것이 먼저 빠진다")
    }

    // MARK: - 결과 해석

    func testVerdictLabels() {
        XCTAssertEqual(DiscussionRelevance.Verdict.alreadyResolved.label, "이미 확인됨")
        XCTAssertEqual(DiscussionRelevance.Relevance.resolution.label, "결론")
    }

    func testDecodesModelOutput() throws {
        let json = """
        {"summary_ko":"kai 가 짚고 rio 이 고쳤습니다","verdict":"already_resolved",
         "related":[{"message_id":"m1","relevance":"resolution","quotes":["누락 아닙니다"],"why_ko":"문제가 아니라고 결론냈습니다"}]}
        """
        let decoded = try JSONDecoder().decode(RelevanceOutput.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.verdict, .alreadyResolved)
        XCTAssertEqual(decoded.related.first?.relevance, .resolution)
        XCTAssertEqual(decoded.related.first?.quotes, ["누락 아닙니다"])
    }

    func testMatchLookupByMessageID() {
        let result = DiscussionRelevance(key: "k", summaryKo: "요약", verdict: .underDiscussion,
                                         matches: [.init(messageID: "m2", relevance: .sameIssue,
                                                         quotes: ["대목"], whyKo: "이유")])
        XCTAssertEqual(result.match(for: "m2")?.relevance, .sameIssue)
        XCTAssertNil(result.match(for: "m1"))
    }
}
