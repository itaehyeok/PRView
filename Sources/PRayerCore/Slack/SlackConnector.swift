import Foundation

/// 슬랙과 주고받기 — **이 맥의 `claude` 에 붙은 claude.ai Slack 커넥터**를 빌려 쓴다.
///
/// PRView 는 토큰을 입력받지 않는다. 슬랙 토큰은 claude.ai 가 들고 있고(사용자가 claude.ai 에서 Slack 을 연결해 둔 것),
/// 글은 사용자 이름으로 간다. 대신 MCP 도구는 모델만 부를 수 있어서, 호출마다 작은 모델(haiku)이 한 번 돈다.
///
/// 실측으로 정한 것(CLI 2.1.284, 2026-10-20):
/// - `--safe-mode` 는 쓸 수 없다 — MCP 를 통째로 끈다. 그래서 CLAUDE.md·자동 기억은 환경 변수로, 사용자·프로젝트 설정은
///   `--setting-sources ""` 로 끈다.
/// - claude.ai 커넥터는 `-p` 에서 기다려 주지 않는다(첫 턴에 `pending`) → `MCP_CONNECTION_NONBLOCKING=false`.
/// - 그러면 붙어 있는 커넥터 30여 개의 도구 449개가 다 실려 요청이 20만 토큰을 넘는다 →
///   `--settings` 의 `allowedMcpServers` 로 Slack 서버(주소)만 남긴다. 서버 이름(`claude.ai Slack`)으로는 안 걸린다.
/// - 쓸 도구 하나만 `--allowedTools` 로 열고(`dontAsk` 라 나머지는 거절), 안 쓰는 Slack 도구는 `--disallowedTools` 로
///   빼서 설명이 안 실리게 한다 — 보내기 한 번이 입력 5.5k 토큰·13초·haiku 로 1센트 아래.
/// - 보낼 글은 모델이 옮겨 적는다. 한 글자라도 다르면 보내지 않도록 `PreToolUse` 훅이 앱이 만든 글·받는 곳과
///   바이트 단위로 맞춰 본다(`SlackSendGuard`). 다르면 도구가 거절되고 모델에게 다시 하지 말라고 한다.
public struct SlackConnector: Sendable {
    public var claudePath: String
    /// 슬랙 일은 짧은 받아쓰기라 가장 빠른 계열로 충분하다. 리뷰 모델 설정과 상관없다.
    public var model: String
    public var timeout: TimeInterval

    public init(claudePath: String, model: String = "haiku", timeout: TimeInterval = 120) {
        self.claudePath = claudePath
        self.model = model
        self.timeout = timeout
    }

    // MARK: - 할 일

    /// 연동 확인 — 커넥터가 붙어 있는지, 붙어 있으면 나는 누구인지.
    public func checkConnection() async throws -> SlackPerson {
        let summary = try await run(tool: .readProfile,
                                    prompt: """
                                    Call the tool slack_read_user_profile exactly once with no arguments.
                                    Then reply with the single word DONE.
                                    """)
        guard let text = summary.successfulResultText(for: .readProfile) else {
            throw summary.failure(for: .readProfile)
        }
        guard let person = SlackResultParser.profile(from: text) else {
            throw SlackConnectorError.unreadable("내 슬랙 정보를 읽지 못했습니다.")
        }
        return person
    }

    /// 채널 찾기. 공개·비공개 채널을 같이 찾는다(비공개는 내가 들어가 있는 것만 나온다 — 슬랙 규칙).
    public func searchChannels(_ query: String) async throws -> [SlackDestination] {
        let words = SlackResultParser.keywords(query)
        guard !words.isEmpty else { return [] }
        let arguments = Self.jsonString([
            "keywords": words,
            "natural_language_query": query,
            "channel_types": "public_channel,private_channel",
            "limit": 20,
            "response_format": "concise"
        ])
        let summary = try await run(tool: .searchChannels,
                                    prompt: """
                                    Call the tool slack_search_channels exactly once with these arguments:
                                    \(arguments)
                                    Then reply with the single word DONE.
                                    """)
        guard let text = summary.successfulResultText(for: .searchChannels) else {
            throw summary.failure(for: .searchChannels)
        }
        return SlackResultParser.channels(from: text)
    }

