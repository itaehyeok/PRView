import Foundation

/// **내 리뷰가 어디까지 갔는가.** PR 이 머지됐는지·닫혔는지는 이 축이 아니다 —
/// 그건 행의 태그(Merged/Closed/Draft/Conflict)가 말한다.
///
/// 한 칸에 두 축을 우겨넣으면 하나가 지워진다. "내가 승인했고 그 PR 은 머지됐다" 는
/// 동시에 참이라, 배지가 Merged 를 말하는 순간 내가 뭘 했는지가 사라진다.
///
/// 이름을 영어로 두는 기준: **GitHub 이 쓰는 말은 GitHub 말 그대로.**
/// Approved·Changes requested·Commented·Dismissed 는 매일 github.com 에서 보는 단어라 배울 것이 없다.
public enum PRBadge: String, Sendable, CaseIterable {
    /// 지금 AI 리뷰가 돌고 있다.
    case reviewing
    /// 초안이 나왔고 필수(머지를 막는) 지적이 있다(아직 안 올림).
    ///
    /// 예전에는 지적이 있으면 무엇이든 "Review ready" 하나였다. 그러면 승인해도 되는 PR 과 막아야 하는 PR 이
    /// 목록에서 똑같이 보였다 — LGTM 도 리뷰가 준비된 것이라 이름도 갈리지 않았다(사용자 피드백, 2026-10-26).
    case blocker
    /// 초안이 나왔고 지적은 있지만 필수는 없다 — 권장·참고뿐이라 승인해도 된다(아직 안 올림).
    case nonBlocker
    /// 초안이 나왔는데 지적이 0건이다(아직 안 올림).
    case lgtm
    /// 실제로 낸 리뷰 — GitHub 의 리뷰 상태 그대로.
    case approved
    case changesRequested
    case commented
    case dismissed
    /// 리뷰를 냈는데 다시 요청이 왔다.
    case reRequested
    /// 아직 아무것도 안 했다.
    case notReviewed

    public var label: String {
        switch self {
        case .reviewing: return "Reviewing"
        case .blocker: return "Blocker"
        case .nonBlocker: return "Non-blocker"
        case .lgtm: return "LGTM"
        case .approved: return "Approved"
        // "Changes" 만으로는 뜻이 안 와닿았다(사용자 피드백). GitHub 이 쓰는 말 그대로 둔다.
        case .changesRequested: return "Changes requested"
        // "Commented" 만으로는 누가 단 코멘트인지 안 보였다 — 이 칸은 내 리뷰 상태라 내가 단 것이다(사용자 결정).
        // 활동 줄의 "Commented" 는 앞에 사람 이름이 붙어 그대로 둔다(PRActivity).
        case .commented: return "You commented"
        case .dismissed: return "Dismissed"
        case .reRequested: return "Re-requested"
        case .notReviewed: return "Not reviewed"
        }
    }

    /// 안 올린 초안의 판정(Blocker·Non-blocker·LGTM)인가. 화면은 이 셋을 꽉 채운 칩으로 그리고, PR 제목 밑에는 두지 않는다 —
    /// 코드 코멘트를 센 결과라 AI 리뷰 탭 코드 코멘트 칸 머리 줄(`VerdictChip`)에 있다.
    public var isVerdict: Bool {
        switch self {
        case .blocker, .nonBlocker, .lgtm: return true
        default: return false
        }
    }

    public var symbolName: String {
        switch self {
        case .reviewing: return "hourglass"
        // 두 이름에 "blocker" 가 같이 들어가 훑어보면 비슷하다 — 아이콘과 색(빨강·주황)을 확실히 다르게 둔다.
        case .blocker: return "exclamationmark.octagon.fill"
        case .nonBlocker: return "text.bubble.fill"
        case .lgtm: return "checkmark.seal.fill"
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .commented: return "bubble.left.fill"
        case .dismissed: return "xmark.circle"
        case .reRequested: return "arrow.clockwise"
        case .notReviewed: return "sparkles"
        }
    }

    /// GitHub 리뷰 상태(APPROVED 등) → 배지. 모르는 값은 Commented 로 둔다 —
    /// "리뷰를 내긴 냈다" 는 사실은 맞으므로 아무것도 안 한 것처럼 보이면 안 된다.
    public static func forReviewState(_ state: String?) -> PRBadge? {
        switch state?.uppercased() {
        case nil: return nil
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "DISMISSED": return .dismissed
        default: return .commented
        }
    }

