import Foundation

/// 게시 버튼이 실제로 하는 일 한 가지.
///
/// 예전에는 "이벤트(코멘트/승인/변경요청)" 를 따로 고르고 "게시" 를 눌렀는데, 그러면 무엇이
/// 나가는지가 두 곳에 나뉘어 있어 본문이 빠진 채로 올라가는 사고가 났다. 그래서 **이벤트와
/// 내용물을 한 덩어리로 묶어** 버튼 이름이 곧 하는 일이 되게 했다.
public enum PostAction: String, Sendable, Codable, CaseIterable, Identifiable {
    /// 본문·인라인 코멘트를 올리되 승인 수에는 영향을 주지 않는다.
    case commentOnly
    /// 본문·인라인 코멘트를 올리면서 승인도 한다.
    case commentAndApprove
    /// 본문도 인라인도 없이 승인 1표만 남긴다.
    case approveOnly
    /// 머지를 막는다. blocker 가 있을 때만 고를 수 있게 둔다.
    case requestChanges

    public var id: String { rawValue }

    public var event: ReviewEvent {
        switch self {
        case .commentOnly: return .comment
        case .commentAndApprove, .approveOnly: return .approve
        case .requestChanges: return .requestChanges
        }
    }

    /// 본문과 인라인 코멘트를 함께 보내는가. 승인만 게시는 둘 다 보내지 않는다.
    public var includesContent: Bool { self != .approveOnly }

    /// 버튼 몸통에 쓰는 이름. **줄임말을 쓰지 않는다** — 확인 창 없이 바로 올라가므로
    /// 이 문구가 마지막 방어선이다.
    public var label: String {
        switch self {
        case .commentOnly: return "코멘트만 게시"
        case .commentAndApprove: return "코멘트+Approve 게시"
        case .approveOnly: return "Approve 만 게시"
        case .requestChanges: return "변경 요청 게시"
        }
    }

    /// 드롭다운 목록에 쓰는 짧은 이름.
    public var menuLabel: String {
        switch self {
        case .commentOnly: return "코멘트만"
        case .commentAndApprove: return "코멘트+Approve"
        case .approveOnly: return "Approve 만"
        case .requestChanges: return "변경 요청"
        }
    }

    public var explanation: String {
        switch self {
        case .commentOnly: return "의견만 남깁니다. Approve 수에 영향이 없습니다."
        case .commentAndApprove: return "본문·인라인 코멘트와 함께 Approve 1표를 남깁니다."
        case .approveOnly: return "본문도 인라인도 보내지 않고 Approve 1표만 남깁니다."
        case .requestChanges: return "머지를 막습니다. 작성자가 다시 요청해야 Approve 절차가 진행됩니다."
        }
    }
}

/// 지금 이 PR·이 초안에서 무엇을 고를 수 있는지 판단하는 데 필요한 사실들.
public struct PostActionContext: Sendable, Equatable {
    /// 체크된 본문 조각이 하나라도 있는가.
    public var hasBody: Bool
    /// 실제로 올라갈 인라인 코멘트 수.
    public var inlineCount: Int
    /// blocker 심각도 항목이 있는가(초안이든 우려사항이든).
    public var hasBlocker: Bool
    /// 모델의 판정.
    public var verdict: Verdict
    /// 내가 올린 PR 인가. GitHub 이 자기 PR 승인을 거부한다.
    public var viewerDidAuthor: Bool
    /// 지금 커밋을 내가 이미 승인했는가.
    public var alreadyApprovedThisHead: Bool
    /// 이미 승인했지만 그 뒤로 새 커밋이 올라왔는가(다시 승인할 이유가 된다).
    public var approvedOlderCommit: Bool

    public init(hasBody: Bool, inlineCount: Int, hasBlocker: Bool, verdict: Verdict,
                viewerDidAuthor: Bool, alreadyApprovedThisHead: Bool, approvedOlderCommit: Bool = false) {
        self.hasBody = hasBody
        self.inlineCount = inlineCount
        self.hasBlocker = hasBlocker
        self.verdict = verdict
        self.viewerDidAuthor = viewerDidAuthor
        self.alreadyApprovedThisHead = alreadyApprovedThisHead
        self.approvedOlderCommit = approvedOlderCommit
    }

    /// 보낼 내용이 아무것도 없다. 빈 COMMENT 리뷰는 GitHub 이 거부한다.
    public var hasNothingToSend: Bool { !hasBody && inlineCount == 0 }
}

public enum PostActionPlan {
    /// 지금 이 PR·이 초안의 사실들. 게시 버튼과 "전송 내용 자세히" 창이 같이 쓴다 —
    /// 둘이 따로 셈하면 버튼과 창이 서로 다른 기본값을 내민다.
    public static func context(record: ReviewRecord, pr: PullRequestInfo) -> PostActionContext {
        let body = PostBuilder.composedBody(record: record)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blocker = record.output.concerns.contains { $0.severity == .blocker }
            || record.output.draftComments.contains { $0.severity == .blocker }
        return PostActionContext(hasBody: !body.isEmpty,
                                 inlineCount: record.comments.filter(\.isPostable).count,
                                 hasBlocker: blocker,
                                 verdict: record.output.verdict,
                                 viewerDidAuthor: pr.viewerDidAuthor,
                                 alreadyApprovedThisHead: pr.viewerApprovedCurrentHead,
                                 approvedOlderCommit: pr.viewerApproved && !pr.viewerApprovedCurrentHead)
    }

