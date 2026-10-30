import Foundation

/// 목록 탭의 종류. 기간은 따로 들고 다닌다 — 같은 종류를 24h·7일·30일로 볼 수 있어야 한다.
/// 탭 순서는 **좁은 것에서 넓은 것으로** 간다 — 내가 할 일 → 내가 한 일 → 그 밖의 전부.
/// `allCases` 순서가 곧 화면의 탭 순서이자 ⌘1/2/3 순서다(선언 순서를 바꾸면 둘 다 바뀐다).
/// rawValue 는 저장 값이라 순서를 바꿔도 예전에 고른 탭이 그대로 복원된다.
public enum PRListScopeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    /// 열린 PR (리뷰 대기함).
    case open
    /// 그 기간에 내가 승인한 PR.
    case myApprovals
    /// 그 기간에 활동이 있었던 PR 전부 — 열림·닫힘·머지.
    case recentAll

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .open: return "To review"
        case .recentAll: return "All PRs"
        case .myApprovals: return "Approved"
        }
    }

    /// 기간을 고를 수 있는 종류인가. 열린 PR 탭은 기간이 없다.
    public var usesWindow: Bool { self != .open }
}

/// 기간 선택지.
///
/// 기간 없이 닫힘까지 긁으면 2,667건이 나와 GitHub 이 502 를 낸다(실측). 그래서 "제한 없음" 은 없다.
/// 90일도 넣지 않는다 — 597건 = 6페이지로, 목록으로 훑을 크기가 아니고 실패 확률만 올라간다.
public enum PRListWindow: Int, Sendable, Codable, CaseIterable, Identifiable {
    case day = 24
    case week = 168
    case month = 720

    public var id: Int { rawValue }
    public var hours: Int { rawValue }

    /// 문장 속에 쓰는 이름 — "최근 7일 안에 …".
    public var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7일"
        case .month: return "30일"
        }
    }

    /// 탭 칩과 기간 고르기 목록에 쓰는 이름. 칩 이름(`To review`·`Approved`)과 같이 영어로 맞춘다.
    public var shortLabel: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    /// 한 칸 더 넓은 기간. 목록이 비었을 때 "더 넓게 볼까?" 를 제안할 때 쓴다.
    public var longer: PRListWindow? {
        switch self {
        case .day: return .week
        case .week: return .month
        case .month: return nil
        }
    }

    /// 이 기간에서 받아 둘 최대 건수. 실측 결과 건수(24h 31 / 7일 71 / 30일 188)에
    /// 여유를 얹은 값이다. 페이지 수가 아니라 건수로 잡아야, 요청이 예산을 넘겨
    /// 페이지 크기가 줄어들 때도 목록이 잘리지 않는다.
    public var maxResults: Int {
        switch self {
        case .day: return 200
        case .week: return 300
        case .month: return 600
        }
    }
}

/// 목록을 무엇으로 채울지 = 종류 + 기간.
///
/// 두 값은 만든 뒤에 바꿀 수 없다. `init` 이 "열린 PR 탭에는 기간이 없고, 기간을 쓰는 탭에는
/// 반드시 기간이 있다" 를 보장하는데, 바깥에서 `scope.window = .month` 로 고칠 수 있으면
/// 그 보장이 깨진다 — 열린 PR 탭에 기간이 붙고, `== .open` 비교가 전부 어긋나 헤더 필터가
/// 통째로 꺼진다. 저장은 Codable 이 아니라 `storageValue` 로만 한다(형식이 둘로 갈리면
/// 마이그레이션이 한쪽만 돈다).
public struct PRListScope: Sendable, Equatable, Hashable, Identifiable {
    public let kind: PRListScopeKind
    /// `open` 은 기간을 쓰지 않는다. 기간을 쓰는 종류는 항상 값이 있다.
    public let window: PRListWindow?

    public init(kind: PRListScopeKind, window: PRListWindow? = nil) {
        self.kind = kind
        self.window = kind.usesWindow ? (window ?? Self.defaultWindow) : nil
    }

    /// 기간을 처음 고를 때의 기본값.
    public static let defaultWindow: PRListWindow = .day

    public static let open = PRListScope(kind: .open)
    public static func recentAll(_ window: PRListWindow) -> PRListScope {
        PRListScope(kind: .recentAll, window: window)
    }
    public static func myApprovals(_ window: PRListWindow) -> PRListScope {
        PRListScope(kind: .myApprovals, window: window)
    }

    public var id: String { storageValue }

    /// 탭에 쓰는 이름. 기간을 쓰는 탭은 고른 기간이 함께 보인다.
    public var label: String {
        guard let window else { return kind.shortLabel }
        return "\(kind.shortLabel) \(window.shortLabel)"
    }

    // MARK: - 쿼리에 쓰는 값

    public var windowHours: Int? { window?.hours }
    public var includesClosed: Bool { kind != .open }
    public var requiresMyApproval: Bool { kind == .myApprovals }

    /// 받아 둘 최대 건수.
    ///
    /// 열린 PR 은 전량 확보한다 — 닫힌 PR 이 최근 갱신 순 자리를 차지해 열린 PR 을 밀어내면 안 된다.
    public var maxResults: Int { window?.maxResults ?? 400 }

