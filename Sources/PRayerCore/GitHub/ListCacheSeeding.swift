import Foundation

/// 한 탭에서 받은 PR 로 다른 탭의 지난 목록을 미리 고쳐 둔다 — 그 탭으로 옮겨 가면 받기 전에도 이미 아는 PR 이
/// 보이게(사용자 요청 2026-10-28). 어느 탭을 먼저 받든 같다: 리뷰 대기에서 Approve 한 PR 은 Approved 에, 리뷰
/// 대기·Approved 에서 본 PR 은 All PRs 에, All PRs·Approved 에서 본 열린 PR 은 리뷰 대기에 먼저 떠 있다. 그 탭을
/// 다시 받으면 받은 것으로 바뀐다(`AppModel.applyFetched`).
public enum ListCacheSeeding {
    /// `fetched` 를 그 탭의 지난 목록 `cached` 에 반영한다. 바뀐 것이 없으면 nil.
    ///
    /// - 같은 PR 이 이미 있으면 받은 것으로 갈아 끼운다. 받은 것이 더 오래됐으면(다른 탭이 더 늦게 받아 둔 것) 둔다.
    /// - 없으면 그 탭의 검색에 걸릴 PR 일 때만 더한다(`belongs`).
    public static func merge(_ fetched: [PullRequestInfo], into cached: [PullRequestInfo], scope: PRListScope,
                             viewerLogin: String?, now: Date) -> [PullRequestInfo]? {
        var byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for pr in fetched {
            if let old = byID[pr.id] {
                guard pr.updatedAt >= old.updatedAt, pr != old else { continue }
            } else {
                guard belongs(pr, to: scope, viewerLogin: viewerLogin, now: now) else { continue }
            }
            byID[pr.id] = pr
            changed = true
        }
        guard changed else { return nil }
        return sortedForList(byID.values)
    }

    /// 기간을 넓힐 때(`PRListScope.widens(from:)`) 넓힌 탭에 먼저 보일 목록 — 그 탭의 지난 목록에 좁은 탭에서 보던
    /// 목록을 **전부** 얹는다. 좁은 탭 결과는 넓힌 탭 결과에 다 들어서, 비우고 다시 받으면 보던 행이 사라졌다가 그대로
    /// 돌아올 뿐이다(사용자 피드백 2026-11-05). 받으면 여기 없던 것만 새 행으로 펼쳐진다(`AppModel.applyFetched`).
    ///
    /// `merge` 와 달리 `belongs` 로 거르지 않는다 — Approved 에는 오래전에 Approve 했어도 그 뒤에 일이 생겨 보이는 PR
    /// 이 있는데(`AppModel.approvedInWindow`), Approve 한 시각으로 거르면 그것만 빠졌다 받은 뒤 다시 들어온다.
    /// 같은 PR 은 더 새로 받은 쪽을 남긴다.
    public static func widened(_ shown: [PullRequestInfo], into cached: [PullRequestInfo]) -> [PullRequestInfo] {
        var byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for pr in shown where byID[pr.id].map({ pr.updatedAt >= $0.updatedAt }) ?? true {
            byID[pr.id] = pr
        }
        return sortedForList(byID.values)
    }

    /// 목록은 늘 올린 시각순이다(AppModel.performRefresh). 같은 시각이면 키로 순서를 고정한다.
    private static func sortedForList(_ prs: some Sequence<PullRequestInfo>) -> [PullRequestInfo] {
        prs.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// 그 탭의 검색(`GitHubClient.pullRequestSlice`)에 걸릴 PR 인가.
    static func belongs(_ pr: PullRequestInfo, to scope: PRListScope, viewerLogin: String?, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(scope.windowHours ?? 0) * 3600)
        switch scope.kind {
        case .open:
            // 기간 없이 열린 PR 전부를 받는다(`is:open`). 다른 탭에서 본 열린 PR 은 반드시 그 안에 든다 — 화면에
            // 보일지(Approve 한 것·초안은 빠진다)는 그 탭의 거르기(PRVisibility.scopeIncludes)가 정한다. 다른 탭에서
            // 본 것만으로는 빠진 것이 없는지 모르지만, 그 탭을 받으면 나머지가 들어온다.
            return pr.isOpen
        case .recentAll:
            // 서버 조건 `updated:>=` 와 같다 — 그 기간에 활동이 있었던 PR.
            return pr.updatedAt >= cutoff
        case .myApprovals:
            // 서버는 `reviewed-by:` 로 넓게 받고 화면이 Approve 한 시각으로 거른다(AppModel.approvedInWindow). 같은 잣대.
            guard let login = viewerLogin, let at = pr.viewerApprovedAt(login: login) else { return false }
            return at >= cutoff
        }
    }

    /// 리뷰 대기 탭을 받았더니 없어진 PR(열린 PR 만 받으니 머지·닫힘이다). 칩이 All PRs 로 날아갔는데 그 탭에 없으면
    /// 어긋나서 그 탭에도 넣는다. 언제 닫혔는지는 모르지만 지난번 받은 때(`since`) 뒤인 것은 알아서, 그 시각을 활동
    /// 시각으로 삼아 기간 조건을 가린다 — 며칠 묵은 지난 목록에서 빠진 것은 24h 탭에 들지 않는다. 머지인지 닫힘인지는
    /// 몰라 상태는 그대로 둔다(그 탭을 받으면 바뀐다).
    public static func departed(_ prs: [PullRequestInfo], since: Date) -> [PullRequestInfo] {
        prs.map { pr in
            var pr = pr
            pr.updatedAt = max(pr.updatedAt, since)
            return pr
        }
    }

    /// 이 앱에서 방금 Approve 한 PR 을 GitHub 이 알려 주기 전에 그 모습으로 만든다 — Approved 탭의 지난 목록에
    /// 먼저 넣으려고. 그 탭을 받으면 GitHub 이 준 것으로 바뀐다.
    public static func approved(_ pr: PullRequestInfo, by login: String, at date: Date) -> PullRequestInfo {
        var pr = pr
        pr.viewerLatestReviewState = "APPROVED"
        pr.viewerLatestReviewCommit = pr.headRefOid
        pr.viewerLatestReviewAt = date
        pr.viewerOpinion = ViewerOpinion(state: "APPROVED", commitOid: pr.headRefOid)
        pr.viewerHasReviewRequest = false
        pr.reviewEvents.append(PRReviewEvent(author: login, state: "APPROVED", submittedAt: date, body: ""))
        if !pr.approvals.contains(where: { $0.login == login }) {
            pr.approvals.append(ApprovalInfo(login: login, commitOid: pr.headRefOid))
        }
        // 방금 활동이 있었다 — All PRs 의 기간 조건에도 맞고, 늦게 받은 옛 정보가 이것을 덮지 않는다.
        pr.updatedAt = max(pr.updatedAt, date)
        return pr
    }
}

extension PullRequestInfo {
    /// 그 사람이 이 PR 을 Approve 한 시각(여러 번이면 가장 최근).
    public func viewerApprovedAt(login: String) -> Date? {
        reviewEvents
            .filter { $0.author == login && $0.state.uppercased() == "APPROVED" }
            .map(\.submittedAt)
            .max()
    }
}
