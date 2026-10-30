import XCTest
@testable import PRayerCore

final class ClearedItemsTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    private func concern(_ key: String, _ title: String) -> Concern {
        Concern(issueKey: key, severity: .major, title: title, path: "A.swift", line: 10, side: .right)
    }

    private func draft(_ key: String, body: String = "본문입니다 여기에 `sink` 가 있습니다") -> DraftComment {
        DraftComment(issueKey: key, path: "A.swift", line: 10, side: .right, body: body,
                     severity: .major, anchorText: "}")
    }

    private func record(concerns: [Concern] = [],
                        questions: [AuthorQuestion]? = nil,
                        comments: [DraftCommentState] = []) -> ReviewRecord {
        let output = ReviewOutput(verdict: .comment, summaryKo: "요약", concerns: concerns,
                                  strengths: [], draftComments: comments.map(\.comment),
                                  questionsForAuthor: questions)
        return ReviewRecord(repo: repo, number: 1, headSha: "abc", baseRefName: "develop",
                            promptVersion: "v1", model: "opus", trigger: .manual, output: output,
                            comments: comments, bodyDraft: "", usage: EngineUsage(),
                            validationIssues: [])
    }

    // MARK: - 표시와 되돌리기

    func testClearingAnItemStoresTheNote() {
        var rec = record(concerns: [concern("c1", "제목")])
        let key = ReviewItemKey.concern(rec.output.concerns[0])
        XCTAssertFalse(rec.isCleared(key))
        rec.setCleared("**제목** — 확인했습니다. 문제 아닙니다", for: key)
        XCTAssertTrue(rec.isCleared(key))
        XCTAssertEqual(rec.clearedNote(for: key), "**제목** — 확인했습니다. 문제 아닙니다")
    }

    func testUnclearingRemovesIt() {
        var rec = record(concerns: [concern("c1", "제목")])
        let key = ReviewItemKey.concern(rec.output.concerns[0])
        rec.setCleared("메모", for: key)
        rec.setCleared(nil, for: key)
        XCTAssertFalse(rec.isCleared(key))
        XCTAssertNil(rec.clearedItems, "다 지우면 사전 자체를 비운다")
    }

    func testBlankNoteIsNotTreatedAsCleared() {
        var rec = record(concerns: [concern("c1", "제목")])
        let key = ReviewItemKey.concern(rec.output.concerns[0])
        rec.setCleared("   ", for: key)
        XCTAssertNil(rec.clearedNote(for: key), "빈 줄을 본문에 올리면 안 된다")
    }

    /// 본문에 "확인했다" 고 쓰면서 같은 자리에 지적을 또 올리면 말이 안 된다.
    func testClearingADraftCommentAlsoStopsItFromBeingPosted() {
        var rec = record(comments: [DraftCommentState(comment: draft("d1"))])
        XCTAssertTrue(rec.comments[0].isPostable)
        rec.setCleared("확인했습니다", for: ReviewItemKey.draft(rec.comments[0].comment))
        XCTAssertFalse(rec.comments[0].isPostable)
    }

    // MARK: - 키

    /// 우려사항과 코멘트 초안은 같은 issue_key 를 쓸 수 있다. 한 사전에 담기므로 섞이면 안 된다.
    func testConcernAndDraftWithSameIssueKeyDoNotCollide() {
        var rec = record(concerns: [concern("same", "제목")],
                         comments: [DraftCommentState(comment: draft("same"))])
        rec.setCleared("우려사항만 정리", for: ReviewItemKey.concern(rec.output.concerns[0]))
        XCTAssertFalse(rec.isCleared(ReviewItemKey.draft(rec.comments[0].comment)))
        XCTAssertTrue(rec.comments[0].isPostable, "코멘트는 그대로 올라가야 한다")
    }

    /// 질문에는 issue_key 가 없다. 앱을 다시 켜도 같은 키가 나와야 저장한 표시를 찾는다.
    func testQuestionKeyIsStableAcrossRuns() {
        let question = AuthorQuestion(question: "이 구독은 언제 해제됩니까?", rationaleKo: nil, evidence: nil)
        XCTAssertEqual(ReviewItemKey.question(question), ReviewItemKey.question(question))
        XCTAssertEqual(ReviewItemKey.stableHash("같은 글"), ReviewItemKey.stableHash("같은 글"))
        XCTAssertNotEqual(ReviewItemKey.stableHash("가"), ReviewItemKey.stableHash("나"))
    }

    func testQuestionKeyIgnoresSurroundingWhitespace() {
        let a = AuthorQuestion(question: "질문", rationaleKo: nil, evidence: nil)
        let b = AuthorQuestion(question: "  질문\n", rationaleKo: nil, evidence: nil)
        XCTAssertEqual(ReviewItemKey.question(a), ReviewItemKey.question(b))
    }

    // MARK: - 게시 본문

    func testComposedBodyGetsTheClearedSectionWithAHeading() {
        var rec = record(concerns: [concern("c1", "제목")])
        rec.setCleared("**구독 저장** — 누락 아닙니다", for: ReviewItemKey.concern(rec.output.concerns[0]))
        let body = PostBuilder.composedBody(record: rec)
        XCTAssertTrue(body.contains("### 확인했고 문제없던 것"),
                      "제목이 없으면 작성자가 지적 목록으로 읽는다")
        XCTAssertTrue(body.contains("- **구독 저장** — 누락 아닙니다"))
    }

    func testClearedSectionIsAbsentWhenNothingCleared() {
        let body = PostBuilder.composedBody(record: record(concerns: [concern("c1", "제목")]))
        XCTAssertFalse(body.contains(PostBuilder.clearedHeading))
    }

    /// 사전은 순서가 없다. 본문이 매번 뒤바뀌면 안 된다.
    func testClearedNotesFollowTheReviewOrder() {
        var rec = record(concerns: [concern("c1", "첫째"), concern("c2", "둘째")],
                         comments: [DraftCommentState(comment: draft("d1"))])
        rec.setCleared("코멘트", for: ReviewItemKey.draft(rec.comments[0].comment))
        rec.setCleared("둘째 우려", for: ReviewItemKey.concern(rec.output.concerns[1]))
        rec.setCleared("첫째 우려", for: ReviewItemKey.concern(rec.output.concerns[0]))
        XCTAssertEqual(rec.orderedClearedNotes, ["첫째 우려", "둘째 우려", "코멘트"])
    }

    func testDefaultNoteMentionsTheTopic() {
        XCTAssertEqual(PostBuilder.defaultClearedNote(topic: "구독 저장"),
                       "**구독 저장** — 확인했습니다. 문제 아닙니다")
        XCTAssertTrue(PostBuilder.defaultClearedNote(topic: "  ").contains("이 항목"))
    }

    /// 옛 기록에는 이 필드가 없다. 그대로 읽혀야 한다.
    func testOldRecordWithoutClearedItemsStillDecodes() throws {
        var rec = record(concerns: [concern("c1", "제목")])
        rec.setCleared("메모", for: ReviewItemKey.concern(rec.output.concerns[0]))
        let data = try JSONEncoder().encode(rec)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "clearedItems")
        json.removeValue(forKey: "includeCleared")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ReviewRecord.self, from: stripped)
        XCTAssertNil(decoded.clearedItems)
        XCTAssertTrue(decoded.bodyIncludesCleared, "값이 없으면 켠 것으로 본다")
        XCTAssertFalse(PostBuilder.composedBody(record: decoded).contains(PostBuilder.clearedHeading))
    }
}
