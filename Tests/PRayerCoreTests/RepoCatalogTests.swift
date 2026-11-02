import XCTest
@testable import PRayerCore

/// 레포 고르기는 받아 둔 목록 안에서만 찾는다. 그러니 이 목록이 **빠짐없이** 와야 한다.
final class RepoCatalogTests: XCTestCase {
    // MARK: 한 쪽 읽기

    private let pageResponse = """
    HTTP/2.0 200 OK\r
    Content-Type: application/json; charset=utf-8\r
    Link: <https://api.github.com/user/repos?per_page=100&page=2&sort=created&direction=asc>; rel="next", <https://api.github.com/user/repos?per_page=100&page=22&sort=created&direction=asc>; rel="last"\r
    \r
    [{"full_name":"acme/sample-ios","private":true,"archived":false,"fork":false,"default_branch":"develop",
      "pushed_at":"2026-10-30T09:00:00Z","permissions":{"admin":false,"maintain":false,"push":true,"triage":true,"pull":true}},
     {"full_name":"jamie/notes","private":false,"archived":true,"fork":true,"default_branch":"main",
      "pushed_at":null,"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]
    """

    func testParsesReposFromAPage() throws {
        let page = try RepoCatalog.parsePage(pageResponse)
        XCTAssertEqual(page.entries.map(\.option.repo.full), ["acme/sample-ios", "jamie/notes"])
        let first = page.entries[0]
        XCTAssertTrue(first.option.isPrivate)
        XCTAssertEqual(first.option.defaultBranch, "develop")
        XCTAssertNotNil(first.pushedAt)
        let second = page.entries[1]
        XCTAssertTrue(second.option.isArchived)
        XCTAssertTrue(second.option.isFork)
        // 빈 레포는 push 한 적이 없다.
        XCTAssertNil(second.pushedAt)
    }

    /// GraphQL `viewerPermission` 과 같은 이름. 여러 권한이 켜져 있으면 가장 센 것 하나.
    func testPermissionTakesTheStrongestFlag() throws {
        let page = try RepoCatalog.parsePage(pageResponse)
        XCTAssertEqual(page.entries.map(\.option.permission), ["WRITE", "READ"])
    }

    /// 첫 쪽에서 마지막 쪽 번호를 알아야 나머지를 한꺼번에 부른다. `per_page=100` 에도 `page=` 가 있어
    /// 글자로 찾으면 100 을 집는다.
    func testLastPageComesFromTheLinkHeader() throws {
        XCTAssertEqual(try RepoCatalog.parsePage(pageResponse).lastPage, 22)
    }

