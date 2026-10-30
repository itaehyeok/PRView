import Foundation

/// 커밋 탭 위쪽 표의 행과 그래프.
///
/// 레인 계산은 GitLane 의 `LaneComputer` 를 옮겨 PR 에 맞게 고쳤다. 다른 점은 PR 밖의 부모다.
/// - 첫 부모가 PR 밖이면(브랜치의 첫 커밋) 맨 아래 "분기점" 행 하나로 모은다. 그 선은 거기서 끝난다.
/// - 두 번째 이후 부모가 PR 밖이면(develop 을 받아온 머지) 레인을 열지 않는다. 그 develop 커밋은 목록에 없어서
///   레인을 열면 끝나지 않는 선이 화면 아래로 이어진다. 대신 행에 `mergesFromBase` 를 달아 짧은 선만 그린다.
public struct CommitGraph: Sendable {
    public enum Kind: Sendable, Hashable {
        case commit(BranchCommit)
        /// 브랜치가 갈라져 나온 base 쪽 커밋. 목록에 없어 oid 만 안다.
        case base(oid: String)
    }

    /// 그래프 한 행에서 그릴 선 하나. 값은 열 번호, nil 은 그쪽으로 선이 없음(이 행의 점에서 시작·끝).
    public struct Line: Sendable, Hashable {
        /// 레인 id — 색을 정한다.
        public let lane: Int
        public let top: Int?
        public let middle: Int
        public let bottom: Int?

        public init(lane: Int, top: Int?, middle: Int, bottom: Int?) {
            self.lane = lane
            self.top = top
            self.middle = middle
            self.bottom = bottom
        }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public let kind: Kind
        public let lines: [Line]
        /// 점이 놓이는 열.
        public let column: Int
        /// 점 색을 정하는 레인 id.
        public let lane: Int
        /// PR 밖(base 브랜치)에서 받아온 머지 — 오른쪽에서 들어오는 짧은 선을 그린다.
        public let mergesFromBase: Bool

        public var id: String {
            switch kind {
            case .commit(let commit): return commit.oid
            case .base(let oid): return "base:" + oid
            }
        }

        public var commit: BranchCommit? {
            if case .commit(let commit) = kind { return commit }
            return nil
        }

        /// 이 행에서 쓰는 가장 오른쪽 열.
        public var maxColumn: Int {
            lines.reduce(column) { max($0, $1.top ?? -1, $1.middle, $1.bottom ?? -1) }
        }
    }

    /// 위가 새 커밋이다.
    public let rows: [Row]

    public var commits: [BranchCommit] { rows.compactMap(\.commit) }

    /// 그래프 칸 너비를 정할 열 수.
    public var columnCount: Int { (rows.map(\.maxColumn).max() ?? 0) + 1 }

    public init(_ commits: [BranchCommit]) {
        let ordered = Self.topologicalNewestFirst(commits)
        let inPR = Set(ordered.map(\.oid))
        let baseOid = ordered.last.flatMap { last in last.parents.first { !inPR.contains($0) } }
        let baseKey = "\u{0}base"

        var lanes = LaneState()
        var rows: [Row] = []
        for commit in ordered {
            var parents: [String] = []
            var mergesFromBase = false
            for (index, parent) in commit.parents.enumerated() {
                if inPR.contains(parent) {
                    parents.append(parent)
                } else if index == 0 {
                    parents.append(baseKey)
                } else {
                    mergesFromBase = true
                }
            }
            let graph = lanes.append(commit.oid, parents: parents)
            rows.append(Row(kind: .commit(commit), lines: graph.lines, column: graph.column,
                            lane: graph.lane, mergesFromBase: mergesFromBase))
        }
        if let baseOid, lanes.isWaiting(for: baseKey) {
            let graph = lanes.append(baseKey, parents: [])
            rows.append(Row(kind: .base(oid: baseOid), lines: graph.lines, column: graph.column,
                            lane: graph.lane, mergesFromBase: false))
        }
        self.rows = rows
    }

    // MARK: - 리뷰한 지점

    /// 리뷰한 커밋의 행 번호. 그 위의 행들이 "리뷰 이후" 다. 목록에 없으면(강제 푸시로 사라짐) nil.
    public func reviewedRowIndex(reviewedOid: String?) -> Int? {
        guard let reviewedOid else { return nil }
        return rows.firstIndex { $0.commit?.oid == reviewedOid }
    }

    /// 리뷰 뒤에 올라온 커밋. 리뷰한 커밋이 목록에 없거나 맨 위(head)면 빈 배열.
    public func commitsAfterReview(reviewedOid: String?) -> [BranchCommit] {
        guard let index = reviewedRowIndex(reviewedOid: reviewedOid) else { return [] }
        return rows[..<index].compactMap(\.commit)
    }

    // MARK: - 고른 커밋 → diff 범위

    /// 고른 커밋들의 diff 범위. 하나면 그 커밋, 여럿이면 가장 아래(오래된) 커밋의 첫 부모부터 가장 위 커밋까지.
    /// 첫 부모가 없는 커밋(저장소 첫 커밋)이 가장 아래면 범위를 만들 수 없어 nil.
    public func diffSpec(for selected: Set<String>) -> CommitDiffSpec? {
        let picked = rows.compactMap(\.commit).filter { selected.contains($0.oid) }
        guard let newest = picked.first, let oldest = picked.last else { return nil }
        if picked.count == 1 { return .commit(newest.oid) }
        guard let base = oldest.parents.first else { return nil }
        return .range(base: base, head: newest.oid)
    }

