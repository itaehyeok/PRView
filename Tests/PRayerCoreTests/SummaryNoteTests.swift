import XCTest
@testable import PRayerCore

/// 요약은 그 자체로 완결돼야 한다. 우려사항·질문을 소개하는 문장은 그 항목을 실제로 켰을 때만
/// 따라 붙는다 — 안 그러면 본문에 없는 것을 가리키는 요약이 올라간다(실측).
final class SummaryNoteTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    private func record(concerns: Int = 1,
                        questions: Int = 2,
                        concernsNote: String? = "우려는 아래에 적었습니다.",
                        questionsNote: String? = "질문은 아래에 남깁니다.",
                        summary: Bool = true,
                        showConcerns: Bool = false,
                        showQuestions: Bool = false) -> ReviewRecord {
        let output = ReviewOutput(
            verdict: .comment,
            summaryKo: "머지를 막을 사안은 없습니다.",
            concerns: (0..<concerns).map {
                Concern(issueKey: "c\($0)", severity: .major, title: "우려 \($0)", path: "A.swift", line: 1)
            },
            strengths: [],
            draftComments: [],
            questionsForAuthor: (0..<questions).map {
                AuthorQuestion(question: "질문 \($0)", rationaleKo: nil, evidence: nil)
            },
            concernsNoteKo: concernsNote,
            questionsNoteKo: questionsNote)
        return ReviewRecord(repo: repo, number: 1, headSha: "abc", baseRefName: "develop",
                            promptVersion: "v1", model: "opus", trigger: .manual, output: output,
                            includeSummary: summary, includeConcerns: showConcerns,
                            includeQuestions: showQuestions,
                            comments: [], bodyDraft: "", usage: EngineUsage(), validationIssues: [])
    }

    // MARK: - 체크 조합

    func testSummaryOnlyHasNoDanglingReference() {
        let body = PostBuilder.composedBody(record: record())
        XCTAssertEqual(body, "머지를 막을 사안은 없습니다.", "켜지지 않은 항목을 가리키면 안 된다")
    }

    func testConcernsOnAddsOnlyItsNote() {
        let body = PostBuilder.composedBody(record: record(showConcerns: true))
        XCTAssertTrue(body.contains("우려는 아래에 적었습니다."))
        XCTAssertFalse(body.contains("질문은 아래에 남깁니다."))
    }

    func testQuestionsOnAddsOnlyItsNote() {
        let body = PostBuilder.composedBody(record: record(showQuestions: true))
        XCTAssertTrue(body.contains("질문은 아래에 남깁니다."))
        XCTAssertFalse(body.contains("우려는 아래에 적었습니다."))
    }

    func testBothOnAddsBothNotesInOrder() {
        let body = PostBuilder.composedBody(record: record(showConcerns: true, showQuestions: true))
        let concerns = try? XCTUnwrap(body.range(of: "우려는 아래에 적었습니다."))
        let questions = try? XCTUnwrap(body.range(of: "질문은 아래에 남깁니다."))
        XCTAssertNotNil(concerns)
        XCTAssertNotNil(questions)
        if let concerns, let questions {
            XCTAssertTrue(concerns.lowerBound < questions.lowerBound, "우려 → 질문 순서")
        }
    }

    /// 안내는 요약 문장의 일부다. 요약이 꺼져 있으면 혼자 첫 줄로 튀어나오면 안 된다.
    func testNotesDoNotAppearWithoutTheSummary() {
        let body = PostBuilder.composedBody(record: record(summary: false, showConcerns: true, showQuestions: true))
        XCTAssertFalse(body.contains("아래에 적었습니다."))
        XCTAssertFalse(body.contains("아래에 남깁니다."))
    }

    /// 켰지만 항목이 비어 있으면 소개할 것이 없다.
    func testEmptySectionGetsNoNote() {
        let body = PostBuilder.composedBody(record: record(concerns: 0, showConcerns: true))
        XCTAssertFalse(body.contains("우려는 아래에 적었습니다."))
    }

    func testBlankNoteIsIgnored() {
        let body = PostBuilder.composedBody(record: record(concernsNote: "   ", showConcerns: true))
        XCTAssertEqual(body.components(separatedBy: "\n").first, "머지를 막을 사안은 없습니다.")
        XCTAssertFalse(body.contains("\n\n\n"))
    }

    /// 안내 문장이 없는 옛 초안도 그대로 조립돼야 한다.
    func testOldRecordWithoutNotesStillComposes() throws {
        let old = record(concernsNote: nil, questionsNote: nil, showConcerns: true, showQuestions: true)
        let body = PostBuilder.composedBody(record: old)
        XCTAssertTrue(body.contains("머지를 막을 사안은 없습니다."))
        XCTAssertTrue(body.contains("- [높음] 우려 0") || body.contains("우려 0"))
    }

    func testDecodesOutputWithoutTheNewFields() throws {
        let json = """
        {"verdict":"comment","summary_ko":"요약","concerns":[],"strengths":[],
         "draft_comments":[]}
        """
        let decoded = try JSONDecoder().decode(ReviewOutput.self, from: Data(json.utf8))
        XCTAssertNil(decoded.concernsNoteKo)
        XCTAssertNil(decoded.questionsNoteKo)
    }

    func testDecodesOutputWithTheNewFields() throws {
        let json = """
        {"verdict":"comment","summary_ko":"요약","concerns":[],"strengths":[],
         "draft_comments":[],
         "concerns_note_ko":"우려 안내","questions_note_ko":"질문 안내"}
        """
        let decoded = try JSONDecoder().decode(ReviewOutput.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.concernsNoteKo, "우려 안내")
        XCTAssertEqual(decoded.questionsNoteKo, "질문 안내")
    }

    /// 새 형식: 지적은 code_comments 하나이고, 앱 안에서는 줄에 달 코멘트(DraftComment)로 바뀐다.
    /// 중요도는 필수 → blocker, 권장 → minor, 참고 → nit 로 옮긴다(화면은 다시 필수·권장·참고로 보인다).
    func testDecodesCodeCommentsIntoInlineDrafts() throws {
        let json = """
        {"code_comments":[
           {"issue_key":"double-resume","importance":"required","path":"A.swift","line":12,"side":"RIGHT",
            "body":"취소와 완료가 겹치면 continuation 이 두 번 깨어납니다.","anchor_text":"cont.resume()",
            "rationale_ko":"근거","evidence":[{"path":"A.swift","line":12,"note":"여기서 깨운다"}]},
           {"issue_key":"cleanup","importance":"recommended","path":"B.swift","line":3,"start_line":1,"side":"LEFT",
            "body":"(비블로커) 옵저버 해제가 빠졌습니다.","anchor_text":"observe()","rationale_ko":"근거",
            "duplicates_existing":true,"existing_note":"riley 가 짚음"},
           {"issue_key":"ask","importance":"informational","path":"C.swift","line":7,"side":"RIGHT",
            "body":"[질문] 이 값은 의도된 기본값인가요?","anchor_text":"let x = 1","rationale_ko":"근거"}],
         "verdict":"request_changes","summary_ko":"요약","strengths":[]}
        """
        let decoded = try JSONDecoder().decode(ReviewOutput.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.concerns.isEmpty)
        XCTAssertNil(decoded.questionsForAuthor)
        XCTAssertEqual(decoded.draftComments.map(\.severity), [.blocker, .minor, .nit])
        XCTAssertEqual(decoded.draftComments.map(\.issueKey), ["double-resume", "cleanup", "ask"])
        let second = decoded.draftComments[1]
        XCTAssertEqual(second.side, .left)
        XCTAssertEqual(second.startLine, 1)
        XCTAssertEqual(second.duplicatesExisting, true)
        XCTAssertEqual(second.existingNote, "riley 가 짚음")
        XCTAssertEqual(decoded.draftComments[0].evidence?.first?.line, 12)
    }

    /// 저장은 예전 꼴(draft_comments)로 한다 — 옛 앱·옛 기록과 같은 모양이라야 다시 읽힌다.
    func testCodeCommentsSurviveSaveAndReload() throws {
        let json = """
        {"code_comments":[{"issue_key":"k","importance":"recommended","path":"A.swift","line":1,"side":"RIGHT",
          "body":"(비블로커) 정리가 빠졌습니다.","anchor_text":"a","rationale_ko":"근거"}],
         "verdict":"comment","summary_ko":"요약","strengths":["좋습니다"]}
        """
        let decoded = try JSONDecoder().decode(ReviewOutput.self, from: Data(json.utf8))
        let saved = try JSONEncoder().encode(decoded)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(raw["code_comments"])
        XCTAssertNotNil(raw["draft_comments"])
        let reloaded = try JSONDecoder().decode(ReviewOutput.self, from: saved)
        XCTAssertEqual(reloaded.draftComments.map(\.severity), [.minor])
        XCTAssertEqual(reloaded.strengths, ["좋습니다"])
    }
}

