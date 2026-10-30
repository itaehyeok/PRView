import Foundation

/// 상세 화면 하단 대화창의 말 한 마디.
public struct ChatMessage: Sendable, Codable, Identifiable, Hashable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    /// 답을 받지 못한 자리. 글에는 까닭이 들어 있다 — 실패한 답을 지우면 무엇을 물었다가 막혔는지 알 수 없다.
    public var failed: Bool

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), failed: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.failed = failed
    }
}

/// 리뷰를 만든 대화(`ReviewRecord.sessionID`)를 이어 간 기록. 키는 그 세션 ID 다.
///
/// 대화 자체는 CLI 가 `~/.claude/projects`·`~/.codex/sessions` 에 남긴다 — 그래서 터미널에서 `--resume` 하면
/// 여기서 나눈 말까지 이어진다. 앱은 화면에 다시 그릴 말만 따로 들고 있는다. CLI 의 대화 파일을 읽어 그리지 않는
/// 까닭: 리뷰 프롬프트(diff 전체)와 도구 호출까지 섞여 있고, 꼴이 CLI 버전마다 바뀐다.
public struct ReviewChat: Sendable, Codable, Identifiable, Hashable {
    public var sessionID: String
    public var engine: ReviewEngineKind
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public var id: String { sessionID }

    public init(sessionID: String, engine: ReviewEngineKind, messages: [ChatMessage] = [], updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.engine = engine
        self.messages = messages
        self.updatedAt = updatedAt
    }
}
