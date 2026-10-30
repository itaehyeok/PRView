import Foundation

/// Codex CLI 로 리뷰한다. `codex exec` 한 번 = 리뷰 1건(Claude 의 `claude -p` 자리).
///
/// 실측(0.149.0, 2026-10-29)으로 정한 것:
/// - 구조화 출력은 `--output-schema`. OpenAI 엄격 스키마라 모든 속성이 required 여야 해서 `StrictSchema` 로 바꿔 넘긴다.
///   앱의 스키마 넷(리뷰·설명·대조·다시 확인)이 길이·개수 제한까지 그대로 통과했다.
/// - 시스템 프롬프트 파일 옵션이 없어 가이드를 프롬프트 앞에 붙인다.
/// - `--ignore-user-config`·`--ignore-rules`: 사용자의 config.toml(모델·MCP·훅)과 실행 규칙을 읽지 않는다. 인증은 그대로 쓴다.
/// - `-s read-only`: 파일을 쓰거나 네트워크로 나가는 명령을 막는다. 다만 **읽기는 디스크 전체**라, 도구가 필요 없는 리뷰는
///   셸을 아예 끈다 — `shell_tool`·`unified_exec` 둘을 끄면 모델이 명령을 부르지 못한다(실측: 파일을 읽으라 해도 "도구 없음").
///   `code_mode_host` 까지 끄면 실행마다 오류 이벤트만 하나 더 생겨서 남겨 둔다.
public actor CodexRunner {
    private let runner = ProcessRunner()
    /// 경로·버전마다 `codex features list` 결과. 끌 기능을 고를 때 쓴다.
    private var knownFeatures: [String: [String]] = [:]

    public init() {}

    /// npm·Homebrew 의 흔한 자리. 셸에 묻기 전에 본다.
    public static let candidatePaths: [String] = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "\(NSHomeDirectory())/.local/bin/codex",
    ]

    /// 셸에서도 못 찾았을 때. CLI 없이 Codex 앱만 쓰는 사람은 앱 안의 CLI 로 돈다 — 같은 로그인(`~/.codex`)을 쓴다.
    static var fallbackPaths: [String] {
        ExecutableLocator.userToolDirectories().map { "\($0)/codex" }
            + ["/Applications/Codex.app/Contents/Resources/codex",
               "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex"]
    }

    /// 공식 설치 명령(npm). Homebrew 를 쓰면 `brew install codex` 도 된다.
    public static let installCommand = "npm install -g @openai/codex"
    public static let loginCommand = "codex login"

    /// 도구가 필요 없는 호출에서 끄는 기능. CLI 가 모르는 이름은 넘기지 않는다(`CodexCatalog.features`).
    static let toolFeatures = ["shell_tool", "unified_exec"]
    /// 리뷰와 상관없는 기능 — 늘 끈다. 앱·플러그인·브라우저·이미지·하위 에이전트 같은 것이 PR 내용을 보고 움직이지 않게.
    static let unrelatedFeatures = ["apps", "plugins", "browser_use", "computer_use", "in_app_browser",
                                    "image_generation", "view_image", "multi_agent", "multi_agent_v2",
                                    "goals", "memories", "tool_suggest", "skill_search", "standalone_web_search"]

    public func discoverPath() async -> String? {
        await ExecutableLocator.find("codex", preferred: Self.candidatePaths, fallback: Self.fallbackPaths)
    }

    /// npm 으로 깐 codex 는 `#!/usr/bin/env node` 스크립트다. nvm 처럼 셸 설정으로만 PATH 에 드는 node 는 GUI 앱이
    /// 못 찾으므로, codex 가 있는 폴더(node 도 대개 같은 폴더)를 PATH 맨 앞에 둔다.
    static func environment(codexPath: String) -> [String: String] {
        let base = ProcessEnvironment.base()
        let folder = URL(fileURLWithPath: codexPath).deletingLastPathComponent().path
        return ProcessEnvironment.base(extra: ["PATH": folder + ":" + (base["PATH"] ?? "")])
    }

    public func status(path: String) async -> EngineStatus {
        var status = EngineStatus(path: path)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            status.errorMessage = "실행 파일이 없습니다: \(path)"
            return status
        }
        let env = Self.environment(codexPath: path)
        guard let version = try? await runner.run(ProcessSpec(executable: path, arguments: ["--version"],
                                                              environment: env, timeout: 20)),
              version.succeeded, let parsed = CodexModelProbe.version(inVersionOutput: version.stdout) else {
            status.errorMessage = "`codex --version` 실행에 실패했습니다."
            return status
        }
        status.version = parsed
        guard let login = try? await runner.run(ProcessSpec(executable: path, arguments: ["login", "status"],
                                                            environment: env, timeout: 20)) else {
            status.errorMessage = "`codex login status` 실행에 실패했습니다."
            return status
        }
        // 결과는 **stderr** 로 나온다("Logged in using ChatGPT", 실측). 두 쪽을 다 본다.
        let text = [login.stdout, login.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        status.loginKnown = !text.isEmpty
        status.loggedIn = login.succeeded && text.lowercased().contains("logged in")
        if status.loggedIn {
            // "Logged in using ChatGPT" → "ChatGPT", "Logged in using an API key - sk-…" → "API 키"
            let lower = text.lowercased()
            status.accountLabel = lower.contains("chatgpt") ? "ChatGPT" : (lower.contains("api key") ? "API 키" : nil)
        } else {
            status.errorMessage = "Codex 로그인이 필요합니다."
        }
        return status
    }

    // MARK: - 모델 목록

    /// 모델 목록과 기능 이름을 묻는다. 토큰을 쓰지 않는다(`CodexModelProbe`). 못 물으면 nil.
    public func probeCatalog(path: String, version: String) async -> CodexCatalog? {
        async let models = probeModels(path: path)
        async let features = features(path: path)
        guard let list = await models, !list.isEmpty else { return nil }
        return CodexCatalog(codexPath: path, codexVersion: version, models: list,
                            features: await features, checkedAt: Date())
    }

    /// `codex features list`. 실행 파일이 그대로면 다시 묻지 않는다 — 앱이 켜진 채 CLI 를 올려도 실제 파일(링크가 가리키는
    /// 것)의 수정 시각이 바뀌어 다시 묻는다. 지난 목록으로 사라진 이름을 넘기면 codex 가 멈춘다.
    func features(path: String) async -> [String] {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: real)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(real)|\(modified)"
        if let cached = knownFeatures[key] { return cached }
        let spec = ProcessSpec(executable: path, arguments: ["features", "list"],
                               currentDirectory: AppPaths.claudeWorkingDirectory.path,
                               environment: Self.environment(codexPath: path), timeout: 20, gracePeriod: 2)
        guard let result = try? await runner.run(spec), result.succeeded else { return [] }
        let names = CodexModelProbe.features(inList: result.stdout)
        if !names.isEmpty { knownFeatures[key] = names }
        return names
    }

    /// `codex app-server` 에 `model/list` 를 묻는다. 답을 받을 때까지 표준 입력을 열어 둬야 해서 ProcessRunner 를 쓰지 않는다.
    func probeModels(path: String, timeout: TimeInterval = 20) async -> [CodexModel]? {
        AppPaths.ensureDirectories()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = AppPaths.claudeWorkingDirectory
        process.environment = Self.environment(codexPath: path)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let lines = CodexModelProbe.requestLines.joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(lines.utf8))

        let box = ProbeProcess(process: process, input: input)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[CodexModel]?, Never>) in
            let finish: @Sendable ([CodexModel]?) -> Void = { models in
                // 답을 받았거나 시간이 지났다. 입력을 닫으면 스스로 끝나고, 안 끝나면 끈다 — 막혀 있던 읽기도 이걸로 풀린다.
                guard box.claim() else { return }
                box.stop()
                continuation.resume(returning: models)
            }
            let handle = output.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { return finish(nil) }   // 끝났는데 답이 없다
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let models = CodexModelProbe.models(inResponseLine: line) { return finish(models) }
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: - 실행

    /// 리뷰·설명·대조·다시 확인 1건. 모델·effort 는 부르는 쪽이 Codex 이름으로 풀어 준다(`CodexModels.resolve`).
    public func run(request: EngineRequest) async throws -> EngineRunResult {
        AppPaths.ensureDirectories()
        // 결과를 남길 폴더를 받았으면(본 리뷰) 거기에 둔다 — 앱이 죽은 뒤 수확할 때 마지막 메시지 파일도 읽는다.
        let scratch: URL
        let ownsScratch: Bool
        if let spool = request.stdioDirectory {
            scratch = spool
            ownsScratch = false
        } else {
            scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("prayer-codex-\(UUID().uuidString)", isDirectory: true)
            ownsScratch = true
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { if ownsScratch { try? FileManager.default.removeItem(at: scratch) } }

        let schemaURL = scratch.appendingPathComponent("schema-strict.json")
        try Data((StrictSchema.strictified(request.schemaText) ?? request.schemaText).utf8).write(to: schemaURL)
        let lastMessage = Self.lastMessageURL(in: scratch)

        let known = await features(path: request.executablePath)
        let arguments = Self.arguments(request: request, schemaPath: schemaURL.path, lastMessagePath: lastMessage.path,
                                       knownFeatures: known)
        // 가이드는 프롬프트 앞에 붙인다(시스템 프롬프트 파일 옵션이 없다).
        let prompt = request.guideText + "\n\n---\n\n" + request.prompt
        let spec = ProcessSpec(executable: request.executablePath,
                               arguments: arguments,
                               stdin: prompt,
                               currentDirectory: request.workingDirectory,
                               environment: Self.environment(codexPath: request.executablePath),
                               timeout: request.timeout,
                               gracePeriod: 5,
                               stdioDirectory: request.stdioDirectory)
        let started = Date()
        let result = try await runner.run(spec)
        var parsed = Self.parse(result: result, lastMessageURL: lastMessage, model: request.model ?? "")
        // 이벤트에 걸린 시간이 없다. 리뷰 시간 어림(`ClaudeStepEstimate`)이 지난 리뷰의 시간을 쓰므로 여기서 잰다.
        parsed.usage.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        parsed.cancelled = Task.isCancelled
        return parsed
    }

    static func lastMessageURL(in folder: URL) -> URL {
        folder.appendingPathComponent("last-message.json")
    }

    static func arguments(request: EngineRequest, schemaPath: String, lastMessagePath: String,
                          knownFeatures: [String]) -> [String] {
        var result = ["exec", "--json"]
        // 본 리뷰만 대화를 남긴다 — `codex resume <ID>` 로 이어 가게. 보조 호출이 사용자의 대화 목록을 덮지 않게 나머지는 지운다.
        if !request.persistSession { result.append("--ephemeral") }
        result += [
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "-s", "read-only",
            "-C", request.workingDirectory,
        ]
        // 전체 리뷰(읽기 도구를 연 호출)만 셸을 남긴다 — 샌드박스가 읽기 전용이라 호출부를 grep·cat 으로 읽기만 한다.
        let off = (request.allowedTools.isEmpty ? toolFeatures : []) + unrelatedFeatures
        for feature in off where knownFeatures.contains(feature) {
            result += ["--disable", feature]
        }
        result += ["-c", "web_search=\"disabled\""]
        if let model = request.model, !model.isEmpty {
            result += ["-m", model]
        }
        if let effort = request.effort {
            result += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        result += ["--output-schema", schemaPath, "-o", lastMessagePath, "-"]
        return result
    }

    /// 순수 파싱 — 앱이 죽은 뒤 결과를 수확할 때도 쓴다.
    ///
    /// 표준 출력은 이벤트 한 줄씩(JSONL)이다. 마지막 답은 `item.completed` 의 `agent_message` 에도 실려 오므로
    /// `-o` 파일이 없어도(수확) 표준 출력만으로 읽는다. 단 **턴이 끝났을 때(`turn.completed`)만** 그 메시지를 답으로 친다 —
    /// 전체 리뷰는 일하는 도중에도 `agent_message` 를 내고, 그것도 스키마 꼴(JSON)로 온다. 실측(2026-10-29):
    /// 리뷰 도중 앱이 꺼진 뒤 수확이 "…확인해 추리겠습니다" 라는 중간 메시지를 초안으로 저장했다(토큰 0·0초).
    static func parse(result: ProcessResult, lastMessageURL: URL, model: String) -> EngineRunResult {
        var run = EngineRunResult(output: nil, usage: EngineUsage(model: model), isError: !result.succeeded,
                                  stderr: result.stderr, timedOut: result.timedOut, engine: .codex)
        var lastText: String?
        var completed = false
        var failure: String?
        var usage = EngineUsage(model: model)
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "thread.started":
                run.sessionID = event["thread_id"] as? String
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    lastText = text
                }
            case "turn.completed":
                completed = true
                guard let counts = event["usage"] as? [String: Any] else { continue }
                // 캐시에서 읽은 입력은 입력의 일부로 온다. Claude 처럼 따로 센다.
                let input = (counts["input_tokens"] as? Int) ?? 0
                let cached = (counts["cached_input_tokens"] as? Int) ?? 0
                usage.inputTokens = max(0, input - cached)
                usage.cacheReadTokens = cached
                usage.cacheCreationTokens = (counts["cache_write_input_tokens"] as? Int) ?? 0
                usage.outputTokens = (counts["output_tokens"] as? Int) ?? 0
            case "turn.failed":
                failure = ((event["error"] as? [String: Any])?["message"] as? String) ?? failure
            case "error":
                // 실행 중 경고성 오류도 이 이름으로 온다. 답이 없을 때만 원인으로 쓴다.
                failure = failure ?? (event["message"] as? String)
            default:
                continue
            }
        }
        // ChatGPT 구독으로 도는 경로라 달러 값이 없다. 원장에는 토큰만 남는다.
        usage.costUSD = 0
        run.usage = usage

        // `-o` 파일은 codex 가 끝에 쓴다 — 있으면 끝난 것이다. 이벤트의 메시지는 턴이 끝났을 때만 믿는다.
        let fileText = (try? Data(contentsOf: lastMessageURL)).flatMap { String(data: $0, encoding: .utf8) }
        let text = [fileText, completed ? lastText : nil].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let text {
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
                ? text : extractJSONObject(from: text)
            if let json {
                run.structuredJSON = Data(json.utf8)
                run.output = try? JSONDecoder().decode(ReviewOutput.self, from: Data(json.utf8))
            }
        }
        run.rawResult = text ?? failure
        run.isError = !result.succeeded || run.structuredJSON == nil
        if run.structuredJSON == nil {
            let haystack = [failure, result.stderr].compactMap { $0 }.joined(separator: " ")
            run.limitReached = LimitDetector.matches(haystack)
        }
        return run
    }

    /// 모델이 코드펜스나 설명을 덧붙였을 때 첫 JSON 객체만 뽑는다.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// 모델 목록을 묻는 app-server 프로세스. 답을 받은 쪽과 시간이 다 된 쪽 중 **먼저 온 하나만** 끝맺게 한다.
private final class ProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private let process: Process
    private let input: Pipe

    init(process: Process, input: Pipe) {
        self.process = process
        self.input = input
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