    /// 한 요청에서 몇 건씩 받을지.
    ///
    /// GitHub 은 한 요청에서 실제로 펼쳐지는 PR 노드가 많으면 실행 예산을 넘겼다며 거절한다
    /// (`RESOURCE_LIMITS_EXCEEDED`). 실측 — 닫힘 포함 188건 검색에서 `first:100` 은 실패,
    /// 75·50·25 는 성공. 중첩 필드를 깎거나 `mergeable` 같은 계산 필드를 빼도 100 은 그대로 실패했다.
    /// 즉 원인은 필드가 아니라 한 요청에서 펼쳐지는 PR 수다.
    /// 열린 PR 탭은 실제로 9건만 펼쳐져 100 이어도 2.9초에 끝나므로 100 을 유지한다.
    public var pageSize: Int { includesClosed ? 50 : 100 }

    public var help: String {
        switch kind {
        case .open:
            return "열려 있는 PR 만 봅니다. 목록 헤더의 필터는 이 탭에만 적용됩니다."
        case .recentAll:
            return "최근 \(window?.label ?? "") 안에 활동이 있었던 PR 전부 — 열림·닫힘·머지 모두. 필터는 적용하지 않습니다."
        case .myApprovals:
            return "내가 최근 \(window?.label ?? "") 안에 Approve 한 PR. 닫힘·머지도 보입니다. 필터는 적용하지 않습니다."
        }
    }

    // MARK: - 목록 가운데 문구

    /// 이 탭의 첫 결과를 받는 동안 빈 행 자리 위 제목("'탭 이름' 가져오는 중") 아래에 쓰는 설명.
    ///
    /// 예전에는 어느 탭이든 "PR 을 불러오는 중" 한 줄이라 무엇을 받는지 몰랐고, 지난 목록이 다 걸러져
    /// 비면 받는 중인데도 "없습니다" 가 떴다.
    public var fetchingDescription: String {
        switch kind {
        case .open: return "열려 있는 PR 을 받고 있습니다."
        case .recentAll: return "최근 \(window?.label ?? "") 안에 활동이 있었던 PR 을 받고 있습니다."
        case .myApprovals: return "내가 최근 \(window?.label ?? "") 안에 Approve 한 PR 을 받고 있습니다."
        }
    }

    /// 첫 페이지를 다 걸렀는데 뒤 페이지가 남았을 때. "없습니다" 로 단정하면 조금 뒤 목록이 채워지며 거짓이 된다.
    /// - hiddenByFilters: 필터·검색어를 다 끄면 보이는 것이 있는가(`EmptyListDiagnosis.allOffCount > 0`).
    ///   탭 조건에 걸린 것을 "필터에 걸렸다" 고 하면 필터를 꺼도 안 나와 헛걸음한다.
    public static func continuingDescription(hiddenByFilters: Bool) -> String {
        hiddenByFilters
            ? "지금까지 받은 PR 은 모두 필터에 걸렸습니다."
            : "지금까지 받은 PR 중에는 조건에 맞는 것이 없습니다."
    }

    /// 다 받았는데 보여 줄 PR 이 없을 때 가운데 설명.
    ///
    /// 기간 탭은 아무것도 못 받았을 때와 받았지만 맞는 것이 없을 때 같은 말을 한다 — 예전에는 한쪽은
    /// 탭 설명만, 다른 쪽은 "활동이 있었던 PR 이 없습니다" 를 띄워 같은 빈 화면이 두 문장으로 갈렸다.
    /// 리뷰 대기만 둘을 가른다. 열린 PR 자체가 없는 것과, 있는데 리뷰할 것이 없는 것은 다른 일이다.
    /// - receivedAny: 이 탭으로 받은 PR 이 하나라도 있었나.
    public func emptyDescription(receivedAny: Bool) -> String {
        let span = window?.label ?? ""
        // 가장 긴 기간이면 늘릴 데가 없다. 그때 "늘려 보세요" 를 말하면 누를 버튼도 없는 권유가 된다.
        let widen = window?.longer == nil ? "" : " 기간을 늘려 보세요."
        let all = PRListScopeKind.recentAll.shortLabel
        switch kind {
        case .open:
            return receivedAny
                ? "지금 리뷰할 PR 이 없습니다. 이미 Approve 한 PR 과 초안은 '\(all)' 에서 볼 수 있습니다."
                : "열린 PR 이 없습니다. 닫히거나 머지된 PR 은 '\(all)' 에서 볼 수 있습니다."
        case .recentAll:
            return "최근 \(span) 안에 활동이 있었던 PR 이 없습니다.\(widen)"
        case .myApprovals:
            return "최근 \(span) 안에 내가 Approve 한 PR 이 없습니다.\(widen)"
        }
    }

    // MARK: - 저장

    /// `종류:시간` 으로 저장한다.
    public var storageValue: String { "\(kind.rawValue):\(window?.hours ?? 0)" }

    /// 저장된 값을 읽는다. 옛 형식(`myApprovals24h` 등)도 받아 새 형식으로 옮긴다 —
    /// 그렇게 안 하면 업데이트한 사람의 탭 선택이 조용히 초기화된다.
    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let kind = PRListScopeKind(rawValue: parts[0]) {
            self.init(kind: kind, window: PRListWindow(rawValue: Int(parts[1]) ?? 0))
            return
        }
        switch storageValue {
        case "open": self = .open
        case "recentAll": self = .recentAll(.month)
        case "myApprovals24h": self = .myApprovals(.day)
        case "myApprovals7d": self = .myApprovals(.week)
        default: return nil
        }
    }
}
