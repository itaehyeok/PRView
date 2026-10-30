import XCTest
@testable import PRayerCore

/// 목록 가운데 문구 — 받는 중과 다 받았는데 없을 때. 탭마다 같은 틀로 말해야 한다.
final class ListEmptyTextTests: XCTestCase {
    func testFetchingNamesWhatIsBeingFetched() {
        XCTAssertEqual(PRListScope.open.fetchingDescription, "열려 있는 PR 을 받고 있습니다.")
        XCTAssertEqual(PRListScope.recentAll(.day).fetchingDescription,
                       "최근 24h 안에 활동이 있었던 PR 을 받고 있습니다.")
        XCTAssertEqual(PRListScope.myApprovals(.week).fetchingDescription,
                       "내가 최근 7일 안에 Approve 한 PR 을 받고 있습니다.")
    }

    /// 가운데 제목이 목록 위 띠("'탭 이름' 가져오는 중")와 같은 이름을 쓴다.
    func testLabelsUsedInFetchingTitle() {
        XCTAssertEqual(PRListScope.open.label, "To review")
        XCTAssertEqual(PRListScope.recentAll(.day).label, "All PRs 24h")
        XCTAssertEqual(PRListScope.myApprovals(.week).label, "Approved 7d")
        XCTAssertEqual(PRListScope.recentAll(.month).label, "All PRs 30d")
    }

    /// 탭 조건에 걸린 것을 "필터에 걸렸다" 고 하면 필터를 꺼도 안 나와 헛걸음한다.
    func testContinuingTextBlamesFiltersOnlyWhenTheyHide() {
        XCTAssertEqual(PRListScope.continuingDescription(hiddenByFilters: true),
                       "지금까지 받은 PR 은 모두 필터에 걸렸습니다.")
        XCTAssertEqual(PRListScope.continuingDescription(hiddenByFilters: false),
                       "지금까지 받은 PR 중에는 조건에 맞는 것이 없습니다.")
    }

    /// 리뷰 대기만 두 경우를 가른다 — 열린 PR 자체가 없는 것과 리뷰할 것이 없는 것은 다른 일이다.
    func testOpenTabSeparatesNothingOpenFromNothingToReview() {
        XCTAssertEqual(PRListScope.open.emptyDescription(receivedAny: false),
                       "열린 PR 이 없습니다. 닫히거나 머지된 PR 은 'All PRs' 에서 볼 수 있습니다.")
        XCTAssertEqual(PRListScope.open.emptyDescription(receivedAny: true),
                       "지금 리뷰할 PR 이 없습니다. 이미 Approve 한 PR 과 초안은 'All PRs' 에서 볼 수 있습니다.")
    }

    /// 기간 탭은 못 받았을 때와 받았지만 맞는 게 없을 때 같은 말을 한다(예전에는 두 문장으로 갈렸다).
    func testWindowTabsSaySameThingEitherWay() {
        for scope in [PRListScope.recentAll(.day), .myApprovals(.week)] {
            XCTAssertEqual(scope.emptyDescription(receivedAny: false), scope.emptyDescription(receivedAny: true))
        }
        XCTAssertEqual(PRListScope.recentAll(.day).emptyDescription(receivedAny: true),
                       "최근 24h 안에 활동이 있었던 PR 이 없습니다. 기간을 늘려 보세요.")
        XCTAssertEqual(PRListScope.myApprovals(.week).emptyDescription(receivedAny: true),
                       "최근 7일 안에 내가 Approve 한 PR 이 없습니다. 기간을 늘려 보세요.")
    }

    /// 가장 긴 기간이면 늘릴 데가 없다 — 누를 버튼도 없는 권유를 하지 않는다.
    func testLongestWindowDoesNotSuggestWidening() {
        XCTAssertEqual(PRListScope.myApprovals(.month).emptyDescription(receivedAny: true),
                       "최근 30일 안에 내가 Approve 한 PR 이 없습니다.")
        XCTAssertEqual(PRListScope.recentAll(.month).emptyDescription(receivedAny: true),
                       "최근 30일 안에 활동이 있었던 PR 이 없습니다.")
    }
}
