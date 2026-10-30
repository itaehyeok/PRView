import XCTest
@testable import PRayerCore

final class EmptyDiagnosisTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    private func pr(_ number: Int,
                    title: String = "제목",
                    isDraft: Bool = false,
                    approvals: Int = 0,
                    labels: [String] = [],
                    author: String = "alex",
                    open: Bool = true) -> PullRequestInfo {
        PullRequestInfo(repo: repo, number: number, nodeID: "n\(number)", title: title, bodyText: "",
                        author: author, isDraft: isDraft, state: open ? "OPEN" : "CLOSED",
                        createdAt: Date(), updatedAt: Date(), headRefOid: "abc", headRefName: "f",
                        baseRefName: "develop", additions: 1, deletions: 0, changedFiles: 1,
                        mergeable: .mergeable, mergeStateStatus: nil, reviewDecision: nil,
                        approvals: (0..<approvals).map { ApprovalInfo(login: "r\($0)", commitOid: nil) },
                        labels: labels, viewerDidAuthor: false,
                        viewerHasReviewRequest: true, viewerLatestReviewState: nil,
                        viewerLatestReviewCommit: nil, checkState: nil, threads: [])
    }

    /// 숨길 사람은 `noisy-bot` 하나로 고정한다.
    private func diagnose(_ prs: [PullRequestInfo],
                          _ state: PRFilterState,
                          scope: PRListScope = .open) -> EmptyListDiagnosis {
        EmptyListDiagnosis.make(prs: prs, state: state, scope: scope,
                                hasHiddenLabel: { $0.labels.contains("DO NOT REVIEW") },
                                approvedInWindow: { _ in true },
                                isIgnoredAuthor: { $0.author == "noisy-bot" })
    }

    func testCountsGainPerFilterSeparately() {
        let prs = [
            pr(1, labels: ["DO NOT REVIEW"]),      // DO NOT REVIEW 하나에 걸림
            pr(2, labels: ["DO NOT REVIEW"]),      // DO NOT REVIEW 하나에 걸림
            pr(3, author: "noisy-bot"),            // 특정 사람 하나에 걸림
        ]
        let state = PRFilterState(hideIgnoredAuthors: true, hideLabels: true,
                                  hasIgnoredAuthors: true)
        let d = diagnose(prs, state)
        XCTAssertEqual(d.hiddenCount, 3)
        XCTAssertEqual(d.allOffCount, 3)
        let gains = Dictionary(uniqueKeysWithValues: d.gains.map { ($0.kind, $0.gain) })
        XCTAssertEqual(gains[.hideLabels], 2)
        XCTAssertEqual(gains[.hideIgnoredAuthors], 1)
        XCTAssertFalse(d.hasOverlap)
    }

    func testOverlappingPRCountsForNeitherFilter() {
        // 두 필터에 동시에 걸린 PR 은 어느 하나를 꺼도 안 나온다. 그래서 어느 줄에도 세지 않는다.
        let prs = [pr(1, labels: ["DO NOT REVIEW"], author: "noisy-bot")]
        let state = PRFilterState(hideIgnoredAuthors: true, hideLabels: true,
                                  hasIgnoredAuthors: true)
        let d = diagnose(prs, state)
        XCTAssertEqual(d.hiddenCount, 1)
        XCTAssertTrue(d.gains.allSatisfy { $0.gain == 0 })
        XCTAssertTrue(d.hasOverlap, "합이 숨김 수와 달라 겹침을 알려야 한다")
        XCTAssertEqual(d.allOffCount, 1, "다 끄면 보인다")
    }

    func testSearchOnlyBlocker() {
        let prs = [pr(1, title: "로그인 수정"), pr(2, title: "설정 수정")]
        let state = PRFilterState(search: "PROJ-9999")
        let d = diagnose(prs, state)
        XCTAssertTrue(d.searchIsOnlyBlocker)
        XCTAssertEqual(d.searchGain, 2)
        XCTAssertEqual(d.allOffCount, 2)
    }

    func testSearchPlusFilterIsNotSearchOnly() {
        let prs = [pr(1, title: "로그인", labels: ["DO NOT REVIEW"])]
        let state = PRFilterState(hideLabels: true, search: "로그인")
        let d = diagnose(prs, state)
        // 검색은 통과하고 필터만 걸렸다 → 검색어만 원인이 아니다.
        XCTAssertFalse(d.searchIsOnlyBlocker)
        XCTAssertEqual(d.gains.first { $0.kind == .hideLabels }?.gain, 1)
    }

    func testApprovalScopeIgnoresFiltersAndReportsZeroWhenWindowExcludes() {
        // 승인 탭은 필터를 쓰지 않는다. 기간을 못 채우면 "필터를 풀면 보인다" 고 하면 안 된다.
        let prs = [pr(1, labels: ["DO NOT REVIEW"])]
        let d = EmptyListDiagnosis.make(prs: prs,
                                        state: PRFilterState(hideLabels: true),
                                        scope: .myApprovals(.day),
                                        hasHiddenLabel: { _ in false },
                                        approvedInWindow: { _ in false })
        XCTAssertEqual(d.allOffCount, 0, "탭 조건에서 이미 빠졌다")
        XCTAssertEqual(d.hiddenCount, 0)
    }

    func testDoNotReviewLabelCountsAsItsOwnFilter() {
        let prs = [pr(1, labels: ["DO NOT REVIEW"])]
        let d = diagnose(prs, PRFilterState(hideLabels: true))
        XCTAssertEqual(d.gains.first { $0.kind == .hideLabels }?.gain, 1)
    }

    func testByRepoBreakdown() {
        let other = RepoID(owner: "acme", name: "sample-sdk")
        var otherRepoPR = pr(9, labels: ["DO NOT REVIEW"])
        otherRepoPR.repo = other
        let d = diagnose([pr(1, labels: ["DO NOT REVIEW"]), otherRepoPR], PRFilterState(hideLabels: true))
        XCTAssertEqual(d.byRepo.map(\.name), ["sample-ios", "sample-sdk"])
        XCTAssertEqual(d.byRepo.map(\.count), [1, 1])
    }

    func testVisibilityMatchesDiagnosis() {
        // 목록 판정과 진단이 같은 규칙을 써야 안내가 어긋나지 않는다.
        let prs = [pr(1, labels: ["DO NOT REVIEW"]), pr(2)]
        let state = PRFilterState(hideLabels: true)
        let visible = prs.filter {
            PRVisibility.hidingFilters(pr: $0, state: state, scope: .open,
                                       hasHiddenLabel: $0.labels.contains("DO NOT REVIEW")).isEmpty
        }
        let d = diagnose(prs, state)
        XCTAssertEqual(visible.map(\.number), [2])
        XCTAssertEqual(d.hiddenCount, 1)
    }
}
