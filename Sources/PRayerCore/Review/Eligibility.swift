import Foundation

public enum SkipReason: Sendable, Equatable {
    case notOpen
    case isDraft
    case ownPR
    case noReviewRequest
    case alreadyReviewedByMe
    case hiddenLabel(String)
    case conflicting
    case mergeableUnknown
    case approvalThresholdReached(Int)
    case tooLarge(lines: Int, cap: Int)
    case alreadyHasRecord

    public var label: String {
        switch self {
        case .notOpen: return "열린 PR 이 아님"
        case .isDraft: return "초안(draft) PR"
        case .ownPR: return "내가 만든 PR"
        case .noReviewRequest: return "내가 리뷰어로 등록되지 않음"
        case .alreadyReviewedByMe: return "내가 이미 리뷰함"
        case .hiddenLabel(let label): return "\(label) 라벨"
        case .conflicting: return "충돌 상태"
        case .mergeableUnknown: return "머지 가능 여부 계산 중"
        case .approvalThresholdReached(let count): return "Approve \(count)명으로 임계값 도달"
        case .tooLarge(let lines, let cap): return "변경 \(lines)줄 (자동 상한 \(cap)줄 초과)"
        case .alreadyHasRecord: return "이 커밋의 리뷰 결과가 이미 있음"
        }
    }
}

/// 리뷰를 굳이 돌릴 필요가 없는 PR 의 **사유**를 알려 준다.
///
/// 자동 사전 리뷰 기능을 걷어낸 뒤로는 판정 결과가 목록의 뱃지("큼")와 상세 화면의
/// 안내 문구로만 쓰인다. 수동 리뷰를 막지는 않는다.
///
/// 조건을 켜고 끄는 설정은 없앴다. 끈다고 사실이 달라지지 않고(초안은 초안이다),
/// 목록에서 감추는 일은 화면 위 필터가 이미 한다. 설정이 둘로 갈려 있으면 "초안을 껐는데
/// 왜 초안이 보이지" 처럼 서로 다른 뜻의 토글을 같은 말로 읽게 된다.
public enum ReviewSkip {
    public static func skipReason(pr: PullRequestInfo,
                                  settings: Settings,
                                  approvalThreshold: Int,
                                  changedLinesAfterExclusion: Int?,
                                  hasRecordForHead: Bool) -> SkipReason? {
        if !pr.isOpen { return .notOpen }
        if pr.viewerDidAuthor { return .ownPR }
        if pr.isDraft { return .isDraft }
        if !pr.viewerHasReviewRequest {
            // 리뷰를 제출하면 GitHub 가 리뷰 요청을 없앤다. 둘을 구분해 사유를 보여준다.
            return pr.viewerHasSubmittedReview ? .alreadyReviewedByMe : .noReviewRequest
        }
        if let hit = settings.hiddenLabel(in: pr.labels) {
            return .hiddenLabel(hit)
        }
        if pr.mergeable == .conflicting { return .conflicting }
        if pr.mergeable == .unknown { return .mergeableUnknown }
        if pr.approvalCount >= approvalThreshold {
            return .approvalThresholdReached(pr.approvalCount)
        }
        if hasRecordForHead { return .alreadyHasRecord }
        let lines = changedLinesAfterExclusion ?? pr.changedLines
        if lines > settings.autoSizeCapLines {
            return .tooLarge(lines: lines, cap: settings.autoSizeCapLines)
        }
        return nil
    }
}
