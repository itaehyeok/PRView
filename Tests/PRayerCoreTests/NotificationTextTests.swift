import XCTest
@testable import PRayerCore

/// 알림 문구. 제목 한 줄뿐이고, 갈래 표시 + 무슨 일을 짧은 명사로 쓴다(사용자가 고른 꼴, 2026-10-30).
/// 작성자 이름·건수·PR 번호·오류 원문이 다시 끼어들지 않게 잠근다.
final class NotificationTextTests: XCTestCase {
    func testReviewResults() {
        XCTAssertEqual(NotificationText.reviewDone, "✨ AI 리뷰 완료")
        XCTAssertEqual(NotificationText.reviewFailed, "✨ AI 리뷰 실패")
        XCTAssertEqual(NotificationText.limitReached, "✨ 사용 한도 도달")
    }

    func testPRChangeTitles() {
        XCTAssertEqual(NotificationText.prChange(.appeared(reviewRequested: true)), "📥 새 PR")
        XCTAssertEqual(NotificationText.prChange(.appeared(reviewRequested: false)), "📥 새 PR")
        XCTAssertEqual(NotificationText.prChange(.reviewRequested), "📥 리뷰어 지정")
        XCTAssertEqual(NotificationText.prChange(.reReviewRequested), "📥 재리뷰 요청")
        XCTAssertEqual(NotificationText.prChange(.commentsOnMyPR(added: 2)), "📥 내 PR 새 코멘트")
        XCTAssertEqual(NotificationText.prChange(.approvalsReached(count: 3)), "📥 머지 가능")
        XCTAssertEqual(NotificationText.prChange(.checksFailed), "📥 CI 실패")
        XCTAssertEqual(NotificationText.prChange(.conflictAppeared), "📥 충돌")
        XCTAssertEqual(NotificationText.prChange(.newCommitsOnReviewed), "📥 리뷰한 PR 새 커밋")
        XCTAssertEqual(NotificationText.prChange(.merged), "📥 머지 완료")
    }

    func testSummaryIsJustTheCount() {
        XCTAssertEqual(NotificationText.prChangeSummary(count: 5), "📥 PR 소식 5건")
    }

    /// 갈래 표시: 내가 부르지 않았는데 온 PR 변화는 📥, 내가 돌린 리뷰의 결과는 ✨. 한 알림 종류도 빠지면 안 된다.
    func testOriginMarkSplitsIncomingFromRequested() {
        let all: [PRChange] = [.appeared(reviewRequested: true), .appeared(reviewRequested: false), .reviewRequested,
                               .reReviewRequested, .commentsOnMyPR(added: 1), .approvalsReached(count: 1),
                               .checksFailed, .conflictAppeared, .newCommitsOnReviewed, .merged]
        let incoming = all.map(NotificationText.prChange) + [NotificationText.prChangeSummary(count: 4)]
        let requested = [NotificationText.reviewDone, NotificationText.reviewFailed, NotificationText.limitReached]
        for title in incoming { XCTAssertTrue(title.hasPrefix("📥 "), title) }
        for title in requested { XCTAssertTrue(title.hasPrefix("✨ "), title) }
    }
}
