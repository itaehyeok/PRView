import XCTest
@testable import PRayerCore

/// 기본 갱신 주기를 120 → 60초로 바꾸며 옛 설정을 옮기는 규칙. 옛 기본값만 옮기고 사람이 고른 값은 그대로 둔다.
final class PollIntervalMigrationTests: XCTestCase {
    private func load(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testOldDefaultMovesToNewDefault() throws {
        XCTAssertEqual(try load(#"{"pollSeconds": 120}"#).pollSeconds, 60)
    }

    func testOldChosenValueIsKept() throws {
        XCTAssertEqual(try load(#"{"pollSeconds": 90}"#).pollSeconds, 90)
        XCTAssertEqual(try load(#"{"pollSeconds": 300}"#).pollSeconds, 300)
    }

    /// 새 키에 있는 값은 늘 사람이 고른 것이다 — 120 이어도 옮기지 않는다.
    func testNewKeyIsTakenAsIs() throws {
        XCTAssertEqual(try load(#"{"pollIntervalSeconds": 120}"#).pollSeconds, 120)
    }

    func testMissingUsesDefault() throws {
        XCTAssertEqual(try load("{}").pollSeconds, Settings.default.pollSeconds)
        XCTAssertEqual(Settings.default.pollSeconds, 60)
    }

    /// 저장하면 새 키로 쓴다 — 다시 읽어도 사람이 고른 120 이 60 으로 바뀌지 않는다.
    func testSavedValueSurvivesRoundTrip() throws {
        var settings = Settings.default
        settings.pollSeconds = 120
        let loaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.pollSeconds, 120)
    }
}
