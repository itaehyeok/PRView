import Foundation
import PRayerCore

extension AppModel {
    /// 머지 확인 줄의 방식 메뉴. 못 받으면 세 방식을 다 보인다(막힌 방식이면 GitHub 이 이유와 함께 거절한다).
    func mergeOptions(for repo: RepoID) async -> MergeOptions {
        do {
            return try await github.mergeOptions(repo)
        } catch {
            Log.error("머지 방식 조회 실패 \(repo.full): \(error.localizedDescription)", "merge")
            return .fallback
        }
    }

    /// 내 PR 을 머지한다. 확인 줄의 "머지하기" 만 부른다.
    ///
    /// 화면에서 본 head 로만 머지한다(`expectedHead`). 성공이든 실패든 그 PR 을 다시 받는다 —
    /// 성공이면 머지됨 줄로 바뀌고, 새 커밋 때문에 거절됐으면 화면이 그 커밋을 보여 준다.
    func merge(_ pr: PullRequestInfo, method: MergeMethod) async throws {
        do {
            let sha = try await github.mergePullRequest(pr.repo, number: pr.number, method: method,
                                                        expectedHead: pr.headRefOid)
            Log.info("머지 \(pr.id) \(method.rawValue) → \(String(sha.prefix(7)))", "merge")
        } catch {
            Log.error("머지 실패 \(pr.id): \(error.localizedDescription)", "merge", problem: .mergeFailed)
            await refreshOne(repo: pr.repo, number: pr.number)
            throw error
        }
        await refreshOne(repo: pr.repo, number: pr.number)
    }
}
