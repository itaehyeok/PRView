import XCTest
@testable import PRayerCore

/// 판정기 자체의 정확도. 헛잡으면 멀쩡한 프롬프트를 고치러 가고, 놓치면 나쁜 결과를
/// 통과시킨다. 실제로 나왔던 문장으로 양쪽을 다 잠근다.
final class ReviewStyleCheckTests: XCTestCase {
    private func summaryIssues(_ summary: String, verdict: Verdict = .approve) -> [String] {
        let output = ReviewOutput(verdict: verdict, summaryKo: summary, concerns: [],
                                  strengths: [], draftComments: [])
        return ReviewStyleCheck.check(output).filter { $0.level == .hard }.map(\.rule)
    }

    // MARK: 잡아야 하는 것 — 전부 실제로 나왔던 문장

    /// 영문 이름·아이디 뒤의 "님" 만 잡는다. 한글 이름 뒤의 "님" 은 앱 기본 규칙상 맞는 말이다
    /// (예전에는 "님을 붙이지 않는다" 가 모든 사람에게 걸려 있었다).
    func testHonorificOnlyAfterLatinNames() {
        XCTAssertTrue(summaryIssues("riley님이 짚은 캐시 순서를 고쳐 그대로 가도 좋겠습니다.").contains("님"))
        XCTAssertTrue(summaryIssues("alex-k님 확인대로 정리돼 그대로 가도 좋겠습니다.").contains("님"))
        XCTAssertFalse(summaryIssues("홍길동님이 짚은 캐시 순서를 고쳐 그대로 가도 좋겠습니다.").contains("님"))
        XCTAssertFalse(summaryIssues("riley 가 짚은 캐시 순서를 고쳐 그대로 가도 좋겠습니다.").contains("님"))
    }

    func testCatchesRealNegativeClosings() {
        XCTAssertTrue(summaryIssues("…정리한 PR입니다. 코드 구조상 머지를 막을 이슈는 없습니다.").contains("요약-부정형"))
        XCTAssertTrue(summaryIssues("…일치합니다. 이 외 이슈 없습니다.").contains("요약-부정형"))
        XCTAssertTrue(summaryIssues("…변경입니다. 코드 구조상 머지를 막을 이슈는 보이지 않고, 실기기 동작 확인이 필요한 부분만 남아 있습니다.")
            .contains("요약-부정형"))
        // 에서 실제로 나온 꼴. "지장" 도 판정을 없는 것으로 세우는 말이다.
        XCTAssertTrue(summaryIssues("…이 부분만 확인되면 머지에 지장 없어 보입니다.").contains("요약-부정형"))
    }

    /// 실측 — 판정기가 처음에 놓쳤다. "없어 승인합니다" 꼴.
    func testCatchesNoIssuesThereforeApprove() {
        XCTAssertTrue(summaryIssues("…반영한 변경입니다. 앞선 리뷰에서 짚은 사항 외 추가 이슈는 없어 승인합니다.")
            .contains("요약-부정형"))
        XCTAssertTrue(summaryIssues("…작은 변경입니다. 추가로 지적할 이슈는 없어서 승인합니다.")
            .contains("요약-부정형"))
    }

    func testCatchesOpenSummaries() {
        XCTAssertTrue(summaryIssues("…늦어지는 부분만 확인 부탁드려요.").contains("요약-열어둠"))
        XCTAssertTrue(summaryIssues("…diff 밖 코드에 걸린 부분은 질문으로 남깁니다.").contains("요약-열어둠"))
        XCTAssertTrue(summaryIssues("…결함이 있어 코멘트로 남깁니다.", verdict: .comment).contains("요약-열어둠"))
    }

    func testApproveWordOnlyWithApproveVerdict() {
        XCTAssertTrue(summaryIssues("…잘 정리되었습니다. 승인합니다.", verdict: .comment).contains("요약-판정불일치"))
        XCTAssertFalse(summaryIssues("…잘 정리되었습니다. 승인합니다.", verdict: .approve).contains("요약-판정불일치"))
    }

