import Foundation

/// "이미 언급됨" 뒤의 대화 중 **정말 이어지는 대목**을 AI 가 골라 준 결과.
///
/// 낱말이 겹치는지로만 고르면 놓치고 헛짚는다(실측: 초안은 `.sink` 미저장 얘기인데 같은 파일의
/// 스레드는 `addSubview` z-순서 얘기였다 — 낱말은 하나도 겹치지 않지만 사람은 둘을 구분해야 한다).
/// 그래서 후보만 코드로 모으고, 무엇이 이어지는지와 어디를 칠할지는 모델이 정한다.
public struct DiscussionRelevance: Sendable, Codable, Hashable, Identifiable {
    public enum Verdict: String, Sendable, Codable {
        /// 이미 확인됐거나 고쳐졌다.
        case alreadyResolved = "already_resolved"
        /// 언급은 됐지만 결론이 없다.
        case underDiscussion = "under_discussion"
        /// 이어지는 대목이 없다.
        case notRelated = "not_related"

        public var label: String {
            switch self {
            case .alreadyResolved: return "이미 확인됨"
            case .underDiscussion: return "논의 중"
            case .notRelated: return "이어지는 대화 없음"
            }
        }
    }

    public enum Relevance: String, Sendable, Codable {
        case sameIssue = "same_issue"
        case resolution
        case authorReply = "author_reply"
        case related

        public var label: String {
            switch self {
            case .sameIssue: return "같은 사안"
            case .resolution: return "결론"
            case .authorReply: return "작성자 답변"
            case .related: return "관련"
            }
        }
    }

    public struct Match: Sendable, Codable, Hashable, Identifiable {
        /// 프롬프트에 넣었던 짧은 id(`m1`…). 화면에서 실제 메시지로 되돌린다.
        public var messageID: String
        public var relevance: Relevance
        /// 본문에서 그대로 발췌한 대목들. 화면은 이걸 찾아 형광펜을 칠한다.
        public var quotes: [String]
        public var whyKo: String

        public var id: String { messageID }

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case relevance
            case quotes
            case whyKo = "why_ko"
        }

        public init(messageID: String, relevance: Relevance, quotes: [String], whyKo: String) {
            self.messageID = messageID
            self.relevance = relevance
            self.quotes = quotes
            self.whyKo = whyKo
        }
    }

    public var key: String
    public var summaryKo: String
    public var verdict: Verdict
    public var matches: [Match]
    public var createdAt: Date
    public var usage: EngineUsage

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case summaryKo = "summary_ko"
        case verdict
        case matches = "related"
        case createdAt
        case usage
    }

    public init(key: String, summaryKo: String, verdict: Verdict, matches: [Match],
                createdAt: Date = Date(), usage: EngineUsage = EngineUsage()) {
        self.key = key
        self.summaryKo = summaryKo
        self.verdict = verdict
        self.matches = matches
        self.createdAt = createdAt
        self.usage = usage
    }

    public func match(for messageID: String) -> Match? {
        matches.first { $0.messageID == messageID }
    }
}

/// 모델이 돌려주는 부분만 담는 형태(key·createdAt·usage 는 앱이 채운다).
struct RelevanceOutput: Decodable {
    var summaryKo: String
    var verdict: DiscussionRelevance.Verdict
    var related: [DiscussionRelevance.Match]

    enum CodingKeys: String, CodingKey {
        case summaryKo = "summary_ko"
        case verdict
        case related
    }
}
