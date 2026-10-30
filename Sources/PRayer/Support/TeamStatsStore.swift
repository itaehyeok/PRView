import Foundation
import Observation
import PRayerCore

/// 팀 통계의 상태 — 고른 기간·레포와 받아 온 재료.
///
/// 재료는 "고른 기간의 바로 앞 기간 시작"부터 지금까지 한 번에 받는다. 내 순위 카드의 "지난주 3위" 를 그리려면
/// 앞 기간도 있어야 하고, 기간을 앞뒤로 넘길 때마다 다시 받지 않게 한 번 받은 범위는 들고 있는다(더 앞으로
/// 가면 그만큼만 넓혀 다시 받는다).
///
/// 다 받고 나면 다 지난 기간의 순위를 이 맥에 남긴다(`TeamStatsCache`). 다음에 지난 기간을 보면 받지 않고
/// 바로 그린다 — 고른 기간과 그 앞 기간이 둘 다 남아 있을 때만. 새로고침은 늘 다시 받아 덮어쓴다.
@MainActor
@Observable
final class TeamStatsStore {
    enum Load: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// 몇 기간 앞까지 넘겨 볼 수 있나. PR 검색이 1,000건에서 끊기는데, 활발한 레포도 한 달 PR 이 수백 개
    /// 안쪽이라 그 안에 들게 잡았다.
    static let maxBack: [TeamStatPeriodKind: Int] = [.week: 12, .month: 6]

    var kind: TeamStatPeriodKind = .week {
        didSet { if kind != oldValue { offset = 0 } }
    }
    /// 0 이 지금 기간, -1 이 하나 앞.
    var offset = 0
    var repo: RepoID?

    private(set) var states: [TeamStatMetric: Load] = [:]
    private(set) var updatedAt: Date?
    private(set) var prTruncated = false
    private var pullRequests: [TeamStatEvent] = []
    private var approvals: [TeamStatEvent] = []
    private var comments: [TeamStatEvent] = []
    private var commits: [TeamStatCommit] = []
    /// 커밋 메일을 로그인으로 잇는 데 쓸 이름들. PR·리뷰·코멘트를 받을 때마다 다시 잇는다.
    private var commitEvents: [TeamStatEvent] = []
    private var viewerLogin: String?

    private var loadedRepo: RepoID?
    private var loadedSince: Date?
    private var task: Task<Void, Never>?
    private var cache = TeamStatsCache()
    private var cacheRepo: RepoID?

    let calendar = TeamStatPeriod.calendar()

    var period: TeamStatPeriod {
        TeamStatPeriod.containing(Date(), kind: kind, calendar: calendar).shifted(by: offset, calendar: calendar)
    }

    var previousPeriod: TeamStatPeriod { period.shifted(by: -1, calendar: calendar) }

    var canGoBack: Bool { offset > -(Self.maxBack[kind] ?? 0) }
    var canGoForward: Bool { offset < 0 }

    func events(_ metric: TeamStatMetric) -> [TeamStatEvent] {
        switch metric {
        case .commits: return commitEvents
        case .pullRequests: return pullRequests
        case .approvals: return approvals
        case .comments: return comments
        }
    }

    /// 받은 재료가 이 기간을 다 덮는가.
    private func covers(_ period: TeamStatPeriod) -> Bool {
        loadedRepo == repo && (loadedSince.map { $0 <= period.start } ?? false)
    }

    private func liveLoaded(_ metric: TeamStatMetric, in period: TeamStatPeriod) -> Bool {
        covers(period) && states[metric] == .loaded
    }

    private func cached(_ period: TeamStatPeriod) -> TeamStatsCache.Entry? {
        cacheRepo == repo ? cache.entry(for: period) : nil
    }

    /// 받은 재료로 센 순위가 먼저, 없으면 저장해 둔 순위. 새로고침하는 동안에도 저장해 둔 것을 보인다.
    func ranking(_ metric: TeamStatMetric, in period: TeamStatPeriod) -> [TeamStatRow] {
        if liveLoaded(metric, in: period) { return TeamStats.ranking(events(metric), in: period) }
        if let rows = cached(period)?.rows[metric.rawValue] { return rows }
        return covers(period) ? TeamStats.ranking(events(metric), in: period) : []
    }

    /// 고른 기간의 이 칸 상태. 저장해 둔 순위가 있으면 받는 중이거나 실패해도 그것을 보인다.
    func state(_ metric: TeamStatMetric) -> Load {
        if liveLoaded(metric, in: period) { return .loaded }
        if cached(period)?.rows[metric.rawValue] != nil { return .loaded }
        return states[metric] ?? .idle
    }

    /// 고른 기간을 저장해 둔 기록으로 보이고 있으면 그 기록을 남긴 때.
    var cachedAt: Date? {
        guard !TeamStatMetric.allCases.allSatisfy({ liveLoaded($0, in: period) }) else { return nil }
        return cached(period)?.savedAt
    }

    var isLoading: Bool { states.values.contains(.loading) }

    var hasFailure: Bool {
        states.values.contains { if case .failed = $0 { return true } else { return false } }
    }

    private func loadCache(for repo: RepoID) {
        guard cacheRepo != repo else { return }
        cache = TeamStatsCache.load(repo)
        cacheRepo = repo
    }

