import Foundation
@testable import PRayerCore

enum Fixtures {
    static let repo = RepoID(owner: "acme", name: "sample-ios")

    static func pr(number: Int = 42,
                   isDraft: Bool = false,
                   state: String = "OPEN",
                   mergeable: MergeableState = .mergeable,
                   approvals: [String] = [],
                   labels: [String] = [],
                   viewerDidAuthor: Bool = false,
                   viewerHasReviewRequest: Bool = true,
                   viewerLatestReviewState: String? = nil,
                   additions: Int = 40,
                   deletions: Int = 10,
                   headRefOid: String = "aaaaaaaaaaaa1111") -> PullRequestInfo {
        PullRequestInfo(repo: repo,
                        number: number,
                        nodeID: "PR_\(number)",
                        title: "[PROJ-1234][IOS] 목록 새로고침 후 스크롤 위치 복원",
                        bodyText: "리뷰 포인트: 오류 처리",
                        author: viewerDidAuthor ? "alex-kim" : "riley-park-acme",
                        isDraft: isDraft,
                        state: state,
                        createdAt: Date(timeIntervalSince1970: 1_779_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                        headRefOid: headRefOid,
                        headRefName: "feature/PROJ-1234",
                        baseRefName: "develop",
                        additions: additions,
                        deletions: deletions,
                        changedFiles: 3,
                        mergeable: mergeable,
                        mergeStateStatus: nil,
                        reviewDecision: nil,
                        approvals: approvals.map { ApprovalInfo(login: $0, commitOid: headRefOid) },
                        labels: labels,
                        viewerDidAuthor: viewerDidAuthor,
                        viewerHasReviewRequest: viewerHasReviewRequest,
                        viewerLatestReviewState: viewerLatestReviewState,
                        viewerLatestReviewCommit: nil,
                        checkState: "SUCCESS",
                        threads: [],
                        commits: [])
    }

    static func output(verdict: Verdict = .comment,
                       comments: [DraftComment] = [],
                       concerns: [Concern] = []) -> ReviewOutput {
        ReviewOutput(verdict: verdict,
                     summaryKo: "요약입니다.",
                     concerns: concerns,
                     strengths: ["구조 분리가 합리적입니다."],
                     draftComments: comments)
    }

    static func comment(key: String = "k1", line: Int = 11, path: String = "Sources/Foo.swift") -> DraftComment {
        DraftComment(issueKey: key, path: path, line: line, side: .right,
                     body: "여기서 실패를 흘리면 상태가 어긋납니다. 실패 처리를 추가해주시면 어떨까요?",
                     severity: .major, anchorText: "        print(x)")
    }

    static func record(pr: PullRequestInfo,
                       output: ReviewOutput,
                       posted: PostedInfo? = nil,
                       headSha: String? = nil) -> ReviewRecord {
        ReviewRecord(repo: pr.repo,
                     number: pr.number,
                     headSha: headSha ?? pr.headRefOid,
                     baseRefName: pr.baseRefName,
                     promptVersion: "abc123",
                     model: "claude-sonnet-5",
                     trigger: .manual,
                     output: output,
                     comments: output.draftComments.map { DraftCommentState(comment: $0) },
                     bodyDraft: "총평",
                     usage: EngineUsage(model: "claude-sonnet-5", inputTokens: 10, cacheCreationTokens: 3000,
                                        outputTokens: 5000, costUSD: 0.07, durationMs: 60_000),
                     posted: posted)
    }
}