    /// 실측: 예시를 따라 "…다뤄 주셨습니다. 승인합니다." 로 끊었다.
    func testCatchesDetachedApproval() {
        XCTAssertTrue(summaryIssues("…정리한 변경입니다. 빠짐없이 다뤄 주셨습니다. 승인합니다.").contains("요약-판정분리"))
        XCTAssertTrue(summaryIssues("…정리한 변경입니다. 잘 바뀌었습니다. 그대로 가면 되겠습니다.").contains("요약-판정분리"))
        XCTAssertFalse(summaryIssues("…정리한 변경입니다. 빠짐없이 다뤄 주셔서 승인합니다.").contains("요약-판정분리"))
    }

    /// 실측: "무난하게 정리되어" — 중립이 아니라 긍정으로 끝내라 했다.
    func testCatchesLukewarmClosing() {
        XCTAssertTrue(summaryIssues("…변경입니다. 기존 패턴을 따라 무난하게 정리되어 그대로 가도 좋겠습니다.", verdict: .comment)
            .contains("요약-미지근"))
    }

    /// 실측: major 우려(캐시 무효화 누락)가 있는데 요약이 "그대로 가도 좋겠습니다".
    func testMajorConcernForbidsGoAhead() {
        let output = ReviewOutput(
            verdict: .comment,
            summaryKo: "…정리한 변경입니다. 흐름이 자연스럽게 이어져 그대로 가도 좋겠습니다.",
            concerns: [Concern(issueKey: "c", severity: .major, title: "무효화 순서", path: "A.m", line: 1)],
            strengths: [], draftComments: [],
            concernsNoteKo: "앞서 짚은 문제가 diff 에 그대로 남아 있어 아래에 한 번 더 적었습니다.")
        let rules = ReviewStyleCheck.check(output).filter { $0.level == .hard }.map(\.rule)
        XCTAssertTrue(rules.contains("요약-major진행권유"))
        XCTAssertTrue(rules.contains("안내-중요도"), "중요한 우려를 '다시 적었습니다' 로만 소개했다")

        var fixed = output
        fixed.summaryKo = "…정리한 변경입니다. 캐시 무효화 규칙을 계층마다 같은 순서로 깔끔하게 맞춰 두셨습니다."
        fixed.concernsNoteKo = "앞서 짚은 문제가 그대로 남아 있어, 이 부분은 확인이 필요합니다."
        XCTAssertEqual(ReviewStyleCheck.check(fixed).filter { $0.level == .hard }.map(\.rule), [])
    }

    /// 가벼운 것만 남았으면 진행을 권해도 된다 — 과하게 막으면 멀쩡한 요약을 고치러 간다.
    func testMinorConcernAllowsGoAhead() {
        let output = ReviewOutput(
            verdict: .comment,
            summaryKo: "…정리한 변경입니다. 저장 경로를 한 곳으로 잘 모아 그대로 가도 좋겠습니다.",
            concerns: [Concern(issueKey: "c", severity: .minor, title: "이름", path: "A.m", line: 1)],
            strengths: [], draftComments: [],
            concernsNoteKo: "사소한 이름 문제 하나를 아래에 적었습니다.")
        XCTAssertEqual(ReviewStyleCheck.check(output).filter { $0.level == .hard }.map(\.rule), [])
    }

    // MARK: 잡으면 안 되는 것 — 변경을 설명하는 문장

    func testDoesNotFlagDescriptionsOfTheChange() {
        XCTAssertEqual(summaryIssues("화면에 보이지 않던 버튼을 노출하도록 바꾼 변경입니다. 노출 조건을 한 곳에서 판단하게 잘 모아 승인합니다."), [])
        XCTAssertEqual(summaryIssues("스크롤 중 메모리 이슈는 없어졌습니다. 원인을 정확히 짚어 잘 고쳐서 승인합니다."), [])
        XCTAssertEqual(summaryIssues("상수 하나만 바꾼 변경이라 그대로 반영하면 되겠습니다."), [])
    }

    // MARK: 잘된 점

