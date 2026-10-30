import XCTest
@testable import PRayerCore

/// 판정과 코멘트 앞말은 사용자 리뷰 규칙이 무엇을 시키든 앱이 같은 규칙으로 정한다.
final class ReviewFormatGuardTests: XCTestCase {
    private func comment(_ severity: Severity, _ body: String) -> DraftComment {
        DraftComment(issueKey: UUID().uuidString, path: "A.swift", line: 1, side: .right,
                     body: body, severity: severity, anchorText: "let a = 1")
    }

    private func output(_ verdict: Verdict, _ comments: [DraftComment]) -> ReviewOutput {
        ReviewOutput(verdict: verdict, summaryKo: "요약", concerns: [], strengths: [], draftComments: comments)
    }

    // MARK: - 판정

    func testBlockerForcesRequestChangesEvenIfModelApproved() {
        let fixed = ReviewFormatGuard.conform(output(.approve, [comment(.nit, "a"), comment(.blocker, "b")]))
        XCTAssertEqual(fixed.verdict, .requestChanges)
    }

    func testRecommendedMakesComment() {
        XCTAssertEqual(ReviewFormatGuard.conform(output(.approve, [comment(.minor, "a")])).verdict, .comment)
        XCTAssertEqual(ReviewFormatGuard.conform(output(.requestChanges, [comment(.major, "a")])).verdict, .comment)
    }

    func testInformationalOnlyOrNothingApproves() {
        XCTAssertEqual(ReviewFormatGuard.conform(output(.comment, [comment(.nit, "a")])).verdict, .approve)
        XCTAssertEqual(ReviewFormatGuard.conform(output(.requestChanges, [])).verdict, .approve)
    }

    func testOldFormatConcernsCountToo() {
        var old = output(.approve, [])
        old.concerns = [Concern(issueKey: "c", severity: .blocker, title: "막음", path: "A.swift")]
        XCTAssertEqual(ReviewFormatGuard.verdict(for: old), .requestChanges)
    }

    // MARK: - 앞말

    func testNonBlockerGetsPrefixWhenMissing() {
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("  나중에 정리하면 좋겠습니다.", severity: .minor),
                       "(비블로커) 나중에 정리하면 좋겠습니다.")
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("알아 두면 좋습니다.", severity: .nit),
                       "(비블로커) 알아 두면 좋습니다.")
    }

    func testExistingPrefixesAreKept() {
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("(비블로커) 이미 있음", severity: .minor), "(비블로커) 이미 있음")
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("[질문] 의도인가요?", severity: .nit), "[질문] 의도인가요?")
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("[질문] 막아야 하나요?", severity: .blocker), "[질문] 막아야 하나요?")
    }

    func testBlockerLosesNonBlockerPrefix() {
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("(비블로커)  크래시가 납니다.", severity: .blocker), "크래시가 납니다.")
        XCTAssertEqual(ReviewFormatGuard.prefixedBody("크래시가 납니다.", severity: .blocker), "크래시가 납니다.")
    }

    func testConformAppliesPrefixesToEveryComment() {
        let fixed = ReviewFormatGuard.conform(output(.comment, [comment(.minor, "a"), comment(.blocker, "(비블로커) b")]))
        XCTAssertEqual(fixed.draftComments.map(\.body), ["(비블로커) a", "b"])
    }

    /// 카드 칸에는 앞말 없이 보이고, 고친 글은 앞말을 다시 붙여 저장한다 — 올라가는 글은 그대로다.
    func testNonBlockerPrefixHiddenInEditorAndRestoredOnEdit() {
        let stored = "(비블로커) 한 번에 모아 주세요."
        XCTAssertEqual(ReviewFormatGuard.withoutNonBlockerPrefix(stored), "한 번에 모아 주세요.")
        XCTAssertEqual(ReviewFormatGuard.restoringNonBlockerPrefix("한 번에 모아 주세요!", from: stored),
                       "(비블로커) 한 번에 모아 주세요!")
        // 앞말이 없던 글(필수·질문)은 손대지 않는다.
        XCTAssertEqual(ReviewFormatGuard.withoutNonBlockerPrefix("[질문] 왜요?"), "[질문] 왜요?")
        XCTAssertEqual(ReviewFormatGuard.restoringNonBlockerPrefix("고쳐 주세요", from: "고쳐 주세요."), "고쳐 주세요")
        // 다 지웠으면 앞말만 남기지 않고, 앞말을 직접 쳤으면 두 번 붙이지 않는다.
        XCTAssertEqual(ReviewFormatGuard.restoringNonBlockerPrefix("", from: stored), "")
        XCTAssertEqual(ReviewFormatGuard.restoringNonBlockerPrefix("(비블로커) 다시", from: stored), "(비블로커) 다시")
    }
}
