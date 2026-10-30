import Foundation

/// 하단 대화창의 질문 하나. 리뷰를 만든 대화(`ReviewRecord.sessionID`)를 ID 로 이어 간다.
public struct ChatTurn: Sendable {
    public var engine: ReviewEngineKind
    public var executablePath: String
    public var sessionID: String
    /// 리뷰를 돌린 모델(`ReviewRecord.model`) — 별칭이 아니라 실제 모델 ID 라 그때와 같은 모델이 답한다.
    public var model: String?
    public var question: String
    /// 이 대화창에서 처음 묻는 것인가. 처음에만 형식 안내를 붙인다(`ReviewChatRunner.prompt(for:)`).
    public var isFirst: Bool
    public var timeout: TimeInterval

    public init(engine: ReviewEngineKind, executablePath: String, sessionID: String, model: String?,
                question: String, isFirst: Bool, timeout: TimeInterval = 600) {
        self.engine = engine
        self.executablePath = executablePath
        self.sessionID = sessionID
        self.model = model
        self.question = question
        self.isFirst = isFirst
        self.timeout = timeout
    }
}

public struct ChatTurnResult: Sendable {
    public var text: String?
    public var usage: EngineUsage
    public var failureMessage: String?
    public var limitReached: Bool
    public var timedOut: Bool
    public var cancelled: Bool
    public var sessionID: String?

    public init(text: String? = nil, usage: EngineUsage, failureMessage: String? = nil, limitReached: Bool = false,
                timedOut: Bool = false, cancelled: Bool = false, sessionID: String? = nil) {
        self.text = text
        self.usage = usage
        self.failureMessage = failureMessage
        self.limitReached = limitReached
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.sessionID = sessionID
    }
}

/// 질문 하나 = CLI 한 번(`claude -p --resume <ID>` · `codex exec resume <ID>`).
///
/// 실측(2026-10-30, Claude Code 2.1.284 · Codex 0.166.0):
/// - 둘 다 대화를 만든 폴더가 아니어도 ID 로 이어지고, **같은 ID 에 덧붙는다**(새 대화가 갈라지지 않는다). 그래서 앱에서 나눈
///   말이 터미널의 `--resume` 에도 이어진다.
/// - Claude 는 리뷰 때의 시스템 프롬프트가 따라오고, 읽기 도구를 쓴 전체 리뷰도 `--tools ""` 로 이어 물을 수 있다.
/// - Codex 는 리뷰 때 `--output-schema` 로 답하게 한 대화라, 그냥 물으면 **이어 묻는 답도 리뷰 JSON 꼴로 낸다**.
///   첫 질문 앞에 형식 안내 한 줄(`preamble`)을 붙이면 글로 답한다. Claude 에도 같이 붙인다 — 리뷰 지침이 출력 형식을 정해 둔 대화다.
/// - Claude 는 `stream-json` + `--include-partial-messages` 로 글자 조각이 오고, Codex `exec --json` 은 다 쓴 답이 한 번에 온다.
public struct ReviewChatRunner: Sendable {
    private let runner = ProcessRunner()
    private let codex: CodexRunner

    public init(codex: CodexRunner = CodexRunner()) {
        self.codex = codex
    }

    static let preamble = "[PRView 안내] 리뷰는 끝났다. 지금부터는 리뷰한 사람과 나누는 대화다 — JSON 이나 리뷰 출력 형식을 쓰지 말고, "
        + "사람에게 말하듯 평범한 글(마크다운 가능)로 답한다."

    static func prompt(for turn: ChatTurn) -> String {
        turn.isFirst ? preamble + "\n\n" + turn.question : turn.question
    }

    /// 리뷰처럼 도구를 주지 않는다 — PR 내용은 믿을 수 없는 입력이다. 대화는 남긴다(리뷰한 그 대화에 덧붙인다).
    static func claudeArguments(sessionID: String, model: String?) -> [String] {
        var result = [
            "-p",
            "--resume", sessionID,
            "--safe-mode",
            "--strict-mcp-config",
            "--tools", "",
            "--permission-mode", "dontAsk",
        ]
        if let model, !model.isEmpty {
            result += ["--model", model]
        }
        result += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        return result
    }

