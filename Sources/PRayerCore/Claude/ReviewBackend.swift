import Foundation

public struct EngineStatus: Sendable, Equatable {
    public var path: String
    public var version: String?
    public var loggedIn: Bool
    /// `auth status` 가 실제로 답했는가. 명령이 돌지 못해도 `loggedIn` 은 false 라,
    /// 이것 없이는 "로그아웃" 과 "확인 못 함" 을 가르지 못한다(`AuthFailure.loginRecovered`).
    public var loginKnown: Bool
    /// 계정 요약(이메일·조직·플랜 또는 "ChatGPT").
    public var accountLabel: String?
    public var errorMessage: String?

    public var isInstalled: Bool { version != nil }
    public var isReady: Bool { isInstalled && loggedIn }
    /// 플래그 세트를 실측한 버전과 같은지. 다르면 경고만 한다.
    public var versionVerified: Bool { version == AppInfo.verifiedClaudeVersion }

    public init(path: String, version: String? = nil, loggedIn: Bool = false, loginKnown: Bool = false,
                accountLabel: String? = nil, errorMessage: String? = nil) {
        self.path = path
        self.version = version
        self.loggedIn = loggedIn
        self.loginKnown = loginKnown
        self.accountLabel = accountLabel
        self.errorMessage = errorMessage
    }
}

public struct EngineRequest: Sendable {
    /// 이 요청을 돌릴 CLI. `model`·`effort` 는 그 엔진의 이름으로 풀어 둔 값이다(Codex 는 `codex:` 앞말을 뗀 모델).
    public var engine: ReviewEngineKind
    public var prompt: String
    public var executablePath: String
    /// 시스템 프롬프트(팀 리뷰 가이드) 파일 경로.
    public var guidePath: String
    public var guideText: String
    public var schemaPath: String
    public var schemaText: String
    public var model: String?
    public var timeout: TimeInterval
    public var workingDirectory: String
    /// 깊은 리뷰에서 허용할 도구. 비어 있으면 도구 없이 돈다.
    public var allowedTools: [String] = []
    /// 결과를 남길 영속 디렉터리. 주면 앱이 죽어도 나중에 수확할 수 있다.
    public var stdioDirectory: URL?
    /// `--effort` 값. nil 이면 기본값. 리뷰에서만 채운다.
    public var effort: String?
    /// 대화를 남겨 `claude --resume` 으로 이어 갈 수 있게 할지. 본 리뷰만 켠다(`ClaudeInvocation.persistSession`).
    public var persistSession: Bool

    public init(prompt: String, executablePath: String, guidePath: String, guideText: String,
                schemaPath: String, schemaText: String, model: String?,
                timeout: TimeInterval, workingDirectory: String, allowedTools: [String] = [],
                stdioDirectory: URL? = nil, effort: String? = nil, persistSession: Bool = false,
                engine: ReviewEngineKind = .claude) {
        self.engine = engine
        self.persistSession = persistSession
        self.allowedTools = allowedTools
        self.stdioDirectory = stdioDirectory
        self.effort = effort
        self.prompt = prompt
        self.executablePath = executablePath
        self.guidePath = guidePath
        self.guideText = guideText
        self.schemaPath = schemaPath
        self.schemaText = schemaText
        self.model = model
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }
}

public struct EngineRunResult: Sendable {
    public var output: ReviewOutput?
    public var usage: EngineUsage
    public var isError: Bool
    public var subtype: String?
    public var terminalReason: String?
    public var rawResult: String?
    public var stderr: String
    public var sessionID: String?
    public var timedOut: Bool
    /// 사용 한도 도달로 보이는 실패. 재시도하지 않고 대체 엔진으로 넘긴다.
    public var limitReached: Bool
    /// 사용자가 취소했지만 프로세스는 이미 끝나 있던 경우. 토큰은 소모됐으므로 원장에는 기록한다.
    public var cancelled: Bool = false
    /// 모델이 낸 구조화 JSON 원본. 리뷰가 아닌 다른 스키마(요약 등)를 디코딩할 때 쓴다.
    public var structuredJSON: Data?
    /// 돌린 CLI. 실패 문구에 이름을 넣는다.
    public var engine: ReviewEngineKind

    public init(output: ReviewOutput?, usage: EngineUsage, isError: Bool,
                subtype: String? = nil, terminalReason: String? = nil, rawResult: String? = nil,
                stderr: String = "", sessionID: String? = nil, timedOut: Bool = false,
                limitReached: Bool = false, cancelled: Bool = false, engine: ReviewEngineKind = .claude) {
        self.engine = engine
        self.output = output
        self.usage = usage
        self.isError = isError
        self.subtype = subtype
        self.terminalReason = terminalReason
        self.rawResult = rawResult
        self.stderr = stderr
        self.sessionID = sessionID
        self.timedOut = timedOut
        self.limitReached = limitReached
        self.cancelled = cancelled
    }

    public var failureMessage: String? {
        guard output == nil else { return nil }
        if timedOut { return "제한 시간을 넘겨 중단했습니다." }
        if limitReached { return "\(engine.productName) 사용 한도에 도달했습니다." }
        if let subtype, subtype.contains("budget") {
            return "리뷰 1건 예산 상한을 넘었습니다. 설정에서 상한을 올리세요."
        }
        if let raw = rawResult, !raw.isEmpty { return String(raw.prefix(400)) }
        if !stderr.isEmpty { return String(stderr.prefix(400)) }
        return "리뷰 결과를 해석할 수 없습니다."
    }
}

/// 한도 도달로 보이는 실패인지 문구로 판정한다(정확한 코드가 없다).
enum LimitDetector {
    static let patterns = ["usage limit", "rate limit", "limit reached", "quota", "5-hour",
                           "too many requests", "429", "resets at", "out of credits",
                           "insufficient_quota", "usage_limit_reached"]

    static func matches(_ haystack: String) -> Bool {
        let lower = haystack.lowercased()
        return patterns.contains { lower.contains($0) }
    }
}
