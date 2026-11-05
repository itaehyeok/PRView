import Foundation

/// 내 코멘트 답글을 어디까지 봤나. 목록의 "답글 N" 칩과 개요 탭의 "새 답글" 줄이 이것을 본다.
///
/// 알림 기억(`PRSnapshot`)과 따로 둔다 — 그쪽은 새로고침마다 덮여서, 그걸로 칩을 그리면 PR 을 열어 보지 않았는데도
/// 다음 새로고침에 칩이 사라진다.
public struct MyReplyReadState: Codable, Sendable, Equatable {
    /// 이 기능을 처음 켠 시각. 그 전에 달린 답글은 본 것으로 친다 — 업데이트하자마자 지난 답글이 전부 새 것으로 뜨면 안 된다.
    public var since: Date
    /// 스레드별로 본 마지막 글의 시각.
    public var seenUpTo: [String: Date]

    /// 이만큼 지난 스레드 기록은 버린다. 그보다 오래된 답글은 `since` 를 그만큼 당겨 본 것으로 친다.
    public static let memory: TimeInterval = 60 * 24 * 3600

    public init(since: Date, seenUpTo: [String: Date] = [:]) {
        self.since = since
        self.seenUpTo = seenUpTo
    }

    public func isUnread(_ reply: MyCommentReply) -> Bool {
        reply.at > max(since, seenUpTo[reply.threadID] ?? .distantPast)
    }

    public func unread(in pr: PullRequestInfo, viewer: String?) -> [MyCommentReply] {
        MyCommentReplies.replies(in: pr, viewer: viewer).filter(isUnread)
    }

    /// 목록 답글 칩의 수 — 나에게 온 답글 전부와 그중 안 본 것. 칩은 전부를 적고, 안 본 것이 있을 때만 꽉 채운다
    /// (다 보면 테두리만 남는다). 전부를 적어야 다 본 뒤에도 숫자가 줄지 않는다 — 안 본 것만 세면 새 답글이
    /// 하나 오는 순간 "답글 3" 이 "답글 1" 로 줄었다.
    public func counts(in pr: PullRequestInfo, viewer: String?) -> (total: Int, unread: Int) {
        let replies = MyCommentReplies.replies(in: pr, viewer: viewer)
        return (replies.count, replies.filter(isUnread).count)
    }

    /// PR 을 열어 봤다 — 내가 참여한 스레드는 지금 받아 둔 글까지 본 것이다.
    /// 지금 시각이 아니라 마지막 글의 시각을 적는다: 맥 시계와 GitHub 시계가 어긋나도 열어 본 뒤에 달린 답글을 놓치지 않게.
    /// - Returns: 바뀐 것이 있는가(저장할지 정한다).
    @discardableResult
    public mutating func markRead(_ pr: PullRequestInfo, viewer: String?) -> Bool {
        guard let me = viewer?.lowercased(), !me.isEmpty else { return false }
        var changed = false
        for thread in pr.threads where thread.comments.contains(where: { $0.author.lowercased() == me }) {
            guard let latest = thread.comments.compactMap({ PRActivityBuilder.isoDate($0.createdAt) }).max(),
                  latest > (seenUpTo[thread.id] ?? .distantPast) else { continue }
            seenUpTo[thread.id] = latest
            changed = true
        }
        return changed
    }

    /// 오래된 스레드 기록을 버린다. 버린 스레드에 남은 옛 답글이 다시 새 것으로 뜨지 않게 `since` 를 같이 당긴다.
    @discardableResult
    public mutating func prune(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.memory)
        let before = seenUpTo.count
        seenUpTo = seenUpTo.filter { $0.value >= cutoff }
        guard seenUpTo.count != before else { return false }
        since = max(since, cutoff)
        return true
    }
}
