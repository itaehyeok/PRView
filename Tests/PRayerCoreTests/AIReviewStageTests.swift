import XCTest
@testable import PRayerCore

/// 상세 탭 줄 "AI 리뷰" 칸 아래 한 줄이 AI 리뷰 단계를 맞게 말하는가.
///
/// 배경: 탭마다 이름 아래 상태를 한 줄씩 붙이면서(사용자 선택 B안) AI 리뷰 칸이 초안·게시 말고도
/// 대기·실패·새 커밋을 말하게 됐다. 무엇이 무엇보다 앞서는지가 틀리면 "리뷰 중인데 리뷰 완료" 처럼 보인다.
final class AIReviewStageTests: XCTestCase {
    private let head = "head000000000"
    private let queuedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(head recordHead: String? = nil, posted: Bool = false, createdAt: Date? = nil) -> ReviewRecord {
        let pr = Fixtures.pr(headRefOid: head)
        var record = Fixtures.record(pr: pr, output: Fixtures.output(),
                                     posted: posted ? PostedInfo(reviewID: 1, htmlURL: "u", event: "APPROVE",
                                                                 postedAt: queuedAt, commentCount: 0) : nil,
                                     headSha: recordHead)
        if let createdAt { record.createdAt = createdAt }
        return record
    }

    private func stage(_ lastJob: AIReviewStage.LastJob?, _ record: ReviewRecord?) -> AIReviewStage {
        AIReviewStage.resolve(lastJob: lastJob, record: record, headSha: head)
    }

    /// 사용자와 정한 이름 그대로. 오래됨은 목록 배지 덧표시와 같은 말이어야 한다.
    func testLabelsAreTheChosenNames() {
        XCTAssertEqual(AIReviewStage.notReviewed.label, "리뷰 전")
        XCTAssertEqual(AIReviewStage.queued.label, "대기 중")
        XCTAssertEqual(AIReviewStage.running.label, "리뷰 중")
        XCTAssertEqual(AIReviewStage.ready.label, "리뷰 완료")
        XCTAssertEqual(AIReviewStage.posted.label, "게시함")
        XCTAssertEqual(AIReviewStage.failed.label, "실패")
        XCTAssertEqual(AIReviewStage.stale.label, PRBadgeOverlay.stale.label)
    }

    func testNothingYetIsNotReviewed() {
        XCTAssertEqual(stage(nil, nil), .notReviewed)
    }

    /// 돌고 있으면 남은 기록보다 그게 먼저다 — 다시 돌리는 중인데 지난 초안을 말하면 안 된다.
    func testActiveJobWinsOverRecord() {
        XCTAssertEqual(stage(.queued, record()), .queued)
        XCTAssertEqual(stage(.running, record(posted: true)), .running)
        XCTAssertEqual(stage(.running, record(head: "old0000000000")), .running)
    }

    func testDraftOnHeadIsReadyAndPostedIsPosted() {
        XCTAssertEqual(stage(nil, record()), .ready)
        XCTAssertEqual(stage(nil, record(posted: true)), .posted)
    }

    /// 초안이든 게시한 리뷰든, 그 뒤 새 커밋이 왔으면 오래됨(목록 배지와 같은 순서).
    func testRecordOnOlderCommitIsStaleEvenIfPosted() {
        XCTAssertEqual(stage(nil, record(head: "old0000000000")), .stale)
        XCTAssertEqual(stage(nil, record(head: "old0000000000", posted: true)), .stale)
    }

    /// 마지막 잡이 실패했으면 그보다 앞서 만든 기록이 있어도 실패를 말한다 — 다시 돌릴 일이 남았다.
    func testFailedJobWinsOverOlderRecord() {
        XCTAssertEqual(stage(.failed(queuedAt: queuedAt), nil), .failed)
        XCTAssertEqual(stage(.failed(queuedAt: queuedAt), record(createdAt: queuedAt.addingTimeInterval(-60))), .failed)
    }

    /// 실패보다 나중에 생긴 기록이 있으면 실패는 지난 일이다.
    func testRecordNewerThanFailureWins() {
        XCTAssertEqual(stage(.failed(queuedAt: queuedAt), record(createdAt: queuedAt.addingTimeInterval(60))), .ready)
    }
}
