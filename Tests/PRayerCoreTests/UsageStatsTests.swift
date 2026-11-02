import XCTest
@testable import PRayerCore

/// 사용 통계(UsageStats) — 언제 세고, 무엇을 보내고, 무엇은 절대 싣지 않는가.
final class UsageStatsTests: XCTestCase {
    private let config = UsageStatsConfig(appID: "00000000-0000-0000-0000-000000000001", namespace: "dev.example",
                                          isTestMode: true)!
    private let client = UsageStatsClient(appVersion: "0.6.5", betaNumber: 9, osVersion: "26.6")

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func stats(startDay: String? = "2026-11-01") -> UsageStats {
        var stats = UsageStats()
        if let startDay { stats.noteStarted(day: startDay) }
        return stats
    }

    private func decodedBody(_ stats: UsageStats, day: String) throws -> [String: Any] {
        let body = try XCTUnwrap(stats.body(for: day, config: config, client: client, calendar: utc))
        let array = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.count, 1, "하루에 신호 하나")
        return try XCTUnwrap(array.first)
    }

    func testDoesNotCountBeforeStarted() {
        var stats = stats(startDay: nil)
        stats.record(.approve, day: "2026-11-01")
        XCTAssertTrue(stats.days.isEmpty, "파일을 읽기 전에 센 것은 읽은 파일에 덮이므로 세지 않는다")
    }

    func testStartDayIsKeptFromFirstTime() {
        var stats = stats(startDay: "2026-11-01")
        stats.noteStarted(day: "2026-11-05")
        XCTAssertEqual(stats.startDay, "2026-11-01")
    }

    func testCountsPerDayAndEvent() {
        var stats = stats()
        stats.record(.approve, day: "2026-11-01")
        stats.record(.approve, day: "2026-11-01")
        stats.record(.merge, day: "2026-11-02")
        XCTAssertEqual(stats.days["2026-11-01"]?["pr.approve"], 2)
        XCTAssertEqual(stats.days["2026-11-02"]?["pr.merge"], 1)
    }

    func testTurningOffDropsUnsentAndStopsCounting() {
        var stats = stats()
        stats.record(.approve, day: "2026-11-01")
        stats.setEnabled(false)
        stats.record(.approve, day: "2026-11-01")
        XCTAssertTrue(stats.days.isEmpty, "끄면 안 보낸 것도 버리고 더 세지 않는다")
        XCTAssertTrue(stats.pendingDays(today: "2026-11-09").isEmpty)
    }

    func testOnlyFinishedDaysArePending() {
        var stats = stats()
        stats.record(.appLaunch, day: "2026-11-02")
        stats.record(.appLaunch, day: "2026-11-01")
        stats.record(.appLaunch, day: "2026-11-03")
        XCTAssertEqual(stats.pendingDays(today: "2026-11-03"), ["2026-11-01", "2026-11-02"], "오늘 것은 하루가 끝나야 보낸다")
    }

    func testMarkSentRemovesDayAndKeepsBody() {
        var stats = stats()
        stats.record(.appLaunch, day: "2026-11-01")
        stats.markSent(day: "2026-11-01", body: "[]", at: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertNil(stats.days["2026-11-01"])
        XCTAssertEqual(stats.lastSent?.day, "2026-11-01")
        XCTAssertEqual(stats.lastSent?.body, "[]")
    }

    func testStoredDaysAreCapped() {
        var stats = stats(startDay: "2026-10-01")
        for day in 1...20 {
            stats.record(.appLaunch, day: String(format: "2026-10-%02d", day))
        }
        XCTAssertEqual(stats.days.count, UsageStats.maxStoredDays)
        XCTAssertNil(stats.days["2026-10-01"], "오래된 날부터 버린다")
        XCTAssertNotNil(stats.days["2026-10-20"])
    }

    func testBodyCarriesOnlyVersionsAndCounts() throws {
        var stats = stats()
        stats.record(.approve, day: "2026-11-01")
        let signal = try decodedBody(stats, day: "2026-11-01")
        XCTAssertEqual(Set(signal.keys), ["appID", "clientUser", "type", "isTestMode", "payload", "receivedAt"])
        XCTAssertEqual(signal["type"] as? String, UsageStats.signalType)
        XCTAssertEqual(signal["isTestMode"] as? Bool, true)
        let payload = try XCTUnwrap(signal["payload"] as? [String: Any])
        let allowed = Set(["day", "appVersion", "betaNumber", "macOS"] + UsageStats.Event.allCases.map(\.rawValue))
        XCTAssertEqual(Set(payload.keys), allowed, "이벤트 횟수와 버전 말고는 싣지 않는다")
        XCTAssertEqual(payload["pr.approve"] as? Int, 1)
        XCTAssertEqual(payload["pr.merge"] as? Int, 0, "안 쓴 기능은 0 으로 채운다")
        XCTAssertEqual(payload["appVersion"] as? String, "0.6.5")
        XCTAssertEqual(payload["betaNumber"] as? String, "9")
    }

    func testBodyOmitsBetaNumberForPublicBuild() throws {
        var stats = stats()
        stats.record(.approve, day: "2026-11-01")
        let body = try XCTUnwrap(stats.body(for: "2026-11-01", config: config,
                                            client: UsageStatsClient(appVersion: "0.6.5", betaNumber: nil, osVersion: "26.6"),
                                            calendar: utc))
        XCTAssertFalse(body.contains("betaNumber"))
    }

    func testBodyIsDatedAtNoonOfThatDay() throws {
        var stats = stats()
        stats.record(.approve, day: "2026-11-01")
        let signal = try decodedBody(stats, day: "2026-11-01")
        XCTAssertEqual(signal["receivedAt"] as? String, "2026-11-01T12:00:00Z")
    }

    func testNoBodyForUnknownDay() {
        XCTAssertNil(stats().body(for: "2026-11-01", config: config, client: client, calendar: utc))
    }

    func testClientUserIsHashOfInstallID() throws {
        let stats = stats()
        XCTAssertEqual(stats.clientUser.count, 64)
        XCTAssertFalse(stats.clientUser.localizedCaseInsensitiveContains(stats.installID.uuidString),
                       "설치 ID 를 그대로 보내지 않는다")
    }

    func testBrokenFieldKeepsTurnedOffChoice() throws {
        let json = #"{"enabled": false, "installID": "00000000-0000-0000-0000-0000000000AB", "days": "깨진 값"}"#
        let stats = try JSONDecoder().decode(UsageStats.self, from: Data(json.utf8))
        XCTAssertFalse(stats.enabled, "파일 한 칸이 깨졌다고 끈 사람이 다시 켜지면 안 된다")
        XCTAssertEqual(stats.installID.uuidString, "00000000-0000-0000-0000-0000000000AB")
        XCTAssertTrue(stats.days.isEmpty)
    }

    func testConfigNeedsAppID() {
        XCTAssertNil(UsageStatsConfig(appID: "", namespace: "dev.example", isTestMode: false), "빈 App ID 는 이 빌드가 안 보낸다는 뜻")
        XCTAssertNil(UsageStatsConfig(appID: nil, namespace: nil, isTestMode: false))
    }

    func testEndpointUsesNamespace() {
        XCTAssertEqual(config.endpoint?.absoluteString, "https://nom.telemetrydeck.com/v2/namespace/dev.example/")
        let plain = UsageStatsConfig(appID: "A", namespace: "", isTestMode: false)
        XCTAssertEqual(plain?.endpoint?.absoluteString, "https://nom.telemetrydeck.com/v2/")
    }

    func testDayKeyFollowsCalendar() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        // 2026-11-01 16:00 UTC = 2026-11-02 01:00 서울
        let date = Date(timeIntervalSince1970: 1_793_548_800)
        XCTAssertEqual(UsageStats.dayKey(date, calendar: utc), "2026-11-01")
        XCTAssertEqual(UsageStats.dayKey(date, calendar: seoul), "2026-11-02")
    }

    func testOSVersionKeepsMajorAndMinor() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 1)
        XCTAssertEqual(UsageStatsClient.osVersion(version), "26.6")
    }
}
