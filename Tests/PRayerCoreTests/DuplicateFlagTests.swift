import XCTest
@testable import PRayerCore

/// 초안 코멘트에만 있던 "이미 언급됨" 표시를 우려사항·작성자 질문까지 넓힌 뒤의 계약.
final class DuplicateFlagTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - 우려사항

    func testConcernDuplicateFlagRoundTrips() throws {
        let concern = try decode("""
        {"issue_key":"c1","severity":"major","title":"제목","path":"A.swift",
         "duplicates_existing":true,"existing_note":"alex 가 같은 지적을 했습니다"}
        """, as: Concern.self)
        XCTAssertTrue(concern.isDuplicate)
        XCTAssertEqual(concern.existingNote, "alex 가 같은 지적을 했습니다")

        let again = try decode(String(decoding: try JSONEncoder().encode(concern), as: UTF8.self),
                               as: Concern.self)
        XCTAssertEqual(again, concern, "저장했다 읽으면 그대로여야 한다")
    }

    /// 옛 초안에는 두 필드가 없다. 없으면 "중복 아님" 이다.
    func testConcernWithoutFlagsIsNotDuplicate() throws {
        let concern = try decode("""
        {"issue_key":"c1","severity":"minor","title":"제목","path":"A.swift"}
        """, as: Concern.self)
        XCTAssertFalse(concern.isDuplicate)
        XCTAssertNil(concern.existingNote)
    }

    // MARK: - 작성자 질문 (직접 쓴 디코더라 갈래가 셋이다)

    func testQuestionLegacyStringStillDecodes() throws {
        let question = try decode("\"이거 왜 이렇게 했나요?\"", as: AuthorQuestion.self)
        XCTAssertEqual(question.question, "이거 왜 이렇게 했나요?")
        XCTAssertNil(question.issueKey)
        XCTAssertFalse(question.isDuplicate)
    }

    func testQuestionKeyedFormWithoutNewFields() throws {
        let question = try decode("""
        {"question":"질문","rationale_ko":"근거"}
        """, as: AuthorQuestion.self)
        XCTAssertNil(question.issueKey)
        XCTAssertFalse(question.isDuplicate)
    }

    func testQuestionWithIssueKeyAndDuplicateFlag() throws {
        let question = try decode("""
        {"issue_key":"q1","question":"질문","rationale_ko":"근거",
         "duplicates_existing":true,"existing_note":"sam 이 이미 물었습니다"}
        """, as: AuthorQuestion.self)
        XCTAssertEqual(question.issueKey, "q1")
        XCTAssertTrue(question.isDuplicate)
        XCTAssertEqual(question.existingNote, "sam 이 이미 물었습니다")
    }

    // MARK: - 안정된 열쇠

    func testStableKeyPrefersIssueKey() {
        let question = AuthorQuestion(question: "질문", issueKey: "q1")
        XCTAssertEqual(question.stableKey, "q1")
    }

    /// 열쇠가 실행마다 바뀌면 저장해 둔 결과가 통째로 미아가 된다.
    /// (String.hashValue 는 프로세스마다 시드가 달라 쓸 수 없다.)
    func testStableKeyIsDeterministicWithoutIssueKey() {
        let a = AuthorQuestion(question: "  다른 경우도 테스트할 계획이 있을까요?  ")
        let b = AuthorQuestion(question: "다른 경우도 테스트할 계획이 있을까요?")
        XCTAssertEqual(a.stableKey, b.stableKey, "앞뒤 공백은 같은 것으로 본다")
        XCTAssertEqual(a.stableKey, "q:1082dcc4fd45e9ba",
                       "값이 실행마다 달라지면 안 된다(달라졌다면 해시가 바뀐 것이다)")
        XCTAssertNotEqual(a.stableKey, AuthorQuestion(question: "다른 질문").stableKey)
    }

    // MARK: - 게시 본문

    /// 이미 나온 얘기를 빼 버리면 리뷰어가 올리려던 것이 조용히 사라지고,
    /// 표시 없이 올리면 작성자는 처음 보는 지적으로 읽는다. 남기되 표시한다.
    func testDuplicatesAreMarkedInThePostedBody() {
        let output = ReviewOutput(
            verdict: .comment,
            summaryKo: "요약",
            concerns: [Concern(issueKey: "c1", severity: .major, title: "기존 지적",
                               path: "A.swift", duplicatesExisting: true),
                       Concern(issueKey: "c2", severity: .major, title: "새 지적", path: "A.swift")],
            strengths: [],
            draftComments: [])
        var record = Fixtures.record(pr: Fixtures.pr(), output: output)
        record.includeConcerns = true
        record.includeQuestions = true
        let body = PostBuilder.composedBody(record: record)
        XCTAssertTrue(body.contains("기존 지적 (이미 언급된 사안)"))
        XCTAssertTrue(body.contains("새 지적"))
        XCTAssertFalse(body.contains("새 지적 (이미"), "중복이 아닌 항목에는 표시가 붙지 않는다")
    }
}
