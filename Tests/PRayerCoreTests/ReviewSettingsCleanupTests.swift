import XCTest
@testable import PRayerCore

/// 리뷰 탭 정리. 2026-10-02 에 효과 없던 설정 넷을 없앴고, 2026-10-06 에 리뷰 가이드를 바꾸는 칸 둘
/// (팀 규칙 덧붙이기, 통째 교체)도 없앴다 — 리뷰는 늘 앱에 든 가이드로 돈다.
final class ReviewSettingsCleanupTests: XCTestCase {
    /// 없앤 키(코멘트 수·길이 상한, 리뷰 종류 기본값, 완전허용이면 Approve, 리뷰 가이드 두 칸, 끝 표기 두 칸)가 남은
    /// 옛 설정 파일도 읽힌다.
    /// 다른 값은 그대로 살아야 한다 — 키 하나 때문에 설정 전체가 기본값으로 돌아가면 레포 목록이 사라진다.
    func testOldSettingsWithRemovedKeysStillDecode() throws {
        let json = #"""
        {"onboardingCompleted":true,"model":"opus","maxDraftComments":3,"maxCommentBodyChars":250,
         "defaultReviewEvent":"APPROVE","approveWhenFullyOK":true,"aiAttribution":true,"attributionStyle":"byClaude",
         "reviewGuidePath":"/tmp/old-guide.md","teamRulesPath":"/tmp/team-rules.md",
         "repos":[{"repo":{"owner":"acme","name":"sample-ios"}}]}
        """#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(settings.model, "opus")
        XCTAssertEqual(settings.repos.map(\.repo.full), ["acme/sample-ios"])
        // 없앤 키는 다시 쓰지 않는다.
        let written = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        for key in ["maxDraftComments", "maxCommentBodyChars", "defaultReviewEvent", "approveWhenFullyOK",
                    "reviewGuidePath", "teamRulesPath", "aiAttribution", "attributionStyle"] {
            XCTAssertFalse(written.contains(key), "\(key) 가 다시 저장됐다")
        }
    }
}
