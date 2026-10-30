import XCTest
@testable import PRayerCore

/// 프롬프트에 **써 두지 않은 것은 모델이 하지 않는다.**
///
/// `strengths` 는 스키마에만 있고 프롬프트에는 한 줄도 없었다. 그래서 모델이 어미를
/// 제 마음대로 골라 "~함 / ~됨" 같은 명사형으로 냈고, 화면의 `잘된 점` 소제목 아래
/// 붙으면 칭찬인지 그냥 코드 설명인지 구분이 안 됐다(실측).
/// 지시가 통째로 사라지는 일을 막는 최소한의 그물이다 — 모델 출력까지는 못 잡는다.
final class PromptContractTests: XCTestCase {
    /// 모델이 실제로 받는 지침 — 기본 리뷰 규칙 + (빈) 사용자 리뷰 규칙 + 앱 형식 규칙.
    private var guideText: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let base = try String(contentsOf: root.appendingPathComponent("Resources/review.md"), encoding: .utf8)
            let format = try String(contentsOf: root.appendingPathComponent("Resources/review-format.md"), encoding: .utf8)
            return ReviewGuideText.compose(base: base, format: format, userRules: "")
        }
    }

    private var schema: [String: Any] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let data = try Data(contentsOf: root.appendingPathComponent("Resources/schema.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    /// 앱이 쓰는 코멘트 수·길이 상한은 스키마의 상한과 같아야 한다. 예전에는 설정으로 따로 바꿀 수 있어서,
    /// 올리면 스키마에 막혀 그대로였고 낮추면 모델은 모른 채 다 쓰고 뒤에서 잘렸다.
    func testCommentLimitsMatchSchema() throws {
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let drafts = try XCTUnwrap(properties["code_comments"] as? [String: Any])
        XCTAssertEqual(drafts["maxItems"] as? Int, ReviewLimits.schemaMaxComments)
        let item = try XCTUnwrap(drafts["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let body = try XCTUnwrap(itemProperties["body"] as? [String: Any])
        XCTAssertEqual(body["maxLength"] as? Int, ReviewLimits.schemaMaxBodyChars)
    }

    /// 팀 규칙을 덧붙이는 기능을 뺐다(2026-10-06). 가이드가 없는 [팀 규칙] 절을 가리키면 모델이 그 절을 찾는다.
    func testGuideDoesNotPointToTeamRules() throws {
        XCTAssertFalse(try guideText.contains("[팀 규칙"), "없는 [팀 규칙] 절을 가리킨다")
    }

    /// 스키마에 있는 필드는 프롬프트에도 설명이 있어야 한다.
    func testEveryOutputFieldIsExplainedInThePrompt() throws {
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        for field in properties.keys {
            XCTAssertTrue(try guideText.contains(field),
                          "스키마의 `\(field)` 가 리뷰 지침에 한 번도 안 나온다 — 모델이 뭘 넣을지 모른다")
        }
    }

    func testStrengthsForbidNounEndings() throws {
        let text = try guideText
        XCTAssertTrue(text.contains("[잘된 점 — strengths]"), "잘된 점 지시 항목이 통째로 빠졌다")
        XCTAssertTrue(text.contains("명사형 종결을 쓰지 않는다"), "명사형 금지 규칙이 빠졌다")
        XCTAssertTrue(text.contains("~했습니다"), "권장 어미가 예시로 들어 있어야 한다")
    }

    /// 어미만 맞추면 "~하게 처리했습니다" 같은 **사실 설명**이 나온다(실측).
    /// 그 꼴을 모델이 어디서 배웠나 보니 프롬프트의 ○ 예시가 "안전하게 처리했습니다" 였다.
    /// 예시가 곧 지시다 — 잘된 점 구역의 ○ 예시는 전부 평가하는 말을 품어야 한다.
    func testStrengthExamplesAllCarryPraise() throws {
        let text = try guideText
        XCTAssertTrue(text.contains("평가하는 말을 반드시 넣고, 문장 끝 서술어에 둔다"), "평가어 규칙이 빠졌다")

        let start = try XCTUnwrap(text.range(of: "[잘된 점 — strengths]"))
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n[")?.lowerBound ?? rest.endIndex
        let section = rest[..<end]

        // 판정기와 같은 목록을 쓴다. 둘이 따로 놀면 프롬프트가 권한 말을 한쪽이 틀렸다고 한다.
        let praise = ReviewStyleCheck.praiseWords
        var examples = 0
        for line in section.split(whereSeparator: \.isNewline) where line.contains("○") {
            examples += 1
            XCTAssertTrue(praise.contains { line.contains($0) },
                          "평가하는 말이 없는 좋은 예: \(line.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertGreaterThanOrEqual(examples, 3, "좋은 예가 너무 적다 — 모델이 한 문장만 돌려쓴다")
    }

    /// "~했습니다" 는 명사형보다 길다. 상한이 빡빡하면 모델이 글자 수를 맞추려고
    /// 다시 명사형으로 돌아간다.
    func testStrengthLimitLeavesRoomForVerbEndings() throws {
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let strengths = try XCTUnwrap(properties["strengths"] as? [String: Any])
        let items = try XCTUnwrap(strengths["items"] as? [String: Any])
        let maxLength = try XCTUnwrap(items["maxLength"] as? Int)
        XCTAssertGreaterThanOrEqual(maxLength, 100, "어미를 붙일 자리가 없으면 명사형으로 돌아간다")
    }

    /// 요약은 승인 사인이라 "남은 일" 을 적으면 안 된다. 이 규칙도 실측으로 한 번 깨졌다.
    func testSummaryStaysClosed() throws {
        let text = try guideText
        XCTAssertTrue(text.contains("요약은 승인 사인이다"))
        XCTAssertTrue(text.contains("코드 코멘트를 요약에서 언급하지 않는다"))
    }

    /// 괜찮으면 괜찮다고 끝낸다.
    ///
    /// 이 규칙은 **프롬프트가 정반대를 권하고 있어서** 한 번 통째로 새어 나갔다 —
    /// `"머지를 막을 이슈는 없습니다." ○` 가 좋은 예로 적혀 있었다.
    ///
    /// 그리고 그걸 고친 뒤에도 파일 **아래쪽 예시에는 ○ 로 남아 있었다.** 앞 테스트가
    /// `"…" ○` 라는 **글자 배열**을 찾는 바람에 `○ summary_ko: "…"` 꼴을 놓쳤다.
    /// 그래서 배열이 아니라 **뜻**으로 검사한다 — 금지 문구가 ○ 와 같은 줄에 있으면 잡는다.
    func testClosingVerdictIsPositive() throws {
        let text = try guideText
        XCTAssertTrue(text.contains("괜찮으면 괜찮다고 끝낸다"), "긍정 마무리 규칙이 빠졌다")
        XCTAssertTrue(text.contains("쓰지 않는 말"), "금지 문구 목록이 빠졌다")

        // 금지 문구가 좋은 예(○)로 적힌 줄이 하나도 없어야 한다. 표기 순서와 무관하게 잡힌다.
        // comment(권장) 의 맺음말 하나만은 예외다(사용자가 고른 꼴) — 그 글자만 빼고 본다.
        let banned = ["머지를 막을", "이슈 없습니다", "특이사항 없습니다", "보이지 않습니다"]
        for line in text.split(whereSeparator: \.isNewline) where line.contains("○") {
            let rest = line.replacingOccurrences(of: Self.allowedCommentClosing, with: "")
            for phrase in banned {
                XCTAssertFalse(rest.contains(phrase),
                               "금지 문구가 좋은 예로 적혀 있다: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// comment 이고 권장(필수 없음)만 남았을 때 허용하는 단 하나의 "머지를 막을 …" 꼴.
    static let allowedCommentClosing = "머지를 막을 만한 부분은 없습니다"

    /// comment(권장) 는 사용자가 고른 두 맺음말 중 하나로 닫는다. 예전에는 표가 "그대로 가도 좋겠습니다"
    /// 한 문장을 못 박아 comment 4건이 모두 같은 말로 끝났다(실측). 표·예외·예시가 함께 바뀌어 있어야 한다.
    func testLightCommentClosesWithChosenPhrases() throws {
        let text = try guideText
        let row = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("| comment | 권장") },
                                "판정별 표의 comment(권장) 줄이 없다")
        for closing in ReviewStyleCheck.commentClosings {
            XCTAssertTrue(row.contains(closing), "표에 맺음말이 없다: \(closing)")
        }
        XCTAssertTrue(text.contains("딱 하나의 예외"), "금지 목록에 comment(권장) 예외가 없다")
        // 옛 진행 권유 꼴이 좋은 예로 남아 있으면 모델은 규칙이 아니라 예시를 따른다.
        let oldClosings = ["그대로 가도 좋겠습니다", "그대로 반영하면 되겠습니다", "그대로 가면 되겠습니다", "이대로 반영하면 되겠습니다"]
        for line in text.split(whereSeparator: \.isNewline) where line.contains("○") {
            for old in oldClosings {
                XCTAssertFalse(line.contains(old), "옛 맺음말이 좋은 예로 남았다: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// 금지 문구는 **나쁜 예(✗)와 "쓰지 않는 말" 목록 안에만** 나와야 한다.
    ///
    /// ○ 줄만 보던 앞 테스트가 놓친 함정이 있었다 — [이미 논의된 사항] 절의 **지시문**이
    /// "겹칠 내용밖에 없으면 '앞선 리뷰에서 짚은 사항 외 추가 이슈는 없습니다.' 로 끝낸다" 였다.
    /// ○ 표시가 없어 안 잡혔고, 모델은 그대로 따라 요약 전체를 그 한 문장으로 냈다(실측).
    func testBannedPhrasesAppearOnlyAsBadExamples() throws {
        let text = try guideText
        let lines = text.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("**쓰지 않는 말**") }, "금지 목록이 빠졌다")
        let end = try XCTUnwrap(lines[start...].firstIndex { $0.contains("세우는 문장 자체를 쓰지 않는다") })
        let banned = ["머지를 막을", "이슈 없습니다", "이슈는 없습니다", "추가 이슈는 없", "특이사항", "사항 외 추가"]
        for (index, line) in lines.enumerated() {
            let rest = line.replacingOccurrences(of: Self.allowedCommentClosing, with: "")
            guard banned.contains(where: rest.contains) else { continue }
            let allowed = line.contains("✗") || (start...end).contains(index)
            XCTAssertTrue(allowed, "\(index + 1)행: 금지 문구가 나쁜 예 밖에 있다 — \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// 예시가 규칙을 어기면 모델은 규칙이 아니라 예시를 따른다.
    ///
    /// 실측(7회차 점검): 조립 예시 세 곳이 "…처리했습니다. 승인합니다." — 규칙이 막은 판정 분리 —
    /// 를 쓰고 있었고, 그 문장 자체도 ✗ 로 막은 "기존 패턴을 그대로 따라가 안전하게 처리" 였다.
    func testExamplesDoNotUseFormsTheRulesForbid() throws {
        let lines = try guideText.components(separatedBy: "\n")
        // ✗ 로 막은 예시 문장들. 따옴표 안의 글만 꺼낸다.
        let forbidden: [String] = lines.compactMap { line in
            guard let mark = line.range(of: "✗ \"") else { return nil }
            let rest = line[mark.upperBound...]
            return rest.firstIndex(of: "\"").map { ReviewStyleCheck.normalized(String(rest[..<$0])) }
        }.filter { $0.count >= 12 }
        XCTAssertFalse(forbidden.isEmpty, "✗ 예시를 하나도 못 읽었다 — 검사가 헛돈다")

        for (index, line) in lines.enumerated() where !line.contains("✗") {
            let key = ReviewStyleCheck.normalized(line)
            for bad in forbidden where key.contains(bad) {
                XCTFail("\(index + 1)행이 ✗ 로 막은 문장을 쓴다: \(line.trimmingCharacters(in: .whitespaces))")
            }
            // 판정을 따로 떼어 낸 꼴. 그 꼴을 **설명하는** 규칙 문장("…처럼 / 둘로 끊으면")만 예외다.
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            if line.contains("습니다. 승인합니다"), !(line + next).contains("끊으면") {
                XCTFail("\(index + 1)행이 판정을 따로 뗐다: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// 모델은 스키마 순서대로 쓴다. 요약이 우려보다 먼저 있으면 요약을 쓰는 시점에 우려가 아직 없어서,
    /// 요약이 우려가 문제 삼은 바로 그 코드를 칭찬했다(9회차, 7회차).
    /// 코드 코멘트 → 판정 → 요약 → 잘된 점 순서를 지킨다. 잘된 점은 요약을 보고 겹치지 않게 써야 해서 마지막이다.
    func testIssuesAreWrittenBeforeTheSummary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // 순서를 봐야 해서 원문에서 찾는다(JSONSerialization 은 순서를 버린다).
        let raw = try String(contentsOf: root.appendingPathComponent("Resources/schema.json"), encoding: .utf8)
        func position(_ key: String) throws -> String.Index {
            try XCTUnwrap(raw.range(of: "\"\(key)\": {")?.lowerBound, "\(key) 가 스키마에 없다")
        }
        let summary = try position("summary_ko")
        for issue in ["code_comments", "verdict"] {
            XCTAssertLessThan(try position(issue), summary, "\(issue) 가 요약보다 뒤에 있다 — 요약이 그걸 모르고 쓰인다")
        }
        for after in ["strengths"] {
            XCTAssertGreaterThan(try position(after), summary, "\(after) 는 요약을 보고 써야 한다")
        }
    }

    /// 지적은 한 목록(code_comments)뿐이고 중요도는 필수·권장·참고 세 단계다(2026-10-20 사용자 결정).
    /// 스키마·디코더·프롬프트가 같은 세 값을 써야 한다 — 하나만 바뀌면 모델이 낸 값을 앱이 못 읽는다.
    func testImportanceHasThreeLevelsEverywhere() throws {
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        for gone in ["concerns", "questions_for_author", "draft_comments", "concerns_note_ko", "questions_note_ko"] {
            XCTAssertNil(properties[gone], "\(gone) 가 스키마에 남았다 — 지적은 code_comments 하나다")
        }
        let comments = try XCTUnwrap(properties["code_comments"] as? [String: Any])
        let item = try XCTUnwrap(comments["items"] as? [String: Any])
        let required = try XCTUnwrap(item["required"] as? [String])
        for field in ["importance", "path", "line", "side", "anchor_text"] {
            XCTAssertTrue(required.contains(field), "코멘트마다 \(field) 가 있어야 줄에 달린다")
        }
        let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let importance = try XCTUnwrap(itemProperties["importance"] as? [String: Any])
        let values = try XCTUnwrap(importance["enum"] as? [String])
        XCTAssertEqual(Set(values), Set(CodeComment.Importance.allCases.map(\.rawValue)))

        let text = try guideText
        for (value, label) in [("required", "필수"), ("recommended", "권장"), ("informational", "참고")] {
            XCTAssertTrue(text.contains("\(value)(\(label))"), "프롬프트에 \(value)(\(label)) 설명이 없다")
        }
    }

    /// 상황별 문구가 실제로 들어 있는지. 하나짜리 예시만 남으면 모델이 그 문장만 돌려쓴다.
    func testClosingExamplesCoverSeveralSituations() throws {
        let text = try guideText
        for marker in ["① 작고 명확한 변경", "② 기존 패턴", "③ 까다로운", "④ 질문·우려가 함께"] {
            XCTAssertTrue(text.contains(marker), "\(marker) 예시가 빠졌다")
        }
        XCTAssertTrue(text.contains("\"승인합니다\" 는 verdict 가 approve 일 때만 쓴다"))
    }
}

/// CI 가 빨간 이유를 나누는 규칙.
///
/// 합쳐진 값(`statusCheckRollup.state`)은 취소도 실패로 친다. 실측: 실패로 끝난
/// 체크가 `static-analysis` 하나인데 그것도 CANCELLED 였는데 화면은 빨간 FAILURE 만 냈다.
/// 사람이 할 일이 다르다 — 취소는 다시 돌리면 되고, 실패는 코드를 봐야 한다.
final class CheckOutcomeTests: XCTestCase {
    private func pr(_ state: String?, _ checks: [PRCheck]) -> PullRequestInfo {
        var info = Fixtures.pr()
        info.checkState = state
        info.checks = checks
        return info
    }

    func testAllGreenIsPassing() {
        XCTAssertEqual(pr("SUCCESS", [PRCheck(name: "build", outcome: "SUCCESS")]).checkOutcome, .passing)
        XCTAssertEqual(pr("PENDING", []).checkOutcome, .passing)
        XCTAssertEqual(pr(nil, []).checkOutcome, .passing)
    }

    /// 실측한 의 모양 그대로.
    func testCancelledOnlyIsNotAFailure() {
        let outcome = pr("FAILURE", [
            PRCheck(name: "static-analysis", outcome: "CANCELLED"),
            PRCheck(name: "static-analysis", outcome: "SKIPPED"),
            PRCheck(name: "unit-tests", outcome: "SUCCESS"),
        ]).checkOutcome
        XCTAssertEqual(outcome, .cancelled(["static-analysis"]))
        XCTAssertTrue(outcome.isCancelledOnly)
        XCTAssertTrue(outcome.isProblem, "그래도 초록은 아니다")
    }

    /// 진짜 실패가 하나라도 있으면 취소는 덮인다 — 그때는 코드를 봐야 한다.
    func testRealFailureWins() {
        let outcome = pr("FAILURE", [
            PRCheck(name: "static-analysis", outcome: "FAILURE"),
            PRCheck(name: "other", outcome: "CANCELLED"),
        ]).checkOutcome
        XCTAssertEqual(outcome, .failed(["static-analysis"]))
        XCTAssertFalse(outcome.isCancelledOnly)
    }

    func testTimeoutCountsAsFailure() {
        XCTAssertEqual(pr("FAILURE", [PRCheck(name: "e2e", outcome: "TIMED_OUT")]).checkOutcome,
                       .failed(["e2e"]))
    }

    /// 체크 목록을 못 받았으면(옛 스냅샷·조회 실패) 이름 없이 실패로만 말한다.
    /// 조용히 초록으로 바꾸면 깨진 PR 을 못 보고 지나친다.
    func testMissingChecksStillReportsFailure() {
        XCTAssertEqual(pr("FAILURE", []).checkOutcome, .failed([]))
        XCTAssertNil(CheckOutcome.failed([]).detail, "이름이 없으면 덧붙일 말도 없다")
    }

    func testDetailNamesAtMostTwo() {
        XCTAssertEqual(CheckOutcome.failed(["a"]).detail, "a 실패")
        XCTAssertEqual(CheckOutcome.failed(["a", "b"]).detail, "a, b 실패")
        XCTAssertEqual(CheckOutcome.failed(["a", "b", "c", "d"]).detail, "a, b 외 2건 실패")
        XCTAssertEqual(CheckOutcome.cancelled(["x"]).detail, "x 취소됨")
    }

    /// 같은 이름이 여러 번 온다(같은 워크플로가 여러 잡을 낸다). 한 번만 센다.
    func testDuplicateNamesCollapse() {
        XCTAssertEqual(CheckOutcome.failed(["guard", "guard", "guard"]).detail, "guard 실패")
    }
}
