import XCTest
@testable import PRayerCore

/// 목록 검색칸의 글이 서버에 무엇을 묻고, 아래 구역에 무엇이 남는가.
final class PRSearchTests: XCTestCase {
    private let ios = RepoID(owner: "acme", name: "sample-ios")
    private let sdk = RepoID(owner: "acme", name: "sample-sdk")

    // MARK: 검색어 나누기

    func testOneLetterStaysLocal() {
        // 한 글자는 결과가 너무 많고 타자 중간이라 서버에 묻지 않는다.
        XCTAssertNil(PRSearchPlan(search: "a"))
        XCTAssertNil(PRSearchPlan(search: " 다 "))
        XCTAssertNil(PRSearchPlan(search: ""))
    }

    func testNumberLooksUpThatPR() {
        let plan = PRSearchPlan(search: "#131")
        XCTAssertEqual(plan?.number, 131)
        // 제목의 이슈 키(PROJ-131)도 걸리게 단어 검색에도 넣는다. `#` 는 뗀다.
        XCTAssertEqual(plan?.words, "131")
        XCTAssertNil(plan?.author)
        // 숫자는 한 자리여도 묻는다 — 번호 조회는 한 건만 온다.
        XCTAssertEqual(PRSearchPlan(search: "7")?.number, 7)
    }

    func testLoginLikeWordAlsoSearchesAuthor() {
        XCTAssertEqual(PRSearchPlan(search: "alex-kim")?.author, "alex-kim")
        // 한글·여러 단어·숫자뿐인 말은 아이디가 아니다.
        XCTAssertNil(PRSearchPlan(search: "다크")?.author)
        XCTAssertNil(PRSearchPlan(search: "dark mode")?.author)
        XCTAssertNil(PRSearchPlan(search: "-alex")?.author)
    }

    func testSlashWordAlsoSearchesBranch() {
        let plan = PRSearchPlan(search: "feature/PROJ-1234")
        XCTAssertEqual(plan?.branch, "feature/PROJ-1234")
        XCTAssertNil(plan?.author)
    }

    func testScopeWideningQualifiersAreDropped() {
        // `repo:` 를 하나 더 쓰면 GitHub 이 "또는" 으로 읽어 등록하지 않은 레포까지 끌어온다.
        XCTAssertEqual(PRSearchPlan(search: "다크 repo:other/x")?.words, "다크")
        XCTAssertNil(PRSearchPlan(search: "org:other"))
        // 좁히기만 하는 한정어는 그대로 둔다.
        XCTAssertEqual(PRSearchPlan(search: "다크 is:merged")?.words, "다크 is:merged")
    }

    // MARK: 쿼리

    func testWordsQueryCoversAllRegisteredReposWithoutPeriod() throws {
        let plan = try XCTUnwrap(PRSearchPlan(search: "다크 모드"))
        XCTAssertEqual(plan.wordsQuery(repos: [ios, sdk], olderThan: nil),
                       "repo:acme/sample-ios repo:acme/sample-sdk is:pr 다크 모드 in:title,body sort:created-desc")
    }

