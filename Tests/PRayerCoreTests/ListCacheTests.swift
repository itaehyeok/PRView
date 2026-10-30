import XCTest
@testable import PRayerCore

/// 탭마다 남기는 지난 목록.
final class ListCacheTests: XCTestCase {
    /// 탭마다 파일이 하나씩이고, 기간이 다르면 다른 파일이다(같은 종류를 24h·7일로 볼 수 있다).
    func testEachScopeHasItsOwnFile() {
        let names = [PRListScope.open, .myApprovals(.day), .myApprovals(.week), .recentAll(.month)]
            .map { AppPaths.listCacheFile(scope: $0.storageValue).lastPathComponent }
        XCTAssertEqual(names, ["open-0.json", "myApprovals-24.json", "myApprovals-168.json", "recentAll-720.json"])
    }

    // MARK: 받은 지 얼마 안 된 탭

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fresh(minutesAgo: Double?, pollSeconds: Int = 120) -> Bool {
        ListRefreshChange.isFresh(fetchedAt: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, now: now,
                                  pollSeconds: pollSeconds)
    }

    /// 방금 보다가 다른 탭에 갔다 온 것은 조용히 다시 받는다. 5분이 지났으면 "가져오는 중" 을 보인다.
    func testFreshWithinFiveMinutes() {
        XCTAssertTrue(fresh(minutesAgo: 1))
        XCTAssertTrue(fresh(minutesAgo: 4.9))
        XCTAssertFalse(fresh(minutesAgo: 5.1))
    }

    /// 한 번도 받은 적 없는 탭(지난 목록이 디스크에도 없다)은 새것이 아니다.
    func testNeverFetchedIsNotFresh() {
        XCTAssertFalse(fresh(minutesAgo: nil))
    }

    /// 폴링을 길게 잡았으면 지금 탭도 그만큼 묵은 채 보이니, 그 안이면 새것이다.
    func testLongPollingStretchesFreshness() {
        XCTAssertFalse(fresh(minutesAgo: 8))
        XCTAssertTrue(fresh(minutesAgo: 8, pollSeconds: 600))
    }

    /// 탭 파일은 모두 한 폴더에 있다 — 앱을 켤 때 그 폴더를 통째로 읽는다.
    func testFilesLiveInCacheDirectory() {
        let file = AppPaths.listCacheFile(scope: PRListScope.open.storageValue)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL,
                       AppPaths.listCacheDirectory.standardizedFileURL)
    }
}
