import XCTest
@testable import PRayerCore

/// 목록 위 레포 탭이 쓰는 "일부 레포만 보기" 필터.
///
/// 라벨·사람 필터와 달리 모든 탭에 걸리고, 레포 이름의 대소문자를 가리지 않는다.
final class RepoFilterTests: XCTestCase {
    private let ios = RepoID(owner: "acme", name: "sample-ios")
    private let web = RepoID(owner: "acme", name: "sample-web")

    private func pr(_ number: Int, in repo: RepoID) -> PullRequestInfo {
        var pr = Fixtures.pr(number: number)
        pr.repo = repo
        return pr
    }

    private func hiding(_ pr: PullRequestInfo, hidden: [RepoID], scope: PRListScope = .open) -> Set<PRFilterKind> {
        PRVisibility.hidingFilters(pr: pr,
                                   state: PRFilterState(hiddenRepos: Set(hidden.map(PRFilterState.repoKey))),
                                   scope: scope,
                                   hasHiddenLabel: false)
    }

    func testHidesOnlyPRsOfHiddenRepos() {
        XCTAssertEqual(hiding(pr(1, in: web), hidden: [web]), [.repos])
        XCTAssertTrue(hiding(pr(2, in: ios), hidden: [web]).isEmpty)
    }

    /// 승인·전체 탭에서도 건다 — "이 레포만 보기" 는 탭과 상관없이 무엇을 보느냐를 좁히는 것이다.
    /// (라벨·사람 필터는 리뷰 대기에만 건다.)
    func testAppliesToEveryTab() {
        for scope in [PRListScope.open, .myApprovals(.day), .recentAll(.week)] {
            XCTAssertEqual(hiding(pr(1, in: web), hidden: [web], scope: scope), [.repos], "\(scope.kind)")
            XCTAssertEqual(PRFilterState(hiddenRepos: ["acme/sample-web"]).active(in: scope), [.repos])
        }
    }

    /// 설정에 직접 친 이름과 API 가 돌려준 이름은 대소문자가 다를 수 있다.
    func testMatchesRepoNamesCaseInsensitively() {
        let typed = RepoID(owner: "Acme", name: "Sample-Web")
        XCTAssertEqual(PRFilterState.repoKey(typed), PRFilterState.repoKey(web))
        XCTAssertEqual(hiding(pr(1, in: web), hidden: [typed]), [.repos])
    }

    func testNoHiddenRepoMeansNoActiveFilter() {
        XCTAssertTrue(PRFilterState().active(in: .open).isEmpty)
    }

    /// 레포 고르기 때문에 목록이 비면 빈 화면이 "이 필터를 끄면 +N건" 으로 정확히 말한다.
    func testEmptyDiagnosisCountsRepoFilterGain() {
        let prs = [pr(1, in: web), pr(2, in: web), pr(3, in: ios)]
        let state = PRFilterState(hiddenRepos: [PRFilterState.repoKey(web)])
        let diagnosis = EmptyListDiagnosis.make(prs: prs, state: state, scope: .open,
                                                hasHiddenLabel: { _ in false },
                                                approvedInWindow: { _ in true })
        XCTAssertEqual(diagnosis.hiddenCount, 2)
        XCTAssertEqual(diagnosis.gains.first { $0.kind == .repos }?.gain, 2)
        XCTAssertEqual(diagnosis.byRepo.map(\.name), ["sample-web"])
    }

    /// 레포에 걸리고 검색어에도 걸린 PR 은 어느 하나만 꺼서는 안 나온다 — 겹침으로 센다.
    func testOverlapWithSearchIsReported() {
        let prs = [pr(1, in: web)]
        let state = PRFilterState(search: "없는말", hiddenRepos: [PRFilterState.repoKey(web)])
        let diagnosis = EmptyListDiagnosis.make(prs: prs, state: state, scope: .open,
                                                hasHiddenLabel: { _ in false },
                                                approvedInWindow: { _ in true })
        XCTAssertTrue(diagnosis.gains.allSatisfy { $0.gain == 0 })
        XCTAssertTrue(diagnosis.hasOverlap)
    }
}
