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
    /// 대화창에서 리뷰와 다른 모델·Effort 를 골라 둔 채 받은 답이면 그때 넘긴 모델 이름(`claude-sonnet-5-5`·
    /// `gpt-6.1-sol`)과 Effort 단계. 답 아래에 작게 보인다. 리뷰한 설정 그대로 받은 답은 둘 다 nil 이다 —
    /// 표시가 붙은 답만 보면 어디서 설정을 바꿨는지 알 수 있다.
    public var model: String?
    public var effort: String?

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), failed: Bool = false,
                model: String? = nil, effort: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.failed = failed
        self.model = model
        self.effort = effort
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
    /// 이 대화에 고른 모델 — 리뷰 모델 칸과 같은 저장값(`sonnet`·`claude-opus-5`·`codex:terra`). nil 이면 리뷰한
    /// 모델 그대로 묻는다. 대화마다 따로 둔다 — 한 PR 에서 가볍게 바꿔 물은 것이 다른 PR 의 대화로 번지지 않게.
    public var model: String?
    /// 이 대화에 고른 Effort 단계. nil 이면 넘기지 않는다(그 모델의 CLI 기본값). 리뷰 때 단계는 리뷰 기록에 남지
    /// 않아서 "리뷰한 설정" 의 Effort 는 CLI 기본값이다.
    public var effort: String?

    public var id: String { sessionID }

    /// 대화창에서 모델이나 Effort 를 리뷰와 다르게 골라 둔 상태인가.
    public var hasCustomModel: Bool { model != nil || effort != nil }

    public init(sessionID: String, engine: ReviewEngineKind, messages: [ChatMessage] = [], updatedAt: Date = Date(),
                model: String? = nil, effort: String? = nil) {
        self.sessionID = sessionID
        self.engine = engine
        self.messages = messages
        self.updatedAt = updatedAt
        self.model = model
        self.effort = effort
    }
}
