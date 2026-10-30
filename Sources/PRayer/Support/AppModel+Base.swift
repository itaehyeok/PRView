import Foundation
import PRayerCore

// MARK: - base 브랜치 바꾸기 (PR 머리 줄의 받는 쪽 칩, BaseBranchPicker)

extension AppModel {
    /// 고르기 칸 맨 위 후보 — 이 레포의 다른 PR 들이 실제로 향하는 브랜치와 기본 브랜치. 많이 쓰는 순서.
    /// 브랜치가 수천 개인 레포에서도 base 로 고를 것은 대개 이 몇 개 안에 있다.
    func suggestedBases(for pr: PullRequestInfo, defaultBranch: String?) -> [String] {
        var counts: [String: Int] = [:]
        for other in prs where other.repo == pr.repo && !other.baseRefName.isEmpty {
            counts[other.baseRefName, default: 0] += 1
        }
        if let defaultBranch, counts[defaultBranch] == nil { counts[defaultBranch] = 0 }
        if counts[pr.baseRefName] == nil, !pr.baseRefName.isEmpty { counts[pr.baseRefName] = 0 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    func searchBranches(for pr: PullRequestInfo, matching query: String) async throws -> BranchSearchResult {
        guard !DemoMode.isOn else {
            let names = ["main", "develop", "release/2.4", "feature/login-a11y", "feature/sdk-upgrade"]
            let found = query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
            return BranchSearchResult(defaultBranch: "main", names: found, totalCount: found.count)
        }
        return try await github.searchBranches(pr.repo, matching: query)
    }

    /// base 를 바꾸고 그 PR 을 다시 받는다. 고르기 칸의 확인 버튼만 부른다.
    /// diff·커밋 목록은 다시 받은 PR 의 base 가 달라진 것을 보고 `replace(with:)` 가 버린다.
    func changeBase(_ pr: PullRequestInfo, to base: String) async throws {
        guard !DemoMode.isOn else {
            var changed = pr
            changed.baseRefName = base
            replace(with: changed)
            return
        }
        do {
            let ref = try await github.changeBase(pr.repo, number: pr.number, to: base)
            Log.info("base 바꿈 \(pr.id) \(pr.baseRefName) → \(ref)", "base")
        } catch {
            Log.error("base 바꾸기 실패 \(pr.id) → \(base): \(error.localizedDescription)", "base", problem: .baseChangeFailed)
            throw error
        }
        await refreshOne(repo: pr.repo, number: pr.number)
    }
}
