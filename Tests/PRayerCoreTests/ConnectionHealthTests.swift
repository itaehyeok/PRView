import XCTest
@testable import PRayerCore

/// 툴바 "상태" 아이콘 판정. 지켜보는 엔진만 보고, 기본 엔진·GitHub 이 안 되면 빨강, 그 밖의 흔들림은 주황.
final class ConnectionHealthTests: XCTestCase {
    private let ready = EngineStatus(path: "/x", version: "1.0", loggedIn: true, loginKnown: true)
    private let loggedOut = EngineStatus(path: "/x", version: "1.0", loggedIn: false, loginKnown: true)
    private let missing = EngineStatus(path: "/x")

    private func level(primary: ReviewEngineKind = .claude, watched: [ReviewEngineKind] = [.claude],
                       claude: EngineStatus?, codex: EngineStatus?,
                       githubChecked: Bool = true, githubConnected: Bool = true,
                       refreshFailing: Bool = false) -> ConnectionHealth {
        ConnectionHealth.level(primary: primary, watched: watched,
                               status: { $0 == .claude ? claude : codex },
                               githubChecked: githubChecked, githubConnected: githubConnected,
                               refreshFailing: refreshFailing)
    }

    /// 지켜보지 않는 Codex 는 깔려 있고 로그아웃이어도, 아예 없어도 정상이다.
    func testUnwatchedEngineIsIgnored() {
        XCTAssertEqual(level(claude: ready, codex: loggedOut), .ok)
        XCTAssertEqual(level(claude: ready, codex: missing), .ok)
    }

    /// 지켜보는 Codex 의 로그인이 풀리면 경고다(기본 엔진이 아니라 빨강은 아니다).
    func testWatchedSecondaryEngineDroppingIsWarning() {
        XCTAssertEqual(level(watched: [.claude, .codex], claude: ready, codex: loggedOut), .warning)
    }

    func testPrimaryEngineFailingIsError() {
        XCTAssertEqual(level(watched: [], claude: loggedOut, codex: nil), .error)
        XCTAssertEqual(level(primary: .codex, watched: [.claude, .codex], claude: ready, codex: missing), .error)
    }

    func testGitHub() {
        XCTAssertEqual(level(claude: ready, codex: nil, githubConnected: false), .error)
        XCTAssertEqual(level(claude: ready, codex: nil, refreshFailing: true), .warning)
    }

    /// 켜고 확인하기 전에는 빨강이 아니라 "확인 중" 이다.
    func testCheckingBeforeFirstCheck() {
        XCTAssertEqual(level(claude: nil, codex: nil), .checking)
        XCTAssertEqual(level(claude: ready, codex: nil, githubChecked: false, githubConnected: false), .checking)
    }
}
