import Foundation
import PRayerCore

/// 탭 하나를 받은 결과(`AppModel.fetchScope`).
struct ScopeFetch {
    /// 올린 시각 순(최신이 위).
    var prs: [PullRequestInfo]
    var total: Int?
    var truncated: Bool
    var probePages: Int
    /// 자세히 받은 PR 수. 바뀐 것이 없으면 0.
    var detailed: Int
    /// 이번에 든 값(GitHub rateLimit.cost 합).
    var cost: Int
    var fullSync: Bool

    /// 로그 한 줄 — "훑기 1쪽 · 자세히 2건 · 2점".
    var summary: String {
        "훑기 \(probePages)쪽 · 자세히 \(detailed)건 · \(cost)점\(fullSync ? " · 전부" : "")"
    }
}

extension AppModel {
    /// 탭 하나를 받는다 — 가볍게 훑고(`PRProbe`, 100건에 1점) 바뀐 PR 만 자세히 받는다(`PRFetchPlan`).
    ///
    /// 예전에는 매번 전부 자세히 받아 리뷰 대기 한 번에 40점이 들었다(실측). 30분마다·새로고침을 누를 때·맥이 깨어날 때는
    /// 전부 받는다(`lastFullSync`) — 훑기로 못 가르는 변화가 있어도 그때 바로잡힌다.
    ///
    /// - Parameter progress: 자세히 받을 것이 여러 묶음일 때 받은 데까지 늘어놓은 목록. 처음 채울 때 먼저 그리려고 쓴다.
    ///   false 를 돌려주면 그만 받는다(탭을 옮겼다).
    func fetchScope(_ scope: PRListScope,
                    progress: (([PullRequestInfo]) -> Bool)? = nil) async throws -> ScopeFetch {
        let repos = settings.enabledRepos.map(\.repo)
        let key = scope.storageValue
        let startedAt = Date()
        // 받는 동안은 받아 둔 PR 을 잊지 않는다(`pruneKnownPRs`) — 막 받은 PR 은 아직 어느 탭 목록에도 없어서 잊으면 빠진다.
        fetchesInFlight += 1
        defer { fetchesInFlight -= 1 }
        let full = PRFetchPlan.needsFullSync(lastFullSync: lastFullSync[key], now: startedAt)

        var probes: [PRProbe] = []
        var cursor: String?
        var total: Int?
        var truncated = false
        var pages = 0
        var cost = 0
        while pages < GitHubClient.searchPageCeiling {
            let slice = try await github.probeSlice(repos: repos, scope: scope,
                                                    viewerLogin: githubAccount?.login, cursor: cursor)
            pages += 1
            cost += slice.cost
            probes += slice.probes
            total = slice.totalCount ?? total
            rateRemaining = slice.rateRemaining ?? rateRemaining
            guard slice.hasNextPage, let end = slice.endCursor else { break }
            cursor = end
            if probes.count >= scope.maxResults {
                truncated = true
                break
            }
        }
        // 검색 커서는 실시간으로 재정렬되는 결과 위의 오프셋이라 경계의 PR 이 두 페이지에 다 나올 수 있다(`deduped`).
        var seen = Set<String>()
        probes = probes.filter { seen.insert($0.key).inserted }

        let wanted = PRFetchPlan.nodesToFetch(probes, known: knownPRs, fullSync: full)
        var detailed = 0
        for start in stride(from: 0, to: wanted.count, by: PRFetchPlan.detailChunk) {
            let chunk = Array(wanted[start..<min(start + PRFetchPlan.detailChunk, wanted.count)])
            let result = try await github.pullRequests(nodeIDs: chunk)
            cost += result.cost
            rateRemaining = result.rateRemaining ?? rateRemaining
            detailed += result.prs.count
            for pr in result.prs { knownPRs[pr.id] = pr }
            if let progress, start + chunk.count < wanted.count {
                let partial = PRFetchPlan.assemble(probes, known: knownPRs).sorted { $0.createdAt > $1.createdAt }
                guard progress(partial) else { throw CancellationError() }
            }
        }
        if full { lastFullSync[key] = startedAt }
        if let total, probes.count < total { truncated = true }
        return ScopeFetch(prs: PRFetchPlan.assemble(probes, known: knownPRs).sorted { $0.createdAt > $1.createdAt },
                          total: total, truncated: truncated, probePages: pages, detailed: detailed,
                          cost: cost, fullSync: full)
    }

    /// 어느 탭에도 없는 PR 은 잊는다. 다시 나타나면 그때 자세히 받는다.
    ///
    /// 다른 탭을 받는 중이면 건너뛴다. 그 탭이 막 받은 PR 은 아직 어느 목록에도 없어, 여기서 잊으면 그 탭을 다 받았을 때
    /// 목록에서 빠진다(다음 주기에 돌아오긴 하지만 그 사이 한 번 사라진다). 잊는 것은 다음 기회에 해도 된다.
    func pruneKnownPRs() {
        guard fetchesInFlight == 0 else { return }
        var keep = Set(prs.map(\.id))
        for list in listCache.values { keep.formUnion(list.map(\.id)) }
        knownPRs = knownPRs.filter { keep.contains($0.key) }
    }
}
