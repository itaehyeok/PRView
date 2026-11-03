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

    /// 지금 탭 말고도 늘 받아 두는 탭 — 리뷰 대기와 Approved(마지막에 고른 기간). 누르자마자 최신 목록이 보이고
    /// (`isListFresh`), 열지 않은 탭의 소식도 알 수 있다(사용자 결정 2026-11-02). 받는 값이 작아서(바뀐 것만) 기간에
    /// 상관없이 매번 받는다. All PRs 는 건수가 많고 알릴 것이 없어 받지 않는다.
    func refreshInBackground() async {
        guard !DemoMode.isOn, !settings.enabledRepos.isEmpty, !isBackgroundRefreshing else { return }
        isBackgroundRefreshing = true
        defer { isBackgroundRefreshing = false }
        for kind in [PRListScopeKind.open, .myApprovals] {
            let scope = scope(for: kind)
            guard scope != listScope else { continue }
            do {
                try await refreshQuietly(scope)
            } catch is CancellationError {
                continue
            } catch {
                // 화면에 보이는 탭이 아니라 알리지 않는다. 다음 주기에 다시 받는다.
                Log.info("뒤에서 받기 실패(\(scope.label)): \(error.localizedDescription)", "app")
            }
        }
    }

    /// 화면에 없는 탭 하나를 받아 그 탭의 지난 목록(`listCache`)을 바꾼다. 연출 없이 바꾼다 — 그 탭으로 옮기면
    /// 받은 지 얼마 안 된 목록으로 바로 보인다.
    private func refreshQuietly(_ scope: PRListScope) async throws {
        let result = try await fetchScope(scope)
        var fetched = result.prs
        if scope.requiresMyApproval {
            let extra = await recentlyApprovedMissing(from: fetched, windowHours: scope.windowHours)
            for pr in extra { knownPRs[pr.id] = pr }
            fetched += extra
        }
        fetched = GitHubClient.deduped(fetched).sorted { $0.createdAt > $1.createdAt }
        // 받는 사이 이 탭으로 옮겨 왔으면 화면 목록은 그 탭의 refresh 가 맞춘다 — 여기서 바꾸면 연출과 엇갈린다.
        guard scope != listScope else { throw CancellationError() }
        let key = scope.storageValue
        let before = listCache[key] ?? []
        let fetchedBefore = listFetchedAt[key]
        listCache[key] = fetched
        listFetchedAt[key] = Date()
        seedOtherCaches(with: fetched, from: scope)
        seedDeparted(from: before, fetched: fetched, since: fetchedBefore, source: scope)
        // 알림은 리뷰 대기 목록으로 본다 — 열린 PR 전부라 새 PR·새 코멘트·머지 가능을 여기서 안다. 지금 탭의 refresh 도
        // 같은 기억(prSnapshots)에 합치므로 같은 소식이 두 번 오지 않는다.
        if scope.kind == .open { detectChangesAndNotify(in: fetched) }
        if !result.truncated {
            let cached = Store.CachedList(scope: key, savedAt: Date(), prs: fetched)
            Task { [store] in await store.save(list: cached) }
        }
        pruneKnownPRs()
        loadSinceApprovals()
        Log.info("뒤에서 받음 \(scope.label) \(fetched.count)건 — \(result.summary)", "app")
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