    func testNoLinkHeaderMeansASinglePage() throws {
        let response = "HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n[]"
        let page = try RepoCatalog.parsePage(response)
        XCTAssertNil(page.lastPage)
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testGarbageBodyThrows() {
        // 한 쪽을 못 읽었는데 빈 쪽으로 넘기면 그 쪽의 레포 100개가 조용히 빠진다.
        XCTAssertThrowsError(try RepoCatalog.parsePage("HTTP/2.0 200 OK\r\n\r\n<html>bad gateway</html>"))
    }

    /// 쪽을 나눠 받는 몇 초 사이에 순서가 흔들리면 레포가 쪽 사이로 빠진다. 생성 순은 새 레포가 뒤에 붙을 뿐이다.
    func testPagesAreRequestedInCreationOrder() {
        let path = RepoCatalog.pagePath(3)
        XCTAssertTrue(path.contains("sort=created"))
        XCTAssertTrue(path.contains("direction=asc"))
        XCTAssertTrue(path.contains("page=3"))
        XCTAssertTrue(path.contains("affiliation=owner,collaborator,organization_member"))
    }

    // MARK: 전부 받기

    private func entry(_ full: String, pushed: TimeInterval?) -> RepoPage.Entry {
        RepoPage.Entry(option: RepoOption(repo: RepoID(full: full)!, isPrivate: true, isArchived: false, isFork: false,
                                          defaultBranch: "main", permission: "WRITE"),
                       pushedAt: pushed.map { Date(timeIntervalSince1970: $0) })
    }

    /// 쪽 번호 → 그 쪽. 받은 쪽 번호와 동시에 돈 수를 센다.
    private actor FakeServer {
        let pages: [Int: RepoPage]
        let failing: Set<Int>
        private(set) var requested: [Int] = []
        private(set) var maxInFlight = 0
        private var inFlight = 0

        init(pages: [Int: RepoPage], failing: Set<Int> = []) {
            self.pages = pages
            self.failing = failing
        }

        func fetch(_ number: Int) async throws -> RepoPage {
            requested.append(number)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            try await Task.sleep(for: .milliseconds(5))
            inFlight -= 1
            if failing.contains(number) { throw GitHubError.cli("HTTP 500") }
            return pages[number] ?? RepoPage(entries: [], lastPage: nil)
        }
    }

    private func server(pageCount: Int, failing: Set<Int> = []) -> FakeServer {
        var pages: [Int: RepoPage] = [:]
        for number in 1...pageCount {
            // 쪽마다 2개. push 시각은 쪽 번호가 클수록 최근이다(생성 순으로 받으니 뒤쪽이 최근일 수 있다).
            pages[number] = RepoPage(entries: [entry("acme/repo-\(number)a", pushed: Double(number * 10)),
                                               entry("acme/repo-\(number)b", pushed: Double(number * 10 + 1))],
                                     lastPage: number == 1 ? pageCount : nil)
        }
        return FakeServer(pages: pages, failing: failing)
    }

    func testFetchesEveryPageAndOrdersByRecentPush() async throws {
        let fake = server(pageCount: 5)
        let repos = try await RepoCatalog.fetchAll(concurrency: 2, page: { try await fake.fetch($0) })
        XCTAssertEqual(repos.count, 10)
        XCTAssertEqual(repos.first?.repo.full, "acme/repo-5b")
        XCTAssertEqual(repos.last?.repo.full, "acme/repo-1a")
        let requested = await fake.requested
        XCTAssertEqual(requested.sorted(), [1, 2, 3, 4, 5])
    }

    func testNeverRunsMoreThanTheConcurrencyLimit() async throws {
        let fake = server(pageCount: 12)
        _ = try await RepoCatalog.fetchAll(concurrency: 3, page: { try await fake.fetch($0) })
        let maxInFlight = await fake.maxInFlight
        XCTAssertLessThanOrEqual(maxInFlight, 3)
    }

    func testSinglePageMakesOneRequest() async throws {
        let fake = FakeServer(pages: [1: RepoPage(entries: [entry("acme/only", pushed: 1)], lastPage: nil)])
        let repos = try await RepoCatalog.fetchAll(page: { try await fake.fetch($0) })
        XCTAssertEqual(repos.map(\.repo.full), ["acme/only"])
        let requested = await fake.requested
        XCTAssertEqual(requested, [1])
    }

    /// 한 쪽이라도 못 받으면 "전부" 라고 내놓지 않는다. 받은 데까지는 진행 알림으로 이미 넘어갔다.
    func testAMissingPageFailsTheWholeFetch() async {
        let fake = server(pageCount: 4, failing: [3])
        do {
            _ = try await RepoCatalog.fetchAll(concurrency: 2, page: { try await fake.fetch($0) })
            XCTFail("한 쪽이 빠졌는데 성공했다")
        } catch {
            // 기대한 실패
        }
    }

    func testProgressCountsPagesUpToTheTotal() async throws {
        let fake = server(pageCount: 4)
        let seen = ProgressLog()
        _ = try await RepoCatalog.fetchAll(concurrency: 2, page: { try await fake.fetch($0) }) { progress in
            await seen.add(progress)
        }
        let pages = await seen.pages
        XCTAssertEqual(pages, [1, 2, 3, 4])
        let totals = await seen.totals
        XCTAssertEqual(Set(totals), [4])
        let lastCount = await seen.lastRepoCount
        XCTAssertEqual(lastCount, 8)
    }

    private actor ProgressLog {
        private(set) var pages: [Int] = []
        private(set) var totals: [Int] = []
        private(set) var lastRepoCount = 0

        func add(_ progress: RepoCatalog.Progress) {
            pages.append(progress.loadedPages)
            totals.append(progress.totalPages)
            lastRepoCount = progress.repos.count
        }
    }

    /// 받는 도중 새 레포가 생겨 쪽 경계가 밀리면 같은 레포가 두 쪽에 걸쳐 온다. 한 번만 남긴다.
    func testDuplicatesAcrossPagesAreKeptOnce() {
        let pages: [Int: [RepoPage.Entry]] = [
            1: [entry("acme/a", pushed: 1), entry("acme/b", pushed: 2)],
            2: [entry("acme/b", pushed: 2), entry("acme/c", pushed: 3)],
        ]
        XCTAssertEqual(RepoCatalog.ordered(pages).map(\.repo.full), ["acme/c", "acme/b", "acme/a"])
    }

    func testNeverPushedReposGoLastInNameOrder() {
        let pages: [Int: [RepoPage.Entry]] = [
            1: [entry("acme/zeta", pushed: nil), entry("acme/alpha", pushed: nil), entry("acme/live", pushed: 5)],
        ]
        XCTAssertEqual(RepoCatalog.ordered(pages).map(\.repo.full), ["acme/live", "acme/alpha", "acme/zeta"])
    }

    // MARK: 저장

    func testCatalogRoundTripsThroughJSON() throws {
        let catalog = RepoCatalog(host: "github.com", login: "itaehyeok",
                                  repos: [entry("acme/sample-ios", pushed: 1).option],
                                  fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(RepoCatalog.self, from: encoder.encode(catalog)), catalog)
    }
}
