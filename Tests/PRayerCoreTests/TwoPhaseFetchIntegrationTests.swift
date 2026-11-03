import XCTest
@testable import PRayerCore

/// 두 단계 받기(훑기 → 바뀐 것만 자세히)가 예전 방식(매번 전부 자세히)과 **같은 목록**을 내는지 실제 GitHub 으로 잰다.
/// 빠지는 PR 이나 칸이 있으면 화면이 조용히 틀린다 — 단위 테스트의 가짜 데이터로는 못 잡는다.
///
/// `bash Scripts/test.sh --fetch` (레포는 `PRAYER_TEST_REPO`). GraphQL 을 백 점 남짓 쓴다.
final class TwoPhaseFetchIntegrationTests: XCTestCase {
    private var repo: RepoID {
        let raw = ProcessInfo.processInfo.environment["PRAYER_TEST_REPO"] ?? "acme/sample-ios"
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return RepoID(owner: "acme", name: "sample-ios") }
        return RepoID(owner: parts[0], name: parts[1])
    }
    private var client: GitHubClient { GitHubClient(ghPath: "/opt/homebrew/bin/gh") }

    private func requireIntegration() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRAYER_INTEGRATION"] == "1",
                          "PRAYER_INTEGRATION=1 일 때만 실행합니다.")
    }

    /// 앱이 쓰는 탭 전부.
    private let scopes: [PRListScope] = [.open, .myApprovals(.day), .myApprovals(.week), .myApprovals(.month),
                                         .recentAll(.day), .recentAll(.week)]

    private func probes(_ scope: PRListScope, login: String) async throws -> (probes: [PRProbe], cost: Int) {
        var all: [PRProbe] = []
        var cursor: String?
        var cost = 0
        for _ in 0..<GitHubClient.searchPageCeiling {
            let slice = try await client.probeSlice(repos: [repo], scope: scope, viewerLogin: login, cursor: cursor)
            all += slice.probes
            cost += slice.cost
            guard slice.hasNextPage, let end = slice.endCursor, all.count < scope.maxResults else { break }
            cursor = end
        }
        var seen = Set<String>()
        return (all.filter { seen.insert($0.key).inserted }, cost)
    }

    /// 예전 방식 — 검색으로 전부 자세히 받는다(비교 기준). 닫힘이 섞인 50건은 GitHub 이 502 로 끊을 때가 있어(실측)
    /// 25건씩 받는다.
    private func fullFetch(_ scope: PRListScope, login: String) async throws -> [PullRequestInfo] {
        var all: [PullRequestInfo] = []
        var cursor: String?
        for _ in 0..<GitHubClient.searchPageCeiling {
            let slice = try await client.pullRequestSlice(repos: [repo], scope: scope, viewerLogin: login,
                                                          cursor: cursor, pageSize: 25)
            all += slice.prs
            guard slice.hasNextPage, let end = slice.endCursor, all.count < scope.maxResults else { break }
            cursor = end
        }
        return GitHubClient.deduped(all)
    }

    /// 두 PR 의 다른 칸 이름. 같은 PR 을 두 길로 받아 견줄 때 무엇이 어긋났는지 말하려고 쓴다.
    private func differingFields(_ a: PullRequestInfo, _ b: PullRequestInfo) -> [String] {
        let left = Mirror(reflecting: a).children
        let right = Dictionary(uniqueKeysWithValues: Mirror(reflecting: b).children.compactMap { child in
            child.label.map { ($0, String(describing: child.value)) }
        })
        return left.compactMap { child in
            guard let label = child.label else { return nil }
            let value = String(describing: child.value)
            guard right[label] != value else { return nil }
            print("### \(a.id) \(label): \(value.prefix(120)) ≠ \((right[label] ?? "-").prefix(120))")
            return label
        }
    }

    /// 탭마다 훑은 목록이 전부 받은 목록과 같은 PR·같은 순서이고, 받아 둔 것이 그대로면 다시 받을 것이 없다.
    /// 두 번 받는 사이에 PR 이 실제로 바뀌면 어긋날 수 있어 한 번 더 해 본다.
    func testProbeMatchesFullFetchForEveryScope() async throws {
        try requireIntegration()
        let login = try await client.account().login
        for scope in scopes {
            var lastFailure = ""
            for attempt in 1...2 {
                let full = try await fullFetch(scope, login: login)
                let (probes, cost) = try await probes(scope, login: login)
                let known = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let wanted = PRFetchPlan.nodesToFetch(probes, known: known, fullSync: false)
                let assembled = PRFetchPlan.assemble(probes, known: known)
                print("### \(scope.label): 전부 \(full.count)건 · 훑기 \(probes.count)건 \(cost)점 · 다시 받을 것 \(wanted.count)건")
                if probes.map(\.key) == full.map(\.id), wanted.isEmpty, assembled.map(\.id) == full.map(\.id) {
                    lastFailure = ""
                    break
                }
                let missing = Set(full.map(\.id)).subtracting(probes.map(\.key))
                let extra = Set(probes.map(\.key)).subtracting(full.map(\.id))
                let changed = probes.filter { $0.needsDetail(known: known[$0.key]) }.map(\.key)
                lastFailure = "\(scope.label) \(attempt)회: 훑기에 없음 \(missing.sorted()) · 훑기에만 \(extra.sorted())"
                    + " · 바뀐 것으로 본 것 \(changed)"
            }
            XCTAssertEqual(lastFailure, "", lastFailure)
        }
    }

    /// `nodes(ids:)` 로 받은 PR 이 검색으로 받은 PR 과 칸 하나까지 같다 — 다르면 바뀐 것만 받을 때 그 칸이 틀린다.
    /// 머지 가능 여부는 GitHub 이 그때그때 계산해(UNKNOWN ↔ MERGEABLE) 두 번 받는 사이 달라질 수 있어 뺀다.
    func testNodesDetailEqualsSearchDetail() async throws {
        try requireIntegration()
        let login = try await client.account().login
        for scope in [PRListScope.open, .recentAll(.day)] {
            let full = Array(try await fullFetch(scope, login: login).prefix(PRFetchPlan.detailChunk))
            guard !full.isEmpty else { continue }
            let detailed = try await client.pullRequests(nodeIDs: full.map(\.nodeID))
            XCTAssertEqual(detailed.prs.map(\.id), full.map(\.id), "\(scope.label): 받은 순서·건수")
            let byID = Dictionary(uniqueKeysWithValues: detailed.prs.map { ($0.id, $0) })
            var compared = 0
            for pr in full {
                guard let other = byID[pr.id] else { continue }
                // 두 번 받는 사이에 활동이 있었으면 다른 게 맞다.
                guard other.updatedAt == pr.updatedAt else { continue }
                let fields = differingFields(pr, other).filter { !["mergeable", "mergeStateStatus"].contains($0) }
                XCTAssertEqual(fields, [], "\(pr.id) 가 두 길에서 다르다")
                compared += 1
            }
            print("### \(scope.label): 자세히 받기 \(detailed.prs.count)건 \(detailed.cost)점 · 칸까지 견준 것 \(compared)건")
            XCTAssertGreaterThan(compared, 0)
        }
    }

    /// 받아 둔 것이 오래됐으면 — 활동·CI·head 가 바뀌었거나 처음 보는 PR — 그것만 골라 다시 받고, 다 받은 결과는 전부 받은
    /// 것과 같다.
    func testStaleKnownIsRefetchedAndEndsIdentical() async throws {
        try requireIntegration()
        let login = try await client.account().login
        let full = try await fullFetch(.open, login: login)
        guard full.count >= 4 else { throw XCTSkip("열린 PR 이 4건보다 적습니다") }
        let (probes, _) = try await probes(.open, login: login)
        var known = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        known[full[0].id]?.updatedAt = full[0].updatedAt.addingTimeInterval(-60)   // 그 뒤 활동이 있었다
        known[full[1].id]?.checkState = full[1].checkState == "FAILURE" ? "SUCCESS" : "FAILURE"  // CI 가 바뀌었다
        known[full[2].id]?.headRefOid = "0000000000000000000000000000000000000000"  // 새 커밋
        known[full[3].id] = nil  // 처음 본다
        let wanted = PRFetchPlan.nodesToFetch(probes, known: known, fullSync: false)
        XCTAssertEqual(Set(wanted), Set(full.prefix(4).map(\.nodeID)), "고친 네 건만 다시 받아야 한다")
        let detailed = try await client.pullRequests(nodeIDs: wanted)
        for pr in detailed.prs { known[pr.id] = pr }
        let assembled = PRFetchPlan.assemble(probes, known: known)
        XCTAssertEqual(assembled.map(\.id), full.map(\.id))
        for (a, b) in zip(assembled, full) where a.updatedAt == b.updatedAt {
            XCTAssertEqual(differingFields(a, b).filter { !["mergeable", "mergeStateStatus"].contains($0) }, [], a.id)
        }
        print("### 오래된 4건 다시 받기: \(detailed.cost)점")
    }

    /// 값: 훑기는 건수와 상관없이 1점, 자세히 받기는 건수에 비례한다(1건 1점 · 25건 10점).
    func testCosts() async throws {
        try requireIntegration()
        let login = try await client.account().login
        let probe = try await client.probeSlice(repos: [repo], scope: .recentAll(.week), viewerLogin: login)
        XCTAssertEqual(probe.cost, 1, "훑기 \(probe.probes.count)건")
        let ids = probe.probes.prefix(25).map(\.nodeID)
        let one = try await client.pullRequests(nodeIDs: Array(ids.prefix(1)))
        XCTAssertEqual(one.cost, 1)
        let many = try await client.pullRequests(nodeIDs: Array(ids))
        XCTAssertLessThanOrEqual(many.cost, 10)
        print("### 값: 훑기 \(probe.probes.count)건 \(probe.cost)점 · 자세히 1건 \(one.cost)점 · \(ids.count)건 \(many.cost)점")
    }
}
