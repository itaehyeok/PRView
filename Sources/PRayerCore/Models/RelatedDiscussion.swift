import Foundation

/// "이미 언급됨" 뒤에 붙는 실제 대화. 리뷰 초안이 가리키는 지적이 PR 안에서
/// 어디서 어떻게 오갔는지를 모아 준다.
///
/// 새 API 호출은 하지 않는다 — 인라인 스레드 본문·PR 대화 코멘트·리뷰 총평은
/// 목록 조회에서 이미 함께 받아 `PullRequestInfo` 에 들어 있다.
public struct RelatedDiscussion: Sendable, Equatable {
    /// 코멘트 한 개.
    public struct Message: Sendable, Equatable, Identifiable {
        public let id: String
        public let author: String
        public let body: String
        /// 스레드 코멘트의 시각은 원본이 문자열이라 파싱에 실패할 수 있다.
        public let at: Date?
        /// PR 을 올린 사람이 남긴 것인가 — 지적에 대한 "답변" 이라 따로 표시한다.
        public let isAuthorReply: Bool
        /// 이 본문에서 강조할 문구들. 어느 대목을 말하는지 눈으로 집어 주기 위한 것이다.
        public let highlights: [String]

        public init(id: String, author: String, body: String, at: Date?,
                    isAuthorReply: Bool, highlights: [String]) {
            self.id = id
            self.author = author
            self.body = body
            self.at = at
            self.isAuthorReply = isAuthorReply
            self.highlights = highlights
        }
    }

    /// 이 대화를 왜 끌어왔는가. 화면에 그대로 표시해, 무엇이 "바로 그 얘기" 인지 구분되게 한다.
    public enum Relevance: Int, Sendable, Equatable, Comparable {
        /// 초안이 가리키는 바로 그 줄.
        case sameLine = 0
        /// 몇 줄 안쪽.
        case nearby = 1
        /// 자리는 다르지만 같은 문구를 말하고 있다.
        case wording = 2
        /// 같은 파일에서 오간 다른 이야기. 맥락으로만 붙인다.
        case sameFile = 3