    // MARK: 내 채널
    //
    // 커넥터에는 "내가 들어간 채널 목록" 도구가 없다(2026-10-20). 채널 찾기(`slack_search_channels`)는 검색어가
    // 꼭 있어야 하고 공개 채널은 전부 나온다. 그래서 메시지 검색으로 1건씩 찾되, 찾은 채널은 `-in:` 으로 빼고
    // 다시 찾는다 — 한 번에 새 채널이 하나씩 나온다(한 채널 글이 결과를 다 차지하는 것을 피한다, 실측).
    // 두 갈래다: 내가 글을 쓴 채널(`from:나`, 실측 4개·25초)과 들어가 있는 채널(`only_my_channels`, 최근 활동 순,
    // 실측 20개 받는 데 1분 반). 화면은 둘을 따로 받아 먼저 끝난 것부터 보이고, 받은 목록은 저장해 둔다.
    // 봇 글은 빼서(`include_bots` 기본 false) 알림만 오는 채널은 안 나온다.

    /// 내가 글을 쓴 채널, 최근 것부터.
    public func postedChannels(me: SlackPerson, limit: Int = 10) async throws -> [SlackDestination] {
        try await channelLoop(filters: "from:<@\(me.id)>", onlyMine: false, limit: limit,
                              goal: "Find the Slack channels I post in")
    }

    /// 내가 들어가 있는 채널, 최근 활동 순.
    public func memberChannels(limit: Int = 20) async throws -> [SlackDestination] {
        // 도구가 검색어나 필터 중 하나는 꼭 받는다. 날짜 필터로 "아무 글이나" 를 뜻하게 한다.
        try await channelLoop(filters: "after:2000-01-01", onlyMine: true, limit: limit,
                              goal: "List the Slack channels I am a member of")
    }

    /// 메시지 검색을 되풀이하며 채널을 하나씩 모은다(위 "내 채널" 주석).
    private func channelLoop(filters: String, onlyMine: Bool, limit: Int, goal: String) async throws -> [SlackDestination] {
        var arguments: [String: Any] = [
            "filters": filters,
            "channel_types": "public_channel,private_channel",
            "sort": "timestamp",
            "limit": 1,
            "response_format": "detailed",
            "include_context": false,
            "natural_language_query": ""
        ]
        if onlyMine { arguments["only_my_channels"] = true }
        let summary = try await run(tool: .searchMessages,
                                    prompt: """
                                    \(goal), most recent first, by repeating one search.
                                    Call the tool slack_search_public_and_private with these arguments:
                                    \(Self.jsonString(arguments))
                                    The result has a line like "Channel: #name (ID: C0123ABCD)". After each call, append \
                                    " -in:<#ID>" for that channel to "filters" (keep every earlier exclusion) and call again \
                                    with the other arguments unchanged.
                                    Make one call at a time. Stop when a call returns no messages or after \(limit) calls.
                                    Then reply with the single word DONE.
                                    """,
                                    budgetUSD: 0.5)
        let texts = summary.toolResults(for: .searchMessages).filter { !$0.isError }.map(\.text)
        guard !texts.isEmpty else { throw summary.failure(for: .searchMessages) }
        var found: [SlackDestination] = []
        for text in texts {
            for channel in SlackResultParser.channelsFromMessages(text) where !found.contains(where: { $0.id == channel.id }) {
                found.append(channel)
            }
        }
        return found
    }

    /// 사람 찾기(멘션·DM 용).
    public func searchPeople(_ query: String) async throws -> [SlackPerson] {
        let words = SlackResultParser.keywords(query)
        guard !words.isEmpty else { return [] }
        let arguments = Self.jsonString([
            "keywords": words,
            "natural_language_query": query,
            "limit": 20,
            "response_format": "concise"
        ])
        let summary = try await run(tool: .searchUsers,
                                    prompt: """
                                    Call the tool slack_search_users exactly once with these arguments:
                                    \(arguments)
                                    Then reply with the single word DONE.
                                    """)
        guard let text = summary.successfulResultText(for: .searchUsers) else {
            throw summary.failure(for: .searchUsers)
        }
        return SlackResultParser.people(from: text)
    }

