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

    // MARK: 서버로 보낼 검색어

    func testShortBareWordIsNotSentToTheServer() {
        // 한 글자로 검색하면 수천 건이 온다. 거르기만 하고 보내지 않는다.
        XCTAssertNil(RepoQuery("m").searchTerms())
        XCTAssertNotNil(RepoQuery("me").searchTerms())
    }

    func testBareWordSearchesNamesOnly() {
        XCTAssertEqual(RepoQuery("sample").searchTerms(), ["sample", "in:name"])
    }

    /// `acme in:name` 으로 보내면 **이름에 acme 가 든** 레포만 나와서,
    /// 정작 그 조직 레포는 한 건도 안 나온다. 아는 조직이면 `org:` 로 바꿔 보낸다.
    func testKnownOrganizationBecomesAnOrgQuery() {
        XCTAssertEqual(RepoQuery("acme").searchTerms(knownOwners: ["acme"]), ["org:acme"])
        XCTAssertEqual(RepoQuery("ACME").searchTerms(knownOwners: ["acme"]), ["org:acme"])
        // 조직 이름의 일부만 친 것은 아직 조직이 아니다. 이름 검색으로 둔다.
        XCTAssertEqual(RepoQuery("acm").searchTerms(knownOwners: ["acme"]), ["acm", "in:name"])
    }

    func testSlashedQueryScopesToTheOwner() {
        XCTAssertEqual(RepoQuery("acme/ios").searchTerms(), ["org:acme", "ios", "in:name"])
        // 오너만 치고 슬래시로 끝내면 그 조직 전체를 부른다(두 글자 제한과 무관하다).
        XCTAssertEqual(RepoQuery("acme/").searchTerms(), ["org:acme"])
    }

    func testEmptyQuerySendsNothing() {
        XCTAssertNil(RepoQuery("").searchTerms())
        XCTAssertNil(RepoQuery("  ").searchTerms())
    }
}
