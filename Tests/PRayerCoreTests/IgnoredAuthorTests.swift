import XCTest
@testable import PRayerCore

/// "특정 사람의 PR 숨기기" — 라벨(`DO NOT REVIEW`)은 올린 사람이 붙이는 것이라
/// 내가 정할 수 없다. "이 사람 PR 은 볼 일이 없다" 는 내 쪽 사정이라 따로 둔다.
final class IgnoredAuthorTests: XCTestCase {
    private let scope = PRListScope.open

    private func hidden(_ pr: PullRequestInfo, ignored: Bool, on: Bool = true) -> Set<PRFilterKind> {
        PRVisibility.hidingFilters(pr: pr,
                                   state: PRFilterState(hideIgnoredAuthors: on),
                                   scope: scope,
                                   hasHiddenLabel: false,
                                   isIgnoredAuthor: ignored)
    }

    func testIgnoredAuthorIsHidden() {
        XCTAssertTrue(hidden(Fixtures.pr(), ignored: true).contains(.hideIgnoredAuthors))
    }

    func testOthersAreUntouched() {
        XCTAssertTrue(hidden(Fixtures.pr(), ignored: false).isEmpty)
    }

    func testOffMeansVisible() {
        XCTAssertTrue(hidden(Fixtures.pr(), ignored: true, on: false).isEmpty)
    }

    /// 내가 올린 PR 은 맨 위 그룹이 맡는다. 여기서 작성자로 걸러 버리면
    /// 나를 목록에 넣어 둔 순간 내 PR 이 통째로 사라진다.
    func testMyOwnPRIsNeverHiddenByAuthor() {
        let mine = Fixtures.pr(viewerDidAuthor: true)
        XCTAssertTrue(hidden(mine, ignored: true).isEmpty)
    }

    /// GitHub 로그인은 대소문자를 가리지 않는다.
    func testMatchIgnoresCase() {
        var settings = Settings.default
        settings.ignoredAuthors = ["Jamie-QQ"]
        XCTAssertTrue(settings.isIgnoredAuthor("jamie-qq"))
        XCTAssertTrue(settings.isIgnoredAuthor("JAMIE-QQ"))
        XCTAssertFalse(settings.isIgnoredAuthor("jamie"))
    }

    /// 목록이 비면 아무것도 안 거르므로 "필터 N" 에 세지 않는다 —
    /// 숨은 게 없는데 숫자만 올라가면 무엇이 걸렀는지 찾느라 헤맨다.
    func testEmptyListDoesNotCountAsActive() {
        let empty = PRFilterState(hideIgnoredAuthors: true, hasIgnoredAuthors: false)
        XCTAssertFalse(empty.active(in: scope).contains(.hideIgnoredAuthors))

        let filled = PRFilterState(hideIgnoredAuthors: true, hasIgnoredAuthors: true)
        XCTAssertTrue(filled.active(in: scope).contains(.hideIgnoredAuthors))
    }

    /// 새 항목이 없는 옛 설정도 그대로 살아야 한다.
    func testOldSettingsDecodeWithEmptyList() throws {
        let old = #"{"onboardingCompleted":true,"claudePath":"/usr/bin/claude","ghPath":"/usr/bin/gh","repos":[]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertTrue(settings.ignoredAuthors.isEmpty)
    }
}
