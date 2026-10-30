import Foundation

/// 목록에서 PR 을 숨길 수 있는 필터. 빈 화면에서 "무엇이 몇 건을 숨기는지" 말해 주려면
/// 숨긴 이유를 필터별로 알아야 한다.
///
/// **끌 수 있는 것만** 여기 둔다. "리뷰 대기에 닫힌 PR·내가 승인한 PR 을 안 보인다" 는
/// 끌 수 있는 선택지가 아니라 그 탭의 정의라, `scopeIncludes` 로 옮겼다. 켜 봐야 아무 일도
/// 없거나 끄면 탭의 뜻이 깨지는 토글을 늘어놓으면, 정작 쓰는 필터가 그 사이에 묻힌다.
public enum PRFilterKind: String, Sendable, CaseIterable, Identifiable {
    case hideIgnoredAuthors
    case hideLabels
    case repos
    case search

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hideIgnoredAuthors: return "특정 사람의 PR 숨기기"
        case .hideLabels: return "특정 라벨 숨기기"
        case .repos: return "일부 레포만 보기"
        case .search: return "검색어"
        }
    }
}

/// 필터 값만 담은 값 타입. 화면 상태(PRFilter)와 분리해 두면 계산을 테스트할 수 있다.
public struct PRFilterState: Sendable, Equatable {
    /// 골라 둔 사람이 올린 PR 숨기기. 목록이 비어 있으면 아무것도 하지 않는다.
    public var hideIgnoredAuthors: Bool
    /// 골라 둔 라벨(설정의 hiddenLabels)이 붙은 PR 숨기기. 목록이 비어 있으면 아무것도 하지 않는다.
    public var hideLabels: Bool
    public var search: String
    /// 숨길 사람이 한 명이라도 있는가. 화면의 "필터 N" 을 정직하게 세는 데만 쓴다.
    public var hasIgnoredAuthors: Bool
    /// 숨길 라벨이 하나라도 있는가. 같은 이유로만 쓴다.
    public var hasHiddenLabels: Bool
    /// 목록에서 뺄 레포(`repoKey`). 비어 있으면 모든 레포를 보인다.
    ///
    /// 라벨·사람 필터와 달리 **모든 탭**에 건다. "이 레포만 보고 싶다" 는 리뷰 대기만의 조건이
    /// 아니라 지금 무엇을 보느냐를 좁히는 것이라 검색어와 성격이 같다 — 승인 탭에서도 그 레포만 봐야 한다.
    public var hiddenRepos: Set<String>

    public init(hideIgnoredAuthors: Bool = false,
                hideLabels: Bool = false,
                search: String = "",
                hasIgnoredAuthors: Bool = false,
                hasHiddenLabels: Bool = true,
                hiddenRepos: Set<String> = []) {
        self.hideIgnoredAuthors = hideIgnoredAuthors
        self.hideLabels = hideLabels
        self.search = search
        self.hasIgnoredAuthors = hasIgnoredAuthors
        self.hasHiddenLabels = hasHiddenLabels
        self.hiddenRepos = hiddenRepos
    }

    /// `hiddenRepos` 에 넣는 꼴. GitHub 은 레포 이름의 대소문자를 가리지 않는데, 설정에 직접 친 이름과
    /// API 가 돌려준 이름은 대소문자가 다를 수 있어 소문자로 맞춘다.
    public static func repoKey(_ repo: RepoID) -> String { repo.full.lowercased() }

    /// 지금 켜져 있는 필터들. 검색어도 하나로 센다.
    public func active(in scope: PRListScope) -> [PRFilterKind] {
        var result: [PRFilterKind] = []
        if scope.kind == .open {
            // 목록이 비면 아무것도 안 하므로 켜진 필터로 세지 않는다 — "필터 4" 인데
            // 숨은 게 없으면 무엇이 걸렀는지 찾느라 헤맨다.
            if hideIgnoredAuthors, hasIgnoredAuthors { result.append(.hideIgnoredAuthors) }
            if hideLabels, hasHiddenLabels { result.append(.hideLabels) }
        }
        if !hiddenRepos.isEmpty { result.append(.repos) }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { result.append(.search) }
        return result
    }
}

/// 내가 처리해서(승인·게시) 목록에서 뺀 PR 하나.
public struct PRDismissal: Sendable, Equatable {
    /// 뺄 때의 head 커밋. 새 커밋이 올라오면 다시 볼 일이 생긴 것이다.
    public var head: String
    /// 그때 낸 리뷰의 시각(이 앱의 게시 시각). 그 뒤로 다시 리뷰 요청이 왔는지 가르는 기준이다.
    public var reviewedAt: Date

