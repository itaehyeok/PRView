import XCTest
@testable import PRayerCore

final class GitHubClientTests: XCTestCase {
    /// 실제 `gh api -i user` 출력 형태: 상태줄은 LF, 헤더는 CRLF.
    private let sample = "HTTP/2.0 200 OK\n"
        + "Content-Type: application/json; charset=utf-8\r\n"
        + "X-Accepted-Oauth-Scopes: \r\n"
        + "X-Oauth-Scopes: admin:public_key, gist, read:org, repo\r\n"
        + "X-Ratelimit-Remaining: 4997\r\n"
        + "\r\n"
        + "{\"login\":\"alex-kim\",\"id\":123}"

    func testParsesLoginAndScopes() {
        guard let account = GitHubClient.parseAccount(from: sample) else {
            return XCTFail("파싱 실패")
        }
        XCTAssertEqual(account.login, "alex-kim")
        XCTAssertEqual(account.scopes, ["admin:public_key", "gist", "read:org", "repo"])
        XCTAssertTrue(account.hasRequiredScopes)
    }

    func testMissingScopeHeaderStillParsesLogin() {
        // fine-grained PAT·GitHub App 토큰은 x-oauth-scopes 헤더가 없다.
        // 스코프를 모르는 것을 "권한 부족" 으로 단정하면 정상 로그인에 경고가 뜬다.
        let text = "HTTP/2.0 200 OK\r\n\r\n{\"login\":\"someone\"}"
        let account = GitHubClient.parseAccount(from: text)
        XCTAssertEqual(account?.login, "someone")
        XCTAssertEqual(account?.scopes, [])
        XCTAssertTrue(account?.scopesUnknown ?? false)
        XCTAssertTrue(account?.hasRequiredScopes ?? false)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(GitHubClient.parseAccount(from: "not http at all"))
    }

    func testSearchQueryHidesClosedByDefault() {
        let repos = [RepoID(owner: "acme", name: "sample-ios"), RepoID(owner: "acme", name: "other")]
        let query = GitHubClient.searchQuery(repos: repos, includeClosed: false)
        XCTAssertTrue(query.contains("repo:acme/sample-ios"))
        XCTAssertTrue(query.contains("repo:acme/other"))
        XCTAssertTrue(query.contains("is:pr"))
        XCTAssertTrue(query.contains("is:open"))
        XCTAssertFalse(GitHubClient.searchQuery(repos: repos, includeClosed: true).contains("is:open"))
    }
}

final class PRListScopeQueryTests: XCTestCase {
    private let repos = [RepoID(owner: "acme", name: "sample-ios")]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOpenScopeHasNoDateWindow() {
        let query = GitHubClient.searchQuery(repos: repos, scope: .open, viewerLogin: "alex-kim", now: now)
        XCTAssertTrue(query.contains("is:open"))
        XCTAssertFalse(query.contains("updated:"))
        XCTAssertFalse(query.contains("reviewed-by:"))
    }

    /// 모든 (종류 × 기간) 조합. 기간이 없는 조합은 만들 수 없어야 한다.
    private var everyScope: [PRListScope] {
        PRListScopeKind.allCases.flatMap { kind -> [PRListScope] in
            guard kind.usesWindow else { return [PRListScope(kind: kind)] }
            return PRListWindow.allCases.map { PRListScope(kind: kind, window: $0) }
        }
    }

    func testClosedIncludingScopesAlwaysCarryAWindow() {
        // 기간 없이 닫힘까지 긁으면 결과가 수천 건이라 GitHub 이 502 를 낸다(실측).
        for scope in everyScope where scope.includesClosed {
            let query = GitHubClient.searchQuery(repos: repos, scope: scope, viewerLogin: "alex-kim", now: now)
            XCTAssertFalse(query.contains("is:open"), "\(scope.label) 는 닫힘을 포함해야 한다")
            XCTAssertTrue(query.contains("updated:>="), "\(scope.label) 에 기간 제한이 빠졌다")
        }
    }

    /// 기간을 쓰는 종류는 nil 을 넘겨도 기본 기간이 채워진다 — 기간 없는 닫힘 검색이 새어 나가면 안 된다.
    func testWindowedKindsNeverEndUpWithoutAWindow() {
        for kind in PRListScopeKind.allCases where kind.usesWindow {
            XCTAssertNotNil(PRListScope(kind: kind, window: nil).window, "\(kind) 에 기본 기간이 없다")
        }
        XCTAssertNil(PRListScope(kind: .open, window: .month).window, "열린 PR 탭에 기간이 붙었다")
    }

