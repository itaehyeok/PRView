import XCTest
@testable import PRayerCore

/// "리뷰에 담기" — 코드 코멘트를 모아 두었다가 왼쪽 리뷰와 한 리뷰로 올린다.
final class ReviewBasketTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")
    private var diff: ParsedDiff { DiffParser.parse(DiffParserTests.sample, excluding: ["*.pbxproj"]) }

    private func concern(_ key: String, line: Int? = 11) -> Concern {
        Concern(issueKey: key, severity: .major, title: "\(key) 제목", path: "Sources/Foo.swift", line: line, side: .right)
    }

    private func draft(_ key: String, line: Int = 11) -> DraftCommentState {
        DraftCommentState(comment: DraftComment(issueKey: key, path: "Sources/Foo.swift", line: line, side: .right,
                                                body: "\(key) 초안 글", severity: .major, anchorText: "x"))
    }

    private func record(concerns: [Concern] = [], questions: [AuthorQuestion] = [],
                        comments: [DraftCommentState]) -> ReviewRecord {
        let output = ReviewOutput(verdict: .comment, summaryKo: "요약", concerns: concerns,
                                  strengths: [], draftComments: comments.map(\.comment), questionsForAuthor: questions,
                                  concernsNoteKo: "우려 안내", questionsNoteKo: "질문 안내")
        return ReviewRecord(repo: repo, number: 1, headSha: "abc", baseRefName: "develop",
                            promptVersion: "v1", model: "opus", trigger: .manual, output: output,
                            comments: comments, bodyDraft: "", usage: EngineUsage(), validationIssues: [])
    }

    private let question = AuthorQuestion(question: "Split View 절반일 때 2단이 맞나요?", rationaleKo: "의도 확인",
                                          evidence: [CodeEvidence(path: "Sources/Foo.swift", line: 12, note: "근거")])

    private func posted(_ id: Int) -> PostedComment {
        PostedComment(commentID: id, htmlURL: "https://example.com/c/\(id)", postedAt: Date())
    }

    // MARK: - 담기·빼기

    /// 담은 순서대로 나간다. 같은 것을 두 번 담아도 하나다.
    func testBasketKeepsTheOrderItWasFilledIn() {
        var rec = record(comments: [draft("a"), draft("b", line: 12)])
        let a = rec.issues[0], b = rec.issues[1]
        XCTAssertTrue(rec.setInBasket(true, for: b))
        XCTAssertTrue(rec.setInBasket(true, for: a))
        XCTAssertFalse(rec.setInBasket(true, for: a), "이미 담긴 것")
        XCTAssertEqual(rec.basketIssues.map(\.key), [b.key, a.key])
        XCTAssertTrue(rec.isInBasket(a))
        XCTAssertTrue(rec.setInBasket(false, for: b))
        XCTAssertEqual(rec.basketIssues.map(\.key), [a.key])
        XCTAssertTrue(rec.setInBasket(false, for: a))
        XCTAssertNil(rec.basketIssueKeys, "다 빼면 옛 기록과 같은 모양으로")
    }

    /// 리뷰를 이미 올렸거나, 그 지적을 바로 달았거나 정리했으면 담을 수 없다.
    func testCannotBasketWhatIsAlreadyDoneOrAfterPosting() {
        var rec = record(comments: [draft("a"), draft("b", line: 12), draft("c", line: 13)])
        let a = rec.issues[0], b = rec.issues[1], c = rec.issues[2]
        rec.markPostedInline(posted(1), for: a)
        rec.setCleared("확인했고 괜찮습니다", for: b.key)
        XCTAssertFalse(rec.setInBasket(true, for: a))
        XCTAssertFalse(rec.setInBasket(true, for: b))
        XCTAssertTrue(rec.setInBasket(true, for: c))
        rec.posted = PostedInfo(reviewID: 9, htmlURL: "https://example.com/r/9", event: "APPROVE",
                                postedAt: Date(), commentCount: 0)
        XCTAssertTrue(rec.basketIssues.isEmpty, "올린 리뷰에는 더 실을 수 없다")
    }

    /// "모두 담기" 는 아직 안 담았고, 달지도 정리하지도 않았고, 코드 옆에 달 자리가 있는 것만 담는다.
    func testAddAllSkipsBasketedDoneAndPlacelessIssues() {
        var rec = record(concerns: [concern("far", line: 999)],
                         comments: [draft("a"), draft("b", line: 12), draft("c", line: 13), draft("d", line: 14)])
        let all = rec.issues
        XCTAssertEqual(all.count, 5)
        func issue(_ key: String) -> ReviewIssue { all.first { $0.key.hasSuffix(key) } ?? all[0] }
        rec.setInBasket(true, for: issue("a"))
        rec.markPostedInline(posted(1), for: issue("b"))
        rec.setCleared("확인함", for: issue("c").key)
        let addable = rec.issues.filter { rec.canAddToBasket($0, diff: diff) }
        XCTAssertEqual(addable.map(\.key), [issue("d").key], "담은 a·단 b·정리한 c·diff 밖 far 는 빠진다")
    }

    /// 담은 뒤 바로 달면 담은 목록에서도 빠진다 — 같은 코멘트가 두 번 달리면 안 된다.
    func testPostingDirectlyAfterBasketingDropsItFromTheBasket() {
        var rec = record(comments: [draft("a")])
        let a = rec.issues[0]
        rec.setInBasket(true, for: a)
        rec.markPostedInline(posted(1), for: a)
        XCTAssertTrue(rec.basketIssues.isEmpty)
    }

    func testBasketSurvivesEncodingAndOldRecordsStillDecode() throws {
        var rec = record(comments: [draft("a")])
        rec.setInBasket(true, for: rec.issues[0])
        let decoded = try JSONDecoder().decode(ReviewRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.basketKeys, rec.basketKeys)

        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(comments: []))) as! [String: Any]
        plain.removeValue(forKey: "basketIssueKeys")
        let old = try JSONDecoder().decode(ReviewRecord.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertTrue(old.basketKeys.isEmpty)
    }

    // MARK: - 게시할 코멘트

    /// 초안은 고친 글, 초안 없는 질문은 카드에서 고친 글로 diff 안 자리에 만든다. 숨은 마커도 붙는다.
    func testBasketCommentsUseTheEditedText() {
        var rec = record(questions: [question], comments: [draft("a")])
        rec.comments[0].editedBody = "고친 초안"
        for issue in rec.issues { rec.setInBasket(true, for: issue) }
        let built = rec.basketComments(diff: diff, body: { $0.kind == .question ? "고친 질문" : nil })
        XCTAssertTrue(built.missing.isEmpty)
        XCTAssertEqual(built.items.map(\.comment.line), [11, 12])
        XCTAssertTrue(built.items[0].comment.body.hasPrefix("고친 초안"))
        XCTAssertTrue(built.items[1].comment.body.hasPrefix("고친 질문"))
        XCTAssertTrue(built.items.allSatisfy { $0.comment.body.contains("<!-- \(AppInfo.markerPrefix):") })
    }

    /// 자리를 못 찾은 것은 몰래 빼지 않고 따로 알린다(부르는 쪽은 그때 올리지 않는다).
    func testBasketReportsWhatHasNoPlace() {
        var rec = record(concerns: [concern("far", line: 40)], comments: [draft("a")])
        for issue in rec.issues { rec.setInBasket(true, for: issue) }
        let built = rec.basketComments(diff: diff)
        XCTAssertEqual(built.items.map(\.issue.key), [ReviewItemKey.draft(rec.comments[0].comment)])
        XCTAssertEqual(built.missing.map(\.key), [ReviewItemKey.concern(concern("far", line: 40))])
    }

    /// 리뷰 payload 에 담은 코멘트가 실린다. 본문을 비워도 COMMENT 가 422 로 거부되지 않게 기본 문구가 들어간다.
    func testPayloadCarriesTheBasket() {
        var rec = record(comments: [draft("a")])
        rec.setInBasket(true, for: rec.issues[0])
        let items = rec.basketComments(diff: diff).items
        let approve = PostBuilder.payload(record: rec, event: .approve, body: "좋아요", includeComments: false,
                                          basket: items.map(\.comment))
        XCTAssertEqual(approve.event, "APPROVE")
        XCTAssertEqual(approve.comments.count, 1)
        let comment = PostBuilder.payload(record: rec, event: .comment, body: "", includeComments: false,
                                          basket: items.map(\.comment))
        XCTAssertTrue(comment.body.hasPrefix("인라인 코멘트를 남겼습니다."))
    }

    // MARK: - 게시 뒤 짝짓기

    /// 같은 줄에 둘을 담아도 글로 갈라 제 카드에 붙인다. 순서가 뒤바뀌어 와도 된다.
    func testMatchPairsBySpotThenBody() {
        let sent = [ReviewPayload.Comment(path: "A.swift", line: 3, side: "RIGHT", body: "첫째"),
                    ReviewPayload.Comment(path: "A.swift", line: 3, side: "RIGHT", body: "둘째"),
                    ReviewPayload.Comment(path: "B.swift", line: 9, side: "RIGHT", body: "셋째")]
        let received = [ReviewCommentRef(path: "B.swift", line: 9, body: "셋째", posted: posted(30)),
                        ReviewCommentRef(path: "A.swift", line: 3, body: "둘째\r\n", posted: posted(20)),
                        ReviewCommentRef(path: "A.swift", line: 3, body: "첫째", posted: posted(10))]
        XCTAssertEqual(ReviewBasket.match(sent: sent, received: received).map { $0?.commentID }, [10, 20, 30])
    }

    /// 글이 달라졌어도(GitHub 이 손댐) 자리가 같으면 붙인다. 못 찾은 것은 nil — 리뷰 링크로 표시한다.
    func testMatchFallsBackToTheSpotAndLeavesTheRestEmpty() {
        let sent = [ReviewPayload.Comment(path: "A.swift", line: 3, side: "RIGHT", body: "원래 글"),
                    ReviewPayload.Comment(path: "C.swift", line: 1, side: "RIGHT", body: "없어짐")]
        let received = [ReviewCommentRef(path: "A.swift", line: 3, body: "바뀐 글", posted: posted(10))]
        XCTAssertEqual(ReviewBasket.match(sent: sent, received: received).map { $0?.commentID }, [10, nil])
    }

    /// 실제 `pulls/N/comments` 응답 모양(2026-10-27 샌드박스 PR 에 올려 받은 것을 줄임). 다른 리뷰의 코멘트는 빼고,
    /// `line` 으로 자리를 읽어 보낸 것과 짝짓는다. 리뷰 하나의 목록(`reviews/ID/comments`)은 `line` 이 null 로 와서
    /// 이 짝짓기가 전부 실패했었다.
    func testPairsWithThePullCommentsResponse() throws {
        let json = #"""
        [{"id": 4384173316, "pull_request_review_id": 5661131302, "path": "Sources/ListStore.swift",
          "line": 21, "original_line": 21, "side": "RIGHT", "created_at": "2026-10-27T01:14:40Z",
          "html_url": "https://github.com/o/r/pull/2#discussion_r4384173316", "body": "셋째\n\n<!-- prdeck:v1:2641ec0d09c0 -->"},
         {"id": 4384173302, "pull_request_review_id": 5661131302, "path": "Sources/Feed.swift",
          "line": 26, "original_line": 26, "side": "RIGHT", "created_at": "2026-10-27T01:14:39Z",
          "html_url": "https://github.com/o/r/pull/2#discussion_r4384173302", "body": "첫째"},
         {"id": 4300000000, "pull_request_review_id": 5600000000, "path": "Sources/Feed.swift",
          "line": 26, "original_line": 26, "side": "RIGHT", "created_at": "2026-10-20T01:00:00Z",
          "html_url": "https://github.com/o/r/pull/2#discussion_r4300000000", "body": "첫째"},
         {"id": 4384173400, "pull_request_review_id": 5661131302, "path": "Sources/Old.swift",
          "line": null, "original_line": 7, "side": "RIGHT", "created_at": "2026-10-27T01:14:41Z",
          "html_url": null, "body": "넷째"}]
        """#
        let refs = try XCTUnwrap(GitHubClient.parseReviewComments(Data(json.utf8), reviewID: 5661131302,
                                                                  fallbackURL: "https://github.com/o/r/pull/2"))
        XCTAssertEqual(refs.map(\.posted.commentID), [4384173316, 4384173302, 4384173400], "다른 리뷰(5600000000) 것은 뺀다")
        XCTAssertEqual(refs.map(\.line), [21, 26, 7], "코드가 바뀌어 line 이 비면 original_line")
        XCTAssertEqual(refs.last?.posted.htmlURL, "https://github.com/o/r/pull/2")
        let sent = [ReviewPayload.Comment(path: "Sources/Feed.swift", line: 26, side: "RIGHT", body: "첫째"),
                    ReviewPayload.Comment(path: "Sources/ListStore.swift", line: 21, side: "RIGHT",
                                          body: "셋째\n\n<!-- prdeck:v1:2641ec0d09c0 -->")]
        XCTAssertEqual(ReviewBasket.match(sent: sent, received: refs).map { $0?.commentID }, [4384173302, 4384173316])
        XCTAssertNil(GitHubClient.parseReviewComments(Data("{}".utf8), reviewID: 1, fallbackURL: ""))
    }

    /// 올린 뒤에는 카드마다 달림으로 바뀌고 담은 목록이 빈다. 짝을 못 찾은 카드는 리뷰 링크로 달림이 된다.
    func testMarkingTheBasketPosted() {
        var rec = record(comments: [draft("a"), draft("b", line: 12)])
        for issue in rec.issues { rec.setInBasket(true, for: issue) }
        let items = rec.basketComments(diff: diff).items
        let review = PostedInfo(reviewID: 9, htmlURL: "https://example.com/r/9", event: "APPROVE",
                                postedAt: Date(), commentCount: 2)
        rec.markBasketPosted(items, posted: [posted(10), nil], review: review)
        XCTAssertEqual(rec.postedComment(for: items[0].issue)?.commentID, 10)
        XCTAssertEqual(rec.postedComment(for: items[1].issue)?.htmlURL, review.htmlURL)
        XCTAssertNil(rec.basketIssueKeys)
        XCTAssertTrue(rec.comments.allSatisfy { !$0.include }, "다른 게시 경로가 같은 코멘트를 또 올리지 않게")
    }

    // MARK: - 게시 버튼

    /// 담은 줄 코멘트가 있으면 버튼 이름에 그 수를 적고, 그것을 빼고 나가는 "Approve 만" 은 막는다.
    func testButtonSaysHowManyGoAlongAndApproveOnlyIsBlocked() {
        let context = PostActionContext(hasBody: true, inlineCount: 2, hasBlocker: false, verdict: .comment,
                                        viewerDidAuthor: false, alreadyApprovedThisHead: false)
        XCTAssertEqual(PostActionPlan.buttonLabel(.commentAndApprove, in: context), "코멘트+Approve 게시 · 줄 코멘트 2개")
        XCTAssertEqual(PostActionPlan.buttonLabel(.approveOnly, in: context), "Approve 만 게시")
        XCTAssertNotNil(PostActionPlan.disabledReason(.approveOnly, in: context))
        var empty = context
        empty.inlineCount = 0
        XCTAssertEqual(PostActionPlan.buttonLabel(.commentAndApprove, in: empty), "코멘트+Approve 게시")
        XCTAssertNil(PostActionPlan.disabledReason(.approveOnly, in: empty))
    }
}
