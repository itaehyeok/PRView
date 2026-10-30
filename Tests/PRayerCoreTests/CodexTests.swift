import XCTest
@testable import PRayerCore

/// 0.149.0 의 `model/list` 응답에서 줄인 것(설명·서비스 등급은 뺐다).
private func listLine(_ models: [(id: String, name: String, isDefault: Bool, effort: String, efforts: [String])],
                      hidden: [String] = []) -> String {
    let items = models.map { model -> [String: Any] in
        ["id": model.id, "model": model.id, "displayName": model.name, "description": "d",
         "hidden": hidden.contains(model.id), "isDefault": model.isDefault,
         "defaultReasoningEffort": model.effort,
         "supportedReasoningEfforts": model.efforts.map { ["reasoningEffort": $0, "description": "x"] }]
    }
    let root: [String: Any] = ["id": 2, "result": ["data": items, "nextCursor": NSNull()]]
    let data = try! JSONSerialization.data(withJSONObject: root)
    return String(decoding: data, as: UTF8.self)
}

private let sixLevels = ["low", "medium", "high", "xhigh", "max", "ultra"]

private func catalog(_ ids: [String], defaultID: String? = nil) -> CodexCatalog {
    CodexCatalog(codexPath: "/x/codex", codexVersion: "0.149.0",
                 models: ids.map { CodexModel(id: $0, displayName: CodexModels.displayName(forModelID: $0),
                                              isDefault: $0 == defaultID, defaultEffort: "medium",
                                              efforts: $0.hasSuffix("luna") ? Array(sixLevels.prefix(5)) : sixLevels) },
                 features: ["shell_tool", "unified_exec", "apps"], checkedAt: Date())
}