        public var label: String {
            switch self {
            case .sameLine: return "이 줄"
            case .nearby: return "근처 줄"
            case .wording: return "같은 문구"
            case .sameFile: return "같은 파일"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 인라인 코드 스레드 하나. 맥락을 보려면 스레드는 통째로 보여 준다.
    public struct Thread: Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String?
        public let line: Int?
        public let isResolved: Bool
        public let isOutdated: Bool
        public let messages: [Message]
        public let relevance: Relevance

        public init(id: String, path: String?, line: Int?, isResolved: Bool, isOutdated: Bool,
                    messages: [Message], relevance: Relevance) {
            self.id = id
            self.path = path
            self.line = line
            self.isResolved = isResolved
            self.isOutdated = isOutdated
            self.messages = messages
            self.relevance = relevance
        }
    }

    public var threads: [Thread]
    /// 자리가 없는 이야기 — PR 대화 코멘트와 리뷰 총평.
    public var comments: [Message]

    public var isEmpty: Bool { threads.isEmpty && comments.isEmpty }
    public var messageCount: Int { threads.reduce(0) { $0 + $1.messages.count } + comments.count }
    /// 작성자가 답을 남겼는가.
    public var hasAuthorReply: Bool {
        threads.contains { $0.messages.contains(where: \.isAuthorReply) } || comments.contains(where: \.isAuthorReply)
    }

    /// "바로 그 얘기" 라고 말할 수 있는 것이 하나라도 있는가(같은 파일 맥락만 붙은 경우와 구분).
    public var hasDirectMatch: Bool {
        threads.contains { $0.relevance != .sameFile } || !comments.isEmpty
    }

    public init(threads: [Thread] = [], comments: [Message] = []) {
        self.threads = threads
        self.comments = comments
    }
}

public enum RelatedDiscussionBuilder {
    /// AI 판정에 보낼 후보를 **넉넉히** 모은다.
    ///
    /// 낱말이 겹치는지로 미리 걸러 내면, 다른 말로 같은 문제를 말한 코멘트를 모델이 볼 기회조차
    /// 없어진다(실측: 초안은 `.sink` 미저장, 스레드는 `addSubview` z-순서 — 낱말은 하나도 겹치지
    /// 않지만 사람은 둘을 구분해야 한다). 그래서 같은 파일의 스레드와 PR 대화를 통째로 넘기고,
    /// 무엇이 이어지는지는 모델이 정한다.
    ///
    /// 메시지 id 는 `m1`, `m2` … 로 붙인다 — 프롬프트에 넣고 결과에서 되돌리기 위한 짧은 이름이고,
    /// 같은 입력이면 늘 같은 순서로 붙는다.
    public static func candidates(pr: PullRequestInfo,
                                  path: String,
                                  line: Int?,
                                  prAuthor: String,
                                  maxMessages: Int = 20) -> RelatedDiscussion {
        var counter = 0
        func nextID() -> String { counter += 1; return "m\(counter)" }

        var threads: [RelatedDiscussion.Thread] = []
        for thread in pr.threads where thread.path == path || thread.path == nil {
            let messages = thread.comments
                .sorted { (PRActivityBuilder.isoDate($0.createdAt) ?? .distantPast)
                        < (PRActivityBuilder.isoDate($1.createdAt) ?? .distantPast) }
                .map { comment in
                    RelatedDiscussion.Message(id: nextID(),
                                              author: comment.author,
                                              body: comment.body,
                                              at: PRActivityBuilder.isoDate(comment.createdAt),
                                              isAuthorReply: !prAuthor.isEmpty
                                                  && comment.author.caseInsensitiveCompare(prAuthor) == .orderedSame,
                                              highlights: [])
                }
            guard !messages.isEmpty else { continue }
            let relevance: RelatedDiscussion.Relevance = {
                guard let line, let threadLine = thread.line else { return .sameFile }
                if threadLine == line { return .sameLine }
                return abs(threadLine - line) <= nearbyLines ? .nearby : .sameFile
            }()
            threads.append(RelatedDiscussion.Thread(id: thread.id, path: thread.path, line: thread.line,
                                                    isResolved: thread.isResolved, isOutdated: thread.isOutdated,
                                                    messages: messages, relevance: relevance))
        }
        threads.sort {
            if $0.relevance != $1.relevance { return $0.relevance < $1.relevance }
            return ($0.line ?? .max) < ($1.line ?? .max)
        }

        // PR 대화는 최근 것부터 자르고, 화면·프롬프트에는 오래된 것부터 놓는다.
        let conversation = (pr.issueComments.map { (author: $0.author, body: $0.body, at: $0.createdAt) }
                            + pr.reviewEvents.filter { !$0.body.isEmpty }
                                .map { (author: $0.author, body: $0.body, at: $0.submittedAt) })
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.at > $1.at }
            .prefix(maxMessages)
            .sorted { $0.at < $1.at }
        let comments = conversation.map { entry in
            RelatedDiscussion.Message(id: nextID(),
                                      author: entry.author,
                                      body: entry.body,
                                      at: entry.at,
                                      isAuthorReply: !prAuthor.isEmpty
                                          && entry.author.caseInsensitiveCompare(prAuthor) == .orderedSame,
                                      highlights: [])
        }
        return RelatedDiscussion(threads: threads, comments: comments)
    }

    /// 후보 전체를 id 로 찾을 수 있게 펼친다.
    public static func messagesByID(_ discussion: RelatedDiscussion) -> [String: RelatedDiscussion.Message] {
        var result: [String: RelatedDiscussion.Message] = [:]
        for thread in discussion.threads {
            for message in thread.messages { result[message.id] = message }
        }
        for message in discussion.comments { result[message.id] = message }
        return result
    }

    /// 같은 줄이 아니어도 이만큼 안쪽이면 같은 이야기로 본다. 리뷰어가 한두 줄 위아래에
    /// 코멘트를 붙이는 일이 흔하고, 커밋이 쌓이면 줄 번호도 밀린다.
    static let nearbyLines = 5

    /// 문구를 뽑을 때 버리는 흔한 낱말. 이것들을 강조하면 본문이 온통 색칠된다.
    static let stopWords: Set<String> = [
        "self", "let", "var", "func", "return", "weak", "guard", "else", "true", "false",
        "nil", "this", "that", "with", "from", "into", "public", "private", "override",
        "class", "struct", "enum", "case", "await", "async", "throws", "some", "type",
    ]

