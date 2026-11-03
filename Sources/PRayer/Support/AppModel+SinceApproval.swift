import Foundation
import PRayerCore

/// 승인한 뒤 생긴 일 — 이유 칩(`PRBadgeFollowUp.sinceApproval`)과 Approved 탭의 new 표시.
///
/// 2026-11-02 사용자 결정: 리뷰 대기에는 나를 부른 것(다시 요청·승인 취소)만 다시 온다. 승인한 뒤 커밋이 올라온 PR 은 Approved
/// 탭에서 new 점으로 알리고, 칩에 마우스를 올리면 무엇이 바뀌었는지(내 코멘트 단 파일·코드·문서·강제 푸시) 짧게 보인다.
/// PR 을 열면 new 가 꺼진다 — "새 답글" 과 같은 규칙이다.
extension AppModel {
    /// 승인한 커밋...head. 바뀐 것이 없거나 승인이 살아 있지 않으면 nil.
    func sinceApprovalKey(_ pr: PullRequestInfo) -> String? {
        guard pr.isOpen, pr.viewerApprovalAlive, let base = pr.viewerApprovedCommit, base != pr.headRefOid else { return nil }
        return "\(pr.repo.full)|\(base)...\(pr.headRefOid)"
    }

    func sinceApproval(for pr: PullRequestInfo) -> SinceApproval? {
        sinceApprovalKey(pr).flatMap { sinceApprovals[$0] }
    }

    /// 승인 뒤 새로 생긴 일을 아직 안 봤나. base 를 받아온 머지뿐이면 볼 것이 없어 알리지 않는다.
    func hasApprovalNews(_ pr: PullRequestInfo) -> Bool {
        guard sinceApprovalKey(pr) != nil else { return false }
        if sinceApproval(for: pr)?.kind == .baseMergeOnly { return false }
        return seenApprovalNews[pr.id] != pr.headRefOid
    }

    /// Approved 탭 칩에 붙는 new 수. 그 탭을 열지 않아도 뒤에서 받은 목록(`refreshInBackground`)으로 센다.
    var approvalNewsCount: Int {
        _ = backgroundListVersion  // 뒤에서 받은 목록이 바뀌면 다시 센다
        let list = listScope.kind == .myApprovals ? prs : (listCache[scope(for: .myApprovals).storageValue] ?? [])
        return list.filter { hasApprovalNews($0) }.count
    }

    /// 열었다 — 이 head 까지 본 것으로 적는다.
    func markApprovalNewsSeen(_ prID: String) {
        guard let pr = prs.first(where: { $0.id == prID }) ?? knownPRs[prID], hasApprovalNews(pr) else { return }
        seenApprovalNews[pr.id] = pr.headRefOid
        if seenApprovalNews.count > 300 {
            // 오래된 것부터 지울 기준이 없어, 지금 아는 PR 것만 남긴다.
            seenApprovalNews = seenApprovalNews.filter { knownPRs[$0.key] != nil }
        }
        UserDefaults.standard.set(seenApprovalNews, forKey: Self.seenApprovalNewsKey)
    }

    static let seenApprovalNewsKey = "seenApprovalNews"

    func loadSeenApprovalNews() {
        seenApprovalNews = UserDefaults.standard.dictionary(forKey: Self.seenApprovalNewsKey) as? [String: String] ?? [:]
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
