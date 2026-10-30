import Foundation

/// 알림에 띄우는 말. **제목 한 줄뿐이다** — 갈래 표시 + 무슨 일을 짧은 명사로(사용자 결정, 2026-10-30).
///
/// 예전에는 제목에 작성자 이름·건수를 붙이고 본문에 "#번호 PR 제목" 을 한 줄 더 실어서, 쌓이면 깔끔하지 않았다.
/// 어느 PR 인지는 알림을 눌러 앱에서 본다 — 누르면 그 PR 로 간다.
///
/// 제목 앞에는 갈래 표시(`Origin.mark`)를 붙여, 내가 부르지 않았는데 온 것과 내가 돌린 리뷰의 결과를
/// 읽지 않고도 가른다. ✨ 쪽은 "AI 리뷰" 라고 써서 사람이 한 리뷰와 헷갈리지 않게 한다.
public enum NotificationText {
    /// 알림 갈래. 시스템 알림은 글자색을 바꿀 수 없어서, 색과 모양이 둘 다 다른 이모지 하나를 제목 앞에 붙인다
    /// (사용자 결정, 2026-10-30). 색 동그라미(🔵🟠)는 모양이 같아 작게 보면 비슷해서 뺐다.
    public enum Origin: Sendable {
        /// 내가 요청하지 않았는데 온 것 — PR 변화(새 PR·코멘트·충돌 …).
        case incoming
        /// 내가 돌린 AI 리뷰의 결과 — 완료·실패·한도.
        case requested

        public var mark: String {
            switch self {
            case .incoming: return "📥"
            case .requested: return "✨"
            }
        }
    }

    static func titled(_ origin: Origin, _ title: String) -> String {
        "\(origin.mark) \(title)"
    }

    public static let reviewDone = titled(.requested, "AI 리뷰 완료")

    /// 원인은 싣지 않는다 — 앱의 문제 목록에서 본다.
    public static let reviewFailed = titled(.requested, "AI 리뷰 실패")

    /// Claude·Codex 어느 쪽이든 같은 말이다.
    public static let limitReached = titled(.requested, "사용 한도 도달")

    /// PR 변화 한 건. 새 PR 은 나에게 리뷰 요청이 왔든 아니든 같은 말이다 — "리뷰 요청" 이라고 하면
    /// ✨ 의 AI 리뷰와 헷갈린다.
    public static func prChange(_ change: PRChange) -> String {
        let title: String
        switch change {
        case .appeared: title = "새 PR"
        case .reviewRequested: title = "리뷰어 지정"
        case .reReviewRequested: title = "재리뷰 요청"
        case .commentsOnMyPR: title = "내 PR 새 코멘트"
        case .approvalsReached: title = "머지 가능"
        case .checksFailed: title = "CI 실패"
        case .conflictAppeared: title = "충돌"
        case .newCommitsOnReviewed: title = "리뷰한 PR 새 커밋"
        case .merged: title = "머지 완료"
        }
        return titled(.incoming, title)
    }

    /// 한 번에 여러 건이 바뀌면 하나로 묶는다. 무엇이 바뀌었는지는 앱에서 본다.
    public static func prChangeSummary(count: Int) -> String {
        titled(.incoming, "PR 소식 \(count)건")
    }
}
