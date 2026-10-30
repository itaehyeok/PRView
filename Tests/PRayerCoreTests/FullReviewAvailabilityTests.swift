import XCTest
@testable import PRayerCore

/// 전체 리뷰는 PR 마다 버튼(전체 리뷰 · diff 리뷰)으로 고르고, 로컬 클론 경로를 정한 레포에서만 된다.
/// 전체 리뷰를 통째로 켜고 끄던 설정 스위치는 없앴다 — 스위치가 하던 일은 "경로를 정했어도 막기" 뿐이었다.
final class FullReviewAvailabilityTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    func testClonePathAloneDecides() {
        var s = Settings.default
        XCTAssertNil(s.deepReviewPath(for: repo))
        s.deepReviewRepoPaths = [repo.full: "/Users/me/work/sample-ios"]
        XCTAssertEqual(s.deepReviewPath(for: repo), "/Users/me/work/sample-ios")
        s.deepReviewRepoPaths = [repo.full: ""]
        XCTAssertNil(s.deepReviewPath(for: repo))
    }

    /// 옛 설정 파일에서 스위치를 꺼 뒀어도 클론 경로를 정한 레포는 전체 리뷰가 된다. 다시 저장하면 옛 키는 남지 않는다.
    func testOldSwitchOffIsIgnored() throws {
        let json = #"{"deepReviewEnabled":false,"deepReviewRepoPaths":{"acme/sample-ios":"/Users/me/work/sample-ios"}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.deepReviewPath(for: repo), "/Users/me/work/sample-ios")
        let saved = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(saved.contains("deepReviewEnabled"))
    }
}