    public init(head: String, reviewedAt: Date) {
        self.head = head
        self.reviewedAt = reviewedAt
    }
}

public enum PRVisibility {
    /// 탭 자체의 조건. 필터를 다 풀어도 이건 그대로 적용된다.
    ///
    /// - 승인 탭: "그 기간에 내가 승인했는가" 가 탭의 정의다.
    /// - 리뷰 대기 탭: **닫힌 PR · 내가 이미 승인한 PR · 초안은 여기 없다.** 셋 다 "리뷰
    ///   대기" 가 아니고, 셋 다 다른 곳(전체 PR / 최근 승인 / 내가 올린 PR 그룹)에서 그대로 볼 수
    ///   있다. 예전에는 끌 수 있는 필터였는데, 끄면 리뷰 대기함이 할 일이 아닌 것으로 차고
    ///   켜 두면 아무 일도 안 하는 토글이라(닫힘 쪽은 서버 쿼리의 `is:open` 이 이미 걸렀다)
    ///   선택지로 둘 이유가 없었다.
    public static func scopeIncludes(pr: PullRequestInfo,
                                     scope: PRListScope,
                                     approvedInWindow: Bool) -> Bool {
        if scope.kind == .open {
            guard pr.isOpen else { return false }
            // 초안은 아직 봐 달라는 게 아니다. 내가 올린 초안은 맨 위 "내가 올린 PR"
            // 그룹이 따로 맡으므로(그쪽은 필터를 안 탄다) 여기서 빠져도 안 보이지 않는다.
            if pr.isDraft { return false }
            // 승인한 뒤 새 커밋이 오면 다시 봐야 하므로 "지금 커밋 기준" 으로 본다.
            // 다시 봐 달라는 요청(Re-request review)이 왔으면 남긴다 — 승인은 그대로지만
            // 사람이 한 번 더 봐 달라고 한 것이다.
            if pr.viewerApprovedCurrentHead, !pr.viewerHasReviewRequest { return false }
            return true
        }
        guard scope.requiresMyApproval else { return true }
        return approvedInWindow
    }

    /// 이 PR 을 숨긴 필터들. 비어 있으면 보인다.
    /// 두 개가 동시에 걸릴 수 있어서 Set 으로 돌려준다 — 그래야 "이것만 끄면 +N건" 을 정확히 셀 수 있다.
    public static func hidingFilters(pr: PullRequestInfo,
                                     state: PRFilterState,
                                     scope: PRListScope,
                                     hasHiddenLabel: Bool,
                                     isIgnoredAuthor: Bool = false) -> Set<PRFilterKind> {
        var reasons: Set<PRFilterKind> = []
        // 목록 헤더의 필터는 "리뷰 대기"(열린 PR) 탭을 위한 것이다.
        // 승인·전체 탭은 그 탭 자체가 조건이라 필터를 걸지 않는다.
        if scope.kind == .open {
            if state.hideLabels, hasHiddenLabel { reasons.insert(.hideLabels) }
            // 내가 올린 것은 맨 위 그룹이 맡으므로 여기서 작성자로 거르지 않는다.
            if state.hideIgnoredAuthors, isIgnoredAuthor, !pr.viewerDidAuthor {
                reasons.insert(.hideIgnoredAuthors)
            }
        }
        if state.hiddenRepos.contains(PRFilterState.repoKey(pr.repo)) { reasons.insert(.repos) }
        // 아래 구역(전체 PR 검색)이 받아 둔 목록을 거를 때도 같은 규칙을 쓴다 — 위아래 구역의 기준이 갈리지 않게.
        if !PRSearchPlan.matchesLocally(pr, needle: state.search) { reasons.insert(.search) }
        return reasons
    }

    /// 사용자가 처리해서(승인·게시) 목록에서 뺀 PR 인가.
    ///
    /// `dismissals` 는 PR id → **뺄 때의 head 커밋과 리뷰 시각**이다. 같은 PR 이어도 다시 볼 일이 생기면
    /// 숨기면 안 된다 — 새 커밋이 올라왔거나, 다시 리뷰 요청이 왔을 때다.
    ///
    /// 재요청이면 숨김을 지우지 않고 둔다. 다시 리뷰해서 요청이 걷히면 도로 빠져야 하고, 게시 직후의 옛 상태를
    /// 잘못 읽었더라도 다음 조회에서 바로잡힌다.
    public static func isDismissed(pr: PullRequestInfo, dismissals: [String: PRDismissal]) -> Bool {
        guard let dismissal = dismissals[pr.id], dismissal.head == pr.headRefOid else { return false }
        return !pr.isReRequested(postedAt: dismissal.reviewedAt)
    }