    private func strengthIssues(_ strength: String) -> [String] {
        let output = ReviewOutput(verdict: .approve, summaryKo: "렌더 순서를 잘 맞춰 승인합니다.", concerns: [],
                                  strengths: [strength], draftComments: [])
        return ReviewStyleCheck.check(output).filter { $0.level == .hard }.map(\.rule)
    }

    func testStrengthRules() {
        XCTAssertTrue(strengthIssues("guard로 분리해 안전하게 처리함").contains("잘된점-명사형"))
        XCTAssertTrue(strengthIssues("코드와 문서가 어긋나지 않게 처리했습니다").contains("잘된점-평가없음"))
        XCTAssertEqual(strengthIssues("주석 표기까지 잘 챙겨서 코드와 문서가 어긋나지 않습니다"), [])
        XCTAssertEqual(strengthIssues("기존 규약을 그대로 지킨 점이 좋습니다"), [])
    }

    // MARK: 안내 문장

    func testNoteMayExplainWhyItAsks() {
        // "diff 에 보이지 않는" 은 질문하는 이유를 설명하는 정당한 말이다.
        let output = ReviewOutput(verdict: .comment, summaryKo: "잘 처리되었습니다.", concerns: [],
                                  strengths: [], draftComments: [],
                                  questionsForAuthor: [AuthorQuestion(question: "q", rationaleKo: nil, evidence: nil)],
                                  questionsNoteKo: "diff에 구현이 보이지 않는 refreshCache() 내부 동작 관련 질문 하나만 남깁니다.")
        XCTAssertFalse(ReviewStyleCheck.check(output).contains { $0.rule == "안내-부정형" })
    }
}

/// 예시 복사 규칙 — 실측: "기존 패턴을 그대로 따라가 안전하게 처리해 승인합니다." 를
/// 프롬프트에서 글자 그대로 가져왔다. 어느 PR 에나 붙는 문장이라 승인 글이 도배된다.
final class ReviewStyleCheckCopyTests: XCTestCase {
    private func rules(_ summary: String) -> [String] {
        ReviewStyleCheck.check(ReviewOutput(verdict: .approve, summaryKo: summary, concerns: [],
                                            strengths: [], draftComments: []))
            .filter { $0.level == .hard }.map(\.rule)
    }

    /// 프롬프트의 ① 첫 ○ 예시를 **원문 그대로** 꺼내 요약 끝에 붙이면 잡혀야 한다.
    /// 예시를 바꿔도 이 테스트는 그대로 돈다 — 문장을 박아 두지 않고 파일에서 읽는다.
    func testCatchesVerbatimCopyOfAPromptExample() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Resources/review.md"), encoding: .utf8)
        let section = try XCTUnwrap(text.range(of: "① 작고 명확한 변경"))
        let line = try XCTUnwrap(text[section.upperBound...].split(whereSeparator: \.isNewline)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("○ \"") })
        let raw = line.trimmingCharacters(in: .whitespaces).dropFirst(3).dropLast()   // ○ "…" 벗기기
        XCTAssertTrue(rules("버튼 색만 바꾼 변경입니다. \(raw)").contains("요약-예시복사"), "복사를 못 잡았다: \(raw)")
    }

    /// 흔한 마무리 말만 겹치는 것은 복사가 아니다.
    func testCommonClosingTailIsNotACopy() {
        XCTAssertFalse(rules("상수 하나만 바꾼 변경입니다. 이름만 고친 변경이라 그대로 반영하면 되겠습니다.").contains("요약-예시복사"))
    }
}

/// 3회차 실측으로 넣은 두 규칙.
final class ReviewStyleCheckRound3Tests: XCTestCase {
    private func rules(_ output: ReviewOutput) -> [String] {
        ReviewStyleCheck.check(output).filter { $0.level == .hard }.map(\.rule)
    }

