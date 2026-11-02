import XCTest
@testable import PRayerCore

/// 검색창이 한 칸이라, 그 한 칸이 오너와 이름을 둘 다 감당하는지가 이 기능의 전부다.
final class RepoQueryTests: XCTestCase {
    private let ios = RepoID(owner: "acme", name: "sample-ios")
    private let sdk = RepoID(owner: "acme", name: "sample-ad-sdk")
    private let mine = RepoID(owner: "itaehyeok", name: "PRayer")

    // MARK: 거르기 — 서버를 기다리지 않고 타자마다 도는 쪽

    func testBareWordMatchesEitherOwnerOrName() {
        XCTAssertTrue(RepoQuery("ios").matches(ios))
        XCTAssertFalse(RepoQuery("ios").matches(sdk))
        // 오너만 쳐도 걸린다 — 뭘 친 건지 사용자가 먼저 정하지 않아도 된다.
        XCTAssertTrue(RepoQuery("acme").matches(ios))
        XCTAssertTrue(RepoQuery("acme").matches(sdk))
        XCTAssertFalse(RepoQuery("acme").matches(mine))
    }

    func testMatchingIgnoresCase() {
        XCTAssertTrue(RepoQuery("PRAYER").matches(mine))
        XCTAssertTrue(RepoQuery("ItaeHyeok/prayer").matches(mine))
    }

    func testSlashSplitsOwnerAndName() {
        XCTAssertTrue(RepoQuery("acme/ad").matches(sdk))
        XCTAssertFalse(RepoQuery("acme/ad").matches(ios))
        // 오너가 다르면 이름이 맞아도 걸리지 않는다.
        XCTAssertFalse(RepoQuery("itaehyeok/ad").matches(sdk))
    }

    func testTrailingSlashKeepsTheWholeOwner() {
        let query = RepoQuery("acme/")
        XCTAssertTrue(query.matches(ios))
        XCTAssertTrue(query.matches(sdk))
        XCTAssertFalse(query.matches(mine))
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertTrue(RepoQuery("").matches(ios))
        XCTAssertTrue(RepoQuery("   ").matches(mine))
        XCTAssertTrue(RepoQuery("  ").isEmpty)
    }

    // MARK: 정확한 이름

    func testExactRepoOnlyWhenBothHalvesArePresent() {
        XCTAssertEqual(RepoQuery("acme/sample-ios").exactRepo, ios)
        XCTAssertNil(RepoQuery("acme").exactRepo)
        XCTAssertNil(RepoQuery("acme/").exactRepo)
        XCTAssertNil(RepoQuery("/sample-ios").exactRepo)
    }

    // MARK: 보일 순서

    private func option(_ full: String) -> RepoOption {
        RepoOption(repo: RepoID(full: full)!, isPrivate: true, isArchived: false, isFork: false,
                   defaultBranch: "main", permission: "WRITE")
    }

    /// 수천 개 중 흔한 말에 수십 개가 걸린다. 이름이 그 말로 시작하는 것이 찾던 것이라 위로 올린다.
    func testNamesStartingWithTheWordComeFirst() {
        let options = ["acme/web-ios-kit", "acme/sample-ios", "jamie/ios-notes", "acme/ios-app"].map(option)
        XCTAssertEqual(RepoQuery("ios").ranked(options).map(\.repo.full),
                       ["jamie/ios-notes", "acme/ios-app", "acme/web-ios-kit", "acme/sample-ios"])
    }

    func testRankingKeepsTheReceivedOrderWithinEachGroup() {
        // 받은 순서가 최근 push 순이다. 앞으로 올린 무리 안에서도, 나머지 안에서도 그 순서를 지킨다.
        let options = ["acme/ios-b", "acme/x-ios", "acme/ios-a", "acme/y-ios"].map(option)
        XCTAssertEqual(RepoQuery("IOS").ranked(options).map(\.repo.full),
                       ["acme/ios-b", "acme/ios-a", "acme/x-ios", "acme/y-ios"])
    }

    func testRankingDropsWhatDoesNotMatch() {
        let options = ["acme/sample-ios", "acme/sample-ad-sdk", "itaehyeok/PRayer"].map(option)
        XCTAssertEqual(RepoQuery("acme/").ranked(options).map(\.repo.full), ["acme/sample-ios", "acme/sample-ad-sdk"])
        XCTAssertEqual(RepoQuery("").ranked(options).count, 3)
    }
}
