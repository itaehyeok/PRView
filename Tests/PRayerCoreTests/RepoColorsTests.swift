import XCTest
@testable import PRayerCore

/// 레포 색 나눠 주기(RepoColors). 레포 탭·행의 점이 이 결과를 쓴다.
///
/// 지키는 약속: 팔레트(12색) 안에서는 두 레포가 같은 색을 받지 않고, 한 번 받은 색은
/// 다른 레포를 넣고 빼도 바뀌지 않으며, 예전(이름 해시) 색이 비어 있으면 그 색을 그대로 받는다.
final class RepoColorsTests: XCTestCase {
    private func names(_ count: Int) -> [String] { (1...count).map { "sample-repo-\($0)" } }

    /// 예전 색이 겹치는 두 이름을 찾는다. 같은 예전 자리를 두고 다투는 경우를 만들려고 쓴다.
    private func legacyCollision() -> (String, String) {
        var byIndex: [Int: String] = [:]
        for name in names(200) {
            let index = RepoColors.legacyIndex(for: name)
            if let other = byIndex[index] { return (other, name) }
            byIndex[index] = name
        }
        XCTFail("예전 자리가 겹치는 이름을 못 찾았다")
        return ("", "")
    }

    func testNoTwoReposShareAColorWithinPalette() {
        let assigned = RepoColors.assign(repos: names(RepoColors.count), existing: [:])
        XCTAssertEqual(assigned.count, RepoColors.count)
        XCTAssertEqual(Set(assigned.values).count, RepoColors.count, "12개까지는 모두 다른 색이어야 한다")
        XCTAssertTrue(assigned.values.allSatisfy { (0..<RepoColors.count).contains($0) })
    }

    /// 업데이트했다고 이미 익숙한 색이 바뀌지 않게 — 예전 자리가 비어 있으면 그대로 준다.
    func testKeepsLegacyColorWhenFree() {
        let name = "sample-ios"
        let assigned = RepoColors.assign(repos: [name], existing: [:])
        XCTAssertEqual(assigned[RepoColors.key(name)], RepoColors.legacyIndex(for: name))
    }

    /// 예전 규칙에서는 같은 색이던 두 레포가 이제는 다른 색을 받는다. 먼저 있던 레포가 예전 색을 지킨다.
    func testLegacyCollisionGetsAFreeColor() {
        let (first, second) = legacyCollision()
        let assigned = RepoColors.assign(repos: [first, second], existing: [:])
        XCTAssertEqual(assigned[RepoColors.key(first)], RepoColors.legacyIndex(for: first))
        XCTAssertNotEqual(assigned[RepoColors.key(first)], assigned[RepoColors.key(second)])
    }

    /// 다른 레포를 빼고 넣어도 남은 레포의 색은 그대로다 — 그래서 결과를 설정에 남긴다.
    /// 맨 앞에 레포 하나를 고정해 둔다 — 첫 자리로 올라온 레포는 피하는 색(avoided)이 달라 색이 바뀔 수 있어서다.
    func testOtherReposKeepTheirColorsWhenListChanges() {
        let (first, second) = legacyCollision()
        let anchor = "sample-ios"
        let third = "sample-web"
        let before = RepoColors.assign(repos: [anchor, first, second, third], existing: [:])
        // 예전 자리를 차지하던 레포를 빼도, 밀려났던 레포는 받은 색을 지킨다(그때그때 셈하면 여기서 바뀐다).
        let after = RepoColors.assign(repos: [anchor, second, third, "sample-android"], existing: before)
        XCTAssertEqual(after[RepoColors.key(second)], before[RepoColors.key(second)])
        XCTAssertEqual(after[RepoColors.key(third)], before[RepoColors.key(third)])
        XCTAssertNil(after[RepoColors.key(first)], "목록에서 뺀 레포의 색은 비워 다음 레포가 쓴다")
        XCTAssertEqual(Set(after.values).count, 4)
    }

    /// 설정을 손으로 고쳐 둘이 같은 색이거나 팔레트 밖의 값이면 다시 나눈다.
    func testRepairsDuplicateOrOutOfRangeEntries() {
        let assigned = RepoColors.assign(repos: ["a-repo", "b-repo", "c-repo"],
                                         existing: ["a-repo": 3, "b-repo": 3, "c-repo": 99])
        XCTAssertEqual(assigned["a-repo"], 3, "앞의 레포가 그 색을 지킨다")
        XCTAssertEqual(Set(assigned.values).count, 3)
        XCTAssertTrue(assigned.values.allSatisfy { (0..<RepoColors.count).contains($0) })
    }

