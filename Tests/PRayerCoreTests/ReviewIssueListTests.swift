import XCTest
@testable import PRayerCore

/// AI 리뷰 탭 오른쪽 "지적" 목록 — 우려사항·질문·초안을 하나로 합치고, 지적마다 올릴 자리를 하나만 고른다.
final class ReviewIssueListTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")
    private var diff: ParsedDiff { DiffParser.parse(DiffParserTests.sample, excluding: ["*.pbxproj"]) }

    private func concern(_ key: String, line: Int? = 11) -> Concern {
        Concern(issueKey: key, severity: .major, title: "\(key) 제목", path: "Sources/Foo.swift", line: line, side: .right)
    }

    private func draft(_ key: String, line: Int = 11, include: Bool = true) -> DraftCommentState {
        DraftCommentState(comment: DraftComment(issueKey: key, path: "Sources/Foo.swift", line: line, side: .right,
                                                body: "`size.width` 만 보면 높이 변경을 놓칩니다. 가드를 넓히면 어떨까요?",
                                                severity: .major, anchorText: "x"),
                          include: include)
    }

    private func record(concerns: [Concern], questions: [AuthorQuestion] = [], comments: [DraftCommentState]) -> ReviewRecord {
        let output = ReviewOutput(verdict: .comment, summaryKo: "요약", concerns: concerns,
                                  strengths: [], draftComments: comments.map(\.comment), questionsForAuthor: questions,
                                  concernsNoteKo: "우려 안내", questionsNoteKo: "질문 안내")
        return ReviewRecord(repo: repo, number: 1, headSha: "abc", baseRefName: "develop",
                            promptVersion: "v1", model: "opus", trigger: .manual, output: output,
                            comments: comments, bodyDraft: "", usage: EngineUsage(), validationIssues: [])
    }

    private let question = AuthorQuestion(question: "Split View 절반일 때 2단이 맞나요?", rationaleKo: "의도 확인",
                                          evidence: [CodeEvidence(path: "Sources/Foo.swift", line: 12, note: "근거")])

    /// 같은 issue_key 의 우려사항과 초안은 지적 하나다(실측: 우려사항 54건 중 40건이 이렇다).
    func testConcernAndDraftWithTheSameKeyBecomeOneIssue() {
        let rec = record(concerns: [concern("same"), concern("alone")], questions: [question],
                         comments: [draft("same"), draft("orphan", line: 12)])
        let issues = rec.issues
        XCTAssertEqual(issues.map(\.kind), [.concern, .concern, .draftOnly, .question])
        XCTAssertEqual(issues[0].draftIssueKey, "same")
        XCTAssertNil(issues[1].draftIssueKey)
        XCTAssertEqual(issues[2].title, "`size.width` 만 보면 높이 변경을 놓칩니다.", "코드 안의 점에서 끊지 않는다")
        XCTAssertNil(issues[3].severity, "질문은 심각도가 없다 — blocker 로 세지 않는다")
        XCTAssertEqual(issues[3].place, "Foo.swift:12")
    }

    /// 기본값은 예전과 같다: 초안이 켜진 것은 코드 옆, 나머지는 안 올림(본문 절 체크 기본값이 꺼짐).
    func testDefaultsMatchTheOldScreen() {
        let rec = record(concerns: [concern("same"), concern("alone")], questions: [question], comments: [draft("same")])
        XCTAssertEqual(rec.issues.map { rec.placement(of: $0) }, [.code, .off, .off])
    }

    /// 코드 옆 ↔ 본문은 배타적이다. 본문으로 옮기면 초안은 꺼지고 본문에 한 줄이 생긴다.
    func testMovingAPairedConcernToTheBodyTurnsTheDraftOff() {
        var rec = record(concerns: [concern("same")], comments: [draft("same")])
        let issue = rec.issues[0]
        XCTAssertTrue(rec.setPlacement(.body, for: issue, diff: diff))
        XCTAssertEqual(rec.placement(of: issue), .body)
        XCTAssertFalse(rec.comments[0].include)
        XCTAssertTrue(PostBuilder.composedBody(record: rec).contains("- [높음] same 제목"))

        XCTAssertTrue(rec.setPlacement(.code, for: issue, diff: diff))
        XCTAssertTrue(rec.comments[0].include)
        XCTAssertFalse(PostBuilder.composedBody(record: rec).contains("same 제목"), "코드 옆이면 본문에서 빠진다")
    }

    /// 초안 없는 질문을 코드 옆에 달면 초안이 생기고, 본문으로 되돌리면 그 초안은 지운다(짝 없는 초안으로 남지 않게).
    func testQuestionToCodeCreatesADraftAndBackRemovesIt() {
        var rec = record(concerns: [], questions: [question], comments: [])
        let issue = rec.issues[0]
        XCTAssertNil(rec.codeBlockedReason(for: issue, diff: diff))
        XCTAssertTrue(rec.setPlacement(.code, for: issue, diff: diff))
        XCTAssertEqual(rec.comments.count, 1)
        XCTAssertEqual(rec.issues.count, 1, "옮겨 만든 초안은 질문에 붙어 따로 뜨지 않는다")
        XCTAssertEqual(rec.placement(of: rec.issues[0]), .code)

        XCTAssertTrue(rec.setPlacement(.body, for: rec.issues[0], diff: diff))
        XCTAssertTrue(rec.comments.isEmpty)
        XCTAssertTrue(PostBuilder.composedBody(record: rec).contains("Split View 절반일 때 2단이 맞나요?"))
    }

    /// diff 밖 줄은 코드 옆에 달 수 없다(GitHub 이 리뷰 전체를 거부한다). 이유를 말하고 자리는 그대로다.
    func testLineOutsideTheDiffStaysPut() {
        var rec = record(concerns: [concern("far", line: 40)], comments: [])
        let issue = rec.issues[0]
        XCTAssertNotNil(rec.codeBlockedReason(for: issue, diff: diff))
        XCTAssertFalse(rec.setPlacement(.code, for: issue, diff: diff))
        XCTAssertEqual(rec.placement(of: issue), .off)
    }

    /// 처음 고를 때 지금 본문에 실리던 항목은 그대로 남는다 — 하나를 고른다고 다른 줄이 사라지면 안 된다.
    func testFirstPickKeepsWhatWasAlreadyInTheBody() {
        var rec = record(concerns: [concern("a"), concern("b")], comments: [])
        rec.includeConcerns = true
        XCTAssertTrue(rec.setPlacement(.off, for: rec.issues[0], diff: diff))
        XCTAssertEqual(rec.bodyConcerns.map(\.issueKey), ["b"])
    }

    /// 초안만 있는 것은 본문용 한 줄이 없어 "본문에" 를 고를 수 없다.
    func testDraftOnlyOffersCodeOrOff() {
        let rec = record(concerns: [], comments: [draft("orphan")])
        XCTAssertEqual(rec.placements(for: rec.issues[0]), [.code, .off])
    }

    func testBodyKeysSurviveEncodingAndOldRecordsStillDecode() throws {
        var rec = record(concerns: [concern("a")], comments: [])
        rec.setPlacement(.body, for: rec.issues[0], diff: diff)
        let decoded = try JSONDecoder().decode(ReviewRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.bodyIssueKeys, ["concern:a"])
    }
    // MARK: - 바로 달기

    /// 초안이 붙은 지적은 초안 자리와 고친 글로 달고, 숨은 마커가 붙는다.
    func testInlineCommentUsesTheDraftAndAddsTheMarker() throws {
        var rec = record(concerns: [concern("same")], comments: [draft("same")])
        rec.comments[0].editedBody = "고친 글"
        let comment = try XCTUnwrap(rec.inlineComment(for: rec.issues[0], body: nil, diff: diff))
        XCTAssertEqual(comment.path, "Sources/Foo.swift")
        XCTAssertEqual(comment.line, 11)
        XCTAssertEqual(comment.side, "RIGHT")
        XCTAssertTrue(comment.body.hasPrefix("고친 글"))
        XCTAssertTrue(comment.body.contains("<!-- \(AppInfo.markerPrefix):"), "마커가 없으면 다음 확인에서 남의 글로 잡힌다")
    }

    /// 초안 없는 질문은 diff 안 근거 자리에 화면에서 고친 글로 단다.
    func testInlineCommentForAQuestionUsesTheEditedText() throws {
        let rec = record(concerns: [], questions: [question], comments: [])
        let comment = try XCTUnwrap(rec.inlineComment(for: rec.issues[0], body: "이렇게 물어볼게요", diff: diff))
        XCTAssertEqual(comment.line, 12)
        XCTAssertTrue(comment.body.hasPrefix("이렇게 물어볼게요"))
    }

    func testNothingToPostOutsideTheDiffOrWithEmptyText() {
        let far = record(concerns: [concern("far", line: 40)], comments: [])
        XCTAssertNil(far.inlineComment(for: far.issues[0], body: nil, diff: diff))
        let q = record(concerns: [], questions: [question], comments: [])
        XCTAssertNil(q.inlineComment(for: q.issues[0], body: "   ", diff: diff))
    }

    /// 단 것은 기록하고, 붙은 초안은 꺼서 다른 게시 경로가 같은 코멘트를 또 올리지 않게 한다.
    func testMarkingPostedTurnsTheDraftOff() throws {
        var rec = record(concerns: [concern("same")], comments: [draft("same")])
        let issue = rec.issues[0]
        rec.markPostedInline(PostedComment(commentID: 7, htmlURL: "https://example.com/c/7", postedAt: Date()), for: issue)
        XCTAssertEqual(rec.postedComment(for: issue)?.commentID, 7)
        XCTAssertFalse(rec.comments[0].include)
        let decoded = try JSONDecoder().decode(ReviewRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.postedComment(for: issue)?.commentID, 7)
    }
    // MARK: - 중요도

    /// 치명 → 필수, 높음·보통 → 권장, 사소·질문 → 참고. 필수만 머지를 막는다.
    func testImportanceMapsSeverityAndQuestions() {
        XCTAssertEqual(ReviewImportance(severity: .blocker), .required)
        XCTAssertEqual(ReviewImportance(severity: .major), .recommended)
        XCTAssertEqual(ReviewImportance(severity: .minor), .recommended)
        XCTAssertEqual(ReviewImportance(severity: .nit), .informational)
        XCTAssertEqual(ReviewImportance(severity: nil), .informational, "질문은 심각도가 없어 참고")
        XCTAssertEqual(ReviewImportance.allCases.map(\.label), ["필수", "권장", "참고"])
        XCTAssertTrue(ReviewImportance.required < .recommended && ReviewImportance.recommended < .informational)

        let rec = record(concerns: [concern("a")], questions: [question], comments: [])
        XCTAssertEqual(rec.issues.map(\.importance), [.recommended, .informational])
        XCTAssertFalse(rec.issues.contains(where: \.isBlocking))
    }
}
