import Foundation

/// 목록 행을 ⌘·⇧ 클릭으로 여러 개 고르는 규칙 — Finder·메일과 같다.
///
/// "내가 올린 PR"(슬랙 리뷰 요청)과 리뷰 목록(한꺼번에 리뷰)이 같은 규칙을 쓴다. 두 목록은 따로 고른다 —
/// 고른 것이 섞이면 우클릭 메뉴가 무엇을 다루는지 흐려진다(슬랙 요청은 내 PR 만, 리뷰는 남의 PR 만 뜻이 있다).
public struct RowSelection: Equatable, Sendable {
    /// 같이 고른 행(키: pr.id). 둘 이상일 때만 뜻이 있다 — 하나면 그냥 고른 PR 이다.
    public var ids: Set<String>
    /// ⇧ 클릭으로 범위를 고를 때의 시작점.
    public var anchor: String?

    public enum Modifier: Sendable { case none, command, shift }

    public init(ids: Set<String> = [], anchor: String? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    /// 여럿을 같이 골랐는가.
    public var isMultiple: Bool { ids.count > 1 }

    /// 같이 고른 것으로 보이는가(둘 이상 골랐을 때만).
    public func isMarked(_ id: String) -> Bool {
        isMultiple && ids.contains(id)
    }

    /// 행 하나를 눌렀다. ⌘ 는 하나씩 더하고 빼고, ⇧ 는 시작점부터 범위로.
    ///
    /// - Parameters:
    ///   - list: 그 행이 있는 목록의 순서(화면 위에서 아래로).
    ///   - current: 지금 오른쪽에 보고 있는 PR.
    /// - Returns: 이제 볼 PR. nil 이면 보고 있던 것을 그대로 둔다.
    public mutating func click(_ id: String, in list: [String], current: String?, modifier: Modifier) -> String? {
        switch modifier {
        case .command:
            // 지금 보고 있는 하나도 같이 고른 것으로 친다 — 그래야 ⌘ 클릭 한 번이 "둘" 이 된다.
            var chosen = ids
            if chosen.isEmpty, let current, list.contains(current) {
                chosen.insert(current)
            }
            anchor = id
            if chosen.contains(id) {
                chosen.remove(id)
                ids = chosen
                // 보고 있던 것을 뺐으면 남은 것 중 하나를 본다.
                guard current == id else { return nil }
                return list.first { chosen.contains($0) }
            }
            chosen.insert(id)
            ids = chosen
            return id
        case .shift:
            if let start = anchor ?? current,
               let from = list.firstIndex(of: start),
               let to = list.firstIndex(of: id) {
                ids = Set(list[min(from, to)...max(from, to)])
                return id
            }
        case .none:
            break
        }
        ids = [id]
        anchor = id
        return id
    }

    /// 방향키로 한 칸 옮겼다. ⇧ 면 시작점은 두고 범위를 늘이거나 줄인다 — Finder·메일과 같다.
    ///
    /// - Parameters:
    ///   - delta: 위 -1 · 아래 +1.
    ///   - current: 지금 보고 있는 PR. 움직이는 쪽 끝이다 — ⇧ 클릭도 누른 행을 보게 하므로 맞물린다.
    /// - Returns: 이제 볼 PR. 목록 끝에서 더 가려 하거나 보고 있는 PR 이 이 목록에 없으면 nil.
    public mutating func move(by delta: Int, in list: [String], current: String?, extend: Bool) -> String? {
        guard let current, let index = list.firstIndex(of: current) else { return nil }
        let target = index + delta
        guard list.indices.contains(target) else { return nil }
        let id = list[target]
        guard extend else {
            ids = [id]
            anchor = id
            return id
        }
        // 시작점이 필터로 안 보이게 됐으면 지금 보던 행에서 다시 시작한다.
        let start: Int
        if let anchor, let anchorIndex = list.firstIndex(of: anchor) {
            start = anchorIndex
        } else {
            start = index
            anchor = current
        }
        ids = Set(list[min(start, target)...max(start, target)])
        return id
    }

    /// 우클릭한 행으로 다룰 것들. 같이 고른 것 안에서 눌렀으면 고른 것 전부(목록 순서), 밖이면 그것 하나 —
    /// Finder 와 같은 규칙. 고른 것이 목록에서 다 빠졌으면(필터·새로고침) 그것 하나.
    public func targets(for id: String, in list: [String]) -> [String] {
        guard isMarked(id) else { return [id] }
        let chosen = list.filter { ids.contains($0) }
        return chosen.isEmpty ? [id] : chosen
    }
}