    /// 설정에 직접 친 이름과 API 가 돌려준 이름은 대소문자가 다를 수 있다.
    func testKeysIgnoreCase() {
        XCTAssertEqual(RepoColors.key("Sample-IOS"), RepoColors.key("sample-ios"))
        let assigned = RepoColors.assign(repos: ["Sample-IOS", "sample-ios"], existing: [:])
        XCTAssertEqual(assigned.count, 1, "같은 레포를 두 번 세지 않는다")
    }

    /// 팔레트보다 레포가 많으면 그때부터는 겹칠 수밖에 없다 — 앞의 12개는 그래도 모두 다르다.
    func testBeyondPaletteFallsBackToLegacyIndex() {
        let list = names(RepoColors.count + 1)
        let assigned = RepoColors.assign(repos: list, existing: [:])
        let firstTwelve = list.prefix(RepoColors.count).compactMap { assigned[RepoColors.key($0)] }
        XCTAssertEqual(Set(firstTwelve).count, RepoColors.count)
        XCTAssertEqual(assigned[RepoColors.key(list.last!)], RepoColors.legacyIndex(for: list.last!))
    }

    /// 앞의 두 레포는 빨강 계열(분홍·빨강)을 받지 않는다 — 빨간 점이 이상 신호로 읽혀서다.
    /// "sample-kit" 는 예전 자리가 분홍(2)이라, 두 번째 레포면 다른 색을 받는다.
    func testLeadingTwoReposNeverGetReddish() {
        XCTAssertEqual(RepoColors.legacyIndex(for: "sample-kit"), 2, "이 테스트의 전제")
        let assigned = RepoColors.assign(repos: ["sample-core", "sample-kit"], existing: [:])
        XCTAssertFalse(RepoColors.reddish.contains(assigned["sample-kit"]!))
        XCTAssertNotEqual(assigned["sample-core"], assigned["sample-kit"])
    }

    /// 예전에 받아 둔 분홍이라도 앞의 두 자리면 내려놓고 다시 받는다. 다른 레포의 색은 그대로다.
    func testLeadingRepoGivesUpSavedReddish() {
        let assigned = RepoColors.assign(repos: ["sample-core", "sample-kit"],
                                         existing: ["sample-core": 1, "sample-kit": 2])
        XCTAssertEqual(assigned["sample-core"], 1)
        XCTAssertFalse(RepoColors.reddish.contains(assigned["sample-kit"]!))
    }

    /// 첫 레포는 파랑 계열을 받지 않는다 — 바로 옆 "전체" 탭이 강조색(기본 파랑)이라 같은 색 탭 둘이 붙는다.
    /// "sample-web" 은 예전 자리가 파랑(0)이다.
    func testFirstRepoNeverGetsBluish() {
        XCTAssertEqual(RepoColors.legacyIndex(for: "sample-web"), 0, "이 테스트의 전제")
        let assigned = RepoColors.assign(repos: ["sample-web", "sample-core"], existing: [:])
        XCTAssertFalse(RepoColors.avoided(at: 0).contains(assigned["sample-web"]!))
        // 첫 레포가 비켜 간 색을 두 번째가 받을 수는 있다 — 두 번째 자리는 파랑을 피하지 않는다.
        XCTAssertNotEqual(assigned["sample-web"], assigned["sample-core"])
    }

    /// 두 번째 자리의 파랑은 괜찮지만, 그 레포를 끌어 첫 자리로 올리면 파랑을 내려놓고 다시 받는다.
    func testRepoMovedToFirstGivesUpBluish() {
        let saved = ["sample-core": 1, "sample-kit": 0]
        let kept = RepoColors.assign(repos: ["sample-core", "sample-kit"], existing: saved)
        XCTAssertEqual(kept, saved, "두 번째 자리는 파랑을 그대로 쓴다")
        let moved = RepoColors.assign(repos: ["sample-kit", "sample-core"], existing: saved)
        XCTAssertFalse(RepoColors.avoided(at: 0).contains(moved["sample-kit"]!))
        XCTAssertEqual(moved["sample-core"], 1)
    }

    /// 세 번째부터는 빨강 계열도 받는다 — 막는 건 앞의 두 자리뿐이다.
    func testThirdRepoMayKeepReddish() {
        let assigned = RepoColors.assign(repos: ["sample-core", "sample-web", "sample-kit"],
                                         existing: ["sample-kit": 2])
        XCTAssertEqual(assigned["sample-kit"], 2)
    }

    /// 옛 설정 파일에는 이 키가 없다. 비어 있는 채로 읽혀야 다른 설정이 기본값으로 돌아가지 않는다.
    func testSettingsDecodeWithoutRepoColorsAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"model":"opus"}"#.utf8))
        XCTAssertEqual(legacy.repoColors, [:])
        XCTAssertEqual(legacy.model, "opus")

        var settings = Settings.default
        settings.repoColors = ["sample-ios": 4]
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.repoColors, ["sample-ios": 4])
    }
}