    /// 받은 범위 안의 다 지난 기간(주·달 모두)을 남긴다. PR 검색이 끊겼으면 앞쪽 Approve 가 덜 셌으니 남기지 않는다.
    private func saveCache() {
        guard let repo = loadedRepo, let since = loadedSince, !prTruncated,
              TeamStatMetric.allCases.allSatisfy({ states[$0] == .loaded }) else { return }
        loadCache(for: repo)
        let now = Date()
        for kind in TeamStatPeriodKind.allCases {
            for period in TeamStatsCache.completedPeriods(kind: kind, since: since, now: now, calendar: calendar) {
                let rows = Dictionary(uniqueKeysWithValues: TeamStatMetric.allCases.map {
                    ($0, TeamStats.ranking(events($0), in: period))
                })
                cache.store(rows, for: period, savedAt: now)
            }
        }
        do {
            try cache.save(repo)
        } catch {
            Log.error("통계 기록 저장 실패 \(repo.full): \(error.localizedDescription)", "stats")
        }
    }

    /// 고른 기간(과 그 앞 기간)이 받은 범위 밖이면 받는다. `force` 는 새로고침 — 범위는 그대로 두고 다시 받는다.
    func load(model: AppModel, force: Bool = false) {
        guard let repo else { return }
        loadCache(for: repo)
        // 지난 기간이고 그 앞 기간까지 남아 있으면 받지 않는다.
        if !force, period.end <= Date(), cached(period) != nil, cached(previousPeriod) != nil { return }
        let need = previousPeriod.start
        let sameRepo = loadedRepo == repo
        let covered = sameRepo && (loadedSince.map { $0 <= need } ?? false)
        let failed = states.values.contains { if case .failed = $0 { return true } else { return false } }
        if covered && !force && !failed { return }
        let since = sameRepo ? min(need, loadedSince ?? need) : need

        task?.cancel()
        if !sameRepo {
            pullRequests = []
            approvals = []
            comments = []
            commits = []
            commitEvents = []
            prTruncated = false
        }
        loadedRepo = repo
        loadedSince = since
        viewerLogin = model.githubAccount?.login
        for metric in TeamStatMetric.allCases { states[metric] = .loading }

        // 데모 모드(README 캡처)에서는 진짜 레포를 부르지 않는다.
        guard !DemoMode.isOn else {
            for metric in TeamStatMetric.allCases { states[metric] = .loaded }
            return
        }
        let github = model.github
        let source = TeamStatsCommitSource(ghPath: model.settings.ghPath, host: model.settings.githubHost)
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.loadPRs(github, repo: repo, since: since) }
                group.addTask { await self?.loadComments(github, repo: repo, since: since) }
                group.addTask { await self?.loadCommits(source, repo: repo, since: since) }
            }
            guard !Task.isCancelled else { return }
            self?.updatedAt = Date()
            self?.saveCache()
        }
    }

    private func loadPRs(_ github: GitHubClient, repo: RepoID, since: Date) async {
        do {
            let activity = try await github.teamPRActivity(repo, since: since)
            guard loadedRepo == repo else { return }
            pullRequests = activity.pullRequests
            approvals = activity.approvals
            prTruncated = activity.truncated
            states[.pullRequests] = .loaded
            states[.approvals] = .loaded
            relinkCommits()
        } catch is CancellationError {
        } catch {
            Log.error("통계 PR 조회 실패 \(repo.full): \(error.localizedDescription)", "stats")
            states[.pullRequests] = .failed(error.localizedDescription)
            states[.approvals] = .failed(error.localizedDescription)
        }
    }

    private func loadComments(_ github: GitHubClient, repo: RepoID, since: Date) async {
        do {
            let events = try await github.teamComments(repo, since: since)
            guard loadedRepo == repo else { return }
            comments = events
            states[.comments] = .loaded
            relinkCommits()
        } catch is CancellationError {
        } catch {
            Log.error("통계 코멘트 조회 실패 \(repo.full): \(error.localizedDescription)", "stats")
            states[.comments] = .failed(error.localizedDescription)
        }
    }

    private func loadCommits(_ source: TeamStatsCommitSource, repo: RepoID, since: Date) async {
        do {
            let list = try await source.commits(repo, since: since)
            guard loadedRepo == repo else { return }
            commits = list
            states[.commits] = .loaded
            relinkCommits()
        } catch is CancellationError {
        } catch {
            Log.error("통계 커밋 조회 실패 \(repo.full): \(error.localizedDescription)", "stats")
            states[.commits] = .failed(error.localizedDescription)
        }
    }

    private func relinkCommits() {
        var logins = TeamStats.activeLogins(pullRequests + approvals + comments, since: loadedSince ?? .distantPast)
        if let viewerLogin { logins.insert(viewerLogin) }
        commitEvents = TeamStats.commitEvents(commits, knownLogins: logins)
    }

    /// 처음 클론하는 중인가 — 커밋 칸에 "처음 한 번 10초쯤" 을 알린다.
    var isFirstCommitClone: Bool {
        guard let repo, states[.commits] == .loading else { return false }
        return !TeamStatsClone.exists(repo)
    }
}
