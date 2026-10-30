import XCTest
@testable import PRayerCore

final class MergeReadinessTests: XCTestCase {
    private func pr(author: Bool = true, state: String = "OPEN", draft: Bool = false,
                    approvals: [String] = ["a", "b", "c"], staleApprovals: [String] = [],
                    mergeable: MergeableState = .mergeable, status: String? = "CLEAN",
                    checkState: String? = "SUCCESS", checks: [PRCheck] = []) -> PullRequestInfo {
        let list = approvals.map { ApprovalInfo(login: $0, commitOid: "head") }
            + staleApprovals.map { ApprovalInfo(login: $0, commitOid: "before") }
        return PullRequestInfo(repo: RepoID(owner: "acme", name: "sample-ios"),
                               number: 1, nodeID: "n", title: "t", bodyText: "", author: "me",
                               isDraft: draft, state: state, updatedAt: Date(), headRefOid: "head",
                               headRefName: "feature/x", baseRefName: "develop",
                               additions: 1, deletions: 0, changedFiles: 1, mergeable: mergeable,
                               mergeStateStatus: status, reviewDecision: nil, approvals: list, labels: [],
                               viewerDidAuthor: author, viewerHasReviewRequest: false,
                               viewerLatestReviewState: nil, viewerLatestReviewCommit: nil,
                               checkState: checkState, checks: checks, threads: [])
    }

    func testHiddenForOthersAndClosed() {
        XCTAssertEqual(MergeReadiness.resolve(pr(author: false), threshold: 3), .hidden)
        XCTAssertEqual(MergeReadiness.resolve(pr(state: "CLOSED"), threshold: 3), .hidden)
    }

    func testMergedShowsEvenWithoutApprovals() {
        XCTAssertEqual(MergeReadiness.resolve(pr(state: "MERGED", approvals: []), threshold: 3), .merged)
    }

    /// 화면의 "Approve 2/3" 과 같은 수 — 지난 커밋 승인도 GitHub 이 남겨 둔 것이면 센다.
    func testCountsApprovalsLikeOverviewCard() {
        XCTAssertEqual(MergeReadiness.resolve(pr(approvals: ["a"]), threshold: 3), .blocked(.needsApprovals(2)))
        XCTAssertEqual(MergeReadiness.resolve(pr(approvals: ["a", "b"], staleApprovals: ["c"]), threshold: 3), .ready)
    }

    /// Approve 가 모자라면 다른 이유보다 그 수를 먼저 말한다.
    func testApprovalsComeFirst() {
        XCTAssertEqual(MergeReadiness.resolve(pr(draft: true, approvals: [], mergeable: .conflicting), threshold: 2),
                       .blocked(.needsApprovals(2)))
        XCTAssertEqual(MergeReadiness.resolve(pr(draft: true, mergeable: .conflicting), threshold: 3), .blocked(.draft))
    }

    func testConflictAndBehind() {
        XCTAssertEqual(MergeReadiness.resolve(pr(mergeable: .conflicting, status: "DIRTY"), threshold: 3), .blocked(.conflict))
        XCTAssertEqual(MergeReadiness.resolve(pr(status: "BEHIND"), threshold: 3), .blocked(.behind))
    }

    func testBlockedNamesChecksWhenItCan() {
        let failing = [PRCheck(name: "build", outcome: "FAILURE")]
        XCTAssertEqual(MergeReadiness.resolve(pr(status: "BLOCKED", checkState: "FAILURE", checks: failing), threshold: 3),
                       .blocked(.checksFailing))
        XCTAssertEqual(MergeReadiness.resolve(pr(status: "BLOCKED", checkState: "PENDING"), threshold: 3), .blocked(.checksPending))
        XCTAssertEqual(MergeReadiness.resolve(pr(status: "BLOCKED"), threshold: 3), .blocked(.blockedByGitHub))
    }

    /// 필수가 아닌 체크 실패(UNSTABLE)·GitHub 이 아직 계산 중(UNKNOWN)이면 누를 수 있다. 막혀 있으면 머지 호출이 이유를 돌려준다.
    func testUnstableAndUnknownStayReady() {
        XCTAssertEqual(MergeReadiness.resolve(pr(status: "UNSTABLE", checkState: "FAILURE"), threshold: 3), .ready)
        XCTAssertEqual(MergeReadiness.resolve(pr(mergeable: .unknown, status: "UNKNOWN"), threshold: 3), .ready)
        XCTAssertEqual(MergeReadiness.resolve(pr(status: nil), threshold: 3), .ready)
    }

    func testOptionsPreferAllowedMethod() {
        XCTAssertEqual(MergeOptions(allowed: [.squash, .rebase], preferred: .merge).preferred, .squash)
        XCTAssertEqual(MergeOptions(allowed: [.merge, .squash], preferred: .squash).preferred, .squash)
        XCTAssertEqual(MergeOptions(allowed: [], preferred: nil).allowed, MergeMethod.allCases)
    }

    func testHeadChangedIsRecognized() {
        XCTAssertEqual(MergeError(githubMessage: "Head branch was modified. Review and try the merge again."), .headChanged)
        XCTAssertEqual(MergeError(githubMessage: "Pull Request is not mergeable"), .rejected("Pull Request is not mergeable"))
    }
}
