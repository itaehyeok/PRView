import XCTest
@testable import PRayerCore

/// 리뷰 본문에서 사용자가 고친 글(`ReviewTextEdits`).
final class ReviewTextEditsTests: XCTestCase {
    private let concern = Concern(issueKey: "c1", severity: .major, title: "만료 시각을 기기 시계로 비교함",
                                  path: "Cache.swift", line: 88)
    private let question = AuthorQuestion(question: "갱신 주기를 서버 값으로 바꿀 계획이 있나요?")

    private func record() -> ReviewRecord {
        var output = Fixtures.output(concerns: [concern])
        output.questionsForAuthor = [question]
        var record = Fixtures.record(pr: Fixtures.pr(), output: output)
        record.includeConcerns = true
        record.includeQuestions = true
        return record
    }

    /// 게시 본문(게시 버튼·미리보기 상자가 같이 쓰는 함수)이 고친 글로 조립된다.
    func testComposedBodyUsesEditedText() {
        var record = record()
        record.setSummaryEdit("요약을 고쳤습니다.")
        record.setStrengthsEdit(["잘된 점 하나", "잘된 점 둘"])
        record.setItemEdit("서버 시각과 비교하도록 바꾸면 시간대가 바뀌어도 맞습니다",
                           for: ReviewItemKey.concern(concern), original: concern.title)
        record.setItemEdit("갱신 주기는 서버 값을 따르나요?",
                           for: ReviewItemKey.question(question), original: question.question)

        let body = PostBuilder.composedBody(record: record)
        XCTAssertTrue(body.contains("요약을 고쳤습니다."))
        XCTAssertFalse(body.contains("요약입니다."))
        XCTAssertTrue(body.contains("- 잘된 점 하나\n- 잘된 점 둘"))
        XCTAssertFalse(body.contains("구조 분리가 합리적입니다."))
        XCTAssertTrue(body.contains("- [\(concern.severity.label)] 서버 시각과 비교하도록"))
        XCTAssertFalse(body.contains(concern.title))
        XCTAssertTrue(body.contains("- 갱신 주기는 서버 값을 따르나요?"))
        // 원문은 그대로 남는다 — 되돌릴 자리이자 항목 키의 재료다.
        XCTAssertEqual(record.output.summaryKo, "요약입니다.")
        XCTAssertEqual(record.output.concerns.first?.title, concern.title)
    }

    /// 질문 키는 문장의 해시다. 문장을 고쳐도 키가 바뀌지 않아야 정리 표시 같은 항목 상태가 남는다.
    func testEditingKeepsItemKeys() {
        var record = record()
        let key = ReviewItemKey.question(question)
        record.setCleared("확인했습니다", for: key)
        record.setItemEdit("다른 문장", for: key, original: question.question)
        XCTAssertEqual(record.clearedNote(for: key), "확인했습니다")
        XCTAssertEqual(ReviewItemKey.question(record.output.questionsForAuthor![0]), key)
    }

    /// 원문과 같아지면 고친 값을 지운다 — "수정함" 표시가 실제로 다른지를 말하게.
    func testSettingOriginalClearsEdit() {
        var record = record()
        record.setSummaryEdit("다른 요약")
        XCTAssertTrue(record.isSummaryEdited)
        record.setSummaryEdit("  요약입니다.\n")
        XCTAssertFalse(record.isSummaryEdited)

        record.setStrengthsEdit(["구조 분리가 합리적입니다."])
        XCTAssertFalse(record.isStrengthsEdited)

        let key = ReviewItemKey.concern(concern)
        record.setItemEdit("다른 제목", for: key, original: concern.title)
        XCTAssertTrue(record.isEdited(itemKey: key))
        record.setItemEdit(concern.title, for: key, original: concern.title)
        XCTAssertFalse(record.isEdited(itemKey: key))
        // 다 되돌리면 필드째 비워 옛 기록과 같은 모양이 된다.
        XCTAssertNil(record.textEdits)
    }

    /// 빈 글은 저장하지 않는다(편집기도 막는다) — 본문에서 빼는 건 체크박스가 한다.
    func testEmptyItemTextRevertsToOriginal() {
        var record = record()
        let key = ReviewItemKey.concern(concern)
        record.setItemEdit("다른 제목", for: key, original: concern.title)
        record.setItemEdit("   ", for: key, original: concern.title)
        XCTAssertEqual(record.text(for: concern), concern.title)
    }

    /// 잘된 점 편집기는 한 줄이 항목 하나다. 불릿을 쳤든 안 쳤든, 빈 줄이 섞였든 받아 준다.
    func testStrengthsEditorRoundTrip() {
        let items = ["경계 처리가 꼼꼼합니다", "테스트까지 묶어 좋습니다"]
        XCTAssertEqual(ReviewTextEdits.editorText(strengths: items), "- 경계 처리가 꼼꼼합니다\n- 테스트까지 묶어 좋습니다")
        XCTAssertEqual(ReviewTextEdits.strengths(fromEditorText: ReviewTextEdits.editorText(strengths: items)), items)
        XCTAssertEqual(ReviewTextEdits.strengths(fromEditorText: "- 하나\n\n* 둘\n• 셋\n  넷  \n-다섯"),
                       ["하나", "둘", "셋", "넷", "다섯"])
    }

    /// "요약과 함께 Approve" 의 짧은 본문도 고친 요약·잘된 점을 쓴다.
    func testDefaultBodyUsesEdits() {
        var record = record()
        XCTAssertEqual(PostBuilder.defaultBody(record: record),
                       PostBuilder.defaultBody(output: record.output, includeStrengths: true))
        record.setSummaryEdit("고친 요약")
        record.setStrengthsEdit(["고친 칭찬"])
        let body = PostBuilder.defaultBody(record: record)
        XCTAssertTrue(body.contains("고친 요약"))
        XCTAssertTrue(body.contains("고친 칭찬"))
        XCTAssertFalse(body.contains("요약입니다."))
    }

    /// 본문에서 고친 문장으로 인라인 초안을 만든다 — 다듬은 글이 원문으로 돌아가면 안 된다.
    func testMoveToInlineCarriesEditedText() throws {
        let diff = DiffParser.parse("""
            diff --git a/Cache.swift b/Cache.swift
            --- a/Cache.swift
            +++ b/Cache.swift
            @@ -86,3 +86,3 @@
             let a = 1
            -let b = 2
            +let b = 3
             let c = 4
            """)
        var record = record()
        let key = ReviewItemKey.concern(concern)
        record.setItemEdit("고친 우려 문장", for: key, original: concern.title)
        let item = try XCTUnwrap(ReviewFollowList.items(in: record.output).first { $0.key == key })
        XCTAssertTrue(record.moveToInline(item, locationIndex: 0, diff: diff))
        XCTAssertEqual(record.comments.last?.comment.body, "고친 우려 문장")
    }

    /// 0.5.1 전 기록에는 textEdits 가 없다. 읽혀야 하고, 원문을 그대로 쓴다.
    func testRecordWithoutTextEditsStillDecodes() throws {
        var record = record()
        record.setSummaryEdit("고친 요약")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let roundTrip = try decoder.decode(ReviewRecord.self, from: encoder.encode(record))
        XCTAssertEqual(roundTrip.effectiveSummary, "고친 요약")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        object.removeValue(forKey: "textEdits")
        let old = try decoder.decode(ReviewRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.textEdits)
        XCTAssertEqual(old.effectiveSummary, "요약입니다.")
    }
}
