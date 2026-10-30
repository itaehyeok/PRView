import Foundation

public struct ClaudeInvocation: Sendable {
    public var claudePath: String
    public var systemPromptPath: String
    public var schemaJSON: String
    public var model: String
    public var timeout: TimeInterval
    public var workingDirectory: String
    /// 깊은 리뷰에서만 채운다. 비어 있으면 도구를 전부 제거한다(기본).
    public var allowedTools: [String]
    /// 결과를 남길 영속 디렉터리.
    public var stdioDirectory: URL?
    /// `--effort` 값. nil 이면 붙이지 않는다(모델·CLI 기본값).
    public var effort: String?
    /// 대화를 `~/.claude/projects` 에 남길지. 본 리뷰만 켠다 — 사용자가 리뷰한 그 대화를
    /// `claude --resume` 으로 이어 갈 수 있게 하려는 것이다. 설명·대조·재확인 같은 보조 호출까지 남기면
    /// 사용자의 `--resume` 목록이 앱이 부른 짧은 대화로 덮인다.
    public var persistSession: Bool

    public init(claudePath: String, systemPromptPath: String, schemaJSON: String, model: String,
                timeout: TimeInterval, workingDirectory: String,
                allowedTools: [String] = [], stdioDirectory: URL? = nil, effort: String? = nil,
                persistSession: Bool = false) {
        self.persistSession = persistSession
        self.allowedTools = allowedTools
        self.stdioDirectory = stdioDirectory
        self.effort = effort
        self.claudePath = claudePath
        self.systemPromptPath = systemPromptPath
        self.schemaJSON = schemaJSON
        self.model = model
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }

    /// 실측으로 확정한 플래그 세트.
    /// - `--safe-mode`: CLAUDE.md·플러그인·훅·MCP 를 끈다(인증은 정상). 이걸 빼면 호출당 오버헤드가 10k~56k 토큰으로 뛴다.
    /// - `--tools ""`: 내장 도구 전부 제거. PR 내용은 신뢰할 수 없는 입력이라 읽기/쓰기/Bash 를 주지 않는다.
    /// - `--bare` 는 쓰지 않는다: OAuth·키체인을 읽지 않아 구독 인증과 양립 불가.
    public var arguments: [String] {
        var result = [
            "-p",
            "--safe-mode",
            "--strict-mcp-config",
            "--system-prompt-file", systemPromptPath,
        ]
        if allowedTools.isEmpty {
            result += ["--tools", ""]
        } else {
            // 깊은 리뷰: 읽기 계열만 준다. 쓰기·실행·네트워크는 명시적으로 막는다
            // (PR 내용은 신뢰할 수 없는 입력이다).
            result += ["--allowedTools", allowedTools.joined(separator: ",")]
            result += ["--disallowedTools",
                       "Bash,Write,Edit,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task"]
        }
        result += ["--permission-mode", "dontAsk"]
        if !persistSession {
            result += ["--no-session-persistence"]
        }
        result += ["--model", model]
        if let effort {
            result += ["--effort", effort]
        }
        result += [
            "--output-format", "json",
            "--json-schema", schemaJSON
        ]
        return result
    }
}