    /// 표에서 두 행 사이(끝 포함)의 커밋 oid — ⇧클릭으로 범위를 고를 때.
    public func oids(between first: String, and second: String) -> [String] {
        let commits = rows.compactMap(\.commit)
        guard let a = commits.firstIndex(where: { $0.oid == first }),
              let b = commits.firstIndex(where: { $0.oid == second }) else { return [] }
        return commits[min(a, b)...max(a, b)].map(\.oid)
    }

    // MARK: - 순서

    /// 자식이 부모보다 먼저 오게(위가 새 것) 줄 세운다. 같이 놓을 수 있으면 GitHub 순서상 뒤(새) 것을 먼저.
    /// GitHub 의 PR 커밋 순서는 날짜 순이라, 날짜가 뒤엉킨 리베이스·머지에서 부모가 자식보다 위에 올 수 있다.
    static func topologicalNewestFirst(_ commits: [BranchCommit]) -> [BranchCommit] {
        let index = Dictionary(commits.enumerated().map { ($1.oid, $0) }, uniquingKeysWith: { first, _ in first })
        var childCount = [String: Int]()
        for commit in commits {
            for parent in Set(commit.parents) where index[parent] != nil {
                childCount[parent, default: 0] += 1
            }
        }
        var ready = commits.indices.filter { childCount[commits[$0].oid, default: 0] == 0 }
        var placed = Set<String>()
        var result: [BranchCommit] = []
        while let best = ready.max() {
            ready.removeAll { $0 == best }
            let commit = commits[best]
            guard placed.insert(commit.oid).inserted else { continue }
            result.append(commit)
            for parent in Set(commit.parents) {
                guard let parentIndex = index[parent] else { continue }
                childCount[parent, default: 0] -= 1
                if childCount[parent] == 0 { ready.append(parentIndex) }
            }
        }
        // 고리(있을 수 없지만)로 못 놓은 커밋은 GitHub 순서의 역순으로 뒤에 붙인다 — 빠뜨리지는 않는다.
        for commit in commits.reversed() where !placed.contains(commit.oid) {
            result.append(commit)
        }
        return result
    }
}

/// 열린 레인 목록(각 레인이 다음에 만날 커밋)을 행마다 갱신한다 — GitLane `LaneComputer` 와 같은 규칙.
/// - ① 이 커밋과 상관없는 레인 → 통과(앞에 빈자리가 생기면 왼쪽으로 당겨진다)
/// - ② 이 커밋을 기다리던 첫 레인 → 점이 그 자리에 놓이고, 첫 부모로 같은 레인(같은 색)을 이어 간다
/// - ③ 같은 커밋을 기다리던 다른 레인 → 점으로 합쳐지고 끝난다
/// - ④ 아무도 안 기다린 커밋(브랜치 끝) → 새 레인
/// - ⑤ 머지의 두 번째 이후 부모 → 그 부모를 기다리는 레인에 합류, 없으면 새 레인
/// 레인 id 는 만들어질 때 정해져, 레인이 왼쪽으로 당겨져도 색이 따라간다.
struct LaneState {
    private struct Lane {
        let id: Int
        let next: String
    }

    private var lanes: [Lane] = []
    private var nextID = 0

    func isWaiting(for oid: String) -> Bool { lanes.contains { $0.next == oid } }

    mutating func append(_ oid: String, parents: [String]) -> (lines: [CommitGraph.Line], column: Int, lane: Int) {
        var next: [Lane] = []
        var lines: [CommitGraph.Line] = []
        var column = -1
        var laneID = -1

        for (oldColumn, lane) in lanes.enumerated() {
            if lane.next != oid {
                lines.append(.init(lane: lane.id, top: oldColumn, middle: next.count, bottom: next.count))
                next.append(lane)
            } else if column < 0 {
                column = next.count
                laneID = lane.id
                if let first = parents.first {
                    next.append(Lane(id: lane.id, next: first))
                    lines.append(.init(lane: lane.id, top: oldColumn, middle: column, bottom: column))
                } else {
                    lines.append(.init(lane: lane.id, top: oldColumn, middle: column, bottom: nil))
                }
            } else {
                lines.append(.init(lane: lane.id, top: oldColumn, middle: column, bottom: nil))
            }
        }
        if column < 0 {
            column = next.count
            laneID = makeID()
            if let first = parents.first {
                next.append(Lane(id: laneID, next: first))
                lines.append(.init(lane: laneID, top: nil, middle: column, bottom: column))
            }
        }
        for parent in parents.dropFirst() {
            if let existing = next.firstIndex(where: { $0.next == parent }) {
                lines.append(.init(lane: next[existing].id, top: nil, middle: column, bottom: existing))
            } else {
                let id = makeID()
                lines.append(.init(lane: id, top: nil, middle: column, bottom: next.count))
                next.append(Lane(id: id, next: parent))
            }
        }
        lanes = next
        return (lines, column, laneID)
    }

    private mutating func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
