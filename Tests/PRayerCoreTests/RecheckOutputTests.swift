import XCTest
@testable import PRayerCore

final class RecheckOutputTests: XCTestCase {
    private func decode(_ json: String) throws -> RecheckOutput {
        try JSONDecoder().decode(RecheckOutput.self, from: Data(json.utf8))
    }

    func testDecodesEveryStatus() throws {
        let expected: [(String, ItemRecheck.Status)] = [
            ("fixed_in_commit", .fixedInCommit),
            ("partially_fixed", .partiallyFixed),
            ("answered_in_comment", .answeredInComment),
            ("untouched", .untouched),
            ("cannot_tell", .cannotTell),
        ]
        for (raw, status) in expected {
            let output = try decode("""
            {"status":"\(raw)","summary_ko":"스무 자를 넘기기 위한 충분한 길이의 설명입니다.","evidence":[]}
            """)
            XCTAssertEqual(output.status, status)
        }
    }

    func testDecodesMixedEvidenceKinds() throws {
        let output = try decode("""
        {"status":"partially_fixed","summary_ko":"스무 자를 넘기기 위한 충분한 길이의 설명입니다.",
         "evidence":[{"kind":"commit","ref":"abc1234","note":"새로고침 로직을 되살렸습니다"},
                     {"kind":"comment","ref":"sage","note":"문제 아니라고 정리했습니다"},
                     {"kind":"code","ref":"Feed.swift","path":"A/Feed.swift","line":267,"note":"그대로입니다"}]}
        """)
        XCTAssertEqual(output.evidence.map(\.kind), [.commit, .comment, .code])
        XCTAssertEqual(output.evidence[2].line, 267)
        XCTAssertNil(output.evidence[0].path, "자리가 없는 근거도 있다")
    }

    // MARK: - 근거 없는 확신 내리기

    /// 근거 없이 "고쳐졌습니다" 만 남으면 사용자가 확인할 방법이 없다.
    func testConfidentVerdictsWithoutEvidenceBecomeCannotTell() {
        XCTAssertEqual(ItemRecheck.Status.fixedInCommit.downgradedIfUnsupported(evidenceCount: 0), .cannotTell)
        XCTAssertEqual(ItemRecheck.Status.partiallyFixed.downgradedIfUnsupported(evidenceCount: 0), .cannotTell)
        XCTAssertEqual(ItemRecheck.Status.answeredInComment.downgradedIfUnsupported(evidenceCount: 0), .cannotTell)
    }

    /// "찾아봤는데 없더라" 와 "모르겠다" 는 원래 근거가 없을 수 있다.
    func testStatusesThatMayHaveNoEvidenceSurvive() {
        XCTAssertEqual(ItemRecheck.Status.untouched.downgradedIfUnsupported(evidenceCount: 0), .untouched)
        XCTAssertEqual(ItemRecheck.Status.cannotTell.downgradedIfUnsupported(evidenceCount: 0), .cannotTell)
    }

    func testEvidenceBackedVerdictIsKept() {
        XCTAssertEqual(ItemRecheck.Status.fixedInCommit.downgradedIfUnsupported(evidenceCount: 1), .fixedInCommit)
    }

    // MARK: - 저장

    func testRoundTripsThroughStorage() throws {
        let result = ItemRecheck(key: "k", status: .fixedInCommit, summaryKo: "요약",
                                 evidence: [.init(kind: .commit, ref: "abc1234", note: "고쳤습니다")],
                                 reviewedHeadSha: "aaa", checkedHeadSha: "bbb",
                                 newCommitCount: 2, newCommentCount: 1)
        let again = try JSONDecoder().decode(ItemRecheck.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(again, result)
    }

    /// 판단한 뒤로 PR 이 또 움직였는지 화면이 이걸로 판단한다.
    func testStalenessComparesAgainstCurrentHead() {
        let result = ItemRecheck(key: "k", status: .untouched, summaryKo: "요약", evidence: [],
                                 reviewedHeadSha: "aaa", checkedHeadSha: "bbb",
                                 newCommitCount: 0, newCommentCount: 0)
        XCTAssertFalse(result.isStale(against: "bbb"))
        XCTAssertTrue(result.isStale(against: "ccc"))
    }
}