/// 모델이 예시의 따옴표까지 따라 쓴 것을 걷어 낸다(실측 7회차: 요약이 `…두셨습니다."` 로 끝났다).
final class StrayQuoteTests: XCTestCase {
    func testStripsUnpairedTrailingQuote() {
        XCTAssertEqual(ReviewOutput.strippingStrayQuotes("…깔끔하게 맞춰 두셨습니다.\""), "…깔끔하게 맞춰 두셨습니다.")
        XCTAssertEqual(ReviewOutput.strippingStrayQuotes("\"…깔끔하게 맞춰 두셨습니다."), "…깔끔하게 맞춰 두셨습니다.")
    }

    func testUnwrapsFullyQuotedText() {
        XCTAssertEqual(ReviewOutput.strippingStrayQuotes("\"오타 두 곳만 고친 변경입니다.\""), "오타 두 곳만 고친 변경입니다.")
        XCTAssertEqual(ReviewOutput.strippingStrayQuotes("“오타 두 곳만 고친 변경입니다.”"), "오타 두 곳만 고친 변경입니다.")
    }

    /// 짝이 맞는 따옴표는 인용이다. 건드리면 원문을 망가뜨린다.
    func testKeepsQuotations() {
        for text in ["기존의 \"알 수 없는 오류\" 알럿을 리포트로 바꾼 변경입니다.",
                     "\"알 수 없는 오류\" 알럿을 리포트로 바꾼 변경입니다.",
                     "알럿 문구를 \"확인\" 으로 바꿔 \"취소\" 와 나란히 둔 점이 좋습니다",
                     "따옴표가 없는 문장입니다."] {
            XCTAssertEqual(ReviewOutput.strippingStrayQuotes(text), text)
        }
        // 인용이 있고 끝에 짝 없는 따옴표가 하나 더 붙은 경우는 끝의 것만 뗀다.
        XCTAssertEqual(ReviewOutput.strippingStrayQuotes("기존의 \"알 수 없는 오류\" 알럿을 정리했습니다.\""),
                       "기존의 \"알 수 없는 오류\" 알럿을 정리했습니다.")
    }

