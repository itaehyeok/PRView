import XCTest
@testable import PRayerCore

final class MemberNamesTests: XCTestCase {
    func testDefaultRuleCutsAtFirstHyphen() {
        XCTAssertEqual(MemberNames.defaultShort("riley-park-acme"), "riley")
        XCTAssertEqual(MemberNames.defaultShort("alex.kim"), "alex.kim")
        XCTAssertEqual(MemberNames.defaultShort("claude[bot]"), "claude[bot]")
    }

    func testDegenerateLogins() {
        XCTAssertEqual(MemberNames.defaultShort("-lead"), "lead")
        XCTAssertEqual(MemberNames.defaultShort(""), "")
    }

    func testOverrideWinsAndBlankOverrideIsIgnored() {
        let overrides = ["riley-park-acme": "라일리", "x-y": "  "]
        XCTAssertEqual(MemberNames.short("riley-park-acme", overrides: overrides, enabled: true), "라일리")
        XCTAssertEqual(MemberNames.short("x-y", overrides: overrides, enabled: true), "x")
    }

    func testDisabledKeepsLogin() {
        XCTAssertEqual(MemberNames.short("riley-park-acme", overrides: [:], enabled: false), "riley-park-acme")
    }

    func testSettingsRoundTripKeepsNicknames() throws {
        var settings = Settings.default
        settings.memberNicknames = ["riley-park-acme": "라일리"]
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(restored.displayName("riley-park-acme"), "라일리")
        XCTAssertEqual(restored.displayName("green-two-acme"), "green")
    }
}