    /// 8건 중 7건이 "…점이 좋습니다" 를 두 번씩 썼다.
    func testRepeatedStrengthEnding() {
        let same = ReviewOutput(verdict: .approve, summaryKo: "…변경입니다. 렌더 순서를 잘 맞춰 승인합니다.",
                                concerns: [], strengths: ["A 를 한 곳으로 모은 점이 좋습니다", "B 를 막아 둔 점이 좋습니다"],
                                draftComments: [])
        XCTAssertTrue(rules(same).contains("잘된점-같은끝"))
        var varied = same
        varied.strengths = ["A 를 한 곳으로 모은 점이 좋습니다", "B 경로까지 빠짐없이 막았습니다"]
        XCTAssertFalse(rules(varied).contains("잘된점-같은끝"))
    }

    /// 막는 판정이면 요약이 이미 말했다 — 안내가 되풀이하면 같은 말이 두 번 나간다.
    func testRequestChangesNoteMustNotRepeat() {
        let concern = Concern(issueKey: "c", severity: .major, title: "무효화 순서", path: "A.m", line: 1)
        let dup = ReviewOutput(verdict: .requestChanges,
                               summaryKo: "…연결한 변경입니다. 다만 무효화 검사가 그대로라 이 부분은 확인이 필요합니다.",
                               concerns: [concern], strengths: [], draftComments: [],
                               concernsNoteKo: "이전 리뷰에서 짚은 문제가 그대로 남아 있어, 확인이 필요합니다.")
        XCTAssertTrue(rules(dup).contains("안내-중복"))
        var fixed = dup
        fixed.concernsNoteKo = "claude[bot] 이 먼저 짚은 내용이라 근거를 아래에 함께 적었습니다."
        XCTAssertEqual(rules(fixed), [], "막는 판정에서는 안내가 '확인이 필요' 를 안 해도 된다")
    }
}

/// 5회차 실측으로 넣은 규칙.
final class ReviewStyleCheckRound5Tests: XCTestCase {
    private func rules(_ output: ReviewOutput) -> [String] {
        ReviewStyleCheck.check(output).filter { $0.level == .hard }.map(\.rule)
    }

    /// 기본 본문이 요약 + 잘된 점이라, 겹치면 같은 사실이 두 번 나간다.
    func testStrengthRepeatingTheSummary() {
        let output = ReviewOutput(
            verdict: .approve,
            summaryKo: "…고친 변경입니다. riley 가 지적한 저장 순서 문제를 queue 구조로 전부 반영해 승인합니다.",
            concerns: [], strengths: ["riley 가 지적한 저장 순서 문제를 queue 구조로 전부 반영해 대응이 빠릅니다"],
            draftComments: [])
        XCTAssertTrue(rules(output).contains("잘된점-요약중복"))
    }

    /// 같은 식별자로 시작하기만 한 것은 중복이 아니다(헛잡이).
    func testSharedIdentifierIsNotRepetition() {
        let output = ReviewOutput(
            verdict: .approve,
            summaryKo: "statusBadgeLabel 노출 중 stale 오판을 막는 가드를 추가한 변경입니다. 크래시 경로를 각각 끊어 승인합니다.",
            concerns: [], strengths: ["statusBadgeLabel 노출 중 겹치는 조건을 doc 주석에 구체적으로 풀어 쓴 점이 좋습니다"],
            draftComments: [])
        XCTAssertFalse(rules(output).contains("잘된점-요약중복"))
    }

    /// "대응이 빠릅니다" 는 칭찬이다 — 처음엔 판정기가 헛잡을 뻔했다.
    func testQuickResponseIsPraise() {
        let output = ReviewOutput(verdict: .approve, summaryKo: "…변경입니다. 렌더 순서를 잘 맞춰 승인합니다.",
                                  concerns: [], strengths: ["리뷰에서 나온 순서 문제를 같은 날 고쳐 대응이 빠릅니다"],
                                  draftComments: [])
        XCTAssertFalse(rules(output).contains("잘된점-평가없음"))
    }

