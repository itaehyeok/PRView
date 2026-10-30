import Foundation

/// 리뷰 1건이 지나가는 단계. 전체 리뷰는 2~3분 걸려서, 진행이 안 보이면 멈춘 것처럼 느껴진다.
public enum ReviewPhase: String, Codable, Sendable, CaseIterable {
    case queued
    case checkingPR
    case loadingDiff
    /// PR 스냅샷을 처음 받는 중(ReviewClone). 레포마다 한 번.
    case cloningSnapshot
    case fetchingCommit
    /// 리뷰할 커밋의 파일 중 PR 스냅샷에 아직 없는 것을 받는 중.
    case fetchingFiles
    case preparingWorktree
    case running
    case validating
    case releasingWorktree
    case finished
    case failed

    public var label: String {
        switch self {
        case .queued: return "대기 중"
        case .checkingPR: return "PR 상태 확인 중"
        case .loadingDiff: return "diff 받는 중"
        case .cloningSnapshot: return "PR 스냅샷 클론 중"
        case .fetchingCommit: return "PR 커밋 받는 중"
        case .fetchingFiles: return "PR 시점 코드 받는 중"
        case .preparingWorktree: return "리뷰용 워크트리 준비 중"
        case .running: return "읽고 판단하는 중"
        case .validating: return "초안 검증 중"
        case .releasingWorktree: return "워크트리 반납 중"
        case .finished: return "완료"
        case .failed: return "실패"
        }
    }

    /// 진행 카드 단계 목록에 쓰는 이름. 읽고 판단하는 단계에는 돌고 있는 엔진 이름을 붙인다.
    public func stepName(engine: ReviewEngineKind) -> String {
        self == .running ? "\(engine.displayName) 가 읽고 판단" : stepName
    }

    /// 진행 카드 단계 목록에 쓰는 이름. `label` 은 "…하는 중" 이라 끝난 단계(✓) 옆에 두면 어색하다.
    public var stepName: String {
        switch self {
        case .checkingPR: return "PR 상태 확인"
        case .loadingDiff: return "diff 받기"
        case .cloningSnapshot: return "PR 스냅샷 클론"
        case .fetchingCommit: return "PR 커밋 받기"
        case .fetchingFiles: return "PR 시점 코드 받기"
        case .preparingWorktree: return "리뷰용 워크트리 준비"
        case .running: return "Claude 가 읽고 판단"
        case .validating: return "초안 검증"
        default: return label
        }
    }

    /// 이 단계에 보통 얼마나 걸리는지 — 오래 걸려도 정상임을 알려 준다.
    public var hint: String? {
        switch self {
        case .cloningSnapshot: return "처음 한 번만 — 다음 리뷰부터는 달라진 파일만 받습니다"
        case .fetchingCommit: return "로컬에 없는 커밋만 받습니다"
        case .fetchingFiles: return "이미 받은 파일은 다시 받지 않습니다"
        case .preparingWorktree: return "처음 한 번은 파일 전체를 체크아웃해 조금 걸립니다"
        case .running: return "보통 1~3분"
        default: return nil
        }
    }

    public var isTerminal: Bool { self == .finished || self == .failed }
}
