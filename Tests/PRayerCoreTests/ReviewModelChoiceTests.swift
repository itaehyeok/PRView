import XCTest
@testable import PRayerCore

/// 리뷰 모델 하나(diff·전체 리뷰 공용)와 PR 별 선택, 계열 최신 / 버전 고정 목록.
final class ReviewModelChoiceTests: XCTestCase {
    private let key = "acme/sample-ios#42"

    func testUsesDefaultWhenPRHasNoChoice() {
        var settings = Settings.default
        settings.model = "opus"
        settings.effort = "high"
        XCTAssertEqual(settings.reviewModelChoice(forPRKey: key),
                       ReviewModelChoice(model: "opus", effort: "high", isPRChoice: false))
    }

    func testPRChoiceWinsOverDefault() {
        var settings = Settings.default
        settings.model = "opus"
        settings.prReviewModels[key] = PRReviewModel(model: "sonnet", effort: "")
        XCTAssertEqual(settings.reviewModelChoice(forPRKey: key),
                       ReviewModelChoice(model: "sonnet", effort: "", isPRChoice: true))
        // 다른 PR 은 기본값 그대로다.
        XCTAssertFalse(settings.reviewModelChoice(forPRKey: "acme/sample-ios#1").isPRChoice)
    }

    func testPRChoicesRoundTripThroughSettingsFile() throws {
        var settings = Settings.default
        settings.prReviewModels[key] = PRReviewModel(model: "claude-opus-5", effort: "max",
                                                     chosenAt: Date(timeIntervalSince1970: 1_790_000_000))
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.prReviewModels, settings.prReviewModels)
    }

    /// 옛 설정 파일에 남은 깊은 리뷰 모델·effort 는 읽지 않는다 — diff 리뷰 모델이 둘 다의 모델이 된다.
    /// 그 키가 있어도 파일 전체가 깨지지 않아야 한다.
    func testOldDeepReviewKeysAreIgnored() throws {
        let json = #"{"model":"sonnet","effort":"high","deepReviewModel":"opus","deepReviewEffort":"low"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.model, "sonnet")
        XCTAssertEqual(settings.effort, "high")
        XCTAssertTrue(settings.prReviewModels.isEmpty)
    }

    /// 머지·닫힌 PR 의 선택이 끝없이 쌓이지 않게 오래된 것은 버린다.
    func testOldPRChoicesArePruned() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let choices = [
            "fresh": PRReviewModel(model: "opus", effort: "", chosenAt: now.addingTimeInterval(-86_400)),
            "stale": PRReviewModel(model: "opus", effort: "", chosenAt: now.addingTimeInterval(-61 * 86_400)),
        ]
        XCTAssertEqual(Set(PRReviewModel.pruned(choices, now: now).keys), ["fresh"])
    }

    // MARK: 계열 최신 · 버전 고정

    /// 기본 목록은 계열마다 하나 — 별칭이라 CLI 가 그 계열의 최신으로 풀어 준다. 순서는 Claude 앱 모델 메뉴와 같다.
    func testFamilyListHasOneEntryPerFamily() {
        XCTAssertEqual(ClaudeModels.all.map(\.id), ["opus", "fable", "sonnet", "haiku"])
        XCTAssertTrue(ClaudeModels.isFamily("opus"))
        XCTAssertFalse(ClaudeModels.isFamily("claude-opus-5"))
    }

    /// '과거 버전 고르기' 는 계열마다 최신을 뺀 지난 버전만 — 계열 순서는 기본 목록과 같고, 같은 계열은 새 버전이 위다.
    func testPastListHoldsOnlyOlderVersions() {
        XCTAssertEqual(ClaudeModels.pastOptions(catalog: nil).map(\.id), ["claude-opus-5", "claude-sonnet-5"])

        // CLI 가 opus 를 6 으로 올리면 5.5 도 지난 버전이 된다.
        let catalog = ModelCatalog(claudePath: "c", claudeVersion: "v",
                                   models: ["opus": ResolvedModel(modelID: "claude-opus-6", displayName: "Opus 6")],
                                   checkedAt: Date(), effortLevels: [])
        XCTAssertEqual(ClaudeModels.pastOptions(catalog: catalog).map(\.id),
                       ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(ClaudeModels.pastOptions(catalog: catalog).first?.label, "Opus 5.5")
    }

    /// 앱이 쌓은 이름(넘어간 앞 버전·직접 입력)도 같은 규칙으로 끼운다. 계열을 알 수 없는 이름은 맨 아래.
    func testPastListMergesRememberedNames() {
        let ids = ClaudeModels.pastOptions(catalog: nil,
                                           remembered: ["claude-3-7-sonnet-20250219", "claude-opus-4-1", "claude-opus-5",
                                                        "claude-sonnet-5-5"]).map(\.id)
        XCTAssertEqual(ids, ["claude-opus-5", "claude-opus-4-1", "claude-sonnet-5", "claude-3-7-sonnet-20250219"],
                       "씨앗과 겹치는 이름은 한 번만, 지금 최신(Sonnet 5.5)은 빼고")
    }

    func testRememberingSkipsSeedsDuplicatesAndAliases() {
        let next = ClaudeModels.remembering(["claude-opus-5", "opus", "claude-opus-6", "claude-opus-6",
                                             "claude-haiku-4-5-20251001", "bad name"], into: ["claude-opus-4-1"])
        XCTAssertEqual(next, ["claude-opus-4-1", "claude-opus-6"],
                       "씨앗(날짜를 떼고 비교)·별칭·빈칸 든 이름은 더하지 않는다")
    }

    /// 버전을 고정한 선택도 이름이 보여야 한다(두 칸·도움말·큰 PR 확인 창).
    func testPinnedModelResolvesName() throws {
        let option = try XCTUnwrap(ClaudeModels.option(id: "claude-opus-5", catalog: nil))
        XCTAssertEqual(option.label, "Opus 5")
        XCTAssertEqual(option.apiID, "claude-opus-5")
        // 직접 입력한 다른 꼴의 이름은 지어내지 않고 그대로 보인다.
        XCTAssertEqual(ClaudeModels.option(id: "claude-3-7-sonnet-20250219", catalog: nil)?.label,
                       "claude-3-7-sonnet-20250219")
        XCTAssertNil(ClaudeModels.option(id: "", catalog: nil))
        XCTAssertNil(ClaudeModels.option(id: "two words", catalog: nil))
    }

    func testModelNameShape() {
        for name in ["claude-opus-5", "sonnet[1m]", "claude-haiku-4-5-20251001", "opus"] {
            XCTAssertTrue(ClaudeModels.isModelName(name), name)
        }
        for name in ["", " opus", "opus\n", "opus; rm -rf", "-p", String(repeating: "a", count: 81)] {
            XCTAssertFalse(ClaudeModels.isModelName(name), name)
        }
    }
}
