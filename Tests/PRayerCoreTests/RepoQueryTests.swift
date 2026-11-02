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
}
