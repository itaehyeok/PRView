import Foundation

/// 리뷰를 돌리는 CLI. 이 맥에 깔린 Claude Code 나 Codex 를 그대로 빌려 쓴다(토큰·키를 받지 않는다).
///
/// 엔진은 따로 저장하지 않고 **모델 값이 말한다** — Codex 모델은 `codex:` 를 앞에 붙여 둔다(`CodexModels.prefix`).
/// 그래서 설정의 기본 모델·PR 마다 고른 모델·리뷰 잡이 들고 다니는 모델 한 칸이 엔진까지 함께 나른다.
/// 예전 설정·초안의 모델 값(`opus`·`claude-opus-5`)은 앞말이 없어 그대로 Claude 다.
public enum ReviewEngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    /// 화면에 보이는 짧은 이름 — 모델 칸·메뉴 머리.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// 설치·로그인 안내에 쓰는 CLI 이름.
    public var productName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// PR 내용이 건너가는 곳 — 온보딩·연결 안내에 적는다.
    public var vendorName: String {
        switch self {
        case .claude: return "Anthropic"
        case .codex: return "OpenAI"
        }
    }

    /// 모델 값이 가리키는 엔진.
    public init(model: String) {
        self = CodexModels.stripped(model) == nil ? .claude : .codex
    }
}
