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

    // MARK: 설정 › 연결의 줄 하나 — 툴바와 같은 판정이어야 한다

    /// 계정은 붙어 있어도 목록 갱신이 실패 중이면 주황이다(예전 설정은 초록 "사용 가능" 이었다).
    func testGitHubRowWarnsWhileRefreshFails() {
        XCTAssertEqual(ConnectionHealth.github(checked: true, connected: true, refreshFailing: true), .warning)
        XCTAssertEqual(ConnectionHealth.github(checked: true, connected: true, refreshFailing: false), .ok)
        XCTAssertEqual(ConnectionHealth.github(checked: true, connected: false, refreshFailing: true), .error)
        XCTAssertEqual(ConnectionHealth.github(checked: false, connected: false, refreshFailing: false), .checking)
    }

    func testEngineRow() {
        func row(_ engine: ReviewEngineKind, _ status: EngineStatus?, watched: [ReviewEngineKind] = [.claude]) -> ConnectionHealth? {
            ConnectionHealth.engine(engine, primary: .claude, watched: watched, status: status)
        }
        XCTAssertEqual(row(.claude, nil), .checking)
        XCTAssertEqual(row(.claude, ready), .ok)
        XCTAssertEqual(row(.claude, loggedOut), .error)
        XCTAssertEqual(row(.codex, loggedOut, watched: [.claude, .codex]), .warning)
        // 지켜보지 않는 엔진은 툴바가 문제로 치지 않는다 — 줄도 경고색이 없다.
        XCTAssertNil(row(.codex, missing))
    }

    /// 줄마다의 판정 중 가장 나쁜 것이 툴바 아이콘과 같다 — 두 곳이 서로 다른 말을 하지 않는다.
    /// (아직 확인 전인 다른 엔진은 툴바를 "확인 중" 으로 붙잡지 않는다 — 그 엔진 줄만 회색이다.)
    func testRowsAgreeWithToolbar() {
        let statuses: [EngineStatus?] = [nil, ready, loggedOut, missing]
        let rank: [ConnectionHealth: Int] = [.ok: 0, .checking: 1, .warning: 2, .error: 3]
        for claude in statuses {
            for codex in statuses {
                for watched in [[ReviewEngineKind.claude], [.claude, .codex]] {
                    for (checked, connected) in [(false, false), (true, false), (true, true)] {
                        for refreshFailing in [false, true] {
                            let toolbar = level(watched: watched, claude: claude, codex: codex,
                                                githubChecked: checked, githubConnected: connected,
                                                refreshFailing: refreshFailing)
                            var rows = [ConnectionHealth.github(checked: checked, connected: connected,
                                                                refreshFailing: refreshFailing)]
                            rows.append(ConnectionHealth.engine(.claude, primary: .claude, watched: watched, status: claude) ?? .ok)
                            if let codexRow = ConnectionHealth.engine(.codex, primary: .claude, watched: watched, status: codex),
                               codexRow != .checking {
                                rows.append(codexRow)
                            }
                            let worst = rows.max { rank[$0, default: 0] < rank[$1, default: 0] }
                            XCTAssertEqual(worst, toolbar,
                                           "claude=\(String(describing: claude)) codex=\(String(describing: codex)) watched=\(watched) github=\(checked)/\(connected) refresh=\(refreshFailing)")
                        }
                    }
                }
            }
        }
    }
}