    /// `exec resume` 에는 `-s`·`-C` 가 없다 — 샌드박스는 설정 값으로 준다. 셸은 리뷰의 보조 호출처럼 끈다.
    static func codexArguments(sessionID: String, model: String?, knownFeatures: [String]) -> [String] {
        var result = [
            "exec", "resume", "--json",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "-c", "sandbox_mode=\"read-only\"",
        ]
        for feature in CodexRunner.toolFeatures + CodexRunner.unrelatedFeatures where knownFeatures.contains(feature) {
            result += ["--disable", feature]
        }
        result += ["-c", "web_search=\"disabled\""]
        if let model, !model.isEmpty {
            result += ["-m", model]
        }
        result += [sessionID, "-"]
        return result
    }

    /// 묻고 답을 받는다. 답이 오는 동안 지금까지의 글을 `onPartial` 로 넘긴다(Claude 는 조각마다, Codex 는 다 쓴 뒤 한 번).
    public func send(_ turn: ChatTurn,
                     onPartial: @escaping @Sendable (String) -> Void) async throws -> ChatTurnResult {
        guard let sessionID = ClaudeSession.normalizedID(turn.sessionID) else {
            return ChatTurnResult(usage: EngineUsage(model: turn.model ?? ""), failureMessage: "대화 ID 가 올바르지 않습니다.")
        }
        AppPaths.ensureDirectories()
        let stdio = FileManager.default.temporaryDirectory
            .appendingPathComponent("prayer-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stdio) }

        let arguments: [String]
        let environment: [String: String]
        switch turn.engine {
        case .claude:
            arguments = Self.claudeArguments(sessionID: sessionID, model: turn.model)
            environment = ProcessEnvironment.base()
        case .codex:
            let known = await codex.features(path: turn.executablePath)
            arguments = Self.codexArguments(sessionID: sessionID, model: turn.model, knownFeatures: known)
            environment = CodexRunner.environment(codexPath: turn.executablePath)
        }
        let spec = ProcessSpec(executable: turn.executablePath,
                               arguments: arguments,
                               stdin: Self.prompt(for: turn),
                               currentDirectory: AppPaths.claudeWorkingDirectory.path,
                               environment: environment,
                               timeout: turn.timeout,
                               gracePeriod: 3,
                               stdioDirectory: stdio)

        // ProcessRunner 는 출력을 파일로 받는다(GitProgressRunner 와 같은 까닭). 끝에 붙는 줄만 짧은 간격으로 읽어 넘긴다.
        let outputFile = stdio.appendingPathComponent("stdout")
        let engine = turn.engine
        let poller = Task.detached {
            var reader = ChatStreamReader(engine: engine)
            var offset: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let handle = try? FileHandle(forReadingFrom: outputFile) else { continue }
                defer { try? handle.close() }
                try? handle.seek(toOffset: offset)
                guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
                offset += UInt64(data.count)
                if reader.feed(data) { onPartial(reader.text) }
            }
        }
        defer { poller.cancel() }

        let started = Date()
        let result = try await runner.run(spec)
        poller.cancel()
        var parsed: ChatTurnResult
        switch turn.engine {
        case .claude: parsed = Self.parseClaude(result: result, model: turn.model ?? "")
        case .codex: parsed = Self.parseCodex(result: result, model: turn.model ?? "")
        }
        // Codex 이벤트에는 걸린 시간이 없다.
        if parsed.usage.durationMs == 0 {
            parsed.usage.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        }
        parsed.cancelled = result.cancelled || Task.isCancelled
        return parsed
    }

    // MARK: - 파싱 (순수 — 테스트가 직접 부른다)