    /// comment 인데 우려가 따로 있으면 요약이 "확인이 필요" 를 말하면 안 된다(5회차).
    /// 우려 없이 인라인 코멘트로만 있으면 요약이 말해도 된다(4회차 — 안내가 붙을 자리가 없다).
    func testCommentVerdictKeepsConcernOutOfSummary() {
        let concern = Concern(issueKey: "c", severity: .major, title: "선검사", path: "A.swift", line: 1)
        var output = ReviewOutput(verdict: .comment,
                                  summaryKo: "…정리한 변경입니다. 앞서 짚은 선검사 문제가 그대로라 이 부분은 확인이 필요합니다.",
                                  concerns: [concern], strengths: [], draftComments: [],
                                  concernsNoteKo: "앞서 짚은 선검사 문제가 그대로라, 이 부분은 확인이 필요합니다.")
        XCTAssertTrue(rules(output).contains("요약-우려가리킴"))
        output.concerns = []
        output.concernsNoteKo = nil
        XCTAssertFalse(rules(output).contains("요약-우려가리킴"))
    }

    /// 말("확인이 필요")만 피하고 내용을 적은 경우(6회차).
    func testConcernContentWithoutTheMagicWords() {
        let concern = Concern(issueKey: "c", severity: .major, title: "retryLimit 선검사가 저장 뒤에 돈다",
                              path: "A.swift", line: 1)
        let viaSignal = ReviewOutput(verdict: .comment,
                                     summaryKo: "…반영한 변경입니다. 다만 저장 경로의 사전 검사는 그대로 남아 있습니다.",
                                     concerns: [concern], strengths: [], draftComments: [],
                                     concernsNoteKo: "앞서 짚은 문제가 그대로라, 이 부분은 확인이 필요합니다.")
        XCTAssertTrue(rules(viaSignal).contains("요약-우려가리킴"))
        var viaToken = viaSignal
        viaToken.summaryKo = "…반영한 변경입니다. retryLimit 처리를 한 곳에 모아 두셨습니다."
        XCTAssertTrue(rules(viaToken).contains("요약-우려가리킴"))
        var clean = viaSignal
        clean.summaryKo = "…반영한 변경입니다. 실패를 화면까지 알리는 흐름을 깔끔하게 잡아 두셨습니다."
        XCTAssertFalse(rules(clean).contains("요약-우려가리킴"))
    }

    func testLongestCommonRun() {
        XCTAssertEqual(ReviewStyleCheck.longestCommonRun("abcdef", "zzcdezz"), 3)
        XCTAssertEqual(ReviewStyleCheck.longestCommonRun("", "abc"), 0)
    }
}

/// 7회차 실측으로 넣은 규칙.
final class ReviewStyleCheckRound7Tests: XCTestCase {
    private func issues(_ output: ReviewOutput) -> [ReviewStyleCheck.Issue] {
        ReviewStyleCheck.check(output)
    }

    private func approve(_ summary: String, _ strengths: [String]) -> ReviewOutput {
        ReviewOutput(verdict: .approve, summaryKo: summary, concerns: [], strengths: strengths, draftComments: [])
    }

    /// 말을 바꿔 되풀이하면 글자가 이어서 겹치지 않아 옛 규칙(10자)이 놓친다(7회차 꼴).
    func testParaphrasedRepetitionIsFlagged() {
        let summary = "문서를 메일로 바로 보내는 sendDocument 인터페이스를 추가한 변경입니다. "
            + "계정 미설정·첨부 디코딩 실패 경로를 BOOL 반환과 에러 reply 로 깔끔하게 연결해 승인합니다."
        let repeated = "계정 미설정·첨부 nil 여부를 먼저 살펴 실패를 BOOL 로 돌려주고 핸들러가 그 결과를 오류 reply 로 잇도록 연결한 점이 좋습니다"
        let found = issues(approve(summary, [repeated]))
        XCTAssertTrue(found.contains { $0.rule == "잘된점-요약겹침" && $0.level == .soft }, "\(found)")
        XCTAssertFalse(found.contains { $0.rule == "잘된점-요약중복" }, "글자로는 안 겹친다 — 옛 규칙이 잡으면 기준이 바뀐 것")

        let distinct = "BOM 이나 개행이 섞인 CSV 까지 받아 주는 파싱 처리가 꼼꼼합니다"
        XCTAssertFalse(issues(approve(summary, [distinct])).contains { $0.rule == "잘된점-요약겹침" })
    }