    /// 이 앱이 게시할 때 쓴 event(APPROVE/REQUEST_CHANGES/COMMENT) → 배지.
    public static func forPostedEvent(_ event: String) -> PRBadge {
        switch event.uppercased() {
        case "APPROVE": return .approved
        case "REQUEST_CHANGES": return .changesRequested
        default: return .commented
        }
    }
}

public enum PRBadgeOverlay: String, Sendable {
    case stale
    case tooBig
    case waiting

    public var label: String {
        switch self {
        case .stale: return "오래됨"
        case .tooBig: return "큼"
        case .waiting: return "대기"
        }
    }

    public var symbolName: String {
        switch self {
        case .stale: return "clock.arrow.circlepath"
        case .tooBig: return "arrow.up.left.and.arrow.down.right"
        case .waiting: return "pause.circle"
        }
    }
}

/// 승인한 PR 이 **왜 다시 떴는지**. 승인한 PR 은 리뷰 대기에서 빠지는데, 다시 요청이 오거나 새 커밋이 오면
/// 돌아온다. 그때 배지가 Approved 만 말하면 "승인했는데 왜 또 떴지?" 가 된다(사용자 피드백).
public enum PRBadgeFollowUp: Sendable, Equatable {
    /// 승인한 뒤 다시 리뷰 요청이 왔다.
    case reRequested
    /// 승인한 뒤 새 커밋이 올라왔다. 개수를 모르면(받아 둔 커밋 목록에 승인한 커밋이 없음) nil.
    case newCommits(Int?)

    /// 넓을 때 칩 글자.
    public var label: String {
        switch self {
        case .reRequested: return "Re-requested"
        case .newCommits(let count?): return count == 1 ? "+1 commit" : "+\(count) commits"
        case .newCommits(nil): return "New commits"
        }
    }

    /// 좁을 때 칩 글자 — 아이콘 옆에 숫자만. nil 이면 아이콘만.
    public var shortLabel: String? {
        switch self {
        case .reRequested: return nil
        case .newCommits(let count?): return "+\(count)"
        case .newCommits(nil): return nil
        }
    }

    public var symbolName: String {
        switch self {
        case .reRequested: return "arrow.clockwise"
        // 활동 목록의 "Pushed commits" 와 같은 아이콘.
        case .newCommits: return "arrow.up.circle"
        }
    }

    /// 마우스를 올렸을 때.
    public var detail: String {
        switch self {
        case .reRequested: return "지난번 Approved — 그 뒤 다시 리뷰 요청이 왔습니다"
        case .newCommits(let count?): return "지난번 Approved — 그 뒤 새 커밋 \(count)개"
        case .newCommits(nil): return "지난번 Approved — 그 뒤 새 커밋이 올라왔습니다"
        }
    }
}

public struct BadgeResult: Sendable, Equatable {
    public var badge: PRBadge
    public var overlays: [PRBadgeOverlay]
    /// 승인한 PR 이 다시 뜬 이유. 있으면 화면은 Approved 를 흐리게 그리고 이유 칩을 붙인다.
    public var followUp: PRBadgeFollowUp?
    /// 안 올린 초안의 지적 수(Blocker·Non-blocker 일 때만).
    public var findings: FindingCounts?

    public init(badge: PRBadge, overlays: [PRBadgeOverlay] = [], followUp: PRBadgeFollowUp? = nil,
                findings: FindingCounts? = nil) {
        self.badge = badge
        self.overlays = overlays
        self.followUp = followUp
        self.findings = findings
    }

    /// 배지 글자. Blocker 는 필수 개수, Non-blocker 는 권장·참고 개수를 붙인다("Blocker 2").
    /// Blocker 일 때 권장·참고 개수는 글자에 넣지 않고 `trailingNonBlockingCount` 로 따로 그린다.
    public var text: String {
        let count: Int?
        switch badge {
        case .blocker: count = findings?.required
        case .nonBlocker: count = findings?.nonBlocking
        default: count = nil
        }
        guard let count, count > 0 else { return badge.label }
        return "\(badge.label) \(count)"
    }

    /// Blocker 배지 뒤에 붙이는 권장·참고 개수. 필수만 있으면 nil — 빈 꼬리를 그리지 않는다.
    /// Blocker 글자에는 필수 개수만 있어서, 승인을 막지 않는 지적이 몇 개 더 있는지 목록에서 안 보였다(사용자 요청).
    public var trailingNonBlockingCount: Int? {
        guard badge == .blocker, let count = findings?.nonBlocking, count > 0 else { return nil }
        return count
    }

    /// 마우스를 올렸을 때. 지적 수가 있으면 중요도별로 다 적는다.
    public var help: String? {
        guard let findings else { return nil }
        return findings.summary
    }
}