    /// 글 보내기. 성공하면 슬랙 메시지 주소를 돌려준다(못 읽으면 nil — 보내지기는 했다).
    public func send(_ message: String, to destination: SlackDestination, unfurlLinks: Bool) async throws -> String? {
        guard !message.isEmpty else { throw SlackConnectorError.emptyMessage }
        guard message.count <= SlackTemplate.maxLength else { throw SlackConnectorError.tooLong(message.count) }
        let guardDir = try SlackSendGuard.prepare(message: message, channelID: destination.id)
        defer { try? FileManager.default.removeItem(at: guardDir) }

        // 글은 표시 사이에 그대로 둔다. JSON 으로 감싸 넘기면 모델이 이스케이프를 풀다 글자를 바꿀 여지가 생긴다.
        let prompt = """
        Send exactly one Slack message with the tool slack_send_message.
        channel_id: \(destination.id)
        unfurl_app_links: \(unfurlLinks ? "true" : "false")
        message: the text between the markers below, copied character for character \
        (no edits, no added or removed lines, no escaping changes).
        <<<MESSAGE
        \(message)
        MESSAGE>>>
        If the tool is blocked or fails, do not retry. Reply with only the message link, or the error.
        """
        let summary: SlackStreamSummary
        do {
            summary = try await run(tool: .sendMessage, prompt: prompt,
                                    hookCommand: SlackSendGuard.hookCommand(directory: guardDir))
        } catch SlackConnectorError.cancelled {
            // 프로세스를 죽였어도 도구가 이미 통과했으면 글은 갔을 수 있다.
            if SlackSendGuard.passed(guardDir) { throw SlackConnectorError.cancelledAfterSend }
            throw SlackConnectorError.cancelled
        }
        if let text = summary.successfulResultText(for: .sendMessage) {
            return SlackResultParser.messageLink(from: text)
        }
        if let blocked = summary.blockedReason(for: .sendMessage) {
            throw SlackConnectorError.blocked(blocked)
        }
        throw summary.failure(for: .sendMessage)
    }

    // MARK: - 실행

    func run(tool: SlackTool, prompt: String, hookCommand: String? = nil,
             budgetUSD: Double? = nil) async throws -> SlackStreamSummary {
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            throw SlackConnectorError.claudeMissing(claudePath)
        }
        AppPaths.ensureDirectories()
        let spec = ProcessSpec(executable: claudePath,
                               arguments: SlackInvocation.arguments(tool: tool, model: model, hookCommand: hookCommand,
                                                                    budgetUSD: budgetUSD),
                               stdin: prompt,
                               currentDirectory: AppPaths.claudeWorkingDirectory.path,
                               environment: ProcessEnvironment.base(extra: SlackInvocation.environment),
                               timeout: timeout,
                               gracePeriod: 3)
        let result: ProcessResult
        do {
            result = try await ProcessRunner().run(spec)
        } catch let error as ProcessRunError {
            throw SlackConnectorError.launchFailed(error.localizedDescription)
        }
        if result.cancelled || Task.isCancelled { throw SlackConnectorError.cancelled }
        if result.timedOut { throw SlackConnectorError.timedOut }
        let summary = SlackStreamSummary.parse(result.stdout)
        if let problem = Self.problem(in: summary, stderr: result.stderr) { throw problem }
        return summary
    }

    /// 도구를 부르기 전에 정해지는 실패. 모델 답과 상관없이 그 이유를 말한다.
    ///
    /// 로그인이 끊긴 것을 **먼저** 본다 — 로그인이 끊기면 claude.ai 커넥터도 같이 안 실려서, 커넥터부터 보면
    /// "Slack 을 연결하세요" 라고 엉뚱한 일을 시킨다. 판정은 리뷰가 쓰는 것과 같은 문구 판정(`AuthFailure`)이다.
    static func problem(in summary: SlackStreamSummary, stderr: String) -> SlackConnectorError? {
        let said = [summary.isError ? summary.finalText : nil, stderr].compactMap { $0 }.joined(separator: "\n")
        if AuthFailure.isExpired(said) { return .loginRequired }
        if let problem = summary.connectorProblem { return problem }
        if !summary.sawInit {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unreadable(detail.isEmpty ? "claude 가 아무것도 돌려주지 않았습니다." : String(detail.prefix(300)))
        }
        return nil
    }

    static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// 이 기능이 쓰는 Slack 커넥터 도구.
public enum SlackTool: String, CaseIterable, Sendable {
    case readProfile = "slack_read_user_profile"
    case searchChannels = "slack_search_channels"
    case searchUsers = "slack_search_users"
    case sendMessage = "slack_send_message"
    /// 메시지 검색 — 내 채널 목록을 모을 때만 쓴다(`myChannels`).
    case searchMessages = "slack_search_public_and_private"

    /// claude.ai 커넥터 도구의 전체 이름. 서버 이름 "claude.ai Slack" 이 `claude_ai_Slack` 이 된다.
    public var qualifiedName: String { SlackInvocation.toolPrefix + rawValue }
}

/// `claude -p` 인자·환경. 순수 함수라 테스트가 묶는다.
public enum SlackInvocation {
    static let toolPrefix = "mcp__claude_ai_Slack__"
    /// claude.ai Slack 커넥터가 붙는 주소. `allowedMcpServers` 가 이 주소의 서버만 남긴다.
    static let serverURLPattern = "https://mcp.slack.com/*"