    func testApprovalScopeFiltersByReviewer() {
        let query = GitHubClient.searchQuery(repos: repos, scope: .myApprovals(.day),
                                             viewerLogin: "alex-kim", now: now)
        XCTAssertTrue(query.contains("reviewed-by:alex-kim"))
        XCTAssertTrue(query.contains("updated:>=2027-01-14"))   // now - 24h
    }

    func testApprovalScopeWithoutLoginOmitsReviewer() {
        let query = GitHubClient.searchQuery(repos: repos, scope: .myApprovals(.day), viewerLogin: nil, now: now)
        XCTAssertFalse(query.contains("reviewed-by:"))
    }

    func testScopeWindows() {
        XCTAssertNil(PRListScope.open.windowHours)
        XCTAssertEqual(PRListScope.myApprovals(.day).windowHours, 24)
        XCTAssertEqual(PRListScope.myApprovals(.week).windowHours, 168)
        XCTAssertEqual(PRListScope.recentAll(.month).windowHours, 720)
        XCTAssertTrue(PRListScope.myApprovals(.week).requiresMyApproval)
        XCTAssertFalse(PRListScope.recentAll(.month).requiresMyApproval)
    }

    /// 옛 저장값을 읽어 새 형식으로 옮긴다. 이게 깨지면 업데이트한 사람의 탭 선택이 초기화된다.
    func testLegacyStoredScopesMigrate() {
        XCTAssertEqual(PRListScope(storageValue: "open"), .open)
        XCTAssertEqual(PRListScope(storageValue: "myApprovals24h"), .myApprovals(.day))
        XCTAssertEqual(PRListScope(storageValue: "myApprovals7d"), .myApprovals(.week))
        XCTAssertEqual(PRListScope(storageValue: "recentAll"), .recentAll(.month))
        XCTAssertNil(PRListScope(storageValue: "복구할 수 없는 값"))
    }

    /// 저장했다 읽으면 그대로 돌아와야 한다.
    func testStorageRoundTrip() {
        for scope in everyScope {
            XCTAssertEqual(PRListScope(storageValue: scope.storageValue), scope, scope.label)
        }
    }

    /// 닫힘을 포함하는 탭은 한 요청에서 100건을 요구하면 안 된다.
    /// 실측: 닫힘 포함 188건 검색에서 first:100 은 RESOURCE_LIMITS_EXCEEDED, 75·50·25 는 성공.
    func testClosedIncludingScopesUseASmallerPage() {
        for scope in everyScope where scope.includesClosed {
            XCTAssertLessThanOrEqual(scope.pageSize, 75, "\(scope.label) 의 페이지가 너무 크다")
        }
        XCTAssertEqual(PRListScope.open.pageSize, 100)
    }
}

final class GatewayRetryTests: XCTestCase {
    private let client = GitHubClient(ghPath: "/opt/homebrew/bin/gh")

    func testRetriesTransientGatewayErrorThenSucceeds() async throws {
        // 502 는 잠깐 뒤 사라지는 일이 많다(실측: 13초간 연속 502 후 자연 회복).
        var attempts = 0
        let value: Int = try await client.withGatewayRetry(context: "테스트",
                                                           delays: [.milliseconds(1), .milliseconds(1)]) {
            attempts += 1
            if attempts < 3 { throw GitHubError.cli("gh 호출 실패: gh: HTTP 502") }
            return attempts
        }
        XCTAssertEqual(value, 3)
        XCTAssertEqual(attempts, 3)
    }

    func testGivesUpAfterAllDelays() async {
        var attempts = 0
        do {
            _ = try await client.withGatewayRetry(context: "테스트",
                                                  delays: [.milliseconds(1)]) { () -> Int in
                attempts += 1
                throw GitHubError.cli("gh: HTTP 503")
            }
            XCTFail("계속 실패하면 던져야 한다")
        } catch {
            XCTAssertEqual(attempts, 2)   // 최초 1회 + 재시도 1회
        }
    }

    func testDoesNotRetryPermanentErrors() async {
        // 권한·rate limit 은 다시 물어봐도 같다. 즉시 던져야 한다.
        var attempts = 0
        do {
            _ = try await client.withGatewayRetry(context: "테스트",
                                                  delays: [.milliseconds(1)]) { () -> Int in
                attempts += 1
                throw GitHubError.cli("gh: HTTP 403 rate limit exceeded")
            }
            XCTFail("영구 오류는 재시도하지 않아야 한다")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }
}

/// 목록을 나눠 받을 때 뒷 페이지가 앞 페이지 위로 끼어들지 않게 하는 계약.
final class ListPagingTests: XCTestCase {
    private let repos = [RepoID(owner: "acme", name: "sample-ios")]