    /// 초안 하나에 대해 관련 대화를 모은다.
    ///
    /// - Parameters:
    ///   - path/line: 초안이 붙는 자리.
    ///   - anchorText: 초안이 가리키는 코드 한 줄.
    ///   - commentBody: 초안 본문. **강조할 문구는 주로 여기서 나온다** — 모델이 주는
    ///     `anchor_text` 는 실제로 `}` 한 글자인 경우가 있어(실측) 그것만으로는 아무것도 못 찾는다.
    ///     본문의 백틱 코드 구간에는 `reloadHeaderView`·`cancellables` 처럼 이야기를 특정하는
    ///     이름이 들어 있어 훨씬 잘 걸린다.
    public static func build(pr: PullRequestInfo,
                             path: String,
                             line: Int?,
                             anchorText: String?,
                             commentBody: String? = nil,
                             prAuthor: String) -> RelatedDiscussion {
        let tokens = distinctiveTokens(anchorText, commentBody: commentBody)
        var threads: [RelatedDiscussion.Thread] = []
        var seen = Set<String>()

        for thread in pr.threads {
            // 같은 파일의 스레드는 모두 가져온다. 이유(relevance)를 함께 달아 화면에서 구분한다.
            //
            // 자리로만 걸러서는 안 된다: GitHub 은 줄이 밀린 스레드의 `line` 을 null 로 준다
            // (실측 — outdated 스레드). 그러면 같은 줄·근처 판정이 둘 다 불가능해져,
            // 정작 그 지적이 오간 스레드가 통째로 빠진다.
            guard thread.path == path || thread.path == nil else { continue }
            let textual = thread.comments.contains { matches(body: $0.body, anchorText: anchorText, tokens: tokens) }
            let relevance: RelatedDiscussion.Relevance = {
                if let line, let threadLine = thread.line {
                    if threadLine == line { return .sameLine }
                    if abs(threadLine - line) <= nearbyLines { return .nearby }
                }
                return textual ? .wording : .sameFile
            }()
            guard seen.insert(thread.id).inserted else { continue }

            let messages = thread.comments
                .map { message(id: "\(thread.id)|\($0.author)|\($0.createdAt)",
                               author: $0.author,
                               body: $0.body,
                               at: PRActivityBuilder.isoDate($0.createdAt),
                               anchorText: anchorText,
                               tokens: tokens,
                               prAuthor: prAuthor) }
                // 스레드 안에서는 오래된 것부터. 대화 순서 그대로 읽혀야 한다.
                .sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
            guard !messages.isEmpty else { continue }
            threads.append(RelatedDiscussion.Thread(id: thread.id,
                                                    path: thread.path,
                                                    line: thread.line,
                                                    isResolved: thread.isResolved,
                                                    isOutdated: thread.isOutdated,
                                                    messages: messages,
                                                    relevance: relevance))
        }

        // 관련이 확실한 것 먼저, 같은 등급 안에서는 줄 번호 순.
        threads.sort {
            if $0.relevance != $1.relevance { return $0.relevance < $1.relevance }
            return ($0.line ?? .max) < ($1.line ?? .max)
        }

        // 자리 없는 이야기는 문구가 겹칠 때만 끌어온다. 아니면 PR 대화 전체가 딸려 온다.
        var comments: [RelatedDiscussion.Message] = []
        for comment in pr.issueComments where matches(body: comment.body, anchorText: anchorText, tokens: tokens) {
            comments.append(message(id: "issue|\(comment.author)|\(comment.createdAt.timeIntervalSince1970)",
                                    author: comment.author,
                                    body: comment.body,
                                    at: comment.createdAt,
                                    anchorText: anchorText,
                                    tokens: tokens,
                                    prAuthor: prAuthor))
        }
        for event in pr.reviewEvents where matches(body: event.body, anchorText: anchorText, tokens: tokens) {
            comments.append(message(id: "review|\(event.author)|\(event.submittedAt.timeIntervalSince1970)",
                                    author: event.author,
                                    body: event.body,
                                    at: event.submittedAt,
                                    anchorText: anchorText,
                                    tokens: tokens,
                                    prAuthor: prAuthor))
        }
        comments.sort { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }

        return RelatedDiscussion(threads: threads, comments: comments)
    }

    // MARK: - 강조할 문구

    private static func message(id: String,
                                author: String,
                                body: String,
                                at: Date?,
                                anchorText: String?,
                                tokens: [String],
                                prAuthor: String) -> RelatedDiscussion.Message {
        RelatedDiscussion.Message(id: id,
                                  author: author,
                                  body: body,
                                  at: at,
                                  isAuthorReply: !prAuthor.isEmpty
                                      && author.caseInsensitiveCompare(prAuthor) == .orderedSame,
                                  highlights: highlights(in: body, anchorText: anchorText, tokens: tokens))
    }