    static func parseClaude(result: ProcessResult, model: String) -> ChatTurnResult {
        var reader = ChatStreamReader(engine: .claude)
        _ = reader.feed(Data(result.stdout.utf8))
        reader.finish()
        var turn = ChatTurnResult(usage: EngineUsage(model: model), timedOut: result.timedOut)
        var finalText: String?
        var isError = !result.succeeded
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            isError = (event["is_error"] as? Bool) ?? isError
            finalText = event["result"] as? String
            turn.sessionID = event["session_id"] as? String
            var usage = EngineUsage(model: model)
            usage.durationMs = (event["duration_ms"] as? Int) ?? 0
            usage.costUSD = (event["total_cost_usd"] as? Double) ?? 0
            if let counts = event["usage"] as? [String: Any] {
                usage.inputTokens = (counts["input_tokens"] as? Int) ?? 0
                usage.cacheCreationTokens = (counts["cache_creation_input_tokens"] as? Int) ?? 0
                usage.cacheReadTokens = (counts["cache_read_input_tokens"] as? Int) ?? 0
                usage.outputTokens = (counts["output_tokens"] as? Int) ?? 0
            }
            turn.usage = usage
        }
        let streamed = reader.text
        if !isError, let text = [finalText, streamed].compactMap({ $0 }).first(where: { !$0.isBlank }) {
            turn.text = text
            return turn
        }
        // 실패해도 조각까지 받은 글은 남긴다 — 멈춤·시간 초과 뒤 어디까지 답했는지 보인다.
        turn.text = streamed.isBlank ? nil : streamed
        let reason = [isError ? finalText : nil, result.stderr].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        turn.failureMessage = Self.failureMessage(reason: reason, timedOut: result.timedOut)
        turn.limitReached = LimitDetector.matches(reason ?? "")
        return turn
    }

    static func parseCodex(result: ProcessResult, model: String) -> ChatTurnResult {
        var reader = ChatStreamReader(engine: .codex)
        _ = reader.feed(Data(result.stdout.utf8))
        reader.finish()
        var turn = ChatTurnResult(usage: EngineUsage(model: model), timedOut: result.timedOut)
        var completed = false
        var failure: String?
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "thread.started":
                turn.sessionID = event["thread_id"] as? String
            case "turn.completed":
                completed = true
                guard let counts = event["usage"] as? [String: Any] else { continue }
                let input = (counts["input_tokens"] as? Int) ?? 0
                let cached = (counts["cached_input_tokens"] as? Int) ?? 0
                turn.usage.inputTokens = max(0, input - cached)
                turn.usage.cacheReadTokens = cached
                turn.usage.cacheCreationTokens = (counts["cache_write_input_tokens"] as? Int) ?? 0
                turn.usage.outputTokens = (counts["output_tokens"] as? Int) ?? 0
            case "turn.failed":
                failure = ((event["error"] as? [String: Any])?["message"] as? String) ?? failure
            case "error":
                failure = failure ?? (event["message"] as? String)
            default:
                continue
            }
        }
        let text = reader.text
        if completed, result.succeeded, !text.isBlank {
            turn.text = text
            return turn
        }
        turn.text = text.isBlank ? nil : text
        let reason = [failure, result.stderr].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        turn.failureMessage = Self.failureMessage(reason: reason, timedOut: result.timedOut)
        turn.limitReached = LimitDetector.matches(reason ?? "")
        return turn
    }

    static func failureMessage(reason: String?, timedOut: Bool) -> String {
        if timedOut { return "답이 너무 오래 걸려 멈췄습니다." }
        guard let reason else { return "답을 받지 못했습니다." }
        let lower = reason.lowercased()
        // CLI 가 오래된 대화를 정리했거나 다른 맥에서 만든 리뷰다.
        if lower.contains("no conversation found") || lower.contains("session not found")
            || lower.contains("no rollout found") || lower.contains("thread not found") {
            return "이 리뷰를 만든 대화를 이 맥에서 찾지 못했습니다. 다시 리뷰하면 새 대화로 이어 갈 수 있습니다."
        }
        return String(reason.prefix(400))
    }
}

/// CLI 표준 출력(JSON 한 줄씩)을 받는 대로 읽어 지금까지의 답 글을 만든다. 줄 중간에서 끊겨 와도 다음 조각과 이어 읽는다.
struct ChatStreamReader {
    let engine: ReviewEngineKind
    private(set) var text = ""
    private var pending = Data()

    init(engine: ReviewEngineKind) {
        self.engine = engine
    }

    /// 글이 바뀌었으면 true.
    mutating func feed(_ data: Data) -> Bool {
        pending.append(data)
        let before = text
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            read(line: Data(line))
        }
        return text != before
    }

    /// 다 받은 뒤 줄바꿈 없이 끝난 마지막 줄까지 읽는다 — 멈추게 한 프로세스는 줄 중간에서 끊긴다.
    mutating func finish() {
        guard !pending.isEmpty else { return }
        read(line: pending)
        pending.removeAll()
    }

    private mutating func read(line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch engine {
        case .claude:
            // 생각 조각(thinking_delta)·서명은 건너뛰고 글 조각만 잇는다.
            guard event["type"] as? String == "stream_event",
                  let inner = event["event"] as? [String: Any],
                  inner["type"] as? String == "content_block_delta",
                  let delta = inner["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String else { return }
            text += piece
        case .codex:
            // 도구를 끈 호출이라 답은 메시지 하나다. 여럿이 오면 마지막 것이 답이다(리뷰 쪽 `CodexRunner.parse` 와 같다).
            guard event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let message = item["text"] as? String else { return }
            text = message
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
