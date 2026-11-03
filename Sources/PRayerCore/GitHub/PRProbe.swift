import Foundation

/// 목록을 가볍게 훑은 한 줄(`GraphQL.prProbeList`). 무엇이 바뀌었는지 가르는 칸만 있다.
///
/// 앱의 목록 쿼리는 GitHub 이 요청한 칸 수로 값을 매겨 100건에 40점이다(실측). 2분마다 리뷰 대기·Approved 를 다 받으면
/// 시간당 한도의 36% 를 썼다. 훑기는 100건이어도 1점이라, 훑은 뒤 바뀐 PR 만 자세히 받는다(`PRFetchPlan`).
public struct PRProbe: Sendable, Equatable {
    /// `PullRequestInfo.id` 와 같은 "owner/name#번호".
    public var key: String
    /// GraphQL 노드 id — 자세히 받을 때(`nodes(ids:)`) 쓴다.
    public var nodeID: String
    public var updatedAt: Date
    public var headRefOid: String
    public var state: String
    public var isDraft: Bool
    public var mergeable: MergeableState
    public var checkState: String?

    public init(key: String, nodeID: String, updatedAt: Date, headRefOid: String, state: String,
                isDraft: Bool, mergeable: MergeableState, checkState: String?) {
        self.key = key
        self.nodeID = nodeID
        self.updatedAt = updatedAt
        self.headRefOid = headRefOid
        self.state = state
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.checkState = checkState
    }

    /// 받아 둔 것(`known`)과 견줘 다시 자세히 받아야 하나.
    ///
    /// 리뷰·코멘트·스레드 답글·코멘트 수정·커밋·리뷰 요청은 `updatedAt` 을 바꾼다(실측: 마지막 답글·수정 시각과 updatedAt
    /// 이 초까지 같았다). CI 결과와 머지 가능 여부는 바꾸지 않아서(실측) 그 값을 직접 견준다. 그래도 빠지는 것(스레드
    /// Resolve 등 확인 못 한 것)은 주기적으로 전부 받을 때 바로잡힌다(`PRFetchPlan.needsFullSync`).
    public func needsDetail(known: PullRequestInfo?) -> Bool {
        guard let known else { return true }
        return known.updatedAt != updatedAt
            || known.headRefOid != headRefOid
            || known.state != state
            || known.isDraft != isDraft
            || known.mergeable != mergeable
            || known.checkState != checkState
    }
}

/// 훑은 목록으로 무엇을 자세히 받을지 정하고, 받은 것을 훑은 순서대로 늘어놓는다.
public enum PRFetchPlan {
    /// 이만큼 지나면 바뀐 것만이 아니라 전부 다시 받는다 — 훑기로 못 가르는 변화가 있어도 이 안에 바로잡힌다.
    public static let fullSyncInterval: TimeInterval = 30 * 60
    /// 자세히 받을 때 한 요청에 담는 건수. 닫힘이 섞인 50건은 실행 예산을 넘긴 적이 있다(`PRListScope.pageSize`).
    public static let detailChunk = 25

    public static func needsFullSync(lastFullSync: Date?, now: Date) -> Bool {
        guard let lastFullSync else { return true }
        return now.timeIntervalSince(lastFullSync) >= fullSyncInterval
    }

    /// 자세히 받을 PR 의 노드 id — 훑은 순서 그대로. 전부 받을 때는 모두.
    public static func nodesToFetch(_ probes: [PRProbe], known: [String: PullRequestInfo], fullSync: Bool) -> [String] {
        probes.filter { fullSync || $0.needsDetail(known: known[$0.key]) }.map(\.nodeID)
    }

    /// 훑은 순서대로 받아 둔 것을 늘어놓는다. 아직 자세히 못 받은 것은 뺀다(처음 채우는 중이면 받은 데까지만 보인다).
    public static func assemble(_ probes: [PRProbe], known: [String: PullRequestInfo]) -> [PullRequestInfo] {
        probes.compactMap { known[$0.key] }
    }
}
