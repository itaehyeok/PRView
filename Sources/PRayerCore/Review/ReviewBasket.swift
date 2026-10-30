import Foundation

/// "리뷰에 담기" — 코드 코멘트를 하나씩 바로 다는 대신 모아 두었다가 왼쪽 리뷰(본문 + Approve 등)와 **한 리뷰로** 올린다.
///
/// 바로 달기(`pulls/N/comments`)는 코멘트마다 따로 올라가 작성자가 그 수만큼 알림을 받는다. 담아 두면 리뷰 하나
/// (`pulls/N/reviews` 의 `comments`)에 실려 알림도 한 번이고, GitHub 화면에서도 리뷰 한 덩어리로 보인다.
/// 담은 목록은 순서만 들고 글·자리는 게시할 때 만든다 — 담은 뒤 카드에서 고친 글이 그대로 올라가게.
extension ReviewRecord {
    /// 담은 지적 키(담은 순서).
    public var basketKeys: [String] { basketIssueKeys ?? [] }

    public func isInBasket(_ issue: ReviewIssue) -> Bool { basketKeys.contains(issue.key) }

    /// 담을 수 있는가. 리뷰를 이미 올렸거나(더 실을 리뷰가 없다), 그 지적을 이미 달았거나 정리했으면 못 담는다.
    public func canBasket(_ issue: ReviewIssue) -> Bool {
        !isPosted && postedComment(for: issue) == nil && !isCleared(issue.key)
    }

    /// "모두 담기" 가 담을 수 있는가 — 아직 안 담았고, 담을 수 있고, 코드 옆에 달 자리가 있다.
    /// 자리가 없는 지적은 담아도 게시 때 `missing` 이 되어 리뷰가 통째로 막힌다(카드 체크도 그때는 꺼져 있다).
    public func canAddToBasket(_ issue: ReviewIssue, diff: ParsedDiff?) -> Bool {
        canBasket(issue) && !isInBasket(issue) && codeBlockedReason(for: issue, diff: diff) == nil
    }

    /// 담거나 뺀다. 바뀌었으면 true.
    @discardableResult
    public mutating func setInBasket(_ isOn: Bool, for issue: ReviewIssue) -> Bool {
        var keys = basketKeys
        if isOn {
            guard canBasket(issue), !keys.contains(issue.key) else { return false }
            keys.append(issue.key)
        } else {
            guard keys.contains(issue.key) else { return false }
            keys.removeAll { $0 == issue.key }
        }
        basketIssueKeys = keys.isEmpty ? nil : keys
        return true
    }

    /// 지금 함께 올라갈 지적(담은 순서). 담은 뒤 바로 달았거나 정리한 것, 다시 리뷰해 없어진 것은 뺀다.
    public var basketIssues: [ReviewIssue] {
        let byKey = Dictionary(issues.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return basketKeys.compactMap { byKey[$0] }.filter(canBasket)
    }

    /// 게시할 줄 코멘트. 자리를 못 만든 지적이 하나라도 있으면 그 지적을 `missing` 에 담는다 — 부르는 쪽은 그때
    /// 올리지 않는다(담은 것 중 일부만 몰래 빠진 채 Approve 가 나가면 안 된다).
    /// `body` — 초안 없는 지적을 카드에서 고친 글(`AppModel.issueBodies`). 초안이 있으면 초안의 고친 글을 쓴다.
    public func basketComments(diff: ParsedDiff?,
                               body: (ReviewIssue) -> String? = { _ in nil }) -> (items: [BasketItem], missing: [ReviewIssue]) {
        var items: [BasketItem] = []
        var missing: [ReviewIssue] = []
        for issue in basketIssues {
            if let comment = inlineComment(for: issue, body: body(issue), diff: diff) {
                items.append(BasketItem(issue: issue, comment: comment))
            } else {
                missing.append(issue)
            }
        }
        return (items, missing)
    }

    /// 리뷰와 함께 올라간 줄 코멘트를 기록하고 담은 목록을 비운다. `posted` 는 `items` 와 같은 순서다
    /// (`ReviewBasket.match`). 짝을 못 찾은 것은 리뷰 링크로 기록한다 — 카드가 "달렸어요" 로 바뀌는 게 우선이다.
    public mutating func markBasketPosted(_ items: [BasketItem], posted: [PostedComment?], review: PostedInfo) {
        for (index, item) in items.enumerated() {
            let comment = (index < posted.count ? posted[index] : nil)
                ?? PostedComment(commentID: 0, htmlURL: review.htmlURL, postedAt: review.postedAt)
            markPostedInline(comment, for: item.issue)
        }
        basketIssueKeys = nil
    }
}

/// 리뷰와 함께 올릴 줄 코멘트 하나와 그 지적.
public struct BasketItem: Sendable {
    public var issue: ReviewIssue
    public var comment: ReviewPayload.Comment

    public init(issue: ReviewIssue, comment: ReviewPayload.Comment) {
        self.issue = issue
        self.comment = comment
    }
}

public enum ReviewBasket {
    /// 리뷰 응답에는 줄 코멘트 ID 가 없어 리뷰의 코멘트 목록을 다시 받아 보낸 것과 짝짓는다.
    /// 자리(경로·줄)와 글이 같은 것 → 자리만 같은 것 순으로 찾고, 한 번 짝지은 것은 다시 쓰지 않는다.
    /// 돌려주는 배열은 `sent` 와 같은 길이·순서다.
    public static func match(sent: [ReviewPayload.Comment], received: [ReviewCommentRef]) -> [PostedComment?] {
        var used = Set<Int>()
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func find(_ comment: ReviewPayload.Comment, sameBody: Bool) -> Int? {
            received.indices.first { index in
                let candidate = received[index]
                return !used.contains(index)
                    && candidate.path == comment.path && candidate.line == comment.line
                    && (!sameBody || normalized(candidate.body) == normalized(comment.body))
            }
        }
        var result: [PostedComment?] = Array(repeating: nil, count: sent.count)
        for pass in [true, false] {
            for (index, comment) in sent.enumerated() where result[index] == nil {
                guard let found = find(comment, sameBody: pass) else { continue }
                used.insert(found)
                result[index] = received[found].posted
            }
        }
        return result
    }
}

/// 리뷰에 실린 줄 코멘트 하나(`GitHubClient.reviewComments`). 짝짓기에 쓰는 것만 들고 있다.
public struct ReviewCommentRef: Sendable, Equatable {
    public var path: String
    public var line: Int?
    public var body: String
    public var posted: PostedComment

    public init(path: String, line: Int?, body: String, posted: PostedComment) {
        self.path = path
        self.line = line
        self.body = body
        self.posted = posted
    }
}
