import Foundation

/// "이미 언급됨" 판정 프롬프트. 코드 본문은 보내지 않는다 — 초안이 짚은 사안과
/// PR 에 오간 코멘트만 대조하면 되는 일이다.
public enum RelevancePromptBuilder {
    /// 메시지 한 건에서 보낼 최대 길이. 봇 리뷰 총평은 4천 자를 넘기도 한다(실측 3,808자).
    public static let maxBodyChars = 1_600
    /// 프롬프트 전체 본문 예산. 넘으면 오래된 메시지부터 뺀다.
    public static let maxTotalChars = 14_000

    public struct Target: Sendable {
        public var path: String
        public var line: Int?
        public var body: String
        public var rationale: String?

        public init(path: String, line: Int?, body: String, rationale: String? = nil) {
            self.path = path
            self.line = line
            self.body = body
            self.rationale = rationale
        }
    }

    public static func build(pr: PullRequestInfo,
                             target: Target,
                             discussion: RelatedDiscussion) -> String {
        var parts: [String] = []
        parts.append("<pr title=\"\(PromptBuilder.sanitize(pr.title))\" author=\"\(pr.author)\" />")

        var item = ["<item path=\"\(target.path)\"" + (target.line.map { " line=\"\($0)\"" } ?? "") + ">"]
        item.append(PromptBuilder.sanitize(target.body).prefix(1_200).description)
        if let rationale = target.rationale, !rationale.isEmpty {
            item.append("<rationale>\(PromptBuilder.sanitize(rationale).prefix(700))</rationale>")
        }
        item.append("</item>")
        parts.append(item.joined(separator: "\n"))

        parts.append(messagesBlock(discussion: discussion, prAuthor: pr.author))
        return parts.joined(separator: "\n\n")
    }

    /// 오래된 것부터 넣고, 예산을 넘으면 **앞쪽(오래된 것)** 을 버린다.
    /// 결론은 대화 끝에 나오므로 최근 것을 남기는 쪽이 맞다.
    static func messagesBlock(discussion: RelatedDiscussion, prAuthor: String) -> String {
        var rendered: [(id: String, text: String)] = []
        for thread in discussion.threads {
            for message in thread.messages {
                let place = [thread.path.map { "path=\"\($0)\"" },
                             thread.line.map { "line=\"\($0)\"" },
                             thread.isResolved ? "resolved=\"true\"" : nil,
                             thread.isOutdated ? "outdated=\"true\"" : nil]
                    .compactMap { $0 }
                    .joined(separator: " ")
                rendered.append((message.id, render(message, kind: "inline", extra: place)))
            }
        }
        for message in discussion.comments {
            rendered.append((message.id, render(message, kind: "conversation", extra: "")))
        }
        guard !rendered.isEmpty else { return "<messages>없음</messages>" }

        var total = rendered.reduce(0) { $0 + $1.text.count }
        var start = 0
        while total > maxTotalChars, start < rendered.count - 1 {
            total -= rendered[start].text.count
            start += 1
        }
        let kept = rendered[start...].map(\.text)
        return "<messages>\n" + kept.joined(separator: "\n") + "\n</messages>"
    }

    private static func render(_ message: RelatedDiscussion.Message, kind: String, extra: String) -> String {
        var attributes = ["id=\"\(message.id)\"",
                          "author=\"\(message.author)\"",
                          "kind=\"\(kind)\""]
        if message.isAuthorReply { attributes.append("author_is_pr_author=\"true\"") }
        if let at = message.at { attributes.append("at=\"\(at.ISO8601Format())\"") }
        if !extra.isEmpty { attributes.append(extra) }
        let body = PromptBuilder.sanitize(message.body).prefix(maxBodyChars)
        return "<message \(attributes.joined(separator: " "))>\n\(body)\n</message>"
    }
}
