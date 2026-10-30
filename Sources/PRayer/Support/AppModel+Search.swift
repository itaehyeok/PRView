import Foundation
import PRayerCore

/// 아래 구역(지금 탭 밖) 검색이 어디까지 왔나.
enum ExtraSearchPhase: Equatable {
    case idle
    case searching
    case done
    case failed(String)
    /// GitHub 검색 한도에 걸렸다 — 실패와 달리 잠시 뒤면 된다.
    case rateLimited
}

/// 아래 구역이 서버에서 받은 것과 다음 페이지.
struct ExtraSearchState {
    var key = ""
    var phase: ExtraSearchPhase = .idle
    /// 번호·단어·작성자·브랜치로 받은 것을 합친 것. 번호로 받은 것을 앞에 둔다.
    var server: [PullRequestInfo] = []
    /// 단어 검색이 알려 준 전체 건수. 받은 수보다 크면 맨 아래 "다음 50건 받기" 가 이 수를 보인다.
    var wordsTotal: Int?
    var wordsReceived = 0
    /// 단어 검색 다음 페이지. 처음 받은 때의 쿼리(기간 포함)를 그대로 이어 쓴다.
    var wordsQuery: String?
    var endCursor: String?
    var hasNextPage = false
    var nextPageSize = 50
    var isLoadingMore = false
}

/// 목록 검색칸으로 **지금 탭 밖** PR 까지 찾는다(2026-10-29 사용자 기획).
///
/// 위 구역은 지금처럼 그 탭에 받아 둔 목록을 거르고, 아래 구역은 그 밖을 찾는다 — To review·Approved 는 등록된 레포의
/// PR 전부(기간 제한 없음), All PRs 는 고른 기간보다 오래된 것만(`PRSearchPlan.olderThan`). 아래 구역은 두 곳에서 채운다:
/// 다른 탭에 받아 둔 목록(바로 보이고, 단어 검색이 못 잡는 글자 일부도 잡는다)과 서버 검색(50건씩).
/// 아래 구역에는 레포 고르기만 걸고 라벨·사람 필터는 걸지 않는다 — 이건 "찾기" 라 숨겨 둔 PR 도 나와야 한다.
extension AppModel {
    /// 아래 구역을 띄울 검색어인가. 숫자가 아닌 한 글자는 위 구역만 거른다(`PRSearchPlan`).
    var extraSearchPlan: PRSearchPlan? { PRSearchPlan(search: filter.search) }

    /// 아래 구역이 찾는 레포 — 레포 고르기만은 아래에도 건다.
    private var extraSearchRepos: [RepoID] {
        let hidden = hiddenRepoKeys
        return settings.enabledRepos.map(\.repo).filter { !hidden.contains(PRFilterState.repoKey($0)) }
    }

    /// 받은 결과를 다시 쓰는 시간. 탭을 오가는 동안은 다시 묻지 않고, 한참 뒤 같은 말을 치면 새로 묻는다.
    static let extraSearchReuse: TimeInterval = 120
    /// 한 번에 보이는 단어 검색 결과 수(사용자 결정 2026-10-29 "50건으로").
    static let extraSearchBatch = 50
    /// 한 요청의 크기. 기간 없는 검색은 오래된 PR(코멘트·커밋이 많다)이 섞여 한 요청에 50건이면 GitHub 이 502 로 끊는다
    /// (2026-10-29 실측, 결과가 수백 건인 한글 검색어: 50건 11초 끊김 · 25건 9초 · 15건 5초). 25건씩 두 번 받아 50건을 채우고,
    /// 첫 25건은 오는 대로 그린다.
    static let extraSearchPageSize = 25

