import XCTest
@testable import PRayerCore

/// 코드 글꼴 기본값을 Menlo 11pt 에서 IBM Plex Mono 12pt 로 바꿨다. 저장된 옛 기본값은 읽을 때 옮겨야
/// 새 기본값이 보인다. 단, 사람이 고른 Menlo 는 옮기지 않는다.
final class CodeFontMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testDefaultIsPlexMono() {
        XCTAssertEqual(Settings.default.codeFontName, "IBM Plex Mono")
        XCTAssertEqual(Settings.default.codeFontSize, 12)
    }

    func testOldDefaultMovesToNewDefault() throws {
        let s = try decode(#"{"codeFontName":"Menlo","codeFontSize":11}"#)
        XCTAssertEqual(s.codeFontName, Settings.default.codeFontName)
        XCTAssertEqual(s.codeFontSize, Settings.default.codeFontSize)
    }

    /// ⌘+ / ⌘- 로 맞춘 크기는 그대로 둔다 — 글꼴만 옮긴다.
    func testAdjustedSizeIsKept() throws {
        let s = try decode(#"{"codeFontName":"Menlo","codeFontSize":14}"#)
        XCTAssertEqual(s.codeFontName, Settings.default.codeFontName)
        XCTAssertEqual(s.codeFontSize, 14)
    }

    /// 예전 글꼴 칸에서 직접 고른 글꼴은 옛 기본값이 아니다.
    func testChosenFontIsKept() throws {
        let s = try decode(#"{"codeFontName":"D2Coding","codeFontSize":11}"#)
        XCTAssertEqual(s.codeFontName, "D2Coding")
        XCTAssertEqual(s.codeFontSize, 11)
    }

    /// 고른 Menlo 가 다음 실행 때 Plex 로 돌아가면 안 된다.
    func testChosenMenloIsKept() throws {
        let s = try decode(#"{"codeFontName":"Menlo","codeFontSize":11,"codeFontChosen":true}"#)
        XCTAssertEqual(s.codeFontName, "Menlo")
        XCTAssertEqual(s.codeFontSize, 11)
    }

    func testChosenSurvivesSaveAndLoad() throws {
        var s = Settings.default
        s.codeFontName = "Menlo"
        s.codeFontChosen = true
        let loaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(loaded.codeFontName, "Menlo")
        XCTAssertTrue(loaded.codeFontChosen)
    }

    func testMissingKeysGetNewDefault() throws {
        let s = try decode("{}")
        XCTAssertEqual(s.codeFontName, "IBM Plex Mono")
        XCTAssertEqual(s.codeFontSize, 12)
    }
}
