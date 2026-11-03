import Foundation
import PRayerCore

/// 승인한 뒤 생긴 일 — 이유 칩(`PRBadgeFollowUp.sinceApproval`).
///
/// 2026-11-02 사용자 결정: 리뷰 대기에는 나를 부른 것(다시 요청·승인 취소)만 다시 온다. 승인한 뒤 커밋이 올라온 PR 은 칩에
/// 마우스를 올리면 무엇이 바뀌었는지(내 코멘트 단 파일·코드·문서·강제 푸시) 짧게 보인다.
extension AppModel {
    /// 승인한 커밋...head. 바뀐 것이 없거나 승인이 살아 있지 않으면 nil.
    func sinceApprovalKey(_ pr: PullRequestInfo) -> String? {
        guard pr.isOpen, pr.viewerApprovalAlive, let base = pr.viewerApprovedCommit, base != pr.headRefOid else { return nil }
        return "\(pr.repo.full)|\(base)...\(pr.headRefOid)"
    }

    func sinceApproval(for pr: PullRequestInfo) -> SinceApproval? {
        sinceApprovalKey(pr).flatMap { sinceApprovals[$0] }
    }

    /// 승인 뒤 무엇이 바뀌었는지 아직 모르는 PR 을 받는다 — 지금 탭과 Approved 탭(뒤에서 받은 것)의 열린 PR 중
    /// 승인한 뒤 커밋이 온 것. 같은 비교는 다시 받지 않고, 실패한 것은 10분 뒤에 다시 받는다.
    func loadSinceApprovals() {
        guard !DemoMode.isOn, sinceApprovalTask == nil else { return }
        let lists = [prs, listCache[scope(for: .myApprovals).storageValue] ?? []]
        let now = Date()
        var seen = Set<String>()
        var targets: [(key: String, pr: PullRequestInfo)] = []
        for pr in lists.joined() {
            guard let key = sinceApprovalKey(pr), seen.insert(key).inserted, sinceApprovals[key] == nil else { continue }
            if let failed = sinceApprovalFailedAt[key], now.timeIntervalSince(failed) < 600 { continue }
            targets.append((key, pr))
        }
        guard !targets.isEmpty else { return }
        let login = githubAccount?.login
        sinceApprovalTask = Task { [weak self] in
            for (key, pr) in targets {
                guard let self, !Task.isCancelled else { return }
                guard let base = pr.viewerApprovedCommit else { continue }
                let commented = Set(pr.threads.filter { $0.comments.first?.author == login }.compactMap(\.path))
                do {
                    let since = try await self.github.sinceApproval(pr.repo, base: base, head: pr.headRefOid,
                                                                    commentedPaths: commented)
                    self.sinceApprovals[key] = since
                } catch {
                    self.sinceApprovalFailedAt[key] = Date()
                    Log.info("승인 뒤 비교 실패 \(pr.id): \(error.localizedDescription)", "github")
                }
            }
            self?.sinceApprovalTask = nil
            // 받는 사이 새로 생긴 것(다음 갱신)이 있으면 이어서 받는다.
            self?.loadSinceApprovals()
        }
    }
}
