import XCTest
@testable import PRayerCore

/// "특정 라벨 숨기기". 예전에는 `DO NOT REVIEW` 계열로 박혀 있던 것을 팀마다 라벨을 고르게 했다.
final class HiddenLabelTests: XCTestCase {
    // MARK: - 설정

    /// 처음 쓰는 팀의 기본값은 널리 쓰는 관례 하나다. "DO NOT MERGE" 는 팀에 따라 리뷰는 해 달라는 뜻이다.
    func testDefaultIsDoNotReviewOnly() {
        XCTAssertEqual(Settings.default.hiddenLabels, ["DO NOT REVIEW"])
    }

    /// 0.3.0 까지는 `doNotReviewLabels` 로 저장했다. 이미 맞춰 둔 목록이 기본값으로 돌아가면 안 된다.
    func testLegacyKeyIsRead() throws {
        let old = #"{"doNotReviewLabels":["DO NOT REVIEW","DO NOT MERGE"]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.hiddenLabels, ["DO NOT REVIEW", "DO NOT MERGE"])
    }

    func testNewKeyWinsOverLegacyKey() throws {
        let both = #"{"hiddenLabels":["WIP"],"doNotReviewLabels":["DO NOT REVIEW"]}"#
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(both.utf8)).hiddenLabels, ["WIP"])
    }

    /// 다 지운 목록은 비어 있어야 한다 — 기본값으로 되살리면 지운 라벨이 다시 숨겨진다.
    func testEmptyListStaysEmpty() throws {
        let empty = #"{"hiddenLabels":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(empty.utf8)).hiddenLabels, [])
    }

    func testSavesOnlyNewKey() throws {
        let json = String(decoding: try JSONEncoder().encode(Settings.default), as: UTF8.self)
        XCTAssertTrue(json.contains("\"hiddenLabels\""))
        XCTAssertFalse(json.contains("doNotReviewLabels"))
    }

    func testMatchingIgnoresCase() {
        var settings = Settings.default
        settings.hiddenLabels = ["wip", "Backend"]
        XCTAssertEqual(settings.hiddenLabel(in: ["feature", "WIP"]), "WIP", "PR 에 붙은 원래 표기를 돌려준다")
        XCTAssertTrue(settings.isHiddenLabel("backend"))
        XCTAssertFalse(settings.hasHiddenLabel(["DO NOT REVIEW"]), "목록에 없으면 기본 라벨이어도 숨기지 않는다")
    }

    // MARK: - 목록 필터

    func testCustomLabelHidesPRInReviewQueue() {
        let pr = Fixtures.pr(labels: ["backend"])
        let reasons = PRVisibility.hidingFilters(pr: pr, state: PRFilterState(hideLabels: true),
                                                 scope: .open, hasHiddenLabel: true)
        XCTAssertEqual(reasons, [.hideLabels])
        XCTAssertEqual(PRFilterKind.hideLabels.label, "특정 라벨 숨기기")
    }

    /// 라벨 목록이 비면 켜 둬도 아무것도 거르지 않는다. "필터 1" 이라고 세면 무엇이 걸렀는지 찾아 헤맨다.
    func testEmptyLabelListIsNotCountedAsActive() {
        let state = PRFilterState(hideLabels: true, hasHiddenLabels: false)
        XCTAssertFalse(state.active(in: .open).contains(.hideLabels))
        XCTAssertTrue(PRFilterState(hideLabels: true).active(in: .open).contains(.hideLabels))
    }

    // MARK: - 리뷰할 필요 없음 표시

    func testSkipReasonUsesTeamLabel() {
        var settings = Settings.default
        settings.hiddenLabels = ["hold"]
        let reason = ReviewSkip.skipReason(pr: Fixtures.pr(labels: ["Hold"]), settings: settings,
                                           approvalThreshold: 3, changedLinesAfterExclusion: nil,
                                           hasRecordForHead: false)
        XCTAssertEqual(reason, .hiddenLabel("Hold"))
        XCTAssertEqual(reason?.label, "Hold 라벨")
        XCTAssertNil(ReviewSkip.skipReason(pr: Fixtures.pr(labels: ["DO NOT REVIEW"]), settings: settings,
                                           approvalThreshold: 3, changedLinesAfterExclusion: nil,
                                           hasRecordForHead: false),
                     "목록에서 뺀 라벨로는 사유를 달지 않는다")
    }
}
