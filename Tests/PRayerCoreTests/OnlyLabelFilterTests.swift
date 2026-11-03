import XCTest
@testable import PRayerCore

/// 목록 행의 라벨을 눌러 거는 "라벨 하나만 보기" 필터.
///
/// 레포 고르기·검색어처럼 모든 탭에 걸리고, 라벨 이름의 대소문자를 가리지 않는다.
final class OnlyLabelFilterTests: XCTestCase {
    private func hiding(_ pr: PullRequestInfo, only label: String?,
                        scope: PRListScope = .open) -> Set<PRFilterKind> {
        PRVisibility.hidingFilters(pr: pr,
                                   state: PRFilterState(onlyLabel: label),
                                   scope: scope,
                                   hasHiddenLabel: false)
    }

    func testHidesPRsWithoutTheLabel() {
        XCTAssertTrue(hiding(Fixtures.pr(labels: ["bug", "ios"]), only: "bug").isEmpty)
        XCTAssertEqual(hiding(Fixtures.pr(labels: ["feature"]), only: "bug"), [.onlyLabel])
        XCTAssertEqual(hiding(Fixtures.pr(labels: []), only: "bug"), [.onlyLabel])
    }

    func testNoLabelMeansNoFilter() {
        XCTAssertTrue(hiding(Fixtures.pr(labels: []), only: nil).isEmpty)
        XCTAssertTrue(PRFilterState().active(in: .open).isEmpty)
    }

    /// 승인·전체 탭에서도 건다 — 무엇을 보느냐를 좁히는 것이라 리뷰 대기만의 조건이 아니다.
    func testAppliesToEveryTab() {
        for scope in [PRListScope.open, .myApprovals(.day), .recentAll(.week)] {
            XCTAssertEqual(hiding(Fixtures.pr(labels: ["feature"]), only: "bug", scope: scope),
                           [.onlyLabel], "\(scope.kind)")
            XCTAssertEqual(PRFilterState(onlyLabel: "bug").active(in: scope), [.onlyLabel])
        }
    }

    /// 숨길 라벨과 같은 규칙 — GitHub 라벨은 대소문자만 다른 이름을 따로 만들 수 없다.
    func testMatchesLabelNamesCaseInsensitively() {
        XCTAssertTrue(hiding(Fixtures.pr(labels: ["Bug"]), only: "bug").isEmpty)
        XCTAssertTrue(PRFilterState.hasLabel(["DO NOT MERGE"], "do not merge"))
    }

    /// 라벨 때문에 목록이 비면 빈 화면이 "이 필터를 끄면 +N건" 으로 정확히 말한다.
    func testEmptyDiagnosisCountsOnlyLabelGain() {
        let prs = [Fixtures.pr(number: 1, labels: ["feature"]),
                   Fixtures.pr(number: 2, labels: []),
                   Fixtures.pr(number: 3, labels: ["bug"])]
        let state = PRFilterState(search: "", onlyLabel: "chore")
        let diagnosis = EmptyListDiagnosis.make(prs: prs, state: state, scope: .open,
                                                hasHiddenLabel: { _ in false },
                                                approvedInWindow: { _ in true })
        XCTAssertEqual(diagnosis.hiddenCount, 3)
        XCTAssertEqual(diagnosis.gains.first { $0.kind == .onlyLabel }?.gain, 3)
        XCTAssertFalse(diagnosis.searchIsOnlyBlocker)
    }

    /// 라벨에 걸리고 검색어에도 걸린 PR 은 어느 하나만 꺼서는 안 나온다 — 겹침으로 센다.
    func testOverlapWithSearchIsReported() {
        let prs = [Fixtures.pr(number: 1, labels: ["feature"])]
        let state = PRFilterState(search: "없는말", onlyLabel: "bug")
        let diagnosis = EmptyListDiagnosis.make(prs: prs, state: state, scope: .open,
                                                hasHiddenLabel: { _ in false },
                                                approvedInWindow: { _ in true })
        XCTAssertTrue(diagnosis.gains.allSatisfy { $0.gain == 0 })
        XCTAssertTrue(diagnosis.hasOverlap)
    }
}
