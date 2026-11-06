import XCTest
@testable import PRayerCore

/// 지켜볼 엔진 — 깔려 있기만 한 엔진은 빼고, 기본 엔진과 연결된 적 있는 엔진만.
final class ConnectedEnginesTests: XCTestCase {
    /// Claude 만 쓰는 사람: Codex 는 기록이 없으니 보지 않는다.
    func testWatchesPrimaryAndConnectedOnly() {
        var settings = Settings.default
        settings.model = "opus"
        XCTAssertEqual(settings.watchedEngines, [.claude])
        settings.connectedEngines = [.codex, .claude]
        XCTAssertEqual(settings.watchedEngines, [.claude, .codex])
    }

    /// 기본 엔진은 기록이 없어도 늘 본다 — 리뷰가 그 엔진으로 돈다.
    func testPrimaryEngineIsAlwaysWatched() {
        var settings = Settings.default
        settings.model = CodexModels.id("gpt-5")
        settings.connectedEngines = [.claude]
        XCTAssertEqual(settings.primaryEngine, .codex)
        XCTAssertEqual(settings.watchedEngines, [.claude, .codex])
    }

    func testNoteEngineConnectedRecordsOnce() {
        var settings = Settings.default
        XCTAssertTrue(settings.noteEngineConnected(.codex))
        XCTAssertFalse(settings.noteEngineConnected(.codex))
        XCTAssertEqual(settings.connectedEngines, [.codex])
    }

    /// 칸이 없던 옛 설정 파일은 빈 목록으로 읽고, 저장하면 남는다.
    func testConnectedEnginesDecoding() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"model": "opus"}"#.utf8))
        XCTAssertEqual(old.connectedEngines, [])
        var settings = Settings.default
        settings.connectedEngines = [.claude, .codex]
        let loaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.connectedEngines, [.claude, .codex])
    }
}