    /// 앱은 목록을 올린 시각 순으로 그린다. 서버가 활동 순이면 두 기준이 어긋나,
    /// 2페이지의 PR 이 1페이지 위로 올라와 읽던 자리가 밀린다.
    func testQuerySortsByCreatedSoPagesAppendBelow() {
        let open = GitHubClient.searchQuery(repos: repos, includeClosed: false)
        XCTAssertTrue(open.contains("sort:created-desc"), open)
        XCTAssertFalse(open.contains("sort:updated-desc"), open)

        let scoped = GitHubClient.searchQuery(repos: repos,
                                              scope: PRListScope(kind: .recentAll, window: .month),
                                              viewerLogin: "alex-kim")
        XCTAssertTrue(scoped.contains("sort:created-desc"), scoped)
    }

    /// 기간은 여전히 활동 기준으로 거른다 — 거르는 기준과 줄 세우는 기준은 별개다.
    func testWindowStillFiltersByActivity() {
        let scoped = GitHubClient.searchQuery(repos: repos,
                                              scope: PRListScope(kind: .recentAll, window: .month),
                                              viewerLogin: "alex-kim")
        XCTAssertTrue(scoped.contains("updated:>="), scoped)
    }

    /// 커서는 재정렬되는 결과 위의 오프셋이라 경계 항목이 두 페이지에 다 나온다.
    func testDedupKeepsFirstOccurrenceAndOrder() {
        let a = Fixtures.pr(number: 1)
        let b = Fixtures.pr(number: 2)
        let deduped = GitHubClient.deduped([a, b, a])
        XCTAssertEqual(deduped.map(\.number), [1, 2])
    }

    /// 닫힘을 포함하면 한 건당 받는 것이 많아 페이지를 절반으로 잡는다.
    func testClosedScopeUsesSmallerPages() {
        let open = GitHubClient.defaultPageSize(scope: PRListScope.open, includeClosed: false)
        let closed = GitHubClient.defaultPageSize(scope: PRListScope(kind: .recentAll, window: .month),
                                                  includeClosed: true)
        XCTAssertGreaterThan(open, closed)
    }
}

/// 탭 순서는 화면 순서이자 ⌘1/2/3 순서다. 선언 순서를 건드리면 둘이 조용히 어긋난다.
final class ScopeTabOrderTests: XCTestCase {
    func testTabsGoFromNarrowToWide() {
        XCTAssertEqual(PRListScopeKind.allCases, [.open, .myApprovals, .recentAll],
                       "내가 할 일 → 내가 한 일 → 그 밖의 전부")
    }

    /// 순서를 바꿔도 저장 값은 rawValue 라 예전에 고른 탭이 그대로 돌아온다.
    func testStoredScopeSurvivesReordering() {
        for kind in PRListScopeKind.allCases {
            let scope = PRListScope(kind: kind, window: kind.usesWindow ? .week : nil)
            XCTAssertEqual(PRListScope(storageValue: scope.storageValue)?.kind, kind)
        }
    }

    // MARK: 한글 변수 전달

    func testKoreanVariablesGoThroughStdinUnchanged() throws {
        // Foundation Process 는 인자를 NFD(자모)로 바꿔 넘겨 "로그인" 검색이 0건이 됐다. 본문을 표준 입력으로 넘긴다.
        let request = GitHubClient.graphQLRequest("query($q:String!){x}", variables: ["q": .string("is:pr 로그인"), "n": .int(50)])
        XCTAssertEqual(request.arguments, ["api", "graphql", "--input", "-"])
        let body = try XCTUnwrap(request.stdin)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let variables = try XCTUnwrap(json["variables"] as? [String: Any])
        let q = try XCTUnwrap(variables["q"] as? String)
        XCTAssertEqual(Array(q.unicodeScalars), Array("is:pr 로그인".precomposedStringWithCanonicalMapping.unicodeScalars))
        XCTAssertEqual(variables["n"] as? Int, 50)
    }

    func testAsciiVariablesStayAsArguments() {
        // 영문만 있는 요청(목록 조회 전부)은 예전 그대로 둔다.
        let request = GitHubClient.graphQLRequest("Q", variables: ["q": .string("repo:a/b is:pr")])
        XCTAssertNil(request.stdin)
        XCTAssertEqual(request.arguments, ["api", "graphql", "-f", "query=Q", "-f", "q=repo:a/b is:pr"])
    }
}