    /// 형용사 끝맺음을 "~게" 바로 뒤에 붙였다(7회차).
    func testAdjectiveEndingNeedsASubject() {
        let summary = "…크래시 경로를 없앤 변경입니다. 배치 갱신을 한 번에 끊어 승인합니다."
        let broken = "cachedRowIndex 과 그 기록 코드까지 함께 걷어내 죽은 상태가 남지 않게 깔끔합니다"
        XCTAssertTrue(issues(approve(summary, [broken])).contains { $0.rule == "잘된점-어긋난끝" && $0.level == .hard })
        // 주어를 끼워 넣어도 "~게" 가 걸려 있으면 어긋난다(8회차).
        let wedged = "대기 시간 실측 근거를 남겨 원인 추적이 쉽게 문서화가 꼼꼼합니다"
        XCTAssertTrue(issues(approve(summary, [wedged])).contains { $0.rule == "잘된점-어긋난끝" })
        for fine in ["cachedRowIndex 과 그 기록 코드까지 함께 걷어내 죽은 상태가 남지 않게 깔끔하게 정리했습니다",
                     "빈 응답까지 받아 주도록 짠 파싱이 탄탄합니다",
                     "원인을 쫓을 수 있게 근거까지 적어 둔 문서화가 꼼꼼합니다",
                     "여러 곳에서 동시에 불려도 꼬이지 않게 잠금으로 감싼 처리가 탄탄합니다",
                     "빠짐없이 적용해 대응이 탄탄합니다"] {
            XCTAssertFalse(issues(approve(summary, [fine])).contains { $0.rule == "잘된점-어긋난끝" }, fine)
        }
    }

