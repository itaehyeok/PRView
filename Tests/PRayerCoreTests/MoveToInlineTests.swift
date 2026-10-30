import XCTest
@testable import PRayerCore

/// 변경 파일 탭에서 우려사항·질문을 그 줄의 인라인 초안으로 옮기기.
final class MoveToInlineTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    private var diff: ParsedDiff {
        DiffParser.parse(DiffParserTests.sample, excluding: ["*.pbxproj"])
    }

    private func concern(_ key: String = "c1", line: Int? = 11, side: DiffSide? = .right,
                         path: String = "Sources/Foo.swift") -> Concern {
        Concern(issueKey: key, severity: .major, title: "실패를 조용히 흘려 상태가 어긋남",
                path: path, line: line, side: side)
    }

    private func question(evidence: [CodeEvidence]) -> AuthorQuestion {
        AuthorQuestion(question: "실패했을 때 화면에는 무엇을 보여 주나요?",
                       rationaleKo: "실패 경로가 화면 상태를 안 바꾼다",
                       evidence: evidence)
    }

    private func record(concerns: [Concern] = [], questions: [AuthorQuestion]? = nil) -> ReviewRecord {
        let output = ReviewOutput(verdict: .comment, summaryKo: "요약", concerns: concerns,
                                  strengths: [], draftComments: [], questionsForAuthor: questions,
                                  concernsNoteKo: "우려 안내", questionsNoteKo: "질문 안내")
        var record = ReviewRecord(repo: repo, number: 1, headSha: "abc", baseRefName: "develop",
                                  promptVersion: "v1", model: "opus", trigger: .manual, output: output,
                                  comments: [], bodyDraft: "", usage: EngineUsage(), validationIssues: [])
        record.includeConcerns = true
        record.includeQuestions = true
        return record
    }

    // MARK: - 따라갈 목록

    /// 리뷰 탭에서 읽던 순서(우려사항 → 질문)와 ‹ › 로 넘기는 순서가 같아야 한다.
    /// 줄을 모르는 것은 펼칠 자리가 없어 뺀다.
    func testFollowListKeepsBodyOrderAndSkipsItemsWithoutLines() {
        let rec = record(concerns: [concern("c1"), concern("c2", line: nil), concern("c3", line: 12)],
                         questions: [question(evidence: [CodeEvidence(path: "Sources/Foo.swift", line: 12, note: "근거"),
                                                         CodeEvidence(path: "Sources/Foo.swift", line: nil, note: "파일만")]),
                                     question(evidence: [])])
        let items = ReviewFollowList.items(in: rec.output)
        XCTAssertEqual(items.map(\.key), [ReviewItemKey.concern(rec.output.concerns[0]),
                                          ReviewItemKey.concern(rec.output.concerns[2]),
                                          ReviewItemKey.question(rec.output.questionsForAuthor![0])])
        XCTAssertEqual(items[2].locations.count, 1, "줄 없는 근거는 자리로 세지 않는다")
        XCTAssertEqual(items[2].kind, .question)
    }

    /// 모델이 side 를 빼먹은 우려사항은 새 코드 쪽으로 본다.
    func testConcernWithoutSideFollowsTheNewCode() {
        let items = ReviewFollowList.items(in: record(concerns: [concern(side: nil)]).output)
        XCTAssertEqual(items.first?.locations.first?.side, .right)
        XCTAssertEqual(items.first?.locations.first?.diffKey, "Sources/Foo.swift#RIGHT#11")
    }

    // MARK: - 옮기기

    func testMovingAConcernAddsAPostableDraftAndTakesItOutOfTheBody() {
        var rec = record(concerns: [concern("c1"), concern("c2", line: 12)])
        let item = ReviewFollowList.items(in: rec.output)[0]
        XCTAssertTrue(rec.moveToInline(item, locationIndex: 0, diff: diff))

        XCTAssertEqual(rec.comments.count, 1)
        let draft = rec.comments[0]
        XCTAssertTrue(draft.isPostable)
        XCTAssertEqual(draft.comment.path, "Sources/Foo.swift")
        XCTAssertEqual(draft.comment.line, 11)
        XCTAssertEqual(draft.comment.side, .right)
        XCTAssertEqual(draft.comment.severity, .major)
        XCTAssertEqual(draft.editedBody, "실패를 조용히 흘려 상태가 어긋남")
        XCTAssertEqual(draft.comment.anchorText, "        guard let x = try? compute() else { return }",
                       "앵커는 그 줄의 글 그대로 — 다시 검증해도 같은 줄에 붙는다")

        let body = PostBuilder.composedBody(record: rec)
        XCTAssertFalse(body.contains("[높음] 실패를 조용히 흘려 상태가 어긋남\n"), "옮긴 것은 본문에서 빠진다")
        XCTAssertEqual(rec.bodyConcerns.map(\.issueKey), ["c2"])
        XCTAssertEqual(PostBuilder.payload(record: rec, event: .comment, body: body).comments.count, 1)
    }

    /// 다 옮기면 본문에 우려사항이 없는데 "아래에 적었습니다" 같은 안내만 남으면 안 된다.
    func testSummaryNoteDisappearsWhenEveryConcernMoved() {
        var rec = record(concerns: [concern("c1")])
        XCTAssertTrue(PostBuilder.composedBody(record: rec).contains("우려 안내"))
        rec.moveToInline(ReviewFollowList.items(in: rec.output)[0], locationIndex: 0, diff: diff)
        let body = PostBuilder.composedBody(record: rec)
        XCTAssertFalse(body.contains("우려 안내"))
        XCTAssertFalse(body.contains("[높음]"))
    }

    func testMovingAQuestionUsesTheChosenEvidenceAndKeepsTheReason() {
        var rec = record(questions: [question(evidence: [CodeEvidence(path: "Sources/Foo.swift", line: 11, note: "첫째"),
                                                         CodeEvidence(path: "Foo.swift", line: 12, note: "둘째")])])
        let item = ReviewFollowList.items(in: rec.output)[0]
        XCTAssertTrue(rec.moveToInline(item, locationIndex: 1, diff: diff))
        let draft = rec.comments[0].comment
        XCTAssertEqual(draft.path, "Sources/Foo.swift", "접미로만 맞은 경로는 diff 의 경로로 바꿔 보낸다")
        XCTAssertEqual(draft.line, 12)
        XCTAssertEqual(draft.severity, .minor, "질문은 머지를 막는 심각도로 세지 않는다")
        XCTAssertEqual(draft.rationaleKo, "실패 경로가 화면 상태를 안 바꾼다")
        XCTAssertEqual(draft.evidence?.count, 2)
        XCTAssertTrue(rec.bodyQuestions.isEmpty)
        XCTAssertFalse(PostBuilder.composedBody(record: rec).contains("질문 안내"))
    }

    /// diff 밖의 줄에 단 코멘트가 하나라도 있으면 GitHub 이 리뷰 전체를 거부한다.
    func testLineOutsideTheDiffCannotBeMoved() {
        var rec = record(concerns: [concern(line: 40)])
        let item = ReviewFollowList.items(in: rec.output)[0]
        XCTAssertFalse(ReviewRecord.canAttachInline(at: item.locations[0], diff: diff))
        XCTAssertFalse(rec.moveToInline(item, locationIndex: 0, diff: diff))
        XCTAssertTrue(rec.comments.isEmpty)
        XCTAssertNil(rec.movedToInline)
    }

    /// 삭제된 줄은 옛 코드 쪽(LEFT)에만 있다. 새 코드 쪽 번호로는 달 수 없다.
    func testDeletedLineNeedsTheOldSide() {
        let left = concern(line: 11, side: .left)
        var rec = record(concerns: [left])
        let item = ReviewFollowList.items(in: rec.output)[0]
        XCTAssertTrue(rec.moveToInline(item, locationIndex: 0, diff: diff))
        XCTAssertEqual(rec.comments[0].comment.anchorText, "        let x = try! compute()")
    }

    func testMovingTwiceDoesNothing() {
        var rec = record(concerns: [concern()])
        let item = ReviewFollowList.items(in: rec.output)[0]
        XCTAssertTrue(rec.moveToInline(item, locationIndex: 0, diff: diff))
        XCTAssertFalse(rec.moveToInline(item, locationIndex: 0, diff: diff))
        XCTAssertEqual(rec.comments.count, 1)
    }

    func testPostedReviewCannotBeChanged() {
        var rec = record(concerns: [concern()])
        rec.posted = PostedInfo(reviewID: 1, htmlURL: "", event: "COMMENT", postedAt: Date(), commentCount: 0)
        XCTAssertFalse(rec.moveToInline(ReviewFollowList.items(in: rec.output)[0], locationIndex: 0, diff: diff))
    }

    /// 정리해 둔 항목을 옮기면 "확인했고 문제없던 것" 과 같은 자리의 지적이 같이 나간다.
    func testMovingClearsAnEarlierClearedNote() {
        var rec = record(concerns: [concern()])
        let item = ReviewFollowList.items(in: rec.output)[0]
        rec.setCleared("확인했습니다", for: item.key)
        rec.moveToInline(item, locationIndex: 0, diff: diff)
        XCTAssertFalse(rec.isCleared(item.key))
    }

    // MARK: - 되돌리기

    func testUndoRemovesTheDraftAndPutsTheItemBack() {
        var rec = record(concerns: [concern()])
        let item = ReviewFollowList.items(in: rec.output)[0]
        rec.moveToInline(item, locationIndex: 0, diff: diff)
        rec.setCleared("초안도 확인함", for: ReviewItemKey.draft(rec.comments[0].comment))

        rec.undoMoveToInline(item.key)
        XCTAssertTrue(rec.comments.isEmpty)
        XCTAssertNil(rec.movedToInline, "다 되돌리면 사전 자체를 비운다")
        XCTAssertNil(rec.clearedItems, "지운 초안에 걸린 정리 표시도 같이 지운다")
        XCTAssertEqual(rec.bodyConcerns.count, 1)
        XCTAssertTrue(PostBuilder.composedBody(record: rec).contains("[높음] 실패를 조용히 흘려 상태가 어긋남"))
    }

    /// 옮긴 것을 저장했다 다시 읽어도 그대로여야 한다. 옛 기록(필드 없음)도 읽혀야 한다.
    func testMovedItemsSurviveEncodingAndOldRecordsStillDecode() throws {
        var rec = record(concerns: [concern()])
        rec.moveToInline(ReviewFollowList.items(in: rec.output)[0], locationIndex: 0, diff: diff)
        let decoded = try JSONDecoder().decode(ReviewRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.movedToInline, rec.movedToInline)
        XCTAssertNotNil(decoded.movedDraft(for: ReviewItemKey.concern(rec.output.concerns[0])))

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(concerns: [concern()]))) as! [String: Any]
        old.removeValue(forKey: "movedToInline")
        let oldRecord = try JSONDecoder().decode(ReviewRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(oldRecord.movedToInline)
        XCTAssertEqual(oldRecord.bodyConcerns.count, 1)
    }
}