    /// 지금 고른 게시 방식. 이 PR 에서 골라 둔 것(`ReviewRecord.plannedAction`)이 있으면 그것, 그게 더 이상
    /// 고를 수 없는 것이면 권장값으로 되돌린다(예: 골라 둔 "코멘트+Approve" 뒤에 그 커밋을 이미 Approve 한 경우).
    public static func current(saved raw: String?, in context: PostActionContext) -> PostAction {
        if let raw, let saved = PostAction(rawValue: raw),
           menu(for: context).contains(saved),
           disabledReason(saved, in: context) == nil {
            return saved
        }
        return recommended(for: context)
    }

    /// 드롭다운에 보여 줄 목록.
    ///
    /// 변경 요청은 **필요할 때만** 낸다. 늘 보이면 실수로 머지를 막기 쉽고, 아예 없애면
    /// 정작 blocker 를 찾았을 때 앱 안에서 막을 방법이 없어진다.
    public static func menu(for context: PostActionContext) -> [PostAction] {
        var actions: [PostAction] = [.commentAndApprove, .commentOnly, .approveOnly]
        if context.hasBlocker || context.verdict == .requestChanges {
            actions.append(.requestChanges)
        }
        return actions
    }

    /// 기본으로 잡아 둘 동작. 승인이 기본이되, 승인할 수 없는 상황이면 코멘트로 내린다.
    public static func recommended(for context: PostActionContext) -> PostAction {
        if context.hasBlocker || context.verdict == .requestChanges {
            // blocker 를 두고 승인을 기본값으로 내밀지 않는다. 고르는 것은 사람이 한다.
            return .commentOnly
        }
        if context.viewerDidAuthor || context.alreadyApprovedThisHead {
            return .commentOnly
        }
        if context.hasNothingToSend { return .approveOnly }
        return .commentAndApprove
    }

    /// 게시 버튼 몸통 이름. 줄 코멘트가 함께 나가면 그 수까지 적는다 — 확인 창이 없어 이 이름이 마지막 방어선이다.
    public static func buttonLabel(_ action: PostAction, in context: PostActionContext) -> String {
        guard action.includesContent, context.inlineCount > 0 else { return action.label }
        return "\(action.label) · 줄 코멘트 \(context.inlineCount)개"
    }

    /// 고를 수 없는 이유. nil 이면 고를 수 있다.
    public static func disabledReason(_ action: PostAction, in context: PostActionContext) -> String? {
        if action.event == .approve {
            if context.viewerDidAuthor { return "내가 올린 PR 은 GitHub 이 Approve 를 거부합니다." }
            if context.alreadyApprovedThisHead { return "이 커밋은 이미 내가 Approve 했습니다." }
        }
        // 내 PR 에 내가 변경 요청을 다는 건 말이 안 되고 GitHub 도 422 로 거부한다. 막는 이슈가 있으면 메뉴에 나타나므로
        // Approve 처럼 꺼 두고 사유를 보인다(2026-10-29 사용자 결정 — 메뉴에서 빼지 않고 끈다).
        if action.event == .requestChanges, context.viewerDidAuthor {
            return "내가 올린 PR 은 GitHub 이 변경 요청을 거부합니다."
        }
        if action.includesContent, context.hasNothingToSend {
            return "보낼 본문도 인라인 코멘트도 없습니다."
        }
        // 담아 둔 줄 코멘트가 말없이 빠진 채 Approve 만 나가면 안 된다. 빼려면 담은 목록에서 뺀다.
        if !action.includesContent, context.inlineCount > 0 {
            return "리뷰에 담은 줄 코멘트 \(context.inlineCount)개가 빠집니다. 함께 올리려면 코멘트+Approve 를 고르세요."
        }
        return nil
    }

    /// 버튼 아래에 적을 "실제로 나가는 것". 무엇이 빠졌는지도 말해 준다.
    public static func summary(_ action: PostAction, in context: PostActionContext) -> String {
        var parts: [String] = []
        if action.includesContent {
            parts.append(context.hasBody ? "본문 포함" : "본문 없음")
            parts.append(context.inlineCount > 0 ? "인라인 \(context.inlineCount)건" : "인라인 없음")
        } else {
            parts.append("본문·인라인 없음")
        }
        switch action.event {
        case .approve: parts.append("Approve 1표")
        case .comment: parts.append("Approve 수 영향 없음")
        case .requestChanges: parts.append("머지 차단")
        }
        if context.approvedOlderCommit, action.event == .approve {
            parts.append("새 커밋에 대해 다시 Approve")
        }
        return parts.joined(separator: " · ")
    }
}