    /// 본문에서 강조할 문구.
    ///
    /// 앵커 코드가 통째로 인용돼 있으면 그것 하나만 강조한다 — 가장 정확하다.
    /// 없으면 앵커에서 뽑은 식별자를 강조한다. 리뷰어는 코드를 그대로 붙이지 않고
    /// 이름만 언급하는 일이 많아서(`reloadHeaderView 가 안 불린다`), 이쪽이 실제로 더 잘 걸린다.
    static func highlights(in body: String, anchorText: String?, tokens: [String]) -> [String] {
        if let anchor = anchorText?.trimmingCharacters(in: .whitespacesAndNewlines),
           anchor.count >= 6, body.contains(anchor) {
            return [anchor]
        }
        return tokens.filter { body.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// 이 본문이 앵커와 관련 있는가.
    static func matches(body: String, anchorText: String?, tokens: [String]) -> Bool {
        !highlights(in: body, anchorText: anchorText, tokens: tokens).isEmpty
    }

    /// 초안 본문의 백틱 코드 구간들. `` `reloadHeaderView()` `` 같은 대목을 꺼낸다.
    public static func codeSpans(in text: String) -> [String] {
        var spans: [String] = []
        var current = ""
        var inside = false
        for character in text {
            if character == "`" {
                if inside, !current.isEmpty { spans.append(current) }
                current = ""
                inside.toggle()
            } else if inside {
                current.append(character)
            }
        }
        return spans
    }

    /// 코드 이름처럼 생긴 낱말. `reloadHeaderView`·`network_error` 는 잡고 `이 코드는` 은 안 잡는다.
    static func codeLikeWords(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 5 else { return }
            let hasUnderscore = current.contains("_")
            let head = current.dropFirst()
            let isCamel = head.contains(where: \.isUppercase) && current.first?.isLowercase == true
            guard hasUnderscore || isCamel else { return }
            words.append(current)
        }
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// 앵커 코드와 초안 본문에서 뽑은 "이름들". 흔한 키워드와 짧은 낱말은 버린다.
    static func distinctiveTokens(_ anchorText: String?, commentBody: String? = nil) -> [String] {
        var sources: [String] = []
        if let anchorText, !anchorText.isEmpty { sources.append(anchorText) }
        if let commentBody {
            let spans = codeSpans(in: commentBody)
            // 백틱이 하나도 없는 글(작성자 질문 같은 것)에서는 본문에서 직접 뽑는다.
            // 코드 이름처럼 생긴 것만 — camelCase 이거나 밑줄이 든 ASCII 낱말.
            // 한글은 걸리지 않아서 흔한 낱말이 통째로 강조되는 일이 없다.
            sources.append(contentsOf: spans.isEmpty ? codeLikeWords(in: commentBody) : spans)
        }
        let joined = sources.joined(separator: " ")
        guard !joined.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        for character in joined {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                tokens.append(current)
                current = ""
            }
        }
        tokens.append(current)
        var seen = Set<String>()
        return tokens.filter {
            $0.count >= 4
                && !stopWords.contains($0.lowercased())
                && $0.contains(where: \.isLetter)
                && seen.insert($0.lowercased()).inserted
        }
    }
}


/// 본문을 "강조할 구간"과 "그 밖"으로 쪼갠 결과. 화면은 이걸 그대로 이어 그린다.
///
/// 문자열 인덱스를 뷰에서 다루면 겹치는 문구·대소문자 차이에서 쉽게 어긋난다.
/// 쪼개는 일은 여기서 하고 테스트로 묶어 둔다.
public struct HighlightedText: Sendable, Equatable {
    public struct Segment: Sendable, Equatable, Identifiable {
        public let id: Int
        public let text: String
        public let isHighlighted: Bool

        public init(id: Int, text: String, isHighlighted: Bool) {
            self.id = id
            self.text = text
            self.isHighlighted = isHighlighted
        }
    }

    public let segments: [Segment]

    public var hasHighlight: Bool { segments.contains { $0.isHighlighted } }

    /// 겹치는 문구는 먼저 시작하는 쪽이 이긴다(같은 자리를 두 번 칠하지 않는다).
    /// 대소문자는 무시하고 찾되, 화면에는 본문에 있던 글자를 그대로 보여 준다.
    public static func split(_ body: String, quotes: [String]) -> HighlightedText {
        let candidates = quotes
            .filter { !$0.isEmpty }
            // 긴 문구부터 찾아야 짧은 조각이 먼저 칠해 긴 인용을 쪼개지 않는다.
            .sorted { $0.count > $1.count }

        var ranges: [Range<String.Index>] = []
        for quote in candidates {
            var searchStart = body.startIndex
            while searchStart < body.endIndex,
                  let found = body.range(of: quote, options: .caseInsensitive,
                                         range: searchStart..<body.endIndex) {
                if !ranges.contains(where: { $0.overlaps(found) }) {
                    ranges.append(found)
                }
                searchStart = found.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }

        var segments: [Segment] = []
        var cursor = body.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                segments.append(Segment(id: segments.count,
                                        text: String(body[cursor..<range.lowerBound]),
                                        isHighlighted: false))
            }
            segments.append(Segment(id: segments.count,
                                    text: String(body[range]),
                                    isHighlighted: true))
            cursor = range.upperBound
        }
        if cursor < body.endIndex {
            segments.append(Segment(id: segments.count,
                                    text: String(body[cursor...]),
                                    isHighlighted: false))
        }
        return HighlightedText(segments: segments)
    }
}