    /// 2026-10-20 의 Slack 커넥터 도구 중 이 기능이 안 쓰는 것. 설명이 실리지 않게 뺀다.
    /// 슬랙이 도구를 더하면 여기 없는 것은 실리기만 하고(토큰이 조금 는다) 부를 수는 없다(`--allowedTools` 밖).
    static let unusedTools = [
        "slack_add_reaction", "slack_create_canvas", "slack_create_conversation", "slack_get_reactions",
        "slack_list_channel_members", "slack_read_canvas", "slack_read_channel", "slack_read_file",
        "slack_read_thread", "slack_schedule_message", "slack_search_emojis", "slack_search_public",
        "slack_send_message_draft", "slack_update_canvas"
    ]

    static let environment: [String: String] = [
        // claude.ai 커넥터가 붙을 때까지 기다린다. 없으면 첫 턴에 Slack 도구가 없다(실측: pending).
        "MCP_CONNECTION_NONBLOCKING": "false",
        // 사용자의 CLAUDE.md·자동 기억을 싣지 않는다. 받아쓰기에 필요 없고, 개인 지침이 답을 바꾼다(실측: 한국어로 답함).
        "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"
    ]

    static let systemPrompt = """
    You are the Slack relay of the PRView app. Call only the one tool you are asked to call, \
    with exactly the arguments given. Never change the message text.
    """

    public static func arguments(tool: SlackTool, model: String, hookCommand: String?,
                                 budgetUSD: Double? = nil) -> [String] {
        var settings: [String: Any] = ["allowedMcpServers": [["serverUrl": serverURLPattern]]]
        if let hookCommand {
            settings["hooks"] = [
                "PreToolUse": [[
                    "matcher": tool.qualifiedName,
                    "hooks": [["type": "command", "command": hookCommand]]
                ]]
            ]
        }
        let unused = SlackTool.allCases.filter { $0 != tool }.map(\.rawValue) + unusedTools
        // `--strict-mcp-config` 는 붙이지 않는다 — claude.ai 커넥터까지 지운다(실측: 서버 0개).
        // 되풀이하는 호출(내 채널)은 모델이 멈추지 않을 때를 대비해 쓸 돈에 상한을 둔다(`--max-turns` 는 없다).
        let budget = budgetUSD.map { ["--max-budget-usd", String(format: "%.2f", $0)] } ?? []
        return budget + [
            "-p",
            "--setting-sources", "",
            "--settings", SlackConnector.jsonString(settings),
            "--tools", "",
            "--system-prompt", systemPrompt,
            "--allowedTools", tool.qualifiedName,
            "--disallowedTools", unused.map { toolPrefix + $0 }.joined(separator: ","),
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--model", model,
            "--output-format", "stream-json",
            "--verbose"
        ]
    }
}

/// 보낼 글을 바이트 단위로 지키는 `PreToolUse` 훅.
///
/// 훅은 도구 입력을 JSON 으로 받는다. `plutil` 은 모든 맥에 있고 JSON 을 읽는다 — `jq`·`python3` 는 없을 수 있다.
/// `plutil -extract … raw` 는 값 끝에 줄바꿈을 하나 붙여서, 맞춰 볼 글도 줄바꿈을 붙여 둔다(실측).
/// 한 번 통과하면 표시(`sent.lock`)를 남겨 두 번째 호출은 막는다 — 모델이 다시 시도해 같은 글이 두 번 가지 않게.
enum SlackSendGuard {
    static let script = """
    # PRView: 앱이 만든 글·받는 곳 그대로일 때만, 그리고 한 번만 보낸다.
    d="$(dirname "$0")"
    f="$d/hook-input.json"
    cat > "$f"
    if /usr/bin/plutil -extract tool_input.message raw -o - - < "$f" | /usr/bin/cmp -s - "$d/expected.txt" \\
       && [ "$(/usr/bin/plutil -extract tool_input.channel_id raw -o - - < "$f")" = "$(cat "$d/channel.txt")" ] \\
       && mkdir "$d/sent.lock" 2>/dev/null; then
      exit 0
    fi
    echo "PRView: message or channel differs from the approved one (or it was already sent). Do not retry." >&2
    exit 2

    """

    static var baseDirectory: URL { AppPaths.support.appendingPathComponent("slack-send", isDirectory: true) }

