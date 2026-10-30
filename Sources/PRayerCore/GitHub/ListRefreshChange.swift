import Foundation

/// 목록을 새로 받았을 때 화면에서 바뀌는 행 — 빠지는 것과 새로 온 것.
///
/// 화면은 이것을 한꺼번에 갈아 끼우지 않고 차례대로 보여 준다(사용자 선택 2026-10-28, 시안 A "순서대로"):
/// 빠지는 행은 칩이 되어 그 PR 이 이제 있는 탭으로 날아가고, 칩이 탭에 닿은 뒤 새 행이 하나씩 펼쳐진다.
/// 위아래가 동시에 움직이면 어디를 봐야 할지 몰라 정신없었다.
public struct ListRefreshChange: Equatable, Sendable {
    /// 화면에서 빠지는 PR(위에서부터).
    public var departures: [String]
    /// 화면에 새로 들어오는 PR(위에서부터).
    public var arrivals: [String]

    /// - Parameters:
    ///   - before: 받기 전 화면에 보이던 PR(위에서부터).
    ///   - after: 받은 뒤 보일 PR(위에서부터).
    public init(before: [String], after: [String]) {
        let beforeSet = Set(before)
        let afterSet = Set(after)
        departures = before.filter { !afterSet.contains($0) }
        arrivals = after.filter { !beforeSet.contains($0) }
    }

    public var isEmpty: Bool { departures.isEmpty && arrivals.isEmpty }

    /// 하나씩 보여 줄 최대 건수. 이보다 많으면(앱을 처음 켰거나 오래 쉬었다 왔을 때) 빠지는 행은 갈 탭마다 칩 하나로
    /// 묶고, 새 행은 간격을 줄여 펼친다(`arrivalCadence`) — 하나씩 0.14초씩 하면 1초를 넘겨 오히려 기다림이 길어진다.
    public static let stepLimit = 5

    public var isLarge: Bool { departures.count + arrivals.count > Self.stepLimit }

    /// 새 행을 위에서부터 하나씩 펼치는 간격(초)과 그중 차례로 펼칠 수 — 나머지는 마지막 차례에 같이 들인다.
    ///
    /// 몇 개 안 되면 0.14초씩 하나하나. 많으면(빈 목록을 처음 채울 때 30행 등) 0.07초씩 화면에 들 만큼(8행)만 차례로
    /// 펼친다 — 0.14초씩 다 하면 30행에 4초가 걸린다. 예전에는 많으면 한꺼번에 들여 툭 생겨 보였다(사용자 지적 2026-10-29).
    public static func arrivalCadence(count: Int) -> (interval: Double, steps: Int) {
        count <= stepLimit ? (0.14, count) : (0.07, min(count, 8))
    }

    /// 받은 지 이만큼이 안 된 탭으로 돌아오면 "가져오는 중" 띠·훑는 빛 없이 조용히 다시 받는다 — 바뀐 행만 날아가거나
    /// 들어온다. 방금 보던 목록을 다른 탭에 갔다 온 것만으로 다시 찾는 모습이 답답했다(사용자 요청 2026-10-28).
    public static let quietRefetchWindow: TimeInterval = 5 * 60

    /// 그 탭의 목록이 아직 새것인가. 지금 탭도 폴링 간격만큼은 묵은 채 보이니, 폴링 간격을 길게 잡았으면 그만큼은
    /// 새것으로 친다.
    public static func isFresh(fetchedAt: Date?, now: Date, pollSeconds: Int) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) < max(quietRefetchWindow, TimeInterval(pollSeconds))
    }

    /// 리뷰 대기 탭에서 빠지는 PR 이 이제 있는 탭. 날아갈 곳이 없으면 nil 이다(제자리에서 접히기만 한다).
    ///
    /// - Parameter pr: 새로 받은 목록 속 그 PR. 목록에서 아예 없어졌으면 nil — 리뷰 대기 탭은 열린 PR 만 받으니
    ///   머지됐거나 닫힌 것이고(어느 쪽인지는 모른다), 둘 다 전체 PR 탭에 있다.
    ///
    /// 다른 탭에서 빠지는 PR 은 기간이 지나 빠지는 것이라 갈 탭이 없다. 받은 목록에 있는데 탭 조건은 그대로 맞으면
    /// 숨김·필터에 걸린 것이라 역시 갈 탭이 없다.
    public static func destination(of pr: PullRequestInfo?, leaving scope: PRListScope) -> PRListScopeKind? {
        guard scope.kind == .open else { return nil }
        guard let pr else { return .recentAll }
        if !pr.isOpen || pr.isDraft { return .recentAll }
        // 리뷰 대기 탭이 빼는 조건(PRVisibility.scopeIncludes)과 같다 — 다시 요청이 오면 승인했어도 남는다.
        if pr.viewerApprovedCurrentHead, !pr.viewerHasReviewRequest { return .myApprovals }
        return nil
    }
}