    func testAllPRsTabSearchesOnlyOlderThanItsWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = try XCTUnwrap(PRSearchPlan.olderThan(scope: .recentAll(.month), now: now))
        XCTAssertEqual(cutoff, now.addingTimeInterval(-720 * 3600))
        // 탭 쿼리의 `updated:>=` 를 뒤집은 것이라 위 구역과 겹치지 않는다.
        let query = try XCTUnwrap(PRSearchPlan(search: "alex")).authorQuery(repos: [ios], olderThan: cutoff)
        XCTAssertEqual(query, "repo:acme/sample-ios is:pr author:alex updated:<\(cutoff.ISO8601Format()) sort:created-desc")
        // 다른 탭은 기간 없이 전부다.
        XCTAssertNil(PRSearchPlan.olderThan(scope: .open, now: now))
        XCTAssertNil(PRSearchPlan.olderThan(scope: .myApprovals(.week), now: now))
    }

    func testExtraSectionName() {
        XCTAssertEqual(PRSearchPlan.extraName(scope: .open), "전체 PR")
        XCTAssertEqual(PRSearchPlan.extraName(scope: .myApprovals(.week)), "전체 PR")
        XCTAssertEqual(PRSearchPlan.extraName(scope: .recentAll(.month)), "30일 이전 PR")
        XCTAssertEqual(PRSearchPlan.extraName(scope: .recentAll(.week)), "7일 이전 PR")
        XCTAssertEqual(PRSearchPlan.extraName(scope: .recentAll(.day)), "24시간 이전 PR")
    }

    func testReviewAndApprovedTabsShareOneServerResult() {
        // 둘 다 기간 없이 찾으니 같은 결과를 다시 받지 않는다. All PRs 는 범위가 달라 따로다.
        let open = PRSearchPlan.cacheKey(search: "다크", scope: .open, repos: [ios])
        XCTAssertEqual(open, PRSearchPlan.cacheKey(search: " 다크 ", scope: .myApprovals(.day), repos: [ios]))
        XCTAssertNotEqual(open, PRSearchPlan.cacheKey(search: "다크", scope: .recentAll(.month), repos: [ios]))
        XCTAssertNotEqual(open, PRSearchPlan.cacheKey(search: "다크", scope: .open, repos: [ios, sdk]))
    }

    // MARK: 아래 구역

    func testExtraDropsTopRowsHiddenReposAndDuplicates() {
        let shown = Fixtures.pr(number: 1)
        let fresh = Fixtures.pr(number: 2, additions: 99)
        let stale = Fixtures.pr(number: 2, additions: 1)
        var other = Fixtures.pr(number: 3)
        other.repo = sdk
        let rows = PRSearchPlan.extra(candidates: [shown, fresh, stale, other],
                                      excluding: [shown.id],
                                      hiddenRepoKeys: [PRFilterState.repoKey(sdk)],
                                      olderThan: nil)
        // 위 구역에 있는 것·레포 고르기로 뺀 레포는 빠지고, 같은 PR 은 앞(서버 결과)이 이긴다.
        XCTAssertEqual(rows.map(\.number), [2])
        XCTAssertEqual(rows.first?.additions, 99)
    }

    func testExtraInAllPRsTabKeepsOnlyOlderOnes() {
        var recent = Fixtures.pr(number: 1)
        recent.updatedAt = Date(timeIntervalSince1970: 2_000)
        var old = Fixtures.pr(number: 2)
        old.updatedAt = Date(timeIntervalSince1970: 500)
        let rows = PRSearchPlan.extra(candidates: [recent, old], excluding: [], hiddenRepoKeys: [],
                                      olderThan: Date(timeIntervalSince1970: 1_000))
        // 받아 둔 목록에서 온 기간 안 PR 이 "30일 이전" 구역에 끼지 않는다.
        XCTAssertEqual(rows.map(\.number), [2])
    }

    func testLocalMatchIsSubstringLikeTopSection() {
        let pr = Fixtures.pr(number: 42)
        XCTAssertTrue(PRSearchPlan.matchesLocally(pr, needle: "스크롤 위치"))
        XCTAssertTrue(PRSearchPlan.matchesLocally(pr, needle: "PROJ-12"))   // 글자 일부 — 서버 단어 검색은 못 잡는다
        XCTAssertTrue(PRSearchPlan.matchesLocally(pr, needle: "riley"))       // 작성자
        XCTAssertTrue(PRSearchPlan.matchesLocally(pr, needle: "feature/"))   // 브랜치
        XCTAssertFalse(PRSearchPlan.matchesLocally(pr, needle: "다크"))
    }

    func testRateLimitIsToldApartFromFailure() {
        XCTAssertTrue(PRSearchPlan.isRateLimited(GitHubError.graphQL(["API rate limit exceeded for user"])))
        XCTAssertFalse(PRSearchPlan.isRateLimited(GitHubError.graphQL(["Bad credentials"])))
    }
}
