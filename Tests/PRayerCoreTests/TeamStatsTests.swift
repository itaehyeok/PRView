import XCTest
@testable import PRayerCore

final class TeamStatsTests: XCTestCase {
    private let seoul = TeamStatPeriod.calendar(timeZone: TimeZone(identifier: "Asia/Seoul") ?? .current)

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    // MARK: - 기간

    func testWeekStartsOnMondayInLocalTime() {
        // 2026-10-28 (수) 한국 시간 오전 — UTC 로는 27일 밤이다.
        let week = TeamStatPeriod.containing(date("2026-10-27T23:00:00Z"), kind: .week, calendar: seoul)
        XCTAssertEqual(week.start, date("2026-10-25T15:00:00Z"))   // 10월 26일(월) 0시
        XCTAssertEqual(week.end, date("2026-11-01T15:00:00Z"))     // 11월 2일(월) 0시
        XCTAssertEqual(week.label(calendar: seoul), "10월 26일 – 11월 1일")
    }

    func testShiftAcrossMonthAndYear() {
        let month = TeamStatPeriod.containing(date("2026-01-10T03:00:00Z"), kind: .month, calendar: seoul)
        let previous = month.shifted(by: -1, calendar: seoul)
        XCTAssertEqual(previous.label(calendar: seoul), "2025년 12월")
        XCTAssertEqual(previous.end, month.start)
        XCTAssertEqual(month.shifted(by: 1, calendar: seoul).label(calendar: seoul), "2026년 2월")
    }

    func testPeriodExcludesEnd() {
        let week = TeamStatPeriod.containing(date("2026-10-20T03:00:00Z"), kind: .week, calendar: seoul)
        XCTAssertTrue(week.contains(week.start))
        XCTAssertFalse(week.contains(week.end))
    }

    // MARK: - 순위

    func testTiesShareRankAndBotsAreDropped() {
        let week = TeamStatPeriod.containing(date("2026-10-20T03:00:00Z"), kind: .week, calendar: seoul)
        let at = date("2026-10-21T03:00:00Z")
        let outside = date("2026-10-28T03:00:00Z")
        let events = ["kim", "kim", "lee", "lee", "park", "claude[bot]", "claude[bot]", "claude[bot]"]
            .map { TeamStatEvent(person: $0, at: at) } + [TeamStatEvent(person: "park", at: outside)]
        let rows = TeamStats.ranking(events, in: week)
        XCTAssertEqual(rows.map(\.person), ["kim", "lee", "park"])
        XCTAssertEqual(rows.map(\.rank), [1, 1, 3])
        XCTAssertEqual(rows.map(\.count), [2, 2, 1])
    }

    // MARK: - 커밋 메일 → 로그인

    func testEmailMatchesSingleLoginByPrefix() {
        let logins: Set<String> = ["alex-k-acme", "riley-c", "jamie-2-acme", "sam-o"]
        XCTAssertEqual(TeamStats.person(forEmail: "alex.k@acme.com", knownLogins: logins), "alex-k-acme")
        XCTAssertEqual(TeamStats.person(forEmail: "Riley.C@acme.com", knownLogins: logins), "riley-c")
        // 회사 도메인이 둘이어도 같은 사람이다.
        XCTAssertEqual(TeamStats.person(forEmail: "jamie.2@acmecorp.com", knownLogins: logins), "jamie-2-acme")
        XCTAssertEqual(TeamStats.person(forEmail: "sam.o@acme.com", knownLogins: logins), "sam-o")
    }

    func testNoreplyAddressCarriesLogin() {
        XCTAssertEqual(TeamStats.person(forEmail: "12345678+jordan-lee@users.noreply.github.com",
                                        knownLogins: ["jordan-lee"]), "jordan-lee")
        // 로그인을 몰라도 noreply 주소 안의 로그인을 쓴다.
        XCTAssertEqual(TeamStats.person(forEmail: "1+sam@users.noreply.github.com", knownLogins: []), "sam")
    }

    func testAmbiguousOrUnknownEmailStaysOnItsOwn() {
        let logins: Set<String> = ["kim-a-acme", "kim-b-acme"]
        XCTAssertEqual(TeamStats.person(forEmail: "kim@acme.com", knownLogins: logins), "kim")
        XCTAssertEqual(TeamStats.person(forEmail: "nobody@acme.com", knownLogins: logins), "nobody")
        // 앞부분만 같은 다른 이름(kimberly)에는 붙지 않는다.
        XCTAssertEqual(TeamStats.person(forEmail: "kim@acme.com", knownLogins: ["kimberly-acme"]), "kim")
    }