    /// `○ 요약: "…"` 꼴의 두 문장짜리 예시도 복사 검사 대상이다. 파일에서 읽는다.
    func testTwoSentenceExamplesAreCopyChecked() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Resources/review.md"), encoding: .utf8)
        let line = try XCTUnwrap(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("○ 요약: \"") }, "○ 요약: 예시가 없다")
        let quoted = line.drop { $0 != "\"" }.dropFirst().prefix { $0 != "\"" }
        let second = try XCTUnwrap(quoted.components(separatedBy: ". ").last)
        let found = issues(ReviewOutput(verdict: .comment, summaryKo: "설정 화면을 고친 변경입니다. \(second)",
                                        concerns: [], strengths: [], draftComments: []))
        XCTAssertTrue(found.contains { $0.rule == "요약-예시복사" }, "복사를 못 잡았다: \(second)")
    }

    /// 버전 번호·파일 이름의 마침표에서 자르지 않는다(9회차 : "2.3.0-beta1" 로 4문장이 됐다).
    func testSentencesIgnoreDotsInsideWords() {
        let text = "SDK 2.3.0-beta1 과 build.sh 를 고친 변경입니다. 두 경로를 실기기로 확인해 승인합니다."
        XCTAssertEqual(ReviewStyleCheck.sentences(of: text),
                       ["SDK 2.3.0-beta1 과 build.sh 를 고친 변경입니다", "두 경로를 실기기로 확인해 승인합니다"])
        XCTAssertEqual(ReviewStyleCheck.sentences(of: "끝에 마침표가 없어도 된다"), ["끝에 마침표가 없어도 된다"])
    }

    /// 승인 문장이 한 일 + 승인으로만 끝나면 중립으로 읽힌다(8~11회차 승인 23건 중 14건).
    func testApprovalWithoutPraiseIsFlaggedSoft() {
        let neutral = approve("…옵저버 해제를 옮긴 변경입니다. 호출부만 지우면 되도록 정리해 승인합니다.", [])
        XCTAssertTrue(issues(neutral).contains { $0.rule == "요약-평가없음" && $0.level == .soft })
        for praised in ["…옵저버 해제를 옮긴 변경입니다. 호출부만 지우면 되도록 한 곳에 깔끔하게 모아 승인합니다.",
                        "…옵저버 해제를 옮긴 변경입니다. 원인을 정확히 짚어 승인합니다."] {
            XCTAssertFalse(issues(approve(praised, [])).contains { $0.rule == "요약-평가없음" }, praised)
        }
        // "잘못" 은 평가가 아니다.
        XCTAssertTrue(issues(approve("…변경입니다. 잘못 들어가던 값을 고쳐 승인합니다.", [])).contains { $0.rule == "요약-평가없음" })
    }

    /// 평가는 한 일을 꾸민다. "탄탄하게 승인합니다" 는 승인을 꾸민 것이다(12회차).
    func testPraiseMustNotModifyTheApproval() {
        let bad = approve("…크래시 경로를 없앤 변경입니다. 세 경로를 각각 끊어 두어 탄탄하게 승인합니다.", [])
        XCTAssertTrue(issues(bad).contains { $0.rule == "요약-승인수식" && $0.level == .hard })
        let good = approve("…크래시 경로를 없앤 변경입니다. 세 경로를 각각 탄탄하게 끊어 두어 승인합니다.", [])
        XCTAssertFalse(issues(good).contains { $0.rule == "요약-승인수식" })
        // "잘 반영해 승인합니다" 는 반영을 꾸민다 — 괜찮다.
        XCTAssertFalse(issues(approve("…변경입니다. 앞서 짚은 두 곳을 잘 반영해 승인합니다.", [])).contains { $0.rule == "요약-승인수식" })
    }

    /// 주석 칭찬이 한 리뷰에 두 번이면 soft 로 알린다(13회차).
    func testTwoCommentPraisesAreFlaggedSoft() {
        let two = approve("…변경입니다. 호출 순서를 한 곳에 깔끔하게 모아 승인합니다.",
                          ["순서 규칙을 주석으로 남겨 둔 점이 세심합니다", "API 의도를 doc 주석으로 남겨 둔 점이 좋습니다"])
        XCTAssertTrue(issues(two).contains { $0.rule == "잘된점-주석두번" && $0.level == .soft })
        let one = approve("…변경입니다. 호출 순서를 한 곳에 깔끔하게 모아 승인합니다.",
                          ["순서 규칙을 주석으로 남겨 둔 점이 세심합니다", "닫힌 뒤 도착한 콜백까지 무시하도록 막아 둔 가드가 꼼꼼합니다"])
        XCTAssertFalse(issues(one).contains { $0.rule == "잘된점-주석두번" })
    }

    /// 값 안에 섞인 형식 조각·혼잣말(14회차).
    func testLeakedMarkupIsHard() {
        let leaked = approve("…변경입니다. 빠짐없이 보완해 승인합니다.</summary_ko... let me fix>", [])
        XCTAssertTrue(issues(leaked).contains { $0.rule == "출력-조각" && $0.level == .hard })
        let monologue = approve("…변경입니다. 빠짐없이 보완해 승인합니다. let me fix this", [])
        XCTAssertTrue(issues(monologue).contains { $0.rule == "출력-조각" })
        XCTAssertFalse(issues(approve("…`Array<Int>` 를 바꾼 변경입니다. 깔끔하게 맞춰 승인합니다.", [])).contains { $0.rule == "출력-조각" })
    }

    /// "남아 있던" 은 고친 버그를 설명하는 말이다 — 우려를 가리킨 것이 아니다(15회차 헛잡이).
    func testPastTenseRemainIsNotAnOpenSignal() {
        let concern = Concern(issueKey: "c", severity: .major, title: "세션이 켜진 채 남을 수 있음", path: "A.swift", line: 1)
        var output = ReviewOutput(verdict: .comment,
                                  summaryKo: "…해제한 변경입니다. 캐시에 남아 있던 이전 상태 때문에 되살아나던 원래 버그를 두 경로에서 빠짐없이 잡아 두셨습니다.",
                                  concerns: [concern], strengths: [], draftComments: [],
                                  concernsNoteKo: "세션이 켜진 채 남는 경로가 그대로라, 이 부분은 확인이 필요합니다.")
        XCTAssertFalse(issues(output).contains { $0.rule == "요약-우려가리킴" })
        output.summaryKo = "…해제한 변경입니다. 다만 세션 정리 경로가 아직 남아 있어 그 부분 확인이 필요합니다."
        XCTAssertTrue(issues(output).contains { $0.rule == "요약-우려가리킴" })
    }

    func testContentTokens() {
        let tokens = ReviewStyleCheck.contentTokens(in: "error 초기화를 fetchItems() 한 곳으로 모아 깔끔하게 정리했습니다")
        XCTAssertTrue(tokens.isSuperset(of: ["error", "fetchitems", "초기", "모아"]), "\(tokens)")
        XCTAssertFalse(tokens.contains("깔끔"), "어디에나 나오는 평가어는 뺀다")
        XCTAssertFalse(tokens.contains("정리"))
    }
}

