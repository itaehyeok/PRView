import XCTest
@testable import PRayerCore

/// 레포 체크 — 툴바 팝오버·설정 창·온보딩이 같은 뜻으로 쓴다.
///
/// 예전에는 팝오버 체크는 끄기, 설정 창 체크는 지우기였다. 그래서 팝오버에서 끈 레포가 설정 창에는
/// 켜진 것처럼 보였고, 설정 창에서 체크를 끄면 고쳐 둔 대상 브랜치가 사라졌다.
final class RepoWatchTests: XCTestCase {
    private let ios = RepoID(owner: "acme", name: "sample-ios")
    private let sdk = RepoID(owner: "acme", name: "sample-sdk")

    /// 끄면 지우지 않는다 — 다시 켜면 고쳐 둔 대상 브랜치·승인 수가 그대로다.
    func testTurningOffKeepsSettings() {
        var s = Settings.default
        s.repos = [RepoConfig(repo: ios, prTargetBranch: "release", approvalThreshold: 2, approvalThresholdFromAPI: true)]
        XCTAssertFalse(s.setRepo(ios, watched: false, defaultBranch: "main"))
        XCTAssertEqual(s.repos.count, 1)
        XCTAssertFalse(s.isWatching(ios))
        XCTAssertTrue(s.enabledRepos.isEmpty)

        XCTAssertFalse(s.setRepo(ios, watched: true, defaultBranch: "main"))
        XCTAssertTrue(s.isWatching(ios))
        XCTAssertEqual(s.repos[0].prTargetBranch, "release")
        XCTAssertEqual(s.repos[0].approvalThreshold, 2)
    }

    /// 처음 켜는 레포는 새로 만들고, 대상 브랜치는 레포 기본 브랜치를 따른다.
    func testTurningOnNewRepoUsesDefaultBranch() {
        var s = Settings.default
        XCTAssertTrue(s.setRepo(sdk, watched: true, defaultBranch: "master"))
        XCTAssertEqual(s.repos.map(\.repo), [sdk])
        XCTAssertEqual(s.repos[0].prTargetBranch, "master")
        XCTAssertTrue(s.isWatching(sdk))
    }

    /// 기본 브랜치를 그대로 레포 기준으로 둔다. 예전에는 특정 기본 브랜치를 다른 브랜치로 바꿔 두는 규칙을
    /// 박아 두었다. PR 하나하나는 그 PR 이 향하는 브랜치의 규칙으로 센다(아래 테스트).
    func testDefaultBranchIsUsedAsIs() {
        var s = Settings.default
        s.setRepo(ios, watched: true, defaultBranch: "staging")
        XCTAssertEqual(s.repos[0].prTargetBranch, "staging")

        // 기본 브랜치를 모르면 자리만 채워 둔다 — 첫 규칙 읽기에서 그 레포의 기본 브랜치 규칙으로 바뀐다.
        var unknown = Settings.default
        unknown.setRepo(ios, watched: true, defaultBranch: nil)
        XCTAssertEqual(unknown.repos[0].prTargetBranch, RepoConfig(repo: ios).prTargetBranch)
    }

    /// Approve 수는 PR 마다 그 PR 이 향하는 브랜치의 규칙으로 센다. 레포 하나에 수 하나를 쓰면 develop 3명·staging 2명인
    /// 레포에서 한쪽 PR 은 늘 틀리게 셌다. 규칙을 모르는 브랜치로 가는 PR 은 레포 기준 수를 쓴다.
    func testApprovalThresholdFollowsPRBaseBranch() {
        var s = Settings.default
        var config = RepoConfig(repo: ios, prTargetBranch: "develop", approvalThreshold: 3, approvalThresholdFromAPI: true)
        config.approvalGroups = [ApprovalGroup(count: 3, branches: ["develop"]),
                                 ApprovalGroup(count: 2, branches: ["staging", "hotfix/*"])]
        s.repos = [config]
        func pr(base: String) -> PullRequestInfo {
            var pr = Fixtures.pr()
            pr.repo = ios
            pr.baseRefName = base
            return pr
        }
        XCTAssertEqual(s.approvalThreshold(for: pr(base: "develop")), 3)
        XCTAssertEqual(s.approvalThreshold(for: pr(base: "staging")), 2)
        XCTAssertEqual(s.approvalThreshold(for: pr(base: "hotfix/1.2.1")), 2)   // 패턴 규칙도 맞춰 본다
        XCTAssertEqual(s.approvalThreshold(for: pr(base: "feature/x")), 3)       // 모르는 브랜치 → 레포 기준
        // 규칙을 못 읽은 레포(묶음 없음)는 직접 정한 수를 그대로 쓴다.
        s.repos[0].approvalGroups = []
        s.repos[0].approvalThreshold = 2
        s.repos[0].approvalThresholdFromAPI = false
        XCTAssertEqual(s.approvalThreshold(for: pr(base: "develop")), 2)
    }

    /// 레포 탭 끌어 옮기기 — 오른쪽으로 끌면 놓은 탭 뒤, 왼쪽으로 끌면 앞. 꺼 둔 레포(탭에 없음)는 제자리에 남는다.
    func testMoveRepoReordersTabs() {
        let a = RepoID(owner: "acme", name: "a")
        let b = RepoID(owner: "acme", name: "b")
        let c = RepoID(owner: "acme", name: "c")
        let off = RepoID(owner: "acme", name: "off")
        var s = Settings.default
        s.repos = [RepoConfig(repo: a), RepoConfig(repo: off, enabled: false), RepoConfig(repo: b), RepoConfig(repo: c)]

        s.moveRepo(a, to: c)
        XCTAssertEqual(s.enabledRepos.map(\.repo), [b, c, a])
        s.moveRepo(a, to: b)
        XCTAssertEqual(s.enabledRepos.map(\.repo), [a, b, c])
        XCTAssertEqual(s.repos.count, 4)
        XCTAssertFalse(s.isWatching(off))

        // 우클릭 "오른쪽으로" — 꺼 둔 레포를 건너뛰고 옆 탭과 자리를 바꾼다.
        s.moveRepo(b, by: 1)
        XCTAssertEqual(s.enabledRepos.map(\.repo), [a, c, b])
        // 맨 앞에서 왼쪽, 제자리 끌기는 아무 일도 아니다.
        s.moveRepo(a, by: -1)
        s.moveRepo(a, to: a)
        XCTAssertEqual(s.enabledRepos.map(\.repo), [a, c, b])
    }

    /// 목록에 없는 레포를 끄는 것은 아무 일도 아니다(빈 설정이 생기지 않는다).
    func testTurningOffUnknownRepoDoesNothing() {
        var s = Settings.default
        XCTAssertFalse(s.setRepo(ios, watched: false, defaultBranch: "main"))
        XCTAssertTrue(s.repos.isEmpty)
    }

    /// 아예 빼면 설정은 사라지지만 로컬 클론 경로는 남는다 — 다시 고르면 바로 전체 리뷰가 된다.
    func testRemovingKeepsClonePath() {
        var s = Settings.default
        s.repos = [RepoConfig(repo: ios), RepoConfig(repo: sdk)]
        s.deepReviewRepoPaths = [ios.full: "/Users/me/work/sample-ios"]
        s.removeRepo(ios)
        XCTAssertEqual(s.repos.map(\.repo), [sdk])
        XCTAssertFalse(s.isWatching(ios))
        XCTAssertEqual(s.deepReviewRepoPaths[ios.full], "/Users/me/work/sample-ios")
    }
}
