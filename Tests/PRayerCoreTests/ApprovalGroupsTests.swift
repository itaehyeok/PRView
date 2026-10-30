import XCTest
@testable import PRayerCore

/// 브랜치별 Approve 규칙 묶기. 설정의 "Approve N명 필요" 와 수 고르기 메뉴가 이 결과를 그대로 그린다.
///
/// 흔한 git-flow 보호 규칙을 본떴다 — 옛 보호 규칙만 쓰는 레포(develop·staging 3명, master·hotfix/* 1명)와
/// 새 규칙(ruleset)만 쓰는 레포(master 1명)가 있다.
final class ApprovalGroupsTests: XCTestCase {
    private let legacy = [
        ApprovalRule(branch: "staging", count: 3),
        ApprovalRule(branch: "develop", count: 3),
        ApprovalRule(branch: "team/**/*", count: 3),
        ApprovalRule(branch: "master", count: 1),
        ApprovalRule(branch: "hotfix/*", count: 1),
    ]

    func testGroupsByCountLargestFirstWithDefaultBranchLeading() {
        let groups = ApprovalGroups.group(legacy, defaultBranch: "develop")
        XCTAssertEqual(groups.map(\.count), [3, 1])
        // 기본 브랜치 → 이름이 정해진 브랜치 → 패턴 순.
        XCTAssertEqual(groups[0].branches, ["develop", "staging", "team/**/*"])
        XCTAssertEqual(groups[1].branches, ["master", "hotfix/*"])
    }

    /// 수가 하나뿐이면 묶음도 하나 — 설정에는 고를 것 없이 "Approve 1명 필요" 만 보인다.
    func testSingleCountMakesOneGroup() {
        let groups = ApprovalGroups.group([ApprovalRule(branch: "master", count: 1)], defaultBranch: "master")
        XCTAssertEqual(groups, [ApprovalGroup(count: 1, branches: ["master"])])
    }

    func testFindsGroupByExactNameThenPattern() {
        let groups = ApprovalGroups.group(legacy, defaultBranch: "develop")
        XCTAssertEqual(ApprovalGroups.group(containing: "staging", in: groups)?.count, 3)
        XCTAssertEqual(ApprovalGroups.group(containing: "hotfix/1.2.1", in: groups)?.count, 1)
        XCTAssertNil(ApprovalGroups.group(containing: "feature/login", in: groups))
    }

    /// 수를 고르면 대표 브랜치를 저장한다 — 다시 읽어도 그 브랜치가 든 묶음의 수가 나와 고른 값이 남는다.
    /// 패턴은 실제 브랜치 이름이 아니라서 이름이 정해진 것을 고른다.
    func testRepresentativePrefersNamedBranch() {
        let groups = ApprovalGroups.group(legacy, defaultBranch: "develop")
        XCTAssertEqual(ApprovalGroups.representative(of: groups[1]), "master")
        XCTAssertEqual(ApprovalGroups.representative(of: ApprovalGroup(count: 2, branches: ["release/*"])), "release/*")
        let chosen = ApprovalGroups.representative(of: groups[1])
        XCTAssertEqual(ApprovalGroups.group(containing: chosen, in: groups)?.count, 1)
    }

    /// 옛 규칙과 새 규칙이 같은 브랜치에 같이 걸리면 큰 쪽이 실제 조건이다(둘 다 지켜야 머지된다).
    func testMergeTakesStricterRuleForSameBranch() {
        let merged = ApprovalGroups.merge(legacy: legacy,
                                          rulesets: [ApprovalRule(branch: "master", count: 2),
                                                     ApprovalRule(branch: "hotfix/1.0", count: 0),
                                                     ApprovalRule(branch: "release", count: 2)])
        XCTAssertEqual(merged.first { $0.branch == "master" }?.count, 2)
        // 새 규칙의 이름이 옛 규칙의 패턴에 걸리면 그 패턴의 수와 견준다.
        XCTAssertEqual(merged.first { $0.branch == "hotfix/1.0" }?.count, 1)
        XCTAssertEqual(merged.first { $0.branch == "release" }?.count, 2)
    }

    /// 새 규칙만 쓰는 레포 — 옛 규칙 없이도 묶인다.
    func testRulesetOnlyRepo() {
        let merged = ApprovalGroups.merge(legacy: [], rulesets: [ApprovalRule(branch: "master", count: 1)])
        XCTAssertEqual(ApprovalGroups.group(merged, defaultBranch: "master").map(\.count), [1])
    }

    /// 옛 설정 파일(묶음 없음)도 읽힌다.
    func testRepoConfigDecodesWithoutGroups() throws {
        let json = #"{"repo":{"owner":"acme","name":"sample-ios"},"prTargetBranch":"develop","approvalThreshold":3}"#
        let config = try JSONDecoder().decode(RepoConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.approvalGroups, [])
        let groups = [ApprovalGroup(count: 3, branches: ["develop"])]
        var withGroups = config
        withGroups.approvalGroups = groups
        let round = try JSONDecoder().decode(RepoConfig.self, from: JSONEncoder().encode(withGroups))
        XCTAssertEqual(round.approvalGroups, groups)
    }
}