final class CodexModelProbeTests: XCTestCase {
    func testParsesModelListResponse() {
        let line = listLine([("gpt-5.6-sol", "GPT-5.6-Sol", true, "low", sixLevels),
                             ("gpt-5.6-luna", "GPT-5.6-Luna", false, "medium", Array(sixLevels.prefix(5))),
                             ("codex-auto-review", "Codex Auto Review", false, "medium", sixLevels)],
                            hidden: ["codex-auto-review"])
        let models = CodexModelProbe.models(inResponseLine: line)
        XCTAssertEqual(models?.map(\.id), ["gpt-5.6-sol", "gpt-5.6-luna"], "숨김 모델은 뺀다")
        XCTAssertEqual(models?.first?.isDefault, true)
        XCTAssertEqual(models?.first?.defaultEffort, "low")
        XCTAssertEqual(models?.last?.efforts, ["low", "medium", "high", "xhigh", "max"], "모델마다 받는 단계가 다르다")
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(CodexModelProbe.models(inResponseLine: #"{"id":1,"result":{"userAgent":"x"}}"#))
        XCTAssertNil(CodexModelProbe.models(inResponseLine: #"{"method":"remoteControl/status/changed","params":{}}"#))
        XCTAssertNil(CodexModelProbe.models(inResponseLine: "not json"))
    }

    /// `codex features list` 의 실제 꼴. removed 는 끌 것이 없으니 뺀다.
    func testParsesFeatureList() {
        let text = """
        apply_patch_freeform                     removed            false
        shell_tool                               stable             true
        unified_exec                             stable             true
        multi_agent_v2                           stable             false
        """
        XCTAssertEqual(CodexModelProbe.features(inList: text), ["shell_tool", "unified_exec", "multi_agent_v2"])
    }

    func testParsesVersion() {
        XCTAssertEqual(CodexModelProbe.version(inVersionOutput: "codex-cli 0.149.0\n"), "0.149.0")
        XCTAssertNil(CodexModelProbe.version(inVersionOutput: "error"))
    }
}

final class CodexModelsTests: XCTestCase {
    func testEngineComesFromModelValue() {
        XCTAssertEqual(ReviewEngineKind(model: "opus"), .claude)
        XCTAssertEqual(ReviewEngineKind(model: "claude-opus-5"), .claude)
        XCTAssertEqual(ReviewEngineKind(model: "codex:sol"), .codex)
        XCTAssertEqual(ReviewEngineKind(model: "codex:gpt-5.6-sol"), .codex)
    }

    /// 계열은 목록에서 가장 새 버전으로 풀린다 — Codex 가 새 버전을 내면 고른 계열이 저절로 따라간다.
    func testFamilyFollowsNewestVersion() {
        let old = catalog(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"], defaultID: "gpt-5.6-sol")
        XCTAssertEqual(CodexModels.resolve("codex:sol", catalog: old), "gpt-5.6-sol")
        let new = catalog(["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-5.6-sol"], defaultID: "gpt-6.1-sol")
        XCTAssertEqual(CodexModels.resolve("codex:sol", catalog: new), "gpt-6.1-sol")
        XCTAssertEqual(CodexModels.options(catalog: new).map(\.id), ["codex:sol", "codex:astra", "codex:terra"],
                       "계열 순서는 Codex 가 준 목록에서 처음 나온 자리")
        XCTAssertEqual(CodexModels.options(catalog: new).first?.label, "GPT-6.1-Sol")
    }

    func testPinnedVersionStaysPut() {
        let new = catalog(["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol"])
        XCTAssertEqual(CodexModels.resolve("codex:gpt-6-sol", catalog: new), "gpt-6-sol")
        XCTAssertEqual(CodexModels.pastOptions(catalog: new).map(\.id), ["codex:gpt-6-sol", "codex:gpt-5.6-sol"],
                       "지난 버전은 같은 계열 안에서 새것이 위")
        // 목록에 없어도 버전까지 적힌 이름은 그대로 넘긴다(지난 버전·직접 입력).
        XCTAssertEqual(CodexModels.resolve("codex:gpt-5-sol", catalog: new), "gpt-5-sol")
    }

    /// 목록에 없는 계열 이름은 모델 이름이 아니라서 넘기지 않는다 — Codex 기본 모델로 돈다.
    func testUnknownFamilyFallsBackToDefault() {
        XCTAssertNil(CodexModels.resolve("codex:sol", catalog: nil))
        XCTAssertNil(CodexModels.resolve("codex:", catalog: catalog(["gpt-5.6-sol"])))
        XCTAssertNil(CodexModels.resolve("opus", catalog: catalog(["gpt-5.6-sol"])))
    }

    func testDefaultChoiceIsFamilyOfCodexDefault() {
        XCTAssertEqual(CodexModels.defaultChoice(catalog: catalog(["gpt-5.6-sol", "gpt-5.6-luna"], defaultID: "gpt-5.6-luna")),
                       "codex:luna")
        XCTAssertEqual(CodexModels.defaultChoice(catalog: nil), "codex:")
    }

    /// effort 단계는 모델마다 Codex 가 알려 준 것. 그 모델이 받지 않는 단계는 넘기지 않는다.
    func testEffortFollowsModel() {
        let list = catalog(["gpt-5.6-sol", "gpt-5.6-luna"])
        XCTAssertEqual(CodexModels.effortLevels(choice: "codex:sol", catalog: list).last, "ultra")
        XCTAssertEqual(CodexModels.effortLevels(choice: "codex:luna", catalog: list).last, "max")
        XCTAssertEqual(CodexModels.effortArgument("ultra", choice: "codex:sol", catalog: list), "ultra")
        XCTAssertNil(CodexModels.effortArgument("ultra", choice: "codex:luna", catalog: list))
        XCTAssertNil(CodexModels.effortArgument("", choice: "codex:sol", catalog: list), "빈 값은 모델 기본값")
        XCTAssertEqual(CodexModels.effortLevels(choice: "codex:sol", catalog: nil), CodexModels.fallbackEfforts)
    }

    func testDisplayNameFromID() {
        XCTAssertEqual(CodexModels.displayName(forModelID: "gpt-5.6-sol"), "GPT-5.6-Sol")
        XCTAssertEqual(CodexModels.displayName(forModelID: "o3"), "o3")
    }

    func testCatalogGoesStale() {
        var list = catalog(["gpt-5.6-sol"])
        XCTAssertTrue(list.isFresh(path: "/x/codex", version: "0.149.0"))
        XCTAssertFalse(list.isFresh(path: "/x/codex", version: "0.150.0"), "CLI 를 올리면 다시 묻는다")
        list.checkedAt = Date(timeIntervalSinceNow: -CodexCatalog.maxAge - 1)
        XCTAssertFalse(list.isFresh(path: "/x/codex", version: "0.149.0"), "서버 목록이 바뀔 수 있어 오래되면 다시 묻는다")
    }
}

final class CodexRunnerTests: XCTestCase {
    private func request(tools: [String] = [], persist: Bool = false, model: String? = "gpt-5.6-sol",
                         effort: String? = "high") -> EngineRequest {
        EngineRequest(prompt: "p", executablePath: "/x/codex", guidePath: "/g", guideText: "g",
                      schemaPath: "/s", schemaText: "{}", model: model, timeout: 10, workingDirectory: "/w",
                      allowedTools: tools, effort: effort, persistSession: persist, engine: .codex)
    }

    /// 도구가 필요 없는 호출은 셸을 끈다. CLI 가 모르는 기능 이름은 넘기지 않는다(넘기면 codex 가 멈춘다).
    func testDiffReviewTurnsShellOff() {
        let args = CodexRunner.arguments(request: request(), schemaPath: "/s2", lastMessagePath: "/o",
                                         knownFeatures: ["shell_tool", "unified_exec", "apps"])
        XCTAssertEqual(disabled(args), ["shell_tool", "unified_exec", "apps"])
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertEqual(value(after: "-m", in: args), "gpt-5.6-sol")
        XCTAssertTrue(args.contains("model_reasoning_effort=\"high\""))
        XCTAssertEqual(value(after: "-s", in: args), "read-only")
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertEqual(args.last, "-", "프롬프트는 표준 입력")
    }

    /// 전체 리뷰는 읽기 전용 샌드박스에서 셸을 남겨 호출부를 읽게 하고, 대화를 남겨 이어 가게 한다.
    func testDeepReviewKeepsShellAndSession() {
        let args = CodexRunner.arguments(request: request(tools: ["Read"], persist: true, model: nil, effort: nil),
                                         schemaPath: "/s2", lastMessagePath: "/o",
                                         knownFeatures: ["shell_tool", "unified_exec", "apps"])
        XCTAssertEqual(disabled(args), ["apps"])
        XCTAssertFalse(args.contains("--ephemeral"))
        XCTAssertFalse(args.contains("-m"), "모델을 못 풀었으면 Codex 기본 모델")
        XCTAssertFalse(args.contains { $0.hasPrefix("model_reasoning_effort") })
    }

    /// 0.149.0 실제 이벤트 꼴. 마지막 답은 `-o` 파일이 없어도 이벤트에서 읽는다(앱이 죽은 뒤 수확).
    func testParsesEventStream() throws {
        let answer = #"{"verdict":"approve","summary_ko":"요약","strengths":[],"code_comments":[]}"#
        let escaped = answer.replacingOccurrences(of: "\"", with: "\\\"")
        let stdout = """
        {"type":"thread.started","thread_id":"01a184ac-56f6-7611-bd83-51042539f60b"}
        {"type":"turn.started"}
        {"type":"error","message":"경고성 오류"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"\(escaped)"}}
        {"type":"turn.completed","usage":{"input_tokens":6272,"cached_input_tokens":2000,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0}}
        """
        let run = CodexRunner.parse(result: ProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false),
                                    lastMessageURL: URL(fileURLWithPath: "/nonexistent/last.json"), model: "gpt-5.6-sol")
        XCTAssertEqual(run.output?.verdict, .approve)
        XCTAssertFalse(run.isError, "답이 있으면 경고성 오류 이벤트는 실패가 아니다")
        XCTAssertEqual(run.sessionID, "01a184ac-56f6-7611-bd83-51042539f60b")
        XCTAssertEqual(run.usage.inputTokens, 4272)
        XCTAssertEqual(run.usage.cacheReadTokens, 2000)
        XCTAssertEqual(run.usage.outputTokens, 30)
        XCTAssertEqual(run.engine, .codex)
    }

    /// 전체 리뷰는 도중에도 스키마 꼴의 `agent_message` 를 낸다. 턴이 안 끝났으면(앱이 꺼진 뒤 수확) 답이 아니다.
    func testInterimMessageIsNotTheAnswer() {
        let interim = #"{"verdict":"approve","summary_ko":"호출부를 확인해 추리겠습니다.","strengths":[],"code_comments":[]}"#
        let escaped = interim.replacingOccurrences(of: "\"", with: "\\\"")
        let stdout = """
        {"type":"thread.started","thread_id":"01a1865c-4c86-7240-9ff0-21817156bff5"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"\(escaped)"}}
        {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"rg foo"}}
        """
        let run = CodexRunner.parse(result: ProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false),
                                    lastMessageURL: URL(fileURLWithPath: "/nonexistent/last.json"), model: "gpt-5.6-sol")
        XCTAssertNil(run.output)
        XCTAssertNil(run.structuredJSON)
        XCTAssertTrue(run.isError)
    }

    func testFailedTurnReportsMessage() {
        let stdout = #"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#
        let run = CodexRunner.parse(result: ProcessResult(exitCode: 1, stdout: stdout, stderr: "", timedOut: false),
                                    lastMessageURL: URL(fileURLWithPath: "/nonexistent"), model: "m")
        XCTAssertNil(run.output)
        XCTAssertTrue(run.isError)
        XCTAssertTrue(run.limitReached)
        XCTAssertEqual(run.failureMessage, "Codex 사용 한도에 도달했습니다.")
    }

    /// 엄격 스키마의 선택 필드는 null 로 온다. 그래도 초안으로 읽혀야 한다.
    func testStrictNullsDecode() throws {
        let json = """
        {"verdict":"comment","summary_ko":"s","strengths":[],
         "code_comments":[{"issue_key":"k","importance":"recommended","path":"A.swift","line":3,"side":"RIGHT",
           "body":"b","anchor_text":"let x = 1","rationale_ko":"r","start_line":null,"duplicates_existing":null,
           "existing_note":null,"evidence":null}]}
        """
        let output = try JSONDecoder().decode(ReviewOutput.self, from: Data(json.utf8))
        XCTAssertEqual(output.draftComments.first?.startLine, nil)
        XCTAssertEqual(output.draftComments.count, 1)
    }

    func testExtractsJSONObjectFromNoisyOutput() {
        XCTAssertEqual(CodexRunner.extractJSONObject(from: "앞말 ```json\n{\"a\":{\"b\":\"}\"},\"c\":1}\n``` 뒷말"),
                       "{\"a\":{\"b\":\"}\"},\"c\":1}")
        XCTAssertNil(CodexRunner.extractJSONObject(from: "JSON 이 없습니다"))
    }

    func testResumeCommand() {
        XCTAssertEqual(ClaudeSession.resumeCommand(sessionID: "01A184AC-56F6-7611-BD83-51042539F60B", engine: .codex),
                       "codex resume 01a184ac-56f6-7611-bd83-51042539f60b")
        XCTAssertNil(ClaudeSession.resumeCommand(sessionID: "x; rm -rf ~", engine: .codex))
    }

    private func disabled(_ args: [String]) -> [String] {
        args.indices.compactMap { args[$0] == "--disable" && $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}

final class StrictSchemaTests: XCTestCase {
    /// OpenAI 구조화 출력은 properties 의 모든 키가 required 에 있어야 한다(실측: 없으면 400 invalid_json_schema).
    func testAllPropertiesBecomeRequiredAndOptionalsNullable() throws {
        let source = """
        { "type": "object", "additionalProperties": false,
          "required": ["verdict"],
          "properties": {
            "verdict": { "enum": ["approve", "comment"] },
            "line": { "type": "integer" },
            "side": { "enum": ["LEFT", "RIGHT"] }
          } }
        """
        let strict = try XCTUnwrap(StrictSchema.strictified(source))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(strict.utf8)) as? [String: Any])
        XCTAssertEqual(Set((root["required"] as? [String]) ?? []), ["verdict", "line", "side"])
        let properties = root["properties"] as? [String: Any] ?? [:]
        XCTAssertNil((properties["verdict"] as? [String: Any])?["type"], "필수였던 필드는 그대로")
        XCTAssertEqual((properties["line"] as? [String: Any])?["type"] as? [String], ["integer", "null"])
        XCTAssertEqual(((properties["side"] as? [String: Any])?["enum"] as? [Any])?.count, 3, "enum 에도 null")
    }

    /// 앱이 쓰는 스키마 넷 전부. 실측(0.149.0): 변환한 넷을 codex 가 길이·개수 제한까지 그대로 받았다.
    func testBundledSchemasBecomeStrict() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["schema", "explain-schema", "relevance-schema", "recheck-schema"] {
            let text = try String(contentsOf: root.appendingPathComponent("Resources/\(name).json"), encoding: .utf8)
            let strict = try XCTUnwrap(StrictSchema.strictified(text), name)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(strict.utf8)) as? [String: Any])
            assertStrict(object, path: name)
        }
    }

    private func assertStrict(_ node: [String: Any], path: String) {
        if let properties = node["properties"] as? [String: Any] {
            XCTAssertEqual(Set((node["required"] as? [String]) ?? []), Set(properties.keys), "\(path): 모든 속성이 required")
            XCTAssertEqual(node["additionalProperties"] as? Bool, false, "\(path): additionalProperties=false")
            for (key, value) in properties {
                if let child = value as? [String: Any] { assertStrict(child, path: "\(path).\(key)") }
            }
        }
        if let items = node["items"] as? [String: Any] { assertStrict(items, path: "\(path)[]") }
    }
}