/// 안 올린 초안의 지적 수 — 중요도(필수·권장·참고)별. AI 리뷰 탭의 지적 목록(`ReviewRecord.issues`)을 센다.
///
/// "문제 아님" 으로 정리한 항목은 뺀다. 내가 읽고 아니라고 판단한 필수 지적이 목록에 계속 Blocker 로 남으면
/// 할 일이 남은 것처럼 읽힌다. "안 올림" 은 빼지 않는다 — 본문용 우려사항은 처음부터 안 올림이 기본값이라
/// 그걸 빼면 아무것도 손대지 않은 초안의 개수부터 틀린다.
public struct FindingCounts: Sendable, Equatable {
    public var required: Int
    public var recommended: Int
    public var informational: Int

    public init(required: Int = 0, recommended: Int = 0, informational: Int = 0) {
        self.required = required
        self.recommended = recommended
        self.informational = informational
    }

    public init(record: ReviewRecord) {
        self.init()
        for issue in record.issues where !record.isCleared(issue.key) {
            switch issue.importance {
            case .required: required += 1
            case .recommended: recommended += 1
            case .informational: informational += 1
            }
        }
    }

    /// 승인을 막지 않는 지적 수.
    public var nonBlocking: Int { recommended + informational }

    /// "필수 2 · 권장 1 · 참고 3" — AI 리뷰 탭과 같은 이름을 쓴다.
    public var summary: String {
        ReviewImportance.allCases.map { importance in
            let count: Int
            switch importance {
            case .required: count = required
            case .recommended: count = recommended
            case .informational: count = informational
            }
            return "\(importance.label) \(count)"
        }
        .joined(separator: " · ")
    }
}

/// AI 리뷰 탭 코드 코멘트 칸 머리 줄의 판정 칩 — 목록 배지(Blocker·Non-blocker·LGTM)를 둘로 풀어 보인다.
///
/// 판정은 코드 코멘트를 센 결과인데 상세 제목 밑에 있어 그 관계가 안 보였다. 그래서 코드 코멘트 칸 머리 줄로 옮기고,
/// 목록에서 Blocker 뒤에 초록 꼬리로 붙던 권장·참고 개수를 "Non-blocker 3" 칩으로 따로 세웠다(사용자 결정 2026-10-30,
/// 시안 C·X). 0 인 쪽은 그리지 않고, 둘 다 없으면 목록 배지와 같은 말을 쓴다 — 지적 0건이면 LGTM,
/// 모두 "문제 아님" 으로 정리했으면 숫자 없는 Non-blocker(`BadgeResolver.resolve` 와 같은 갈래).
public enum VerdictChip: Sendable, Equatable {
    /// 필수 지적 수.
    case blocker(Int)
    /// 권장·참고 지적 수. 셀 것이 없으면(모두 정리) nil.
    case nonBlocker(Int?)
    case lgtm

    public static func chips(for record: ReviewRecord) -> [VerdictChip] {
        if record.output.isFullyOK { return [.lgtm] }
        let findings = FindingCounts(record: record)
        var chips: [VerdictChip] = []
        if findings.required > 0 { chips.append(.blocker(findings.required)) }
        if findings.nonBlocking > 0 { chips.append(.nonBlocker(findings.nonBlocking)) }
        return chips.isEmpty ? [.nonBlocker(nil)] : chips
    }

    /// 이름·아이콘·색을 목록 배지와 같이 쓰려고 배지로 옮긴다.
    public var badge: PRBadge {
        switch self {
        case .blocker: return .blocker
        case .nonBlocker: return .nonBlocker
        case .lgtm: return .lgtm
        }
    }

    /// "Blocker 2" · "Non-blocker 3" · "LGTM".
    public var text: String {
        switch self {
        case .blocker(let count), .nonBlocker(let count?): return "\(badge.label) \(count)"
        case .nonBlocker(nil), .lgtm: return badge.label
        }
    }
}

