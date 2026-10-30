import Foundation

/// 브랜치 하나(또는 `hotfix/*` 같은 패턴)에 걸린 "머지하려면 Approve 몇 명" 규칙.
public struct ApprovalRule: Sendable, Equatable {
    public var branch: String
    public var count: Int

    public init(branch: String, count: Int) {
        self.branch = branch
        self.count = count
    }
}

/// 같은 Approve 수끼리 묶은 브랜치들. 설정의 레포 줄이 그린다 — 묶음이 하나면 "Approve N명 필요" 만 보이고,
/// 여럿이면 기준 수만 보이고 ⓘ 로 묶음별 수를 편다(RepoConfigRow). PR 마다 그 PR 이 향하는 브랜치의 묶음으로 센다.
///
/// 브랜치가 아니라 **수를** 앞에 두는 이유: 사람이 알고 싶은 것은 "몇 명이 Approve 하면 되나" 다.
/// 브랜치 이름을 손으로 치게 했던 때는 오타가 나도 조용히 기본값(3명)으로 떨어졌다.
public struct ApprovalGroup: Codable, Sendable, Equatable, Identifiable {
    public var count: Int
    public var branches: [String]

    public var id: Int { count }

    public init(count: Int, branches: [String]) {
        self.count = count
        self.branches = branches
    }
}

public enum ApprovalGroups {
    /// 규칙을 Approve 수로 묶는다. 수가 큰 묶음이 앞이고, 묶음 안에서는 기본 브랜치 → 이름이 정해진 브랜치 → 패턴 순이다.
    /// 같은 브랜치가 두 번 오면(옛 보호 규칙과 새 규칙) 부르는 쪽이 `merge` 로 먼저 하나로 합친다.
    public static func group(_ rules: [ApprovalRule], defaultBranch: String?) -> [ApprovalGroup] {
        var byCount: [Int: [String]] = [:]
        for rule in rules where !(byCount[rule.count]?.contains(rule.branch) ?? false) {
            byCount[rule.count, default: []].append(rule.branch)
        }
        return byCount.keys.sorted(by: >).map { count in
            ApprovalGroup(count: count, branches: ordered(byCount[count] ?? [], defaultBranch: defaultBranch))
        }
    }

    /// 이 브랜치에 걸리는 묶음. 이름이 같은 것을 먼저 찾고, 없으면 패턴으로 맞춰 본다.
    public static func group(containing branch: String, in groups: [ApprovalGroup]) -> ApprovalGroup? {
        if let exact = groups.first(where: { $0.branches.contains(branch) }) { return exact }
        return groups.first { group in
            group.branches.contains { isPattern($0) && Glob.matches(path: branch, pattern: $0) }
        }
    }

    /// 묶음을 고르면 저장해 둘 대표 브랜치. 다음에 다시 읽을 때 이 브랜치가 든 묶음의 수를 쓰므로,
    /// 고른 Approve 수가 새로고침에 되돌아가지 않는다. 패턴(`hotfix/*`)은 실제 브랜치 이름이 아니라
    /// 이름이 정해진 것을 먼저 쓴다(묶음 안에서 기본 브랜치가 맨 앞이다).
    public static func representative(of group: ApprovalGroup) -> String {
        group.branches.first(where: { !isPattern($0) }) ?? group.branches.first ?? ""
    }

    /// 옛 브랜치 보호 규칙(패턴)과 새 규칙(이름별)을 합친다.
    /// 같은 브랜치에 둘 다 걸리면 큰 쪽이 실제 조건이다 — 둘 다 지켜야 머지된다.
    public static func merge(legacy: [ApprovalRule], rulesets: [ApprovalRule]) -> [ApprovalRule] {
        var result = legacy
        for rule in rulesets {
            if let index = result.firstIndex(where: { $0.branch == rule.branch }) {
                result[index].count = max(result[index].count, rule.count)
                continue
            }
            // 이름은 처음이어도 옛 규칙의 패턴에 걸릴 수 있다(예: hotfix/x 와 hotfix/*). 그때도 큰 쪽이 조건이다.
            let byPattern = legacy
                .filter { isPattern($0.branch) && Glob.matches(path: rule.branch, pattern: $0.branch) }
                .map(\.count)
                .max() ?? 0
            result.append(ApprovalRule(branch: rule.branch, count: max(rule.count, byPattern)))
        }
        return result
    }

    static func isPattern(_ branch: String) -> Bool {
        branch.contains("*") || branch.contains("?") || branch.contains("[")
    }

    private static func ordered(_ branches: [String], defaultBranch: String?) -> [String] {
        branches.sorted { a, b in
            let (ra, rb) = (rank(a, defaultBranch), rank(b, defaultBranch))
            if ra != rb { return ra < rb }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private static func rank(_ branch: String, _ defaultBranch: String?) -> Int {
        if branch == defaultBranch { return 0 }
        return isPattern(branch) ? 2 : 1
    }
}
