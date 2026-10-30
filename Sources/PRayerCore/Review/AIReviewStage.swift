import Foundation

/// 상세 탭 줄 "AI 리뷰" 칸 아래 한 줄 — **AI 리뷰가 어디까지 왔는가.**
///
/// 이름은 사용자와 정했다: 리뷰 전 → 대기 중 → 리뷰 중 → 리뷰 완료 → 게시함, 그 밖에 실패·오래됨.
///
/// 목록 배지(`PRBadge`)와 다른 축이다. 배지는 AI 리뷰와 내가 GitHub 에서 한 리뷰를 합친 "내 리뷰가 어디까지
/// 갔나" 이고, 이 칸은 AI 리뷰만 본다 — GitHub 에서 직접 Approve 했어도 AI 를 안 돌렸으면 여기는 리뷰 전이다.
/// 그래서 배지의 영어 이름(Not reviewed·Non-blocker)을 빌려 쓰지 않았다. 같은 말이 다른 뜻이 된다.
public enum AIReviewStage: Sendable, Hashable, CaseIterable {
    case notReviewed
    case queued
    case running
    /// 초안이 나왔고 아직 안 올렸다. 지적이 있든 없든 같은 이름이다 — 개수는 AI 리뷰 탭 안과
    /// 목록 배지(Blocker·Non-blocker·LGTM)가 말한다("지적 3건"·"지적 없음" 은 사용자가 고르지 않았다).
    case ready
    case posted
    /// 마지막으로 돌린 것이 실패했다.
    case failed
    /// 초안이든 게시한 리뷰든 지금 head 보다 앞 커밋 기준이다 — 그 뒤 새 커밋이 올라왔다.
    case stale

    public var label: String {
        switch self {
        case .notReviewed: return "리뷰 전"
        case .queued: return "대기 중"
        case .running: return "리뷰 중"
        case .ready: return "리뷰 완료"
        case .posted: return "게시함"
        case .failed: return "실패"
        // 목록 배지의 덧표시와 같은 말이다 — 한 화면에서 같은 상태를 두 이름으로 부르지 않는다.
        case .stale: return PRBadgeOverlay.stale.label
        }
    }

    /// 그 PR 의 마지막 잡이 어떻게 됐는가. 앱 타깃의 `JobState` 를 코어로 끌어오지 않으려고 필요한 것만 받는다.
    /// 끝났거나(done) 취소한 잡은 nil 로 넘긴다 — 그때는 남은 기록이 말한다.
    public enum LastJob: Sendable, Equatable {
        case queued
        case running
        /// 실패했다. 언제 넣은 잡인가 — 그보다 나중에 만든 기록이 있으면 실패는 지난 일이다.
        case failed(queuedAt: Date)
    }

    /// 도는 중이면 그것이 먼저, 그다음 실패, 그다음 남은 기록(새 커밋 → 게시 → 초안 순).
    /// 새 커밋이 게시보다 앞서는 것은 목록 배지와 같다 — 올린 뒤 커밋이 왔으면 다시 볼 일이 생긴 것이다.
    public static func resolve(lastJob: LastJob?, record: ReviewRecord?, headSha: String) -> AIReviewStage {
        switch lastJob {
        case .queued:
            return .queued
        case .running:
            return .running
        case .failed(let queuedAt):
            if record.map({ $0.createdAt < queuedAt }) ?? true { return .failed }
        case nil:
            break
        }
        guard let record else { return .notReviewed }
        if record.headSha != headSha { return .stale }
        return record.isPosted ? .posted : .ready
    }
}