    static func prepare(message: String, channelID: String, in base: URL = baseDirectory) throws -> URL {
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: dir.appendingPathComponent("guard.sh"))
        try Data((message + "\n").utf8).write(to: dir.appendingPathComponent("expected.txt"))
        try Data(channelID.utf8).write(to: dir.appendingPathComponent("channel.txt"))
        return dir
    }

    /// 경로에 빈칸이 있다("Application Support") — 따옴표로 감싼다.
    static func hookCommand(directory: URL) -> String {
        "/bin/sh \"\(directory.appendingPathComponent("guard.sh").path)\""
    }

    static func passed(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("sent.lock").path)
    }
}

public enum SlackConnectorError: LocalizedError, Equatable, Sendable {
    case claudeMissing(String)
    case launchFailed(String)
    /// claude.ai 에 Slack 커넥터가 없다(또는 조직 정책으로 막혔다).
    case connectorMissing
    /// 커넥터는 있지만 다시 로그인해야 한다.
    case needsAuth
    /// Claude Code 로그인이 끊겼다. 커넥터는 그 로그인 위에서 돈다.
    case loginRequired
    case connectorFailed(String)
    case toolNotCalled(String?)
    case toolFailed(String)
    case blocked(String)
    case emptyMessage
    case tooLong(Int)
    case timedOut
    case cancelled
    /// 취소했지만 도구는 이미 통과했다 — 글이 갔을 수 있다.
    case cancelledAfterSend
    case unreadable(String)
    /// 여러 갈래 중 일부만 실패했다(내 채널). 받은 것은 쓴다.
    case partial(String)

    public var errorDescription: String? {
        switch self {
        case .claudeMissing(let path): return "Claude Code CLI 를 찾을 수 없습니다: \(path)"
        case .launchFailed(let reason): return "claude 를 실행하지 못했습니다: \(reason)"
        case .connectorMissing: return "claude.ai 에 Slack 커넥터가 연결돼 있지 않습니다."
        case .needsAuth: return "claude.ai 의 Slack 커넥터에 다시 로그인해야 합니다."
        case .loginRequired: return "Claude Code 에 로그인돼 있지 않습니다."
        case .connectorFailed(let status): return "Slack 커넥터에 붙지 못했습니다(\(status))."
        case .toolNotCalled(let reply):
            return "Claude 가 Slack 도구를 부르지 않았습니다." + (reply.map { " — \($0.prefix(200))" } ?? "")
        case .toolFailed(let message): return "Slack 이 거절했습니다: \(message)"
        case .blocked: return "Claude 가 옮겨 적은 글이 미리보기와 달라 보내지 않았습니다."
        case .emptyMessage: return "보낼 글이 비어 있습니다."
        case .tooLong(let count): return "글이 너무 깁니다(\(count)자 — 슬랙 한도 \(SlackTemplate.maxLength)자)."
        case .timedOut: return "응답이 없어 멈췄습니다."
        case .cancelled: return "취소했습니다."
        case .cancelledAfterSend: return "취소했지만 이미 보내졌을 수 있습니다 — 슬랙에서 확인하세요."
        case .unreadable(let detail): return "결과를 읽지 못했습니다: \(detail)"
        case .partial(let detail): return detail
        }
    }

    /// 사용자가 할 일. 화면이 오류 아래에 덧붙인다.
    public var guidance: String? {
        switch self {
        case .connectorMissing:
            return "claude.ai › 설정 › 커넥터에서 Slack 을 연결한 뒤 다시 확인하세요. 회사가 커넥터를 막아 두었으면 쓸 수 없습니다."
        case .needsAuth:
            return "claude.ai › 설정 › 커넥터에서 Slack 을 다시 연결하세요."
        case .claudeMissing, .launchFailed:
            return "설정 › 연결에서 Claude Code 경로를 확인하세요."
        default:
            return nil
        }
    }

    /// 연동 실패를 사람이 할 일로 나눈 것 — 화면이 이 갈래로 안내를 고른다.
    public enum FailureKind: Equatable, Sendable {
        /// claude.ai 에서 Slack 커넥터를 (다시) 연결해야 한다.
        case connector
        /// Claude Code 에 로그인해야 한다.
        case claudeLogin
        /// Claude Code CLI 가 없다.
        case claudeMissing
        /// 일시적이거나 알 수 없다 — 다시 확인하면 된다.
        case other
    }

    public var failureKind: FailureKind {
        switch self {
        case .connectorMissing, .needsAuth, .connectorFailed: return .connector
        case .loginRequired: return .claudeLogin
        case .claudeMissing: return .claudeMissing
        default: return .other
        }
    }

    /// claude.ai 커넥터 설정 화면. 안내 버튼이 연다.
    public static let connectorSettingsURL = URL(string: "https://claude.ai/settings/connectors")!
}