    func testTidiedCoversEveryProseField() {
        let output = ReviewOutput(verdict: .comment, summaryKo: "요약입니다.\"", concerns: [],
                                  strengths: ["\"칭찬이 꼼꼼합니다\""], draftComments: [],
                                  concernsNoteKo: "우려 안내입니다.\"", questionsNoteKo: "\"질문 안내입니다.")
        let tidy = output.tidied()
        XCTAssertEqual(tidy.summaryKo, "요약입니다.")
        XCTAssertEqual(tidy.strengths, ["칭찬이 꼼꼼합니다"])
        XCTAssertEqual(tidy.concernsNoteKo, "우려 안내입니다.")
        XCTAssertEqual(tidy.questionsNoteKo, "질문 안내입니다.")
        XCTAssertEqual(ReviewOutput(verdict: .approve, summaryKo: "그대로입니다.", concerns: [], strengths: [],
                                    draftComments: []).tidied().summaryKo, "그대로입니다.")
    }
}

/// 모델이 값 안에 출력 형식의 조각을 흘린 것을 잘라 낸다(실측 14회차).
final class LeakedMarkupTests: XCTestCase {
    func testCutsLeakedClosingTag() {
        XCTAssertEqual(ReviewOutput.cuttingLeakedMarkup("…빠짐없이 보완해 승인합니다.</summary_ko... let me fix>"),
                       "…빠짐없이 보완해 승인합니다.")
        XCTAssertEqual(ReviewOutput.cuttingLeakedMarkup("…승인합니다. <parameter name=\"strengths\">[…]"), "…승인합니다.")
    }

    /// 코드의 꺾쇠(제네릭·HTML)는 태그가 아니다.
    func testKeepsAngleBracketsInCode() {
        for text in ["`Array<Int>` 로 받던 값을 `Set<String>` 으로 바꾼 변경입니다.",
                     "`<br>` 태그를 줄바꿈으로 바꾸는 처리가 꼼꼼합니다",
                     "`Result<Void, Error>` 를 그대로 돌려주도록 맞춰 승인합니다."] {
            XCTAssertEqual(ReviewOutput.cuttingLeakedMarkup(text), text)
        }
    }

    func testTidiedCutsEveryPostedField() {
        let leak = "</summary_ko… let me fix>"
        let output = ReviewOutput(
            verdict: .comment, summaryKo: "요약입니다.\(leak)",
            concerns: [Concern(issueKey: "c", severity: .major, title: "우려 제목\(leak)", path: "A.swift", line: 1)],
            strengths: ["칭찬이 꼼꼼합니다\(leak)"],
            draftComments: [DraftComment(issueKey: "c", path: "A.swift", line: 1, side: .right,
                                         body: "코멘트 본문입니다.\(leak)", severity: .major, anchorText: "x")],
            questionsForAuthor: [AuthorQuestion(question: "질문인가요?\(leak)")],
            concernsNoteKo: "우려 안내입니다.\(leak)", questionsNoteKo: "질문 안내입니다.\(leak)")
        let tidy = output.tidied()
        XCTAssertEqual(tidy.summaryKo, "요약입니다.")
        XCTAssertEqual(tidy.strengths, ["칭찬이 꼼꼼합니다"])
        XCTAssertEqual(tidy.concerns.first?.title, "우려 제목")
        XCTAssertEqual(tidy.draftComments.first?.body, "코멘트 본문입니다.")
        XCTAssertEqual(tidy.questionsForAuthor?.first?.question, "질문인가요?")
        XCTAssertEqual(tidy.concernsNoteKo, "우려 안내입니다.")
        XCTAssertEqual(tidy.questionsNoteKo, "질문 안내입니다.")
    }
}
