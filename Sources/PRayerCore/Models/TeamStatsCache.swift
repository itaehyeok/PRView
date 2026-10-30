import Foundation

/// 다 지난 기간의 순위를 이 맥에 남겨 둔다. 지난주·지난달 순위는 거의 바뀌지 않는데(지난 커밋·Approve·코멘트는
/// 그대로다), 볼 때마다 GitHub 에서 다시 받으면 기간을 넘길 때마다 몇 초씩 기다린다(사용자 요청, 2026-10-28).
///
/// 진행 중인 기간은 담지 않는다 — 숫자가 계속 바뀐다. 다 지난 기간도 드물게 바뀔 수 있어서(늦게 푸시한 예전
/// 커밋, 지운 코멘트) 화면의 새로고침이 다시 받아 덮어쓴다.
///
/// 레포마다 파일 하나: `team-stats/<owner>_<name>.json`. 순위만 담는다(사람·수·등수) — 받은 원재료(커밋·코멘트
/// 하나하나)는 크고, 화면이 다시 쓰지 않는다.
public struct TeamStatsCache: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var savedAt: Date
        /// `TeamStatMetric.rawValue` → 순위.
        public var rows: [String: [TeamStatRow]]
    }

    public var entries: [String: Entry] = [:]

    public init() {}

    public static var directory: URL {
        AppPaths.support.appendingPathComponent("team-stats", isDirectory: true)
    }

    public static func url(for repo: RepoID, base: URL = directory) -> URL {
        base.appendingPathComponent("\(repo.slug).json")
    }

    /// 기간을 가리키는 열쇠. 시작 시각을 쓴다 — 같은 주라도 시간대가 바뀌면 다른 기간이라 섞이지 않는다.
    public static func key(_ period: TeamStatPeriod) -> String {
        "\(period.kind.rawValue)-\(Int(period.start.timeIntervalSince1970))"
    }

    public func entry(for period: TeamStatPeriod) -> Entry? {
        entries[Self.key(period)]
    }

    public func rows(_ metric: TeamStatMetric, in period: TeamStatPeriod) -> [TeamStatRow]? {
        entry(for: period)?.rows[metric.rawValue]
    }

    public mutating func store(_ rows: [TeamStatMetric: [TeamStatRow]], for period: TeamStatPeriod, savedAt: Date) {
        entries[Self.key(period)] = Entry(savedAt: savedAt,
                                          rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.key.rawValue, $0.value) }))
    }

    /// `since` 이후에 시작해 `now` 전에 끝난 기간들 — 받은 재료로 끝까지 다 셀 수 있는 기간만 담는다.
    /// 시작이 `since` 보다 앞인 기간은 앞부분을 못 받았으니 뺀다.
    public static func completedPeriods(kind: TeamStatPeriodKind, since: Date, now: Date,
                                        calendar: Calendar) -> [TeamStatPeriod] {
        var period = TeamStatPeriod.containing(since, kind: kind, calendar: calendar)
        if period.start < since { period = period.shifted(by: 1, calendar: calendar) }
        var periods: [TeamStatPeriod] = []
        while period.end <= now {
            periods.append(period)
            period = period.shifted(by: 1, calendar: calendar)
        }
        return periods
    }

    /// 파일이 없거나 깨졌으면 빈 기록 — 다시 받으면 된다.
    public static func load(_ repo: RepoID, base: URL = directory) -> TeamStatsCache {
        guard let data = try? Data(contentsOf: url(for: repo, base: base)),
              let cache = try? JSONDecoder().decode(TeamStatsCache.self, from: data) else { return TeamStatsCache() }
        return cache
    }

    public func save(_ repo: RepoID, base: URL = directory) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(for: repo, base: base), options: .atomic)
    }
}