public enum BadgeResolver {
    /// 우선순위: 리뷰중 › (이 앱으로 올린 리뷰 / 안 올린 초안) › 웹에서 낸 리뷰 › 미리뷰.
    /// 낸 리뷰에는 그 뒤로 생긴 일(재요청·새 커밋)을 얹는다(`submitted`).
    ///
    /// 충돌(`mergeable == .conflicting`)은 여기서 판정하지 않는다. 그건 PR 의 상태이지
    /// 내 리뷰 상태가 아니라서, 행의 태그가 맡는다. 예전에는 이 배지가 충돌을 최우선으로
    /// 말했는데, 그러면 충돌난 PR 에서 **내 초안이 준비됐다는 사실이 통째로 가려졌다.**
    public static func resolve(pr: PullRequestInfo,
                               isRunning: Bool,
                               record: ReviewRecord?,
                               skipReason: SkipReason?) -> BadgeResult {
        var overlays: [PRBadgeOverlay] = []
        if let record, record.headSha != pr.headRefOid { overlays.append(.stale) }
        if case .tooLarge = skipReason { overlays.append(.tooBig) }
        if pr.mergeable == .unknown { overlays.append(.waiting) }

        if isRunning {
            return BadgeResult(badge: .reviewing, overlays: overlays)
        }
        if let record, !record.discarded {
            // 이 앱으로 올렸다면 무엇으로 올렸는지까지 안다 — GitHub 을 다시 읽을 필요가 없다.
            if let posted = record.posted {
                // 리뷰한 커밋은 GitHub 이 이 리뷰를 알면 GitHub 말을 따른다 — 그 뒤 웹에서 다시 승인했을 수 있다.
                // 모르면(게시 직후 옛 상태) 그쪽 커밋은 예전 리뷰의 것이라 이 기록의 커밋을 쓴다.
                let known = pr.knowsReview(postedAt: posted.postedAt)
                return submitted(.forPostedEvent(posted.event), pr: pr,
                                 reviewedCommit: known ? (pr.viewerLatestReviewCommit ?? record.headSha) : record.headSha,
                                 reRequested: pr.isReRequested(postedAt: posted.postedAt),
                                 overlays: overlays)
            }
            // 아직 안 올린 초안. 지적이 0건이면 LGTM, 필수 지적이 있으면 Blocker, 권장·참고뿐이면 Non-blocker.
            if record.output.isFullyOK {
                return BadgeResult(badge: .lgtm, overlays: overlays)
            }
            let findings = FindingCounts(record: record)
            return BadgeResult(badge: findings.required > 0 ? .blocker : .nonBlocker,
                               overlays: overlays, findings: findings)
        }
        // 이 앱을 거치지 않고 웹 등에서 낸 리뷰.
        if let badge = PRBadge.forReviewState(pr.viewerLatestReviewState) {
            return submitted(badge, pr: pr, reviewedCommit: pr.viewerLatestReviewCommit,
                             reRequested: pr.isReRequested(), overlays: overlays)
        }
        return BadgeResult(badge: .notReviewed, overlays: overlays)
    }

    /// 낸 리뷰(이 앱으로든 웹으로든) 위에 "그 뒤로 생긴 일" 을 얹는다.
    ///
    /// 승인했으면 Approved 는 그 자리에 두고(화면은 흐리게) 다시 뜬 이유를 덧붙인다 — 재요청은 사람이 직접 한
    /// 말이라 새 커밋보다 앞선다. 승인이 아닌 리뷰(코멘트·변경 요청)에는 새 커밋을 덧붙이지 않는다 — 아직 승인
    /// 전이라 고친 커밋을 다시 보는 것이 자연스러운 흐름이다(사용자 결정). 다만 다시 요청이 왔으면 Re-requested
    /// 하나로 알린다 — 예전에는 이 앱으로 올린 리뷰면 그 기록(Commented 등)이 재요청을 가렸다.
    ///
    /// 닫힌 PR 에는 얹지 않는다. 다시 뜰 리뷰 대기에 있지 않으니 "왜 다시 떴나" 가 뜻이 없다 — 머지된 PR 의
    /// Approved 옆에 +2 commits 가 붙으면 할 일이 있는 것처럼 읽힌다.
    private static func submitted(_ badge: PRBadge, pr: PullRequestInfo, reviewedCommit: String?,
                                  reRequested: Bool, overlays: [PRBadgeOverlay]) -> BadgeResult {
        guard pr.isOpen else {
            return BadgeResult(badge: badge, overlays: overlays)
        }
        guard badge == .approved else {
            if reRequested {
                return BadgeResult(badge: .reRequested, overlays: overlays)
            }
            return BadgeResult(badge: badge, overlays: overlays)
        }
        // 이유 칩이 새 커밋까지 말하므로 "오래됨" 겹침은 뺀다.
        let others = overlays.filter { $0 != .stale }
        if reRequested {
            return BadgeResult(badge: .approved, overlays: others, followUp: .reRequested)
        }
        if let reviewedCommit, reviewedCommit != pr.headRefOid {
            return BadgeResult(badge: .approved, overlays: others,
                               followUp: .newCommits(pr.commitCount(after: reviewedCommit)))
        }
        return BadgeResult(badge: .approved, overlays: overlays)
    }
}