/// comment(minor·nit) 맺음말 — 사용자가 고른 두 꼴. 예전에는 "그대로 가도 좋겠습니다" 한 문장으로 굳어
/// comment 4건이 모두 같은 말로 끝났다(실측).
final class CommentClosingTests: XCTestCase {
    private func comment(_ summary: String, severity: Severity) -> ReviewOutput {
        ReviewOutput(verdict: .comment, summaryKo: summary,
                     concerns: [Concern(issueKey: "c", severity: severity, title: "재시도 간격", path: "A.swift", line: 1)],
                     strengths: [], draftComments: [])
    }

    func testChosenClosingsPassForLightComment() {
        for summary in ["…바꾼 변경입니다. 취소 순서까지 꼼꼼하게 챙겨, 머지를 막을 만한 부분은 없습니다.",
                        "…바꾼 변경입니다. 두 서비스를 같은 방식으로 잘 정리해 이대로 머지해도 문제없겠습니다."] {
            for severity in [Severity.minor, .nit] {
                let issues = ReviewStyleCheck.check(comment(summary, severity: severity))
                XCTAssertFalse(issues.contains { $0.level == .hard }, "\(summary): \(issues)")
                XCTAssertFalse(issues.contains { $0.rule == "요약-맺음말" }, "\(summary): \(issues)")
            }
        }
    }

    /// 예외는 comment(minor·nit) 뿐이다. 승인에서 쓰면 여전히 "없는 것" 으로 세운 판정이다(9/28 금지 이유 그대로).
    func testNoBlockClosingIsStillNegativeForApprove() {
        let output = ReviewOutput(verdict: .approve,
                                  summaryKo: "…바꾼 변경입니다. 취소 순서까지 꼼꼼하게 챙겨, 머지를 막을 만한 부분은 없습니다.",
                                  concerns: [], strengths: [], draftComments: [])
        XCTAssertTrue(ReviewStyleCheck.check(output).contains { $0.rule == "요약-부정형" })
    }

    /// major 가 남았는데 머지를 권하면 같은 본문에 붙을 major 코멘트와 정면으로 어긋난다.
    func testChosenClosingsAreGoAheadWhenMajorRemains() {
        for summary in ["…바꾼 변경입니다. 두 서비스를 같은 방식으로 잘 정리해 이대로 머지해도 문제없겠습니다.",
                        "…바꾼 변경입니다. 취소 순서까지 꼼꼼하게 챙겨, 머지를 막을 만한 부분은 없습니다."] {
            XCTAssertTrue(ReviewStyleCheck.check(comment(summary, severity: .major)).contains { $0.rule == "요약-major진행권유" },
                          summary)
        }
    }

    /// 옛 맺음말은 막지 않고 사람이 읽어 보게 soft 로 짚는다.
    func testOldClosingIsFlaggedSoftly() {
        let issues = ReviewStyleCheck.check(comment("…바꾼 변경입니다. 두 서비스를 같은 방식으로 잘 정리해 그대로 가도 좋겠습니다.",
                                                    severity: .nit))
        XCTAssertTrue(issues.contains { $0.rule == "요약-맺음말" && $0.level == .soft })
    }
}
