import XCTest
@testable import PRayerCore

/// 로그인이 끊겨 실패한 것과, 사람이 다르게 대응해야 하는 실패를 가르는 규칙.
final class AuthFailureTests: XCTestCase {
    /// 실제로 화면에 떴던 문구.
    func testRealExpiredSessionIsDetected() {
        let real = "Failed to authenticate: OAuth session expired and could not be refreshed"
        XCTAssertTrue(AuthFailure.isExpired(real))
    }

    func testOtherAuthShapes() {
        for message in ["Not logged in. Please run `claude auth login`.",
                        "authentication_error: invalid api key",
                        "Claude 로그인이 필요합니다. 터미널에서 `claude auth login` 을 실행하세요.",
                        "Session expired"] {
            XCTAssertTrue(AuthFailure.isExpired(message), message)
        }
    }

    /// 로그인과 무관한 실패에 "다시 로그인" 을 권하면 사용자를 엉뚱한 곳으로 보낸다.
    func testUnrelatedFailuresAreNotAuth() {
        for message in ["Claude 사용 한도에 도달했습니다.",
                        "diff 가 너무 큽니다 (900줄 > 600줄)",
                        "리뷰 결과를 해석하지 못했습니다: JSON 파싱 실패",
                        "요청이 시간 안에 끝나지 않았습니다"] {
            XCTAssertFalse(AuthFailure.isExpired(message), message)
        }
    }

    /// 네트워크 끊김과 겹치면 안 된다 — 한쪽은 다시 누르면 되고 한쪽은 로그인해야 한다.
    func testNetworkFailureIsNotAuthFailure() {
        let network = #"dial tcp 20.200.245.245:443: connect: operation timed out"#
        XCTAssertTrue(TransientFailure.isNetwork(network))
        XCTAssertFalse(AuthFailure.isExpired(network))
    }

    /// GitHub 쪽 401 까지 끌어오면 엔진 로그인과 무관한 실패에 로그인을 권하게 된다.
    func testGenericUnauthorizedIsNotClaimed() {
        XCTAssertFalse(AuthFailure.isExpired("HTTP 401: Bad credentials"))
        XCTAssertFalse(AuthFailure.isExpired("Resource not accessible by integration"))
    }

    private let loggedOut = EngineStatus(path: "/c", version: "2.1.284", loggedIn: false, loginKnown: true)
    private let loggedIn = EngineStatus(path: "/c", version: "2.1.284", loggedIn: true, loginKnown: true)

    /// 실측 순서: 실패 직후 확인은 로그아웃, 터미널에서 로그인하고 돌아오면 로그인.
    func testLoginRecoveredWhenLoggedOutTurnsLoggedIn() {
        XCTAssertTrue(AuthFailure.loginRecovered(lastKnown: false, current: loggedIn))
    }

    /// 로그아웃을 본 적이 없으면 "다시 로그인했다" 고 하지 않는다 — 앱을 켠 첫 확인과,
    /// `auth status` 가 만료를 못 알아보고 계속 로그인이라고 답하는 경우.
    func testLoginNotRecoveredWithoutSeenLogout() {
        XCTAssertFalse(AuthFailure.loginRecovered(lastKnown: nil, current: loggedIn))
        XCTAssertFalse(AuthFailure.loginRecovered(lastKnown: true, current: loggedIn))
    }

    /// 아직 로그아웃이거나, 로그인은 됐다는데 CLI 가 안 돌면 리뷰를 못 한다.
    func testLoginNotRecoveredWhileNotReady() {
        let noVersion = EngineStatus(path: "/c", version: nil, loggedIn: true, loginKnown: true)
        XCTAssertFalse(AuthFailure.loginRecovered(lastKnown: false, current: loggedOut))
        XCTAssertFalse(AuthFailure.loginRecovered(lastKnown: false, current: noVersion))
    }

    /// `auth status` 가 답하지 못한 확인은 로그인 여부를 모르는 것이다. 그걸 로그인으로 치지 않는다.
    func testUnansweredCheckIsNotRecovery() {
        let unanswered = EngineStatus(path: "/c", version: "2.1.284", loggedIn: true, loginKnown: false)
        XCTAssertFalse(AuthFailure.loginRecovered(lastKnown: false, current: unanswered))
    }
}
