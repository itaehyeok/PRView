import XCTest
@testable import PRayerCore

final class DraftValidatorTests: XCTestCase {
    private let limits = ReviewLimits(maxComments: 6, minBodyChars: 20, maxBodyChars: 400, maxSummaryChars: 300)

    private var diff: ParsedDiff {
        DiffParser.parse(DiffParserTests.sample, excluding: ["*.pbxproj"])
    }

    private func comment(key: String = "k1",
                         line: Int = 11,
                         side: DiffSide = .right,
                         anchor: String = "        guard let x = try? compute() else { return }",
                         body: String = "이 경로에서 실패를 조용히 흘리면 상태가 어긋납니다. 실패를 UI 에 반영해주시면 어떨까요?",
                         severity: Severity = .major,
                         path: String = "Sources/Foo.swift") -> DraftComment {
        DraftComment(issueKey: key, path: path, line: line, side: side, body: body,
                     severity: severity, anchorText: anchor)
    }

    private func output(_ comments: [DraftComment],
                        verdict: Verdict = .comment,
                        concerns: [Concern] = [],
                        summary: String = "요약") -> ReviewOutput {
        ReviewOutput(verdict: verdict, summaryKo: summary, concerns: concerns,
                     strengths: [], draftComments: comments)
    }

    func testExactAnchorIsOK() {
        let result = DraftValidator.validate(output: output([comment()]), diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertEqual(result.comments[0].anchorStatus, .ok)
        XCTAssertEqual(result.comments[0].comment.line, 11)
        XCTAssertEqual(result.comments[0].comment.side, .right)
        XCTAssertTrue(result.comments[0].include)
    }

    func testWrongLineIsFixedByAnchorText() {
        let result = DraftValidator.validate(output: output([comment(line: 99)]), diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertEqual(result.comments[0].anchorStatus, .fixed)
        XCTAssertEqual(result.comments[0].comment.line, 11)
        XCTAssertEqual(result.comments[0].originalLine, 99)
    }

    func testDeletionAnchorSwitchesToLeftSide() {
        let result = DraftValidator.validate(
            output: output([comment(line: 11, side: .right, anchor: "        let x = try! compute()")]),
            diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertEqual(result.comments[0].comment.side, .left)
        XCTAssertEqual(result.comments[0].comment.line, 11)
        XCTAssertEqual(result.comments[0].anchorStatus, .fixed)
    }

    func testUnknownAnchorIsUnresolvedAndExcluded() {
        let result = DraftValidator.validate(
            output: output([comment(line: 500, anchor: "존재하지 않는 코드 줄입니다")]),
            diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertEqual(result.comments[0].anchorStatus, .unresolved)
        XCTAssertFalse(result.comments[0].include)
        XCTAssertFalse(result.comments[0].isPostable)
        XCTAssertTrue(result.issues.contains { $0.message.contains("앵커 불명") })
    }

    func testUnknownFileIsUnresolved() {
        let result = DraftValidator.validate(output: output([comment(path: "Nope.swift")]), diff: diff, limits: limits)
        XCTAssertEqual(result.comments[0].anchorStatus, .unresolved)
    }

    func testDuplicateIssueKeyIsDropped() {
        let result = DraftValidator.validate(output: output([comment(key: "same"), comment(key: "same", line: 12)]),
                                             diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertTrue(result.issues.contains { $0.message.contains("issue_key") })
    }

    func testSameLineCollapsed() {
        let a = comment(key: "a")
        let b = comment(key: "b")
        let result = DraftValidator.validate(output: output([a, b]), diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertTrue(result.issues.contains { $0.message.contains("겹쳐") })
    }

    func testCommentCapKeepsHighestSeverity() {
        let tight = ReviewLimits(maxComments: 1, minBodyChars: 20, maxBodyChars: 400, maxSummaryChars: 300)
        let nit = comment(key: "nit", line: 11, severity: .nit)
        let blocker = comment(key: "blocker", line: 12,
                              anchor: "        print(x)", severity: .blocker)
        let result = DraftValidator.validate(output: output([nit, blocker]), diff: diff, limits: tight)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertEqual(result.comments[0].comment.issueKey, "blocker")
        XCTAssertTrue(result.issues.contains { $0.message.contains("상한") })
    }

    func testLongBodyProducesIssueButKeepsComment() {
        let long = String(repeating: "가", count: 500)
        let result = DraftValidator.validate(output: output([comment(body: long)]), diff: diff, limits: limits)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertTrue(result.issues.contains { $0.message.contains("상한(400자)") })
        XCTAssertEqual(result.comments[0].editedBody.count, 500, "길이 초과를 앱이 임의로 자르지 않는다")
    }

    /// 승인하지 않은 이유가 "작성자에게 남긴 질문" 하나뿐인 리뷰는 정상이다.
    /// 질문을 세지 않아서 이런 리뷰마다 경고가 붙었다(실측 — 코멘트 0, 우려사항 0, 질문 1).
    func testQuestionAloneJustifiesNotApproving() {
        var out = output([], verdict: .comment)
        out.questionsForAuthor = [AuthorQuestion(question: "다른 경우도 테스트할 계획이 있을까요?",
                                                 rationaleKo: nil, evidence: nil)]
        let result = DraftValidator.validate(output: out, diff: diff, limits: limits)
        XCTAssertFalse(result.issues.contains { $0.message.contains("verdict") },
                       "질문이 있으면 approve 가 아니어도 경고하지 않는다")
    }

    /// 반대로 정말 아무 말도 없는데 승인하지 않은 것은 여전히 이상하다.
    func testNotApprovingWithNothingToSayStillWarns() {
        let result = DraftValidator.validate(output: output([], verdict: .comment), diff: diff, limits: limits)
        XCTAssertTrue(result.issues.contains { $0.message.contains("verdict") })
    }

    func testLongSummaryProducesIssue() {
        let result = DraftValidator.validate(output: output([], summary: String(repeating: "가", count: 400)),
                                             diff: diff, limits: limits)
        XCTAssertTrue(result.issues.contains { $0.message.contains("요약") })
    }
}
