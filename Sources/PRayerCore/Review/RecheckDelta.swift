import Foundation

/// 리뷰를 만든 뒤로 이 PR 에 무엇이 더 올라왔는가.
///
/// 전부 이미 받아 둔 `PullRequestInfo` 만 훑어 만든다. 새 커밋도 새 코멘트도 없으면
/// **모델을 부르지 않는다** — 물어볼 것이 없는데 토큰을 쓸 이유가 없다.
public struct RecheckDelta: Sendable, Equatable {
    public struct Comment: Sendable, Equatable {
        public var author: String
        public var body: String
        public var at: Date
        /// 인라인 코멘트면 그 자리.
        public var path: String?
        public var line: Int?
        public var isResolvedThread: Bool

        public init(author: String, body: String, at: Date,
                    path: String? = nil, line: Int? = nil, isResolvedThread: Bool = false) {
            self.author = author
            self.body = body
            self.at = at
            self.path = path
            self.line = line
            self.isResolvedThread = isResolvedThread
        }
    }

    public var newCommits: [PRCommit]
    public var newComments: [Comment]
    /// 리뷰한 커밋을 목록에서 찾아 경계를 정확히 잡았는가.
    /// 못 찾으면 시각으로 어림잡는데, 그 결과는 "대략" 이라고 말해야 한다.
    public var commitBoundaryExact: Bool

    public var isEmpty: Bool { newCommits.isEmpty && newComments.isEmpty }

    public init(newCommits: [PRCommit], newComments: [Comment], commitBoundaryExact: Bool) {
        self.newCommits = newCommits
        self.newComments = newComments
        self.commitBoundaryExact = commitBoundaryExact
    }
}

public enum RecheckDeltaBuilder {
    /// 리뷰 이후에 생긴 커밋과 코멘트를 추린다.
    public static func compute(pr: PullRequestInfo, record: ReviewRecord) -> RecheckDelta {
        // 경계는 **리뷰가 본 스냅샷의 GitHub 시각**이다. record.createdAt 은 로컬 맥 시계로
        // 모델이 끝난 뒤에 찍히므로, 리뷰가 도는 동안 달린 코멘트가 양쪽 어디에도 안 걸린다.
        let boundary = record.snapshotUpdatedAt ?? record.createdAt
        // 커밋은 **해시로** 자른다. 시각으로 자르면 리베이스·체리픽처럼 커밋 시각이 과거인
        // 커밋이 통째로 빠진다(작성 시각과 올라온 시각은 다르다).
        let ordered = pr.commits.sorted { $0.committedDate < $1.committedDate }
        var exact = true
        let newCommits: [PRCommit]
        if let index = ordered.firstIndex(where: { $0.oid == record.headSha }) {
            newCommits = Array(ordered.suffix(from: ordered.index(after: index)))
        } else {
            // 리뷰한 커밋이 목록에 없다(force-push 되었거나 30개 밖으로 밀려났다).
            exact = false
            newCommits = ordered.filter { $0.committedDate > boundary }
        }

        var comments: [RecheckDelta.Comment] = []
        for comment in pr.issueComments where comment.createdAt > boundary {
            guard !isOurOwnPost(comment.body) else { continue }
            comments.append(RecheckDelta.Comment(author: comment.author,
                                                 body: comment.body,
                                                 at: comment.createdAt))
        }
        for event in pr.reviewEvents where event.submittedAt > boundary {
            let body = event.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !isOurOwnPost(body) else { continue }
            comments.append(RecheckDelta.Comment(author: event.author, body: body, at: event.submittedAt))
        }
        for thread in pr.threads {
            for reply in thread.comments {
                // 시각을 못 읽으면 **버린다.** 0 으로 두면 전부 "리뷰 이전" 으로 몰려
                // 새 답글이 조용히 사라진다.
                guard let at = PRActivityBuilder.isoDate(reply.createdAt), at > boundary else { continue }
                guard !isOurOwnPost(reply.body) else { continue }
                comments.append(RecheckDelta.Comment(author: reply.author,
                                                     body: reply.body,
                                                     at: at,
                                                     path: thread.path,
                                                     line: thread.line,
                                                     isResolvedThread: thread.isResolved))
            }
        }
        comments.sort { $0.at < $1.at }
        return RecheckDelta(newCommits: newCommits, newComments: comments, commitBoundaryExact: exact)
    }

    /// 이 앱이 올린 글인가. 우리가 올린 리뷰를 "새 코멘트" 로 도로 읽으면
    /// 자기가 한 말을 근거로 판단하게 된다.
    static func isOurOwnPost(_ body: String) -> Bool {
        body.contains("<!-- \(AppInfo.markerPrefix):\(AppInfo.markerVersion):")
    }
}