    /// 검색어·탭·레포 고르기가 바뀌면 부른다. 같은 열쇠면 아무것도 안 한다.
    /// - Parameter force: 실패 뒤 "다시 시도" — 같은 열쇠여도, 받아 둔 것이 있어도 새로 묻는다.
    func scheduleExtraSearch(force: Bool = false) {
        guard let plan = extraSearchPlan, !DemoMode.isOn else {
            extraSearchTask?.cancel()
            extraSearchTask = nil
            if !extraSearch.key.isEmpty { extraSearch = ExtraSearchState() }
            return
        }
        let repos = extraSearchRepos
        let scope = listScope
        let key = PRSearchPlan.cacheKey(search: filter.search, scope: scope, repos: repos)
        guard force || key != extraSearch.key else { return }
        extraSearchTask?.cancel()
        if !force, let cached = extraSearchCache[key], Date().timeIntervalSince(cached.at) < Self.extraSearchReuse {
            extraSearch = cached.state
            return
        }
        extraSearch = ExtraSearchState(key: key, phase: .searching)
        guard !repos.isEmpty else {
            extraSearch.phase = .done
            return
        }
        extraSearchTask = Task { [weak self] in
            // 입력이 멈출 때까지 기다린다 — 글자마다 물으면 GitHub 검색 한도(분당 30회)를 금방 쓴다.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.runExtraSearch(plan: plan, key: key, repos: repos,
                                       olderThan: PRSearchPlan.olderThan(scope: scope))
        }
    }

    func retryExtraSearch() {
        scheduleExtraSearch(force: true)
    }

    private func runExtraSearch(plan: PRSearchPlan, key: String, repos: [RepoID], olderThan: Date?) async {
        let github = self.github
        let wordsQuery = plan.wordsQuery(repos: repos, olderThan: olderThan)
        // 번호·작성자·브랜치는 덤이다 — 없는 아이디처럼 하나가 실패해도 단어 검색 결과는 보인다.
        async let numberHits = Self.fetchNumber(plan.number, repos: repos, github: github)
        let size = Self.extraSearchPageSize
        async let authorHits = Self.optionalSearch(plan.authorQuery(repos: repos, olderThan: olderThan), size: size, github: github)
        async let branchHits = Self.optionalSearch(plan.branchQuery(repos: repos, olderThan: olderThan), size: size, github: github)
        do {
            let first = try await github.searchSlice(query: wordsQuery, pageSize: Self.extraSearchPageSize)
            let extras = await numberHits + authorHits + branchHits
            guard !Task.isCancelled, extraSearch.key == key else { return }
            extraSearch.server = GitHubClient.deduped(extras)
            extraSearch.wordsQuery = wordsQuery
            extraSearch.wordsTotal = first.totalCount
            appendExtraPage(first)
            // 첫 페이지는 위에서 그렸다. 50건이 찰 때까지 이어 받는다 — 그동안 머리 줄은 "찾는 중" 그대로다.
            try await continueExtraPages(key: key, until: Self.extraSearchBatch)
            guard extraSearch.key == key else { return }
            extraSearch.phase = .done
            extraSearchCache[key] = (extraSearch, Date())
            Log.info("전체 PR 검색 \(extraSearch.server.count)건 (단어 검색 \(extraSearch.wordsReceived)/\(first.totalCount ?? 0))", "app")
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), extraSearch.key == key else { return }
            // 이미 받은 페이지와 번호로 바로 받은 것은 그래도 보인다 — 번호 조회는 검색 색인을 거치지 않는다.
            let extras = await numberHits + authorHits + branchHits
            extraSearch.server = GitHubClient.deduped(extras + extraSearch.server)
            extraSearch.phase = PRSearchPlan.isRateLimited(error) ? .rateLimited : .failed(error.localizedDescription)
            Log.info("전체 PR 검색 실패: \(error.localizedDescription)", "app")
        }
    }

    private func appendExtraPage(_ slice: GitHubClient.PullRequestSlice) {
        extraSearch.server = GitHubClient.deduped(extraSearch.server + slice.prs)
        extraSearch.wordsReceived += slice.prs.count
        extraSearch.endCursor = slice.endCursor
        extraSearch.hasNextPage = slice.hasNextPage
        extraSearch.nextPageSize = slice.nextPageSize
    }

    /// 단어 검색을 `count` 건이 찰 때까지 25건씩 이어 받는다. 검색어가 바뀌면(열쇠가 달라지면) 멈춘다.
    private func continueExtraPages(key: String, until count: Int) async throws {
        while extraSearch.key == key, extraSearch.hasNextPage, extraSearch.wordsReceived < count,
              let query = extraSearch.wordsQuery, let cursor = extraSearch.endCursor {
            let slice = try await github.searchSlice(query: query, cursor: cursor,
                                                     pageSize: min(extraSearch.nextPageSize, Self.extraSearchPageSize))
            guard !Task.isCancelled, extraSearch.key == key else { return }
            appendExtraPage(slice)
        }
    }

    /// 단어 검색 다음 50건. 처음 50건만 받고 나머지는 사용자가 누를 때만 받는다 — 흔한 단어는 수백 건이다.
    func loadMoreExtraSearch() {
        guard extraSearch.hasNextPage, !extraSearch.isLoadingMore else { return }
        let key = extraSearch.key
        let target = extraSearch.wordsReceived + Self.extraSearchBatch
        extraSearch.isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await continueExtraPages(key: key, until: target)
                guard extraSearch.key == key else { return }
                extraSearch.isLoadingMore = false
                extraSearchCache[key] = (extraSearch, Date())
            } catch {
                guard extraSearch.key == key else { return }
                extraSearch.isLoadingMore = false
                banner = Banner(kind: .error, message: "검색 결과를 더 받지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func fetchNumber(_ number: Int?, repos: [RepoID],
                                                github: GitHubClient) async -> [PullRequestInfo] {
        guard let number else { return [] }
        return await withTaskGroup(of: PullRequestInfo?.self) { group in
            for repo in repos {
                group.addTask { try? await github.pullRequest(repo, number: number) }
            }
            var found: [PullRequestInfo] = []
            for await pr in group {
                if let pr { found.append(pr) }
            }
            return found.sorted { $0.repo.full < $1.repo.full }
        }
    }

    nonisolated private static func optionalSearch(_ query: String?, size: Int,
                                                   github: GitHubClient) async -> [PullRequestInfo] {
        guard let query else { return [] }
        return (try? await github.searchSlice(query: query, pageSize: size))?.prs ?? []
    }

    // MARK: - 화면이 읽는 값

    /// 위 구역(지금 탭)에 보이는 PR — 아래 구역에서 뺀다.
    var searchTopPRs: [PullRequestInfo] { myOpenPRs + visiblePRs }

    /// 아래 구역에 그릴 PR.
    var extraSearchPRs: [PullRequestInfo] {
        guard extraSearchPlan != nil else { return [] }
        let needle = filter.search
        // 다른 탭에 받아 둔 목록 — 서버를 기다리지 않고 바로 보이고, 단어 검색이 못 잡는 글자 일부도 잡는다.
        // 이 탭 목록(`prs`)에서 필터에 걸려 위에 안 보이는 것도 여기로 온다.
        let local = ([prs] + Array(listCache.values)).joined().filter { PRSearchPlan.matchesLocally($0, needle: needle) }
        return PRSearchPlan.extra(candidates: extraSearch.server + local,
                                  excluding: Set(searchTopPRs.map(\.id)),
                                  hiddenRepoKeys: hiddenRepoKeys,
                                  olderThan: PRSearchPlan.olderThan(scope: listScope))
    }

    // MARK: - 고르기

    /// 아래 구역 행 클릭. 같이 고르기는 하지 않는다 — 우클릭 묶음 리뷰는 위 구역(탭 목록)에서만 한다.
    func clickExtraSearchPR(_ pr: PullRequestInfo) {
        searchPickedPR = pr
        listSelection = RowSelection()
        myPRSelection = RowSelection()
        selectedPRID = pr.id
    }

    /// 게시·Approve 뒤 다시 받은 PR 을 아래 구역과 고른 PR 에도 반영한다.
    func replaceInExtraSearch(_ fresh: PullRequestInfo) {
        if searchPickedPR?.id == fresh.id { searchPickedPR = fresh }
        if let index = extraSearch.server.firstIndex(where: { $0.id == fresh.id }) {
            extraSearch.server[index] = fresh
        }
    }
}
