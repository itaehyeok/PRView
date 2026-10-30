import Foundation
import PRayerCore

/// 변경 파일 탭 "커밋별로 보기" 의 커밋 표 재료.
struct BranchGraphState {
    var commits: BranchCommits?
    var graph: CommitGraph?
    var error: String?
}

// MARK: - 커밋별로 보기 (변경 파일 탭 맨 위 버튼, DiffCommits)

extension AppModel {
    func branchGraphState(for pr: PullRequestInfo) -> BranchGraphState? {
        branchGraphs[diffKey(for: pr)]
    }

    /// PR 브랜치의 커밋과 부모를 받아 그래프를 만든다. head 가 같으면 다시 받지 않는다(새 커밋이 오면 키가 바뀐다).
    func loadBranchGraph(for pr: PullRequestInfo, force: Bool = false) async {
        let key = diffKey(for: pr)
        guard force || branchGraphs[key]?.graph == nil, !loadingBranchKeys.contains(key) else { return }
        loadingBranchKeys.insert(key)
        defer { loadingBranchKeys.remove(key) }
        do {
            let commits: BranchCommits
            if DemoMode.isOn {
                #if DEBUG
                commits = DemoData.branchCommits(for: pr)
                #else
                return
                #endif
            } else {
                commits = try await github.branchCommits(pr.repo, number: pr.number)
            }
            let graph = await Task.detached(priority: .userInitiated) { CommitGraph(commits.commits) }.value
            branchGraphs[key] = BranchGraphState(commits: commits, graph: graph)
            // 옛 head 의 그래프는 버린다 — 새 커밋이 오면 키가 바뀌어 계속 쌓인다.
            for old in branchGraphs.keys where old != key && old.hasPrefix("\(pr.id)@") {
                branchGraphs.removeValue(forKey: old)
            }
        } catch is CancellationError {
            Log.info("커밋 목록 로딩 취소됨 \(key)", "app")
        } catch {
            Log.error("커밋 목록 로딩 실패 \(key): \(error.localizedDescription)", "app")
            branchGraphs[key] = BranchGraphState(error: error.localizedDescription)
        }
    }

    func commitDiffKey(for pr: PullRequestInfo, spec: CommitDiffSpec) -> String {
        "\(pr.repo.full)|\(spec.cacheKey)"
    }

    /// 받은 커밋 diff 를 지금 제외 규칙으로 나눈 것(변경 파일 탭과 같은 규칙 — 잠금 파일·자동 생성 파일은 따로 묶인다).
    func commitDiff(for pr: PullRequestInfo, spec: CommitDiffSpec) -> ParsedDiff? {
        let key = commitDiffKey(for: pr, spec: spec)
        guard let raw = commitDiffCache[key] else { return nil }
        let patterns = settings.excludedPathPatterns
        if let memo = commitExclusionMemo[key], memo.patterns == patterns { return memo.diff }
        let diff = raw.applyingExclusions(patterns)
        commitExclusionMemo[key] = (patterns, diff)
        return diff
    }

    func loadCommitDiff(for pr: PullRequestInfo, spec: CommitDiffSpec) async {
        let key = commitDiffKey(for: pr, spec: spec)
        guard commitDiffCache[key] == nil, !loadingCommitDiffKeys.contains(key) else { return }
        loadingCommitDiffKeys.insert(key)
        commitDiffErrors[key] = nil
        defer { loadingCommitDiffKeys.remove(key) }
        do {
            let text: String
            if DemoMode.isOn {
                #if DEBUG
                text = DemoData.commitDiff(for: spec)
                #else
                text = ""
                #endif
            } else if let cached = await store.cachedCommitDiff(repo: pr.repo, spec: spec) {
                text = cached
            } else {
                text = try await github.diff(pr.repo, spec: spec)
                await store.cacheCommitDiff(text, repo: pr.repo, spec: spec)
            }
            let parsed = await Task.detached(priority: .userInitiated) { DiffParser.parse(text) }.value
            commitDiffCache[key] = parsed
            commitExclusionMemo[key] = nil
            commitDiffOrder.removeAll { $0 == key }
            commitDiffOrder.append(key)
            // 커밋을 넘겨 가며 보면 금방 쌓인다. 화면에 다시 그릴 몇 개만 들고 있고 나머지는 디스크 캐시에서 다시 읽는다.
            while commitDiffOrder.count > 16, let oldest = commitDiffOrder.first {
                commitDiffOrder.removeFirst()
                commitDiffCache.removeValue(forKey: oldest)
                commitExclusionMemo.removeValue(forKey: oldest)
            }
        } catch is CancellationError {
            Log.info("커밋 diff 로딩 취소됨 \(key)", "app")
        } catch {
            Log.error("커밋 diff 로딩 실패 \(key): \(error.localizedDescription)", "app", problem: .diffLoadFailed)
            commitDiffErrors[key] = error.localizedDescription
        }
    }
}
