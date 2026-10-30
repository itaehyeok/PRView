import XCTest
@testable import PRayerCore

/// 나란히 보기에서 hunk 머리글을 좌우로 나누는 규칙.
final class HunkDisplayTests: XCTestCase {
    func testSplitsOldAndNewRanges() {
        let parts = DiffParser.hunkDisplayParts("@@ -104,6 +104,19 @@")
        XCTAssertEqual(parts.left, "@@ -104,6 @@")
        XCTAssertEqual(parts.right, "@@ +104,19 @@")
    }

    /// 뒤에 붙는 함수 이름은 양쪽 공통이라 새 파일 쪽에 붙인다.
    func testContextGoesToTheNewSide() {
        let parts = DiffParser.hunkDisplayParts("@@ -111,32 +124,32 @@ - (void)layoutSubviews")
        XCTAssertEqual(parts.left, "@@ -111,32 @@")
        XCTAssertEqual(parts.right, "@@ +124,32 @@ - (void)layoutSubviews")
    }

    /// 줄 수가 1이면 git 이 콤마를 생략한다.
    func testSingleLineRange() {
        let parts = DiffParser.hunkDisplayParts("@@ -1 +1 @@")
        XCTAssertEqual(parts.left, "@@ -1 @@")
        XCTAssertEqual(parts.right, "@@ +1 @@")
    }

    /// 못 알아보는 모양이면 원문을 왼쪽에 그대로 둔다 — 정보를 잃는 것보다 낫다.
    func testUnknownShapeKeepsRaw() {
        let weird = "@@ 이상한 줄"
        let parts = DiffParser.hunkDisplayParts(weird)
        XCTAssertEqual(parts.left, weird)
        XCTAssertTrue(parts.right.isEmpty)
    }
}

/// 다시 누르면 되는 실패와, 사람이 고쳐야 하는 실패를 가르는 규칙.
final class TransientFailureTests: XCTestCase {
    /// 실제로 화면에 떴던 문구.
    func testRealTimeoutIsTransient() {
        let real = #"gh 호출 실패: Post "https://api.github.com/graphql": dial tcp 20.200.245.245:443: connect: operation timed out"#
        XCTAssertTrue(TransientFailure.isNetwork(real))
    }

    func testOtherNetworkShapes() {
        for message in ["dial tcp: lookup api.github.com: no such host",
                        "read tcp 10.0.0.2:1: connection reset by peer",
                        "net/http: TLS handshake timeout",
                        "connect: network is unreachable"] {
            XCTAssertTrue(TransientFailure.isNetwork(message), message)
        }
    }

    /// 사람이 고쳐야 하는 것은 절대 여기 걸리면 안 된다 — 걸리면 "다시 시도" 만 권하게 된다.
    func testRealProblemsAreNotTransient() {
        for message in ["HTTP 401: Bad credentials",
                        "Resource not accessible by integration",
                        "GraphQL: Could not resolve to a Repository with the name 'acme/sample-ios'.",
                        "gh: command not found"] {
            XCTAssertFalse(TransientFailure.isNetwork(message), message)
        }
    }
}

/// 상대 시각은 **"지금"을 인자로 받아야** 한다 — 뷰가 굳는 버그의 뿌리가 이것이다.
/// (1시간 21분 전 승인이 목록에서 계속 "now" 로 남아 있었다.)
final class RelativeTimeStalenessTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testSameDateReadsDifferentlyAsTimePasses() {
        XCTAssertEqual(RelativeTime.compact(base, now: base.addingTimeInterval(30)), "now")
        XCTAssertEqual(RelativeTime.compact(base, now: base.addingTimeInterval(4_800)), "1h")
        XCTAssertEqual(RelativeTime.ago(base, now: base.addingTimeInterval(30)), "just now")
        XCTAssertEqual(RelativeTime.ago(base, now: base.addingTimeInterval(4_800)), "1h ago")
    }

    /// 30초 틱으로도 "now → 1m" 전환을 놓치지 않는다(틱 간격이 경계보다 짧다).
    func testTickIntervalIsFinerThanTheFirstBoundary() {
        XCTAssertLessThan(30.0, 60.0, "첫 경계(60초)보다 틱이 촘촘해야 한 단계도 건너뛰지 않는다")
    }

    /// 미래 시각은 0 으로 눌러 "now" 로 둔다 — 음수 초를 그대로 쓰면 문구가 깨진다.
    func testFutureDateIsClampedToNow() {
        XCTAssertEqual(RelativeTime.compact(base.addingTimeInterval(600), now: base), "now")
    }
}
