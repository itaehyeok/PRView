import Foundation
import PRayerCore

/// 진행 카드·대기열·목록 배지가 같은 말을 쓰도록 한 곳에서 만든다.
///
/// PR 스냅샷을 처음 받는 잡은 세 단계가 이어진다 — 커밋 기록(클론) → 리뷰할 커밋의 파일 → 파일 풀기.
/// 사용자에게는 "클론 중 1/2 · 커밋 기록", "클론 중 2/2 · PR 시점 코드", "파일 푸는 중" 으로 보인다(사용자 결정 시안).
/// 이미 받아 둔 스냅샷이면 달라진 파일만 받으니 "달라진 파일 받는 중" 이 된다.
extension ReviewJob {
    var progressTitle: String {
        switch phase {
        case .cloningSnapshot:
            return "클론 중 1/2 · 커밋 기록"
        case .fetchingFiles:
            return clonedSnapshot ? "클론 중 2/2 · PR 시점 코드" : "달라진 파일 받는 중"
        case .preparingWorktree where progress?.stage == .updating:
            return "파일 푸는 중"
        default:
            return phase.label
        }
    }

    /// `45% · 29MB · 8.1MB/s` / `정리 중 · 80%` / `8,200 / 12,000개`. 진행을 모르면 nil.
    ///
    /// 처음 클론하는 잡은 퍼센트도 막대와 같은 전체 진행으로 적는다. 단계마다 0% 부터 다시 세면 막대(전체)와
    /// 숫자(단계)가 어긋나 보였다(실측 화면: 막대 16% 옆에 "45%"). 받은 양·속도는 지금 단계의 것 그대로다.
    var progressDetail: String? {
        guard let progress else { return nil }
        let percent = cloneFraction.map { Int(($0 * 100).rounded()) } ?? progress.percent
        switch progress.stage {
        case .receiving:
            return ["\(percent)%", progress.transferred.map(Self.shortUnit), progress.speed.map(Self.shortUnit)]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .resolving:
            return "정리 중 · \(percent)%"
        case .updating:
            return "\(progress.done.formatted()) / \(progress.total.formatted())개"
        }
    }

    /// git 의 `MiB` 를 화면의 다른 숫자처럼 `MB` 로 — `29.00 MiB` → `29MB`, `8.10 MiB/s` → `8.1MB/s`.
    static func shortUnit(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let value = Double(parts[0]) else { return text }
        let unit = parts[1].replacingOccurrences(of: "iB", with: "B").replacingOccurrences(of: "bytes", with: "B")
        let number = value >= 10 || value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return number + unit
    }

    /// 처음 클론하는 잡의 전체 진행(0…1) — 목록 배지 "클론 45%". 단계 길이는 실측 비율로 나눴다
    /// (큰 레포: 커밋 기록 12초 · 파일 14초 · 풀기 2초). 클론이 끝나 리뷰가 시작되면 nil.
    var cloneFraction: Double? {
        guard clonedSnapshot, state == .running else { return nil }
        let fraction = progress?.fraction ?? 0
        switch phase {
        case .cloningSnapshot:
            return progress?.stage == .resolving ? 0.36 + 0.04 * fraction : 0.36 * fraction
        case .fetchingCommit:
            return 0.40
        case .fetchingFiles:
            return progress?.stage == .resolving ? 0.80 + 0.05 * fraction : 0.40 + 0.40 * fraction
        case .preparingWorktree:
            return progress?.stage == .updating ? 0.85 + 0.15 * fraction : 0.85
        default:
            return nil
        }
    }

    /// 지금 받기·풀기 중인가 — 진행 막대를 그릴지.
    var showsTransferProgress: Bool {
        switch phase {
        case .cloningSnapshot, .fetchingFiles: return true
        case .preparingWorktree: return progress != nil
        default: return false
        }
    }

    /// 클론을 처음 받는 동안의 취소는 "클론 취소" 라 부른다(시안). 리뷰가 시작되면 그냥 "취소".
    var cancelTitle: String {
        cloneFraction != nil ? "클론 취소" : "취소"
    }
}
