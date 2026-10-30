import Foundation

/// PR 대화·커밋을 GitHub 처럼 시간순 한 줄기로 본다.
/// 사람 리뷰와 커밋을 따로 두면 "이 코멘트가 어느 커밋 전인지" 를 눈으로 못 맞춘다.
public enum PRTimelineEntry: Identifiable, Sendable, Hashable {
    /// 인라인 코드 코멘트 스레드(답글 포함).
    case thread(PRReviewThread, at: Date)
    /// 리뷰 제출(승인·변경요청·본문 있는 코멘트). 인라인 스레드로 이미 보이는 것은 넣지 않는다.
    case review(PRReviewEvent)
    /// PR 대화 코멘트(claude[bot] 요약 등 봇 코멘트도 포함).
    case comment(PRIssueComment)
    case commit(PRCommit)

    public var at: Date {
        switch self {
        case .thread(_, let at): return at
        case .review(let review): return review.submittedAt
        case .comment(let comment): return comment.createdAt
        case .commit(let commit): return commit.committedDate
        }
    }

    public var author: String {
        switch self {
        case .thread(let thread, _): return thread.comments.first?.author ?? ""
        case .review(let review): return review.author
        case .comment(let comment): return comment.author
        case .commit(let commit): return commit.author
        }
    }

    public var id: String {
        switch self {
        case .thread(let thread, _): return "thread:\(thread.id)"
        case .review(let review): return "review:\(review.author):\(review.submittedAt.timeIntervalSince1970)"
        case .comment(let comment): return "comment:\(comment.author):\(comment.createdAt.timeIntervalSince1970)"
        case .commit(let commit): return "commit:\(commit.oid)"
        }
    }
}

public enum PRTimelineBuilder {
    /// 오래된 것부터. GitHub 대화 탭과 같은 순서다.
    public static func build(from pr: PullRequestInfo) -> [PRTimelineEntry] {
        var entries: [PRTimelineEntry] = []

        var threadTimes: [(author: String, at: Date)] = []
        for thread in pr.threads {
            guard let first = thread.comments.first,
                  let at = PRActivityBuilder.isoDate(first.createdAt) else { continue }
            entries.append(.thread(thread, at: at))
            // 답글까지 센다. 남이 연 스레드에 단 답글도 GitHub 이 본문 없는 COMMENTED 리뷰로 하나씩 감싸는데,
            // 스레드를 연 첫 코멘트만 보면 그 빈 리뷰가 짝을 못 찾아 "○○ 리뷰" 빈 줄로 남았다(사용자 제보).
            for comment in thread.comments {
                if let time = PRActivityBuilder.isoDate(comment.createdAt) {
                    threadTimes.append((comment.author, time))
                }
            }
        }

        for review in pr.reviewEvents {
            let body = review.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasOwnThread = threadTimes.contains {
                $0.author == review.author && abs($0.at.timeIntervalSince(review.submittedAt)) < 300
            }
            // 본문 없는 COMMENTED 리뷰는 인라인 스레드의 껍데기일 뿐이라 줄만 차지한다.
            if body.isEmpty, review.state.uppercased() == "COMMENTED", hasOwnThread { continue }
            entries.append(.review(review))
        }

        for comment in pr.issueComments {
            entries.append(.comment(comment))
        }

        for commit in pr.commits {
            entries.append(.commit(commit))
        }

        return entries.sorted {
            $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at
        }
    }
}
