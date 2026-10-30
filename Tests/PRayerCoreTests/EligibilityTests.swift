import XCTest
@testable import PRayerCore

final class EligibilityTests: XCTestCase {
    private var settings = Settings.default

    private func reason(_ pr: PullRequestInfo,
                        threshold: Int = 3,
                        lines: Int? = nil,
                        hasRecord: Bool = false) -> SkipReason? {
        ReviewSkip.skipReason(pr: pr,
                              settings: settings,
                              approvalThreshold: threshold,
                              changedLinesAfterExclusion: lines,
                              hasRecordForHead: hasRecord)
    }

    func testEligibleWhenReviewerRequested() {
        XCTAssertNil(reason(Fixtures.pr()))
    }

    func testSkipsWhenNotRequestedAsReviewer() {
        XCTAssertEqual(reason(Fixtures.pr(viewerHasReviewRequest: false)), .noReviewRequest)
    }

    func testDistinguishesAlreadyReviewed() {
        // 리뷰를 제출하면 GitHub 가 리뷰 요청을 없앤다 → 사유를 구분해 보여준다.
        let pr = Fixtures.pr(viewerHasReviewRequest: false, viewerLatestReviewState: "APPROVED")
        XCTAssertEqual(reason(pr), .alreadyReviewedByMe)
    }

    func testSkipsOwnPRAndDraft() {
        XCTAssertEqual(reason(Fixtures.pr(viewerDidAuthor: true)), .ownPR)
        XCTAssertEqual(reason(Fixtures.pr(isDraft: true)), .isDraft)
    }

    func testSkipsClosedPR() {
        XCTAssertEqual(reason(Fixtures.pr(state: "MERGED")), .notOpen)
    }

    func testSkipsConflictingAndUnknown() {
        XCTAssertEqual(reason(Fixtures.pr(mergeable: .conflicting)), .conflicting)
        XCTAssertEqual(reason(Fixtures.pr(mergeable: .unknown)), .mergeableUnknown)
    }

    func testSkipsDoNotReviewLabel() {
        let pr = Fixtures.pr(labels: ["DO NOT REVIEW"])
        XCTAssertEqual(reason(pr), .hiddenLabel("DO NOT REVIEW"))
    }

    /// 켜고 끄는 설정은 없앴다 — 승인이 찼다는 사실은 끈다고 달라지지 않는다.
    /// 목록에서 감추는 일은 화면 위 "승인 완료 숨기기" 필터가 따로 맡는다.
    func testSkipsWhenApprovalThresholdReached() {
        let pr = Fixtures.pr(approvals: ["a", "b", "c"])
        XCTAssertEqual(reason(pr), .approvalThresholdReached(3))
        XCTAssertNil(reason(Fixtures.pr(approvals: ["a"])), "임계값을 못 채우면 사유가 없다")
    }

    func testSkipsWhenTooLarge() {
        let pr = Fixtures.pr(additions: 900, deletions: 200)
        XCTAssertEqual(reason(pr), .tooLarge(lines: 1100, cap: 600))
        // 제외 규칙 적용 후 줄 수가 작아지면 대상이 된다.
        XCTAssertNil(reason(pr, lines: 120))
    }

    func testSkipsWhenRecordForHeadExists() {
        XCTAssertEqual(reason(Fixtures.pr(), hasRecord: true), .alreadyHasRecord)
    }
}