    func testOldAccountOutsideRangeDoesNotBlockMatch() {
        let since = date("2026-09-01T00:00:00Z")
        let events = [
            TeamStatEvent(person: "casey-h", at: date("2025-09-18T00:00:00Z")),        // 예전 계정
            TeamStatEvent(person: "casey-h-acme", at: date("2026-10-02T00:00:00Z")),
            TeamStatEvent(person: "dependabot[bot]", at: date("2026-10-02T00:00:00Z")),
        ]
        let logins = TeamStats.activeLogins(events, since: since)
        XCTAssertEqual(logins, ["casey-h-acme"])
        XCTAssertEqual(TeamStats.person(forEmail: "casey.h@acme.com", knownLogins: logins), "casey-h-acme")
    }

    // MARK: - 커밋 중복

    func testCommitLogParsingAndDedupe() {
        let log = """
        aaa\talex.k@acme.com\t2026-10-21T10:00:00+09:00\tfeat: 첫 일
        aaa\talex.k@acme.com\t2026-10-21T10:00:00+09:00\tfeat: 첫 일
        bbb\talex.k@acme.com\t2026-10-21T10:00:00+09:00\tfeat: 첫 일
        ccc\talex.k@acme.com\t2026-10-21T11:00:00+09:00\tfix: 탭\t들어간 제목
        ddd\tbroken line
        """
        let commits = TeamStats.parseCommitLog(log)
        XCTAssertEqual(commits.count, 4)
        XCTAssertEqual(commits.last?.subject, "fix: 탭\t들어간 제목")
        // aaa 는 여러 브랜치에 같이 있는 커밋, bbb 는 리베이스로 해시만 바뀐 복사본이다.
        let events = TeamStats.commitEvents(commits, knownLogins: ["alex-k-acme"])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.person)), ["alex-k-acme"])
    }

    // MARK: - 지난 기간 기록

    func testCompletedPeriodsSkipPartialAndOngoing() {
        // 10월 15일(수)부터 받았고 지금은 10월 28일(수) — 10월 12일 주는 앞부분을 못 받았고, 26일 주는 진행 중이다.
        let since = date("2026-10-14T15:00:00Z")
        let now = date("2026-10-28T03:00:00Z")
        let weeks = TeamStatsCache.completedPeriods(kind: .week, since: since, now: now, calendar: seoul)
        XCTAssertEqual(weeks.map { $0.label(calendar: seoul) }, ["10월 19일 – 10월 25일"])
        let months = TeamStatsCache.completedPeriods(kind: .month, since: date("2026-08-31T15:00:00Z"), now: now, calendar: seoul)
        XCTAssertEqual(months.map { $0.label(calendar: seoul) }, ["2026년 9월"])
    }

    func testCacheRoundTripsThroughFile() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("team-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = RepoID(owner: "acme", name: "app")
        let week = TeamStatPeriod.containing(date("2026-10-20T03:00:00Z"), kind: .week, calendar: seoul)
        let other = week.shifted(by: -1, calendar: seoul)
        var cache = TeamStatsCache()
        cache.store([.approvals: [TeamStatRow(person: "kim", count: 3, rank: 1)]], for: week, savedAt: date("2026-10-28T00:00:00Z"))
        try cache.save(repo, base: base)

        let loaded = TeamStatsCache.load(repo, base: base)
        XCTAssertEqual(loaded, cache)
        XCTAssertEqual(loaded.rows(.approvals, in: week)?.first?.person, "kim")
        XCTAssertNil(loaded.rows(.comments, in: week))
        XCTAssertNil(loaded.entry(for: other))
        // 파일이 없는 레포는 빈 기록이다.
        XCTAssertTrue(TeamStatsCache.load(RepoID(owner: "acme", name: "none"), base: base).entries.isEmpty)
    }

    // MARK: - 조회 도우미

    func testCommentLinesDropBotsAndOldComments() {
        let since = date("2026-10-01T00:00:00Z")
        let text = """
        kim\tUser\t2026-10-02T00:00:00Z
        claude[bot]\tBot\t2026-10-02T00:00:00Z
        lee\tUser\t2026-09-30T23:00:00Z
        """
        let events = GitHubClient.parseCommentLines(text, since: since)
        XCTAssertEqual(events.map(\.person), ["kim"])
    }

    func testSearchDayStartsOneDayEarlierInUTC() {
        // 한국 10월 1일 0시 = UTC 9월 30일 15시 → 하루 앞당겨 9월 29일.
        XCTAssertEqual(GitHubClient.searchDay(date("2026-09-30T15:00:00Z")), "2026-09-29")
    }
}
