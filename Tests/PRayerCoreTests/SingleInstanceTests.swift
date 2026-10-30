import XCTest
@testable import PRayerCore

/// PRayer 를 둘 켜면 같은 데이터 폴더의 설정·초안을 서로 덮어쓴다. 켤 때 다른 PRayer 를 찾는 규칙과 안내 문구.
final class SingleInstanceTests: XCTestCase {
    private let home = "/Users/me"
    private let mine = SingleInstance.Instance(pid: 200, path: "/Applications/PRayer.app", version: "0.4.14")
    private let other = SingleInstance.Instance(pid: 100, path: "/Users/me/Applications/PRayer.app", version: "0.4.12")

    /// 같은 번들 ID 목록에는 나도 들어 있다. 나만 있으면 충돌이 아니다.
    func testSelfAloneIsNoConflict() {
        XCTAssertNil(SingleInstance.conflict(selfPID: 200, running: [mine], dataDirOverridden: false))
        XCTAssertNil(SingleInstance.conflict(selfPID: 200, running: [], dataDirOverridden: false))
    }

    func testOtherInstanceIsConflict() {
        XCTAssertEqual(SingleInstance.conflict(selfPID: 200, running: [mine, other], dataDirOverridden: false), other)
    }

    /// PRAYER_DATA_DIR 로 데이터 폴더를 갈라 띄운 실행은 데이터가 달라 견주지 않는다.
    func testDataDirOverrideSkipsCheck() {
        XCTAssertNil(SingleInstance.conflict(selfPID: 200, running: [mine, other], dataDirOverridden: true))
    }

    /// 두 앱이 어디 있는 어느 버전인지 적는다 — 이름이 같아 무엇이 무엇인지 모르면 고를 수가 없다.
    func testExplanationNamesBothApps() {
        let text = SingleInstance.explanation(existing: other, opened: mine, home: home)
        XCTAssertTrue(text.contains("켜져 있는 것: v0.4.12 · ~/Applications/PRayer.app"), text)
        XCTAssertTrue(text.contains("지금 연 것: v0.4.14 · /Applications/PRayer.app"), text)
        XCTAssertTrue(text.contains("덮어써"), text)
    }

    func testDescribeWithoutPathOrVersion() {
        XCTAssertEqual(SingleInstance.describe(.init(pid: 1, path: nil, version: nil), home: home), "버전 모름")
        XCTAssertEqual(SingleInstance.describe(.init(pid: 1, path: "/Users/meow/PRayer.app", version: "1.0"), home: home),
                       "v1.0 · /Users/meow/PRayer.app")
    }

    /// 자동화 탈출구의 값. 엉뚱한 값은 무시하고 묻는다.
    func testPresetAnswerValues() {
        XCTAssertEqual(SingleInstance.Answer(rawValue: "existing"), .existing)
        XCTAssertEqual(SingleInstance.Answer(rawValue: "replace"), .replace)
        XCTAssertNil(SingleInstance.Answer(rawValue: "yes"))
    }
}
