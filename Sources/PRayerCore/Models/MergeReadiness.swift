import Foundation

/// 머지 방식. GitHub REST 의 `merge_method` 이름을 그대로 rawValue 로 쓴다.
public enum MergeMethod: String, CaseIterable, Identifiable, Sendable, Codable {
    case merge
    case squash
    case rebase

    public var id: String { rawValue }

    /// GitHub 웹의 머지 버튼 메뉴와 같은 이름 — 웹에서 보던 말 그대로 고르게 한다.
    public var label: String {
        switch self {
        case .merge: return "Merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    /// GraphQL `viewerDefaultMergeMethod` 의 값(MERGE / SQUASH / REBASE).
    public init?(graphQL: String?) {
        switch graphQL?.uppercased() {
        case "MERGE": self = .merge
        case "SQUASH": self = .squash
        case "REBASE": self = .rebase
        default: return nil
        }
    }
}

/// 레포가 허용하는 머지 방식과 처음 골라 둘 방식.
public struct MergeOptions: Sendable, Equatable {
    public var allowed: [MergeMethod]
    public var preferred: MergeMethod

    public init(allowed: [MergeMethod], preferred: MergeMethod?) {
        let list = allowed.isEmpty ? MergeMethod.allCases : allowed
        self.allowed = list
        // GitHub 이 알려 준 "내가 마지막에 쓴 방식" 이 지금은 막혀 있을 수 있다. 그러면 허용된 첫 방식.
        self.preferred = preferred.flatMap { list.contains($0) ? $0 : nil } ?? list[0]
    }

    /// 레포 설정을 못 받았을 때. 세 방식을 다 보이고, 막힌 방식이면 GitHub 이 거절하며 이유를 알려 준다.
    public static let fallback = MergeOptions(allowed: MergeMethod.allCases, preferred: .merge)
}

/// 머지를 막는 것. 화면에는 첫 번째 하나만 보인다 — 하나를 풀면 다음 것이 나온다.
public enum MergeBlock: Equatable, Sendable {
    /// Approve 가 이만큼 더 필요하다.
    case needsApprovals(Int)
    case draft
    case conflict
    /// base 가 앞서 있고 레포가 최신으로 맞춘 뒤에만 머지하게 한다.
    case behind
    case checksFailing
    case checksPending
    /// GitHub 이 BLOCKED 라고만 한다(코드 오너 리뷰·브랜치 규칙 등). 이유는 GitHub 에서 본다.
    case blockedByGitHub

    public var message: String {
        switch self {
        case .needsApprovals(let count): return "\(count)명 더 Approve 해야 머지할 수 있습니다"
        case .draft: return "Draft PR 입니다 — Ready for review 로 바꾼 뒤 머지할 수 있습니다"
        case .conflict: return "Conflict — 충돌을 풀어야 머지할 수 있습니다"
        case .behind: return "base 브랜치가 앞서 있습니다 — GitHub 에서 Update branch 뒤 머지할 수 있습니다"
        case .checksFailing: return "CI 실패 — 필수 체크가 통과해야 머지할 수 있습니다"
        case .checksPending: return "CI 가 도는 중입니다 — 끝나면 머지할 수 있습니다"
        case .blockedByGitHub: return "GitHub 규칙이 아직 머지를 막고 있습니다 — 이유는 GitHub 에서 확인하세요"
        }
    }
}

/// 내 PR 상세의 머지 줄이 보여 줄 상태.
public enum MergeReadiness: Equatable, Sendable {
    /// 머지 줄을 그리지 않는다 — 남의 PR 이거나 머지 없이 닫힌 PR.
    case hidden
    case merged
    case blocked(MergeBlock)
    case ready

    /// - Parameter threshold: 이 PR 이 향하는 브랜치의 Approve 기준(`Settings.approvalThreshold(for:)`).
    ///   개요 카드의 "Approve 2/3" 과 같은 수로 센다 — 두 곳이 다른 말을 하지 않게.
    public static func resolve(_ pr: PullRequestInfo, threshold: Int) -> MergeReadiness {
        guard pr.viewerDidAuthor else { return .hidden }
        switch pr.state.uppercased() {
        case "MERGED": return .merged
        case "OPEN": break
        default: return .hidden
        }
        // 사용자가 기다리는 것은 대개 Approve 다. 그래서 그 수를 가장 먼저 말한다.
        let missing = threshold - pr.approvalCount
        if missing > 0 { return .blocked(.needsApprovals(missing)) }
        if pr.isDraft { return .blocked(.draft) }
        let status = pr.mergeStateStatus?.uppercased()
        if pr.mergeable == .conflicting || status == "DIRTY" { return .blocked(.conflict) }
        if status == "BEHIND" { return .blocked(.behind) }
        if status == "BLOCKED" {
            if pr.checkOutcome.isProblem { return .blocked(.checksFailing) }
            if ["PENDING", "EXPECTED"].contains(pr.checkState?.uppercased() ?? "") { return .blocked(.checksPending) }
            return .blocked(.blockedByGitHub)
        }
        // CLEAN·UNSTABLE(필수 아닌 체크 실패)·HAS_HOOKS·UNKNOWN 은 누를 수 있게 둔다.
        // UNKNOWN 은 GitHub 이 아직 계산 중일 때다. 막혀 있으면 머지 호출이 이유와 함께 거절된다.
        return .ready
    }
}
