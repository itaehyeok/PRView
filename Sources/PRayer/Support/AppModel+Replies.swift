import Foundation
import PRayerCore

/// 내 코멘트 답글(MyCommentReplies) — 목록 행의 "답글 N" 칩과 개요 탭의 "새 답글" 줄.
///
/// 읽음은 PR 을 열 때 적는다. 열어 둔 PR 은 새로고침으로 답글이 들어와도 바로 읽은 것으로 친다 — 화면에 떠 있으니까.
/// 알림은 이것과 따로 PR 변화 감지(`PRChange.repliesToMyComments`)가 맡는다.
extension AppModel {
    /// 이 PR 에서 나에게 온 답글 수와 그중 아직 안 본 것(`MyReplyReadState.counts`).
    func replyCounts(for pr: PullRequestInfo) -> (total: Int, unread: Int) {
        guard let myReplyRead else { return (0, 0) }
        return myReplyRead.counts(in: pr, viewer: githubAccount?.login)
    }

    /// 이 스레드에서 "새 답글" 로 보일 글의 키(`MyCommentReplies.key`). 이 PR 을 열 때 안 봤던 답글이다.
    func freshReplyKeys(in thread: PRReviewThread, of pr: PullRequestInfo) -> Set<String> {
        let prefix = "\(thread.id)|"
        return Set((freshReplyIDs[pr.id] ?? []).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    func loadMyReplyRead() async {
        if var state = await store.loadMyReplyRead() {
            if state.prune() { save(myReplyRead: state) }
            myReplyRead = state
        } else {
            // 처음 켰다 — 지금까지 달린 답글은 본 것으로 친다.
            let state = MyReplyReadState(since: Date())
            myReplyRead = state
            save(myReplyRead: state)
        }
    }

    /// 목록 행의 답글 칩을 눌렀다 — 행을 누른 것처럼 고르고(`select`), 그 PR 로 옮겨 갔으면 개요 탭을 열어 첫 새 답글로 간다.
    /// 고르기를 먼저 한다 — 고를 때 안 본 답글이 "새 답글"(`freshReplyIDs`)로 옮겨 와야 개요 탭이 갈 곳을 안다.
    /// ⌘ 클릭처럼 그 PR 로 안 옮겨 갔으면 아무 데도 가지 않는다(남겨 두면 나중에 그 PR 을 열 때 뜬금없이 스크롤한다).
    func openReplies(of pr: PullRequestInfo, select: () -> Void) {
        select()
        guard selectedPRID == pr.id else { return }
        detailTab = .overview
        replyJumpPRID = pr.id
    }

    /// 다른 PR 을 골랐다. 앞 PR 의 "새 답글" 표시는 걷고, 새로 고른 PR 의 안 본 답글을 "새 답글" 로 두고 읽은 것으로 적는다.
    func openRepliesOfSelectedPR() {
        freshReplyIDs = [:]
        absorbRepliesOfSelectedPR()
    }

    /// 보고 있는 PR 의 안 본 답글을 "새 답글" 에 더하고 읽은 것으로 적는다.
    func absorbRepliesOfSelectedPR() {
        guard var state = myReplyRead, let pr = selectedPR else { return }
        let viewer = githubAccount?.login
        let unread = state.unread(in: pr, viewer: viewer)
        if !unread.isEmpty {
            freshReplyIDs[pr.id, default: []].formUnion(unread.map(\.id))
        }
        guard state.markRead(pr, viewer: viewer) else { return }
        myReplyRead = state
        save(myReplyRead: state)
    }

    private func save(myReplyRead state: MyReplyReadState) {
        Task { [store] in await store.save(myReplyRead: state) }
    }
}