    /// 새 커밋이 올라온 PR 의 숨김을 걷어낸다.
    ///
    /// 목록에 없는 PR 의 숨김은 그대로 둔다. 탭을 옮겼다 돌아오는 동안 `prs` 에서 잠깐
    /// 빠지는데, 그때 숨김까지 지우면 돌아오자마자 처리한 PR 이 다시 튀어나온다.
    public static func prunedDismissals(_ dismissals: [String: PRDismissal],
                                        prs: [PullRequestInfo]) -> [String: PRDismissal] {
        guard !dismissals.isEmpty else { return dismissals }
        var heads: [String: String] = [:]
        for pr in prs { heads[pr.id] = pr.headRefOid }
        return dismissals.filter { id, dismissal in
            guard let head = heads[id] else { return true }
            return head == dismissal.head
        }
    }
}

/// 목록이 비었을 때 무엇이 원인인지 정리한 결과. 화면 문구가 이걸 그대로 읽는다.
public struct EmptyListDiagnosis: Sendable {
    /// 필터에 걸려 숨은 PR 수.
    public var hiddenCount: Int
    /// 이 필터 **하나만** 끄면 새로 보이는 건수. 0 인 항목도 담는다(겹쳐 걸린 경우를 정직하게 보여주려고).
    public var gains: [(kind: PRFilterKind, gain: Int)]
    /// 필터를 다 끄면 보이는 건수. 탭 조건은 그대로 적용된다.
    public var allOffCount: Int
    /// 레포별 숨김 건수.
    public var byRepo: [(name: String, count: Int)]
    /// 겹쳐 걸린 PR 이 있어 각 줄의 합이 allOffCount 와 다른가.
    public var hasOverlap: Bool

    public var searchGain: Int { gains.first { $0.kind == .search }?.gain ?? 0 }
    public var filterGains: [(kind: PRFilterKind, gain: Int)] { gains.filter { $0.kind != .search } }
    /// 검색어만 원인인가 — 다른 필터로는 아무것도 나오지 않는데 검색어를 지우면 나온다.
    public var searchIsOnlyBlocker: Bool {
        searchGain > 0 && filterGains.allSatisfy { $0.gain == 0 }
    }

    public init(hiddenCount: Int, gains: [(kind: PRFilterKind, gain: Int)], allOffCount: Int,
                byRepo: [(name: String, count: Int)], hasOverlap: Bool) {
        self.hiddenCount = hiddenCount
        self.gains = gains
        self.allOffCount = allOffCount
        self.byRepo = byRepo
        self.hasOverlap = hasOverlap
    }

    /// prs 전체를 훑어 진단을 만든다. PR 수가 수십 건이라 매번 계산해도 부담이 없다.
    public static func make(prs: [PullRequestInfo],
                            state: PRFilterState,
                            scope: PRListScope,
                            hasHiddenLabel: (PullRequestInfo) -> Bool,
                            approvedInWindow: (PullRequestInfo) -> Bool,
                            isIgnoredAuthor: (PullRequestInfo) -> Bool = { _ in false }) -> EmptyListDiagnosis {
        // 탭 조건을 통과한 것만 대상이다. 승인 탭에서 "필터를 풀면 보인다" 고 하면 거짓말이 된다.
        let candidates = prs.filter {
            PRVisibility.scopeIncludes(pr: $0, scope: scope, approvedInWindow: approvedInWindow($0))
        }
        let reasonsByPR = candidates.map { pr in
            (pr, PRVisibility.hidingFilters(pr: pr, state: state, scope: scope,
                                            hasHiddenLabel: hasHiddenLabel(pr),
                                            isIgnoredAuthor: isIgnoredAuthor(pr)))
        }
        let hidden = reasonsByPR.filter { !$0.1.isEmpty }
        let gains: [(PRFilterKind, Int)] = state.active(in: scope).map { kind in
            // 이 필터 **하나만** 끄면 보이는 것 = 그 필터가 유일한 이유인 PR.
            (kind, hidden.filter { $0.1 == [kind] }.count)
        }
        let byRepo = Dictionary(grouping: hidden, by: { $0.0.repo.name })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
        let sumOfGains = gains.reduce(0) { $0 + $1.1 }
        return EmptyListDiagnosis(hiddenCount: hidden.count,
                                  gains: gains.map { (kind: $0.0, gain: $0.1) },
                                  allOffCount: candidates.count,
                                  byRepo: byRepo,
                                  hasOverlap: sumOfGains != hidden.count)
    }
}
