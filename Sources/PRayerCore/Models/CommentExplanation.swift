import Foundation

/// 남이 쓴 코멘트 하나를 쉬운 말로 풀어 놓은 것. 리뷰가 아니라 통역이다.
public struct CommentExplanation: Sendable, Codable, Hashable, Identifiable {
    public struct Term: Sendable, Codable, Hashable, Identifiable {
        public var term: String
        public var meaning: String
        public var id: String { term }

        public init(term: String, meaning: String) {
            self.term = term
            self.meaning = meaning
        }
    }

    /// 어떤 코멘트를 설명한 것인가. 스레드 id 또는 작성자+시각으로 만든 키.
    public var key: String
    public var point: String
    public var detail: String
    public var action: String
    public var terms: [Term]
    public var isQuestion: Bool
    public var createdAt: Date
    public var usage: EngineUsage

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, point, detail, action, terms
        case isQuestion = "is_question"
        case createdAt, usage
    }

    public init(key: String, point: String, detail: String, action: String,
                terms: [Term], isQuestion: Bool, createdAt: Date = Date(),
                usage: EngineUsage = EngineUsage()) {
        self.key = key
        self.point = point
        self.detail = detail
        self.action = action
        self.terms = terms
        self.isQuestion = isQuestion
        self.createdAt = createdAt
        self.usage = usage
    }
}

/// 모델이 돌려주는 형태(키·시각·사용량은 앱이 채운다).
struct ExplanationOutput: Sendable, Codable {
    var point: String
    var detail: String
    var action: String
    var terms: [CommentExplanation.Term]
    var isQuestion: Bool

    enum CodingKeys: String, CodingKey {
        case point, detail, action, terms
        case isQuestion = "is_question"
    }
}

/// 설명할 대상 1건. 인라인 스레드와 대화 코멘트를 같은 방식으로 다룬다.
public struct ExplainTarget: Sendable, Hashable {
    public var key: String
    public var author: String
    public var body: String
    /// 답글까지 포함한 나머지 대화(있으면).
    public var replies: [String]
    public var path: String?
    public var line: Int?

    public init(key: String, author: String, body: String, replies: [String] = [],
                path: String? = nil, line: Int? = nil) {
        self.key = key
        self.author = author
        self.body = body
        self.replies = replies
        self.path = path
        self.line = line
    }

    public init(thread: PRReviewThread) {
        let comments = thread.comments
        self.init(key: "thread:\(thread.id)",
                  author: comments.first?.author ?? "unknown",
                  body: comments.first?.body ?? "",
                  replies: comments.dropFirst().map { "\($0.author): \($0.body)" },
                  path: thread.path,
                  line: thread.line)
    }

    public init(comment: PRIssueComment) {
        self.init(key: "comment:\(comment.author):\(Int(comment.createdAt.timeIntervalSince1970))",
                  author: comment.author,
                  body: comment.body)
    }
}
