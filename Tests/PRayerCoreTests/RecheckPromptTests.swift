import XCTest
@testable import PRayerCore

/// 프롬프트에 무엇이 실려 나가는가. 여기서 잘리면 모델은 잘린 줄도 모르고 확신한다.
final class RecheckPromptTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func comment(_ author: String, _ offset: Double) -> RecheckDelta.Comment {
        RecheckDelta.Comment(author: author, body: "\(author) 의 말", at: at.addingTimeInterval(offset))
    }

    private func commit(_ oid: String, _ offset: Double) -> PRCommit {
        PRCommit(oid: oid, abbreviatedOid: oid, messageHeadline: "커밋 \(oid)",
                 committedDate: at.addingTimeInterval(offset), author: "rio")
    }

    private func build(_ delta: RecheckDelta) -> String {
        let info = PullRequestInfo(repo: RepoID(owner: "o", name: "r"), number: 1, nodeID: "n",
                                   title: "제목", bodyText: "", author: "rio", isDraft: false,
                                   state: "OPEN", createdAt: at, updatedAt: at, headRefOid: "head",
                                   headRefName: "f", baseRefName: "b", additions: 1, deletions: 0,
                                   changedFiles: 1, mergeable: .mergeable, mergeStateStatus: nil,
                                   reviewDecision: nil, approvals: [], labels: [],
                                   viewerDidAuthor: false, viewerHasReviewRequest: true,
                                   viewerLatestReviewState: nil, viewerLatestReviewCommit: nil,
                                   checkState: nil, threads: [], commits: [], reviewEvents: [],
                                   issueComments: [], mergedAt: nil, mergedBy: nil, closedAt: nil)
        let record = Fixtures.record(pr: info, output: ReviewOutput(verdict: .comment, summaryKo: "요약",
                                                                    concerns: [], strengths: [],
                                                                    draftComments: []))
        return RecheckPromptBuilder.build(pr: info, record: record,
                                          target: .init(kindLabel: "우려사항", body: "지적"),
                                          delta: delta, reviewedDiff: nil, newDiff: nil)
    }

    /// 대화의 결론은 끝에 나온다. 앞에서 자르면 "말씀하신 대로 고쳤습니다" 가 빠지고,
    /// 모델은 남은 옛 코멘트만 보고 "그대로입니다" 를 확신 있게 내놓는다.
    func testNewestCommentsSurviveTruncation() {
        let many = (0..<15).map { comment("사람\($0)", Double($0) * 60) }
        let text = build(RecheckDelta(newCommits: [], newComments: many, commitBoundaryExact: true))
        XCTAssertTrue(text.contains("사람14"), "가장 최근 코멘트가 들어가야 한다")
        XCTAssertFalse(text.contains("사람0 "), "가장 오래된 것이 잘린다")
        XCTAssertTrue(text.contains("생략했습니다"), "잘렸다는 사실을 모델에게 알려야 한다")
    }

    func testNewestCommitsSurviveTruncation() {
        let many = (0..<25).map { commit("c\($0)", Double($0) * 60) }
        let text = build(RecheckDelta(newCommits: many, newComments: [], commitBoundaryExact: true))
        XCTAssertTrue(text.contains("커밋 c24"))
        XCTAssertFalse(text.contains("커밋 c0\n"))
    }

    func testNoTruncationNoticeWhenEverythingFits() {
        let few = (0..<3).map { comment("사람\($0)", Double($0) * 60) }
        let text = build(RecheckDelta(newCommits: [], newComments: few, commitBoundaryExact: true))
        XCTAssertFalse(text.contains("생략했습니다"))
    }

    /// 경계를 어림잡았으면 모델에게 말해 준다.
    func testApproximateBoundaryIsDisclosed() {
        let text = build(RecheckDelta(newCommits: [commit("c1", 60)], newComments: [],
                                      commitBoundaryExact: false))
        XCTAssertTrue(text.contains("어림잡은"))
    }

    func testEmptyBlocksSayNone() {
        let text = build(RecheckDelta(newCommits: [], newComments: [], commitBoundaryExact: true))
        XCTAssertTrue(text.contains("<new_commits>\n없음"))
        XCTAssertTrue(text.contains("<new_comments>\n없음"))
    }
}