public actor ClaudeRunner {
    private let runner = ProcessRunner()

    public init() {}

    /// 공식 설치 스크립트(`~/.local/bin`)와 Homebrew. 셸에 묻기 전에 본다.
    public static let candidatePaths: [String] = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]

    /// 셸에서도 못 찾았을 때 마지막으로 보는 곳. 예전 "로컬 설치" 는 PATH 가 아니라 alias 로만
    /// 불려서, 셸 설정이 깨져 있으면 여기서만 잡힌다.
    static var fallbackPaths: [String] {
        ["\(NSHomeDirectory())/.claude/local/claude"]
            + ExecutableLocator.userToolDirectories().map { "\($0)/claude" }
    }

    /// 공식 설치 명령. CLI 가 없을 때 안내하고, 사용자가 누르면 터미널에서 돌린다.
    public static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    public func discoverPath() async -> String? {
        await ExecutableLocator.find("claude", preferred: Self.candidatePaths, fallback: Self.fallbackPaths)
    }

    public func status(path claudePath: String) async -> EngineStatus {
        var status = EngineStatus(path: claudePath)
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            status.errorMessage = "실행 파일이 없습니다: \(claudePath)"
            return status
        }
        if let result = try? await runner.run(ProcessSpec(executable: claudePath, arguments: ["--version"], timeout: 20)),
           result.succeeded {
            // "2.1.258 (Claude Code)" 형태
            status.version = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .first
                .map(String.init)
        } else {
            status.errorMessage = "`claude --version` 실행에 실패했습니다."
            return status
        }

        guard let result = try? await runner.run(ProcessSpec(executable: claudePath,
                                                             arguments: ["auth", "status", "--json"],
                                                             timeout: 20)) else {
            status.errorMessage = "`claude auth status` 실행에 실패했습니다."
            return status
        }
        struct AuthStatus: Decodable {
            let loggedIn: Bool?
            let authMethod: String?
            let email: String?
            let orgName: String?
            let subscriptionType: String?
        }
        if let parsed = try? JSONDecoder().decode(AuthStatus.self, from: Data(result.stdout.utf8)) {
            status.loggedIn = parsed.loggedIn ?? false
            status.loginKnown = parsed.loggedIn != nil
            status.accountLabel = [parsed.email, parsed.orgName, parsed.subscriptionType]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !status.loggedIn {
                status.errorMessage = "Claude Code 로그인이 필요합니다."
            }
        } else {
            status.errorMessage = "`claude auth status` 응답을 해석할 수 없습니다."
        }
        return status
    }

    /// 별칭이 지금 가리키는 모델을 CLI 에 묻는다. 토큰을 쓰지 않는다(`ModelProbe`).
    ///
    /// 종료 코드가 0 이 아니어도 출력은 읽는다 — 모델 ID 는 명령을 처리하기 전 첫 줄에 이미 나와 있다.
    public func probeModel(alias: String, path claudePath: String) async -> ModelProbe.Outcome? {
        AppPaths.ensureDirectories()
        let spec = ProcessSpec(executable: claudePath,
                               arguments: ModelProbe.arguments(alias: alias),
                               stdin: ModelProbe.prompt,
                               currentDirectory: AppPaths.claudeWorkingDirectory.path,
                               environment: ProcessEnvironment.base(),
                               timeout: 30,
                               gracePeriod: 2)
        guard let result = try? await runner.run(spec), !result.timedOut, !result.cancelled else { return nil }
        return ModelProbe.parse(streamJSON: result.stdout)
    }

    /// `claude --help` 의 글. `--effort` 가 받는 단계를 읽는다(`ModelProbe.effortLevels(inHelp:)`).
    /// 단계 이름은 앱이 정하지 않는다 — CLI 가 바꾸거나 늘려도 따라간다. 실행하지 못하면 nil.
    public func helpText(path claudePath: String) async -> String? {
        AppPaths.ensureDirectories()
        let spec = ProcessSpec(executable: claudePath,
                               arguments: ["--help"],
                               currentDirectory: AppPaths.claudeWorkingDirectory.path,
                               environment: ProcessEnvironment.base(),
                               timeout: 15,
                               gracePeriod: 2)
        guard let result = try? await runner.run(spec), !result.timedOut, !result.cancelled,
              !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    /// 리뷰 1건 = `claude -p` 1회.
    public func run(request: EngineRequest) async throws -> EngineRunResult {
        let invocation = ClaudeInvocation(claudePath: request.executablePath,
                                          systemPromptPath: request.guidePath,
                                          schemaJSON: request.schemaText,
                                          model: request.model ?? "sonnet",
                                          timeout: request.timeout,
                                          workingDirectory: request.workingDirectory,
                                          allowedTools: request.allowedTools,
                                          stdioDirectory: request.stdioDirectory,
                                          effort: request.effort,
                                          persistSession: request.persistSession)
        return try await run(prompt: request.prompt, invocation: invocation)
    }

    public func run(prompt: String, invocation: ClaudeInvocation) async throws -> EngineRunResult {
        AppPaths.ensureDirectories()
        let spec = ProcessSpec(executable: invocation.claudePath,
                               arguments: invocation.arguments,
                               stdin: prompt,
                               currentDirectory: invocation.workingDirectory,
                               environment: ProcessEnvironment.base(),
                               timeout: invocation.timeout,
                               gracePeriod: 5,
                               stdioDirectory: invocation.stdioDirectory)
        let result = try await runner.run(spec)
        // 프로세스가 끝난 뒤라면 토큰은 이미 소모됐다. 여기서 throw 하면 사용량이 원장에서 누락되므로
        // 항상 파싱해서 돌려주고, 취소 여부는 플래그로 알린다.
        var parsed = parse(result: result, model: invocation.model)
        parsed.cancelled = Task.isCancelled
        return parsed
    }

    /// 순수 파싱이라 actor 상태를 만지지 않는다. 앱이 죽은 뒤 결과를 수확할 때도 쓴다.
    nonisolated func parse(result: ProcessResult, model: String) -> EngineRunResult {
        var run = EngineRunResult(output: nil,
                                  usage: EngineUsage(model: model),
                                  isError: !result.succeeded,
                                  subtype: nil,
                                  terminalReason: nil,
                                  rawResult: nil,
                                  stderr: result.stderr,
                                  sessionID: nil,
                                  timedOut: result.timedOut,
                                  limitReached: false)

        guard let data = result.stdout.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if run.rawResult == nil, !result.stdout.isEmpty {
                run.rawResult = String(result.stdout.prefix(2000))
            }
            return run
        }

        run.isError = (root["is_error"] as? Bool) ?? !result.succeeded
        run.subtype = root["subtype"] as? String
        run.terminalReason = root["terminal_reason"] as? String
        run.sessionID = root["session_id"] as? String
        run.rawResult = root["result"] as? String

        var usage = EngineUsage(model: model)
        usage.durationMs = (root["duration_ms"] as? Int) ?? 0
        usage.costUSD = (root["total_cost_usd"] as? Double) ?? 0
        if let usageDict = root["usage"] as? [String: Any] {
            usage.inputTokens = (usageDict["input_tokens"] as? Int) ?? 0
            usage.cacheCreationTokens = (usageDict["cache_creation_input_tokens"] as? Int) ?? 0
            usage.cacheReadTokens = (usageDict["cache_read_input_tokens"] as? Int) ?? 0
            usage.outputTokens = (usageDict["output_tokens"] as? Int) ?? 0
        }
        if let modelUsage = root["modelUsage"] as? [String: Any] {
            // 여러 모델이 섞여 기록될 수 있다(구조화 출력 보조 호출 등). 가장 비싼 항목의 모델명을 남긴다.
            var best = 0.0
            for (name, value) in modelUsage {
                guard let entry = value as? [String: Any] else { continue }
                let cost = (entry["costUSD"] as? Double) ?? 0
                if cost >= best {
                    best = cost
                    usage.model = name
                }
            }
        }
        run.usage = usage

        if let structured = root["structured_output"] as? [String: Any],
           let structuredData = try? JSONSerialization.data(withJSONObject: structured) {
            run.structuredJSON = structuredData
            run.output = try? JSONDecoder().decode(ReviewOutput.self, from: structuredData)
        }
        if run.output == nil, let raw = run.rawResult, let rawData = raw.data(using: .utf8) {
            if run.structuredJSON == nil { run.structuredJSON = rawData }
            run.output = try? JSONDecoder().decode(ReviewOutput.self, from: rawData)
        }

        let haystack = [run.rawResult, run.terminalReason, run.subtype, result.stderr]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let limitPatterns = ["usage limit", "rate limit", "limit reached", "quota", "5-hour", "too many requests"]
        run.limitReached = run.isError && limitPatterns.contains { haystack.contains($0) }
        return run
    }
}
