import XCTest
@testable import PRayerCore

/// 하단 대화창이 리뷰 대화를 이어 묻는 호출(`ReviewChatRunner`). 줄 꼴은 2026-10-30 실측 출력에서 줄인 것이다
/// (Claude Code 2.1.284 `stream-json --include-partial-messages` · Codex 0.166.0 `exec resume --json`).
final class ReviewChatTests: XCTestCase {
    private let sessionID = "336e407a-33c9-4d98-a716-afd281d9063a"

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func claudeDelta(_ delta: [String: Any]) -> String {
        json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 1, "delta": delta]])
    }

    private func claudeResult(_ text: String, isError: Bool = false) -> String {
        json(["type": "result", "subtype": isError ? "error_during_execution" : "success", "is_error": isError,
              "result": text, "session_id": sessionID, "duration_ms": 2_100, "total_cost_usd": 0.01,
              "usage": ["input_tokens": 3, "cache_creation_input_tokens": 120, "cache_read_input_tokens": 9_000,
                        "output_tokens": 14]])
    }

    // MARK: - 인자

    func testClaudeArgumentsResumeWithoutTools() {
        let arguments = ReviewChatRunner.claudeArguments(sessionID: sessionID, model: "claude-opus-5-5")
        XCTAssertEqual(Array(arguments.prefix(3)), ["-p", "--resume", sessionID])
        // 리뷰처럼 도구를 주지 않는다 — PR 내용은 믿을 수 없는 입력이다.
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "claude-opus-5-5")
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        // 대화를 남겨야 리뷰한 그 대화에 덧붙어 터미널의 --resume 에도 이어진다.
        XCTAssertFalse(arguments.contains("--no-session-persistence"))
        XCTAssertFalse(arguments.contains("--json-schema"))
    }

    func testCodexArgumentsDisableOnlyKnownFeatures() {
        let arguments = ReviewChatRunner.codexArguments(sessionID: sessionID, model: "gpt-6.1-sol",
                                                        knownFeatures: ["shell_tool", "unified_exec", "apps"])
        XCTAssertEqual(Array(arguments.prefix(3)), ["exec", "resume", "--json"])
        XCTAssertEqual(Array(arguments.suffix(2)), [sessionID, "-"])
        let disabled = arguments.indices.filter { arguments[$0] == "--disable" }.map { arguments[$0 + 1] }
        XCTAssertEqual(Set(disabled), ["shell_tool", "unified_exec", "apps"])
        // `exec resume` 에는 -s 가 없다 — 샌드박스는 설정 값으로.
        XCTAssertFalse(arguments.contains("-s"))
        XCTAssertTrue(arguments.contains("sandbox_mode=\"read-only\""))
        XCTAssertFalse(arguments.contains("--output-schema"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-m")! + 1], "gpt-6.1-sol")
    }

    // 대화창에서 Effort 를 고르지 않았으면 플래그를 붙이지 않는다 — 그 모델의 CLI 기본값으로 답한다.
    func testEffortOnlyWhenChosen() {
        XCTAssertFalse(ReviewChatRunner.claudeArguments(sessionID: sessionID, model: "sonnet").contains("--effort"))
        let claude = ReviewChatRunner.claudeArguments(sessionID: sessionID, model: "sonnet", effort: "low")
        XCTAssertEqual(claude[claude.firstIndex(of: "--effort")! + 1], "low")
        XCTAssertEqual(claude[claude.firstIndex(of: "--model")! + 1], "sonnet")

        let plain = ReviewChatRunner.codexArguments(sessionID: sessionID, model: "gpt-6.1-terra", knownFeatures: [])
        XCTAssertFalse(plain.contains { $0.hasPrefix("model_reasoning_effort") })
        let codex = ReviewChatRunner.codexArguments(sessionID: sessionID, model: "gpt-6.1-terra", effort: "medium",
                                                    knownFeatures: [])
        XCTAssertTrue(codex.contains("model_reasoning_effort=\"medium\""))
        // 대화 ID 와 표준 입력 표시는 늘 맨 끝이다(`exec resume <ID> -`).
        XCTAssertEqual(Array(codex.suffix(2)), [sessionID, "-"])
    }

    // 모델·Effort 칸이 생기기 전에 저장한 대화 파일도 그대로 읽힌다(고른 것 없음 = 리뷰한 설정).
    func testChatSavedBeforeModelChoiceStillDecodes() throws {
        let old = """
        [{"sessionID":"\(sessionID)","engine":"claude","updatedAt":0,
          "messages":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"네","date":0,"failed":false}]}]
        """
        let chats = try JSONDecoder().decode([ReviewChat].self, from: Data(old.utf8))
        XCTAssertNil(chats[0].model)
        XCTAssertNil(chats[0].effort)
        XCTAssertFalse(chats[0].hasCustomModel)
        XCTAssertNil(chats[0].messages[0].model)
    }

    func testPreambleOnlyOnFirstQuestion() {
        var turn = ChatTurn(engine: .codex, executablePath: "/x/codex", sessionID: sessionID, model: nil,
                            question: "세 번째 지적은 꼭 고쳐야 해?", isFirst: true)
        XCTAssertTrue(ReviewChatRunner.prompt(for: turn).hasPrefix(ReviewChatRunner.preamble))
        XCTAssertTrue(ReviewChatRunner.prompt(for: turn).hasSuffix(turn.question))
        turn.isFirst = false
        XCTAssertEqual(ReviewChatRunner.prompt(for: turn), turn.question)
    }

    // MARK: - 스트림 읽기

    func testClaudeReaderJoinsTextDeltasAndSkipsThinking() {
        var reader = ChatStreamReader(engine: .claude)
        let lines = [
            json(["type": "system", "subtype": "init", "session_id": sessionID]),
            claudeDelta(["type": "thinking_delta", "thinking": "", "estimated_tokens": 50]),
            claudeDelta(["type": "signature_delta", "signature": "abc"]),
            claudeDelta(["type": "text_delta", "text": "7("]),
            claudeDelta(["type": "text_delta", "text": "끝)"]),
        ]
        XCTAssertTrue(reader.feed(Data((lines.joined(separator: "\n") + "\n").utf8)))
        XCTAssertEqual(reader.text, "7(끝)")
    }

    func testReaderWaitsForLineSplitAcrossChunks() {
        var reader = ChatStreamReader(engine: .claude)
        let line = Data((claudeDelta(["type": "text_delta", "text": "안녕하세요"]) + "\n").utf8)
        let cut = line.count / 2
        XCTAssertFalse(reader.feed(line.prefix(cut)))
        XCTAssertEqual(reader.text, "")
        XCTAssertTrue(reader.feed(line.suffix(from: cut)))
        XCTAssertEqual(reader.text, "안녕하세요")
    }

    func testCodexReaderTakesLastAgentMessage() {
        var reader = ChatStreamReader(engine: .codex)
        let lines = [
            json(["type": "thread.started", "thread_id": sessionID]),
            json(["type": "item.completed", "item": ["id": "i0", "type": "reasoning", "text": "생각"]]),
            json(["type": "item.completed", "item": ["id": "i1", "type": "agent_message", "text": "7 (끝)"]]),
        ]
        XCTAssertTrue(reader.feed(Data((lines.joined(separator: "\n") + "\n").utf8)))
        XCTAssertEqual(reader.text, "7 (끝)")
    }

    // MARK: - 결과

    func testClaudeSuccessUsesResultAndUsage() {
        let stdout = [claudeDelta(["type": "text_delta", "text": "7"]), claudeResult("7(끝)")].joined(separator: "\n")
        let turn = ReviewChatRunner.parseClaude(result: ProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false),
                                                model: "claude-opus-5-5")
        XCTAssertEqual(turn.text, "7(끝)")
        XCTAssertNil(turn.failureMessage)
        XCTAssertEqual(turn.sessionID, sessionID)
        XCTAssertEqual(turn.usage.billableTokens, 3 + 120 + 14)
        XCTAssertEqual(turn.usage.cacheReadTokens, 9_000)
    }

    func testClaudeMissingConversationExplainsInKorean() {
        let turn = ReviewChatRunner.parseClaude(
            result: ProcessResult(exitCode: 1, stdout: "",
                                  stderr: "No conversation found with session ID: \(sessionID)", timedOut: false),
            model: "claude-opus-5-5")
        XCTAssertNil(turn.text)
        XCTAssertEqual(turn.failureMessage?.contains("찾지 못했습니다"), true)
        XCTAssertFalse(turn.limitReached)
    }

    func testClaudeStoppedKeepsPartialText() {
        let stdout = claudeDelta(["type": "text_delta", "text": "막혀 있지 않습니다. "])
        let turn = ReviewChatRunner.parseClaude(
            result: ProcessResult(exitCode: 130, stdout: stdout, stderr: "", timedOut: false, cancelled: true),
            model: "claude-opus-5-5")
        XCTAssertEqual(turn.text, "막혀 있지 않습니다. ")
        XCTAssertNotNil(turn.failureMessage)
    }

    func testClaudeLimitIsDetected() {
        let stdout = claudeResult("Claude usage limit reached. Your limit resets at 5pm.", isError: true)
        let turn = ReviewChatRunner.parseClaude(result: ProcessResult(exitCode: 1, stdout: stdout, stderr: "", timedOut: false),
                                                model: "claude-opus-5-5")
        XCTAssertNil(turn.text)
        XCTAssertTrue(turn.limitReached)
    }

    func testCodexSuccessCountsCachedInputSeparately() {
        let stdout = [
            json(["type": "thread.started", "thread_id": sessionID]),
            json(["type": "turn.started"]),
            json(["type": "item.completed", "item": ["id": "i0", "type": "agent_message", "text": "꼭 고쳐야 하는 것은 아닙니다."]]),
            json(["type": "turn.completed", "usage": ["input_tokens": 29_902, "cached_input_tokens": 23_552,
                                                      "cache_write_input_tokens": 0, "output_tokens": 17]]),
        ].joined(separator: "\n")
        let turn = ReviewChatRunner.parseCodex(result: ProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false),
                                               model: "gpt-6.1-sol")
        XCTAssertEqual(turn.text, "꼭 고쳐야 하는 것은 아닙니다.")
        XCTAssertNil(turn.failureMessage)
        XCTAssertEqual(turn.usage.inputTokens, 29_902 - 23_552)
        XCTAssertEqual(turn.usage.cacheReadTokens, 23_552)
        XCTAssertEqual(turn.sessionID, sessionID)
    }

    func testCodexFailureWithoutCompletedTurn() {
        let stdout = [
            json(["type": "thread.started", "thread_id": sessionID]),
            json(["type": "turn.failed", "error": ["message": "stream disconnected before completion"]]),
        ].joined(separator: "\n")
        let turn = ReviewChatRunner.parseCodex(result: ProcessResult(exitCode: 1, stdout: stdout, stderr: "", timedOut: false),
                                               model: "gpt-6.1-sol")
        XCTAssertNil(turn.text)
        XCTAssertEqual(turn.failureMessage, "stream disconnected before completion")
    }

    func testTimeoutMessage() {
        XCTAssertEqual(ReviewChatRunner.failureMessage(reason: "anything", timedOut: true), "답이 너무 오래 걸려 멈췄습니다.")
    }

    // MARK: - 저장 꼴

    func testChatRoundTripsThroughJSON() throws {
        let chat = ReviewChat(sessionID: sessionID, engine: .codex, messages: [
            ChatMessage(role: .user, text: "질문"),
            ChatMessage(role: .assistant, text: "답하다 멈췄습니다.", failed: true),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReviewChat.self, from: encoder.encode(chat))
        XCTAssertEqual(decoded.engine, .codex)
        XCTAssertEqual(decoded.messages.map(\.text), ["질문", "답하다 멈췄습니다."])
        XCTAssertEqual(decoded.messages.map(\.failed), [false, true])
    }

    func testUnknownLedgerKindReadsAsReview() throws {
        // 이 버전이 남긴 "chat" 을 옛 버전이 읽으면 리뷰로 친다 — 같은 길로 모르는 값이 와도 원장 전체가 깨지지 않는다.
        let data = Data(#"{"id":"\#(UUID().uuidString)","date":"2026-10-30T00:00:00Z","repo":"acme/sample-ios","number":1,"tokens":10,"costUSD":0,"model":"m","kind":"someday"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(LedgerEntry.self, from: data).kind, .review)
        let chat = Data(#"{"kind":"chat"}"#.utf8)
        XCTAssertEqual(try decoder.decode(LedgerEntry.self, from: chat).kind, .chat)
    }
}
