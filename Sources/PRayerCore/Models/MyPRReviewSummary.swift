import Foundation

/// 내 PR 한 줄 요약 — 누가 승인했고, 코멘트가 몇 개 달렸고, 누가 아직인가.
///
/// 내 PR 행은 짧게 두고(사용자 결정) 둘째 줄 하나에 이것만 담는다. 이름을 다 늘어놓지 않고
/// 승인한 사람만 이름으로, 나머지는 숫자로 말한다 — 승인은 보통 2~3명이지만 미응답은 열 명 가까이 된다.
public struct MyPRReviewSummary: Sendable, Hashable {
    public struct Approver: Sendable, Hashable {
        public var login: String
        /// 승인한 뒤에 커밋이 더 올라왔다. 승인 수에는 들어가지만 지금 코드를 본 것은 아니다.
        public var isStale: Bool

        public init(login: String, isStale: Bool) {
            self.login = login
            self.isStale = isStale
        }
    }

    /// 지금 코드에 한 승인 먼저, 그다음 지난 커밋에 한 승인. 같은 무리 안에서는 최근 순.
    public var approvers: [Approver]
    /// 마지막 의견이 변경 요청인 사람.
    public var changesRequestedBy: [String]
    /// 다른 사람이 남긴 코멘트 수 — 대화 코멘트 · 코드 코멘트 · 본문 있는 리뷰.
    public var commentCount: Int
    /// 아직 안 풀린 코드 코멘트 스레드(지난 코드에 달린 것은 뺀다). 내가 답할 것이다.
    public var unresolvedThreadCount: Int
    /// 리뷰를 요청받고 아직 아무것도 안 낸 사람(팀이면 팀 이름).
    public var pending: [String]

    public var isEmpty: Bool {
        approvers.isEmpty && changesRequestedBy.isEmpty && commentCount == 0
            && unresolvedThreadCount == 0 && pending.isEmpty
    }

    public init(approvers: [Approver], changesRequestedBy: [String], commentCount: Int,
                unresolvedThreadCount: Int, pending: [String]) {
        self.approvers = approvers
        self.changesRequestedBy = changesRequestedBy
        self.commentCount = commentCount
        self.unresolvedThreadCount = unresolvedThreadCount
        self.pending = pending
    }

    /// 이미 받아 둔 PR 데이터만으로 만든다. 추가 API 호출은 없다.
    ///
    /// 승인 여부는 `approvals`(GitHub 의 사람별 최신 의견)를 따른다 — 승인 수(`approvalCount`)와 같은 근거라
    /// "2/3" 과 이름 수가 어긋나지 않는다. PR 작성자 본인은 어디에도 넣지 않는다 — 자기 PR 스레드에 답하면
    /// GitHub 이 COMMENTED 리뷰로 남긴다.
    public init(pr: PullRequestInfo) {
        let author = pr.author.lowercased()
        func isOther(_ login: String) -> Bool { login.lowercased() != author }

        let events = pr.reviewEvents.filter { isOther($0.author) }
        func approvedAt(_ login: String) -> Date {
            events.filter { $0.author == login && $0.state == "APPROVED" }.map(\.submittedAt).max() ?? .distantPast
        }
        let approvers: [Approver] = pr.approvals
            .filter { isOther($0.login) }
            .map { Approver(login: $0.login, isStale: $0.commitOid.map { $0 != pr.headRefOid } ?? false) }
            .sorted { lhs, rhs in
                if lhs.isStale != rhs.isStale { return !lhs.isStale }
                return approvedAt(lhs.login) > approvedAt(rhs.login)
            }
        let approved = Set(approvers.map { $0.login.lowercased() })

        // 승인하지 않은 사람 중 마지막 의견(승인·변경 요청·철회)이 변경 요청인 사람.
        var lastOpinion: [String: PRReviewEvent] = [:]
        for event in events where event.state != "COMMENTED" {
            if let known = lastOpinion[event.author], known.submittedAt >= event.submittedAt { continue }
            lastOpinion[event.author] = event
        }
        let changesRequestedBy = lastOpinion.values
            .filter { $0.state == "CHANGES_REQUESTED" && !approved.contains($0.author.lowercased()) }
            .sorted { $0.submittedAt > $1.submittedAt }
            .map(\.author)

        var comments = pr.issueComments.filter { isOther($0.author) }.count
        for thread in pr.threads {
            comments += thread.comments.filter { isOther($0.author) }.count
        }
        // 코드 코멘트만 단 리뷰는 본문이 비어 있다 — 그 코멘트는 위 스레드에서 이미 셌다.
        // 승인에 붙은 "LGTM" 같은 말은 승인으로 이미 보이므로 세지 않는다.
        comments += events.filter {
            $0.state != "APPROVED" && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        // 요청이 남아 있어도 이미 승인·변경 요청한 사람은 그쪽이 말한다(다시 요청한 경우).
        var seen = approved.union(changesRequestedBy.map { $0.lowercased() })
        let pending = pr.pendingReviewers.filter { isOther($0) && seen.insert($0.lowercased()).inserted }

        self.init(approvers: approvers,
                  changesRequestedBy: changesRequestedBy,
                  commentCount: comments,
                  unresolvedThreadCount: pr.unresolvedThreadCount,
                  pending: pending)
    }
}
