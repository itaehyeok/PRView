import XCTest
@testable import PRayerCore

/// 모델 목록을 CLI 에 묻는 경로. 새 모델이 나와도 코드를 고치지 않고 목록에 뜨게 하는 장치다.
final class ModelCatalogTests: XCTestCase {
    /// 2026-09-29 실측(Claude Code 2.1.258, `--model opus`, 입력 `/model`)에서 필요한 필드만 남겼다.
    static let probeOutput = """
    {"type":"system","subtype":"init","cwd":"/tmp","session_id":"s","model":"claude-opus-5","claude_code_version":"2.1.258"}
    {"type":"assistant","is_meta":true,"local_command_source":"/model","message":{"role":"assistant","content":[]}}
    {"type":"result","subtype":"success","is_error":false,"num_turns":0,"total_cost_usd":0,"result":"Current model: `Opus 5` (effort: medium)\\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."}
    """

    // MARK: - CLI 출력 읽기

    func testProbeReadsModelIDAndShownName() {
        let outcome = ModelProbe.parse(streamJSON: Self.probeOutput)
        XCTAssertEqual(outcome.model, ResolvedModel(modelID: "claude-opus-5", displayName: "Opus 5",
                                                    defaultEffort: "medium"))
        XCTAssertFalse(outcome.spentTokens)
        XCTAssertTrue(outcome.recognized)
        XCTAssertEqual(outcome.availableAliases, ["sonnet", "opus", "haiku", "fable", "best", "opusplan", "default"],
                       "`sonnet[1m]` 같은 변형과 \"a full model ID\" 는 뺀다")
    }

    /// 모르는 이름도 CLI 는 받아 주지만, 표시 이름 없이 그대로 되풀이한다(실측 2.1.284). 직접 입력을 이걸로 거른다.
    func testUnknownNameIsEchoedRaw() {
        let unknown = """
        {"type":"system","subtype":"init","model":"claude-foo-9"}
        {"type":"result","num_turns":0,"total_cost_usd":0,"result":"Current model: `claude-foo-9`\\nUsage: /model <name>."}
        """
        let outcome = ModelProbe.parse(streamJSON: unknown)
        XCTAssertEqual(outcome.model?.modelID, "claude-foo-9")
        XCTAssertFalse(outcome.recognized)

        let pinned = """
        {"type":"system","subtype":"init","model":"claude-haiku-4-5"}
        {"type":"result","num_turns":0,"total_cost_usd":0,"result":"Current model: `Haiku 4.5`"}
        """
        XCTAssertTrue(ModelProbe.parse(streamJSON: pinned).recognized, "지난 버전 이름은 CLI 가 안다")
        XCTAssertTrue(ModelProbe.parse(streamJSON: """
        {"type":"system","subtype":"init","model":"claude-opus-5-5"}
        {"type":"result","num_turns":0,"total_cost_usd":0,"result":"모델: opus"}
        """).recognized, "문장 꼴이 바뀌어 모르면 막지 않는다")
    }

    /// 새 계열은 `/model` 의 "Available:" 에서 찾되, 같은 이름의 계열 모델로 풀리는 별칭만 계열로 친다.
    func testFamilyRuleDropsBorrowedAliases() {
        func model(_ id: String) -> ResolvedModel { ResolvedModel(modelID: id, displayName: id) }
        XCTAssertTrue(ModelProbe.isFamily(alias: "fable", resolvedTo: model("claude-fable-5-1")))
        XCTAssertTrue(ModelProbe.isFamily(alias: "mythos", resolvedTo: model("claude-mythos-1")), "앱이 모르는 새 계열")
        // 실측 2.1.284: best → Fable 5.1, default → Opus 5.5, opusplan → Sonnet 5.5.
        XCTAssertFalse(ModelProbe.isFamily(alias: "best", resolvedTo: model("claude-fable-5-1")))
        XCTAssertFalse(ModelProbe.isFamily(alias: "default", resolvedTo: model("claude-opus-5-5")))
        XCTAssertFalse(ModelProbe.isFamily(alias: "opusplan", resolvedTo: model("claude-sonnet-5-5")))
    }

    func testAvailableAliasesKeepPlainWordsOnly() {
        XCTAssertEqual(ModelProbe.availableAliases(in: "Usage: /model <name>. Available: sonnet, mythos, sonnet[1m], or a full model ID."),
                       ["sonnet", "mythos"])
        XCTAssertEqual(ModelProbe.availableAliases(in: "Current model: `Opus 5`"), [], "목록이 없으면 빈 배열")
        XCTAssertEqual(ModelProbe.availableAliases(in: "Available: opus\nNext line: haiku, fable"), ["opus"],
                       "그 줄만 읽는다")
    }

    // MARK: - effort 단계 (`claude --help`)

    /// 2.1.284 의 `claude --help` 에서 그대로 옮겼다 — 괄호가 둘째 줄에 있다.
    static let helpSnippet = """
      --disallowedTools <tools...>          Comma or space-separated list of tool names
                                            to deny (e.g. "Bash(git:*) Edit")
      --effort <level>                      Effort level for the current session
                                            (low, medium, high, xhigh, max)
      --environment <environment_id>        Create a new cloud session that runs on
                                            the given self-hosted environment
    """

    func testEffortLevelsComeFromHelp() {
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: Self.helpSnippet), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: "  --effort <level>  Effort level (quick, thorough, ultra)"),
                       ["quick", "thorough", "ultra"], "이름이 바뀌거나 늘어도 CLI 가 적은 대로")
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: "  --effort <level>  Effort (beta) for the session (low, max)"),
                       ["low", "max"], "단계가 둘 이상 나열된 괄호를 쓴다")
    }

    func testEffortLevelsStayInsideTheEffortOption() {
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: """
          --effort <level>    Effort level for the session
          --foo <x>           Foo (a, b, c)
        """), [], "다음 옵션의 괄호는 읽지 않는다")
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: "  --effort-budget <n>  Budget (low, high)"), [],
                       "이름이 비슷한 다른 옵션")
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: "  --model <model>  Model (sonnet, opus)"), [])
        XCTAssertEqual(ModelProbe.effortLevels(inHelp: "  --effort <level>  Effort (Low, High)"), [],
                       "CLI 가 받지 않는 꼴(대문자)이면 믿지 않는다")
    }

    /// CLI 는 기본 effort 를 모델에 따라 밝히기도 하고 안 밝히기도 한다. 안 밝히면 지어내지 않는다.
    func testDefaultEffortOnlyWhenCLISaysSo() {
        XCTAssertEqual(ModelProbe.currentEffort(in: "Current model: `Opus 5` (effort: medium)\nUsage: …"), "medium")
        XCTAssertNil(ModelProbe.currentEffort(in: "Current model: `Sonnet 5`\nUsage: … (effort: high)"),
                     "다른 줄의 괄호는 읽지 않는다")
        XCTAssertEqual(ModelProbe.currentEffort(in: "Current model: `Opus 5` (effort: turbo)"), "turbo",
                       "CLI 가 새 단계를 밝히면 그대로 받는다")
        XCTAssertNil(ModelProbe.currentEffort(in: "Current model: `Opus 5` (effort: Very High)"), "단계 이름 꼴이 아니다")
    }

    /// 결과 문장은 사람이 읽는 글이라 언제든 바뀔 수 있다. 그래도 모델 ID 는 init 줄에서 읽으니 이름을 만든다.
    func testNamesModelFromIDWhenSentenceChanges() {
        let output = """
        {"type":"system","subtype":"init","model":"claude-opus-5-5"}
        {"type":"result","num_turns":0,"total_cost_usd":0,"result":"모델: opus"}
        """
        XCTAssertEqual(ModelProbe.parse(streamJSON: output).model,
                       ResolvedModel(modelID: "claude-opus-5-5", displayName: "Opus 5.5"))
    }

    /// CLI 가 `/model` 을 API 로 넘기게 바뀌면 앱이 켤 때마다 몰래 토큰을 쓴다. 그걸 알아채야 한다.
    func testNoticesTokenSpend() {
        let output = """
        {"type":"system","subtype":"init","model":"claude-sonnet-5"}
        {"type":"result","num_turns":1,"total_cost_usd":0.0123,"result":"I can't change models."}
        """
        let outcome = ModelProbe.parse(streamJSON: output)
        XCTAssertTrue(outcome.spentTokens)
        XCTAssertEqual(outcome.model?.modelID, "claude-sonnet-5", "쓴 건 쓴 거고, 알아낸 모델은 남긴다")
    }

    func testNoInitLineMeansNoModel() {
        let output = #"{"type":"result","num_turns":0,"total_cost_usd":0,"result":"Current model: `Opus 5`"}"#
        XCTAssertNil(ModelProbe.parse(streamJSON: output).model)
    }

    func testSkipsLinesThatAreNotJSON() {
        let output = "warning: something odd\n" + Self.probeOutput + "\n\n"
        XCTAssertEqual(ModelProbe.parse(streamJSON: output).model?.modelID, "claude-opus-5")
    }

    func testDisplayNameFromModelID() {
        XCTAssertEqual(ClaudeModels.displayName(forModelID: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeModels.displayName(forModelID: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ClaudeModels.displayName(forModelID: "claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ClaudeModels.displayName(forModelID: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        // 꼴이 다르면 지어내지 않고 원문을 보인다.
        XCTAssertEqual(ClaudeModels.displayName(forModelID: "claude-3-7-sonnet-20250219"), "claude-3-7-sonnet-20250219")
        XCTAssertEqual(ClaudeModels.displayName(forModelID: "claude-opus-5-5[1m]"), "claude-opus-5-5[1m]")
    }

    /// 격리 플래그가 빠지면 CLAUDE.md·MCP 를 읽거나 도구를 쥔 채로 돈다. 리뷰와 같은 수준을 지킨다.
    func testProbeArgumentsKeepIsolation() {
        let args = ModelProbe.arguments(alias: "opus")
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).map { args[args.index(after: $0)] }
        }
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--model"), "opus")
        XCTAssertEqual(value(after: "--output-format"), "stream-json")
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--no-session-persistence", "--verbose"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        XCTAssertEqual(ModelProbe.prompt, "/model")
    }

    // MARK: - 목록에 입히기

    func testCatalogRelabelsOnlyWhatItKnows() {
        let catalog = Self.catalog(["opus": ResolvedModel(modelID: "claude-opus-5-5", displayName: "Opus 5.5")])
        let opus = ClaudeModels.option(id: "opus", catalog: catalog)
        XCTAssertEqual(opus?.id, "opus", "설정에 저장되는 별칭은 그대로여야 한다")
        XCTAssertEqual(opus?.label, "Opus 5.5")
        XCTAssertEqual(opus?.apiID, "claude-opus-5-5")

        let sonnet = ClaudeModels.option(id: "sonnet", catalog: catalog)
        XCTAssertEqual(sonnet, ClaudeModels.option(id: "sonnet"), "묻지 못한 계열은 기본값 그대로")
    }

    /// 새 버전이 나오면 같은 계열 칸의 이름만 바뀐다. 코드를 고칠 곳이 없다.
    func testNewVersionTakesOverItsFamily() throws {
        let catalog = Self.catalog(["opus": ResolvedModel(modelID: "claude-opus-6", displayName: "Opus 6")])
        let options = ClaudeModels.options(catalog: catalog)
        XCTAssertEqual(options.map(\.id), ClaudeModels.all.map(\.id), "계열과 순서는 바뀌지 않는다")
        XCTAssertEqual(try XCTUnwrap(options.first { $0.id == "opus" }).label, "Opus 6")
    }

    /// CLI 가 알려 준 새 계열은 네 계열 뒤에 붙는다. 이미 아는 계열은 두 번 넣지 않는다.
    func testExtraFamiliesFollowTheKnownFour() {
        var catalog = Self.catalog(["mythos": ResolvedModel(modelID: "claude-mythos-1", displayName: "Mythos 1"),
                                    "opus": ResolvedModel(modelID: "claude-opus-5-5", displayName: "Opus 5.5")])
        catalog.extraFamilies = ["mythos", "opus", "ghost"]
        let options = ClaudeModels.options(catalog: catalog)
        XCTAssertEqual(options.map(\.id), ClaudeModels.all.map(\.id) + ["mythos"], "모델을 모르는 별칭(ghost)은 뺀다")
        XCTAssertEqual(options.last?.label, "Mythos 1")
        XCTAssertTrue(ClaudeModels.isFamily("mythos", catalog: catalog))
        XCTAssertFalse(ClaudeModels.isFamily("mythos"))
    }

    /// CLI 업데이트로 별칭이 다른 모델을 가리키면 앞 모델을 '과거 버전 고르기' 에 남긴다.
    func testReplacedModelsAreTheOldOnes() {
        let old = Self.catalog(["opus": ResolvedModel(modelID: "claude-opus-5-5", displayName: "Opus 5.5"),
                                "sonnet": ResolvedModel(modelID: "claude-sonnet-5-5", displayName: "Sonnet 5.5"),
                                "haiku": ResolvedModel(modelID: "claude-haiku-4-5", displayName: "Haiku 4.5"),
                                "fable": ResolvedModel(modelID: "claude-fable-5-1", displayName: "Fable 5.1")])
        let new = Self.catalog(["opus": ResolvedModel(modelID: "claude-opus-6", displayName: "Opus 6"),
                                "sonnet": ResolvedModel(modelID: "claude-sonnet-5-5", displayName: "Sonnet 5.5"),
                                "haiku": ResolvedModel(modelID: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5")])
        XCTAssertEqual(old.replacedModels(by: new), ["claude-opus-5-5"],
                       "날짜만 붙은 같은 모델(haiku)과 이번에 묻지 못한 계열(fable)은 넘어간 게 아니다")
    }

    func testCatalogMatchesOnlySameCLI() {
        let catalog = Self.catalog([:])
        XCTAssertTrue(catalog.matches(path: "/usr/local/bin/claude", version: "2.1.258"))
        XCTAssertFalse(catalog.matches(path: "/usr/local/bin/claude", version: "2.1.281"),
                       "CLI 를 올리면 별칭이 다른 모델을 가리킬 수 있다")
        XCTAssertFalse(catalog.matches(path: "/opt/homebrew/bin/claude", version: "2.1.258"))
    }

    /// 0.4.25 이하가 남긴 표는 effort 단계·새 계열 칸이 없다. 읽히되(앞 모델을 이어 받아야 한다) 한 번 다시 묻는다.
    func testOldCatalogFileDecodesAndAsksAgain() throws {
        let json = #"{"claudePath":"/usr/local/bin/claude","claudeVersion":"2.1.284","checkedAt":"2026-09-29T00:00:00Z","models":{"opus":{"modelID":"claude-opus-5-5","displayName":"Opus 5.5"}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(ModelCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.models["opus"]?.modelID, "claude-opus-5-5")
        XCTAssertNil(catalog.effortLevels)
        XCTAssertEqual(catalog.extraFamilies, [])
        XCTAssertFalse(catalog.matches(path: "/usr/local/bin/claude", version: "2.1.284"))

        var asked = catalog
        asked.effortLevels = []
        XCTAssertTrue(asked.matches(path: "/usr/local/bin/claude", version: "2.1.284"),
                      "읽었는데 못 찾았으면(빈 배열) 같은 CLI 에선 다시 묻지 않는다")
    }

    func testCatalogRoundTripsLikeStore() throws {
        var catalog = Self.catalog(["fable": ResolvedModel(modelID: "claude-fable-5-1", displayName: "Fable 5.1")])
        catalog.extraFamilies = ["mythos"]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ModelCatalog.self, from: encoder.encode(catalog))
        XCTAssertEqual(restored, catalog)
    }

    // MARK: - 실측

    /// 설치된 CLI 에 실제로 묻는다(`PRAYER_INTEGRATION=1`). 토큰을 쓰지 않는지가 핵심이다.
    func testInstalledCLIAnswersWithoutSpendingTokens() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRAYER_INTEGRATION"] == "1",
                          "PRAYER_INTEGRATION=1 일 때만 실행합니다.")
        let runner = ClaudeRunner()
        guard let path = await runner.discoverPath() else { throw XCTSkip("claude 가 없습니다.") }
        let answer = await runner.probeModel(alias: "sonnet", path: path)
        let outcome = try XCTUnwrap(answer)
        XCTAssertFalse(outcome.spentTokens, "`/model` 이 API 를 불렀다 — 앱이 켤 때마다 토큰을 쓰게 된다")
        XCTAssertTrue(outcome.model?.modelID.hasPrefix("claude-sonnet") ?? false, "\(String(describing: outcome.model))")
    }

    private static func catalog(_ models: [String: ResolvedModel]) -> ModelCatalog {
        ModelCatalog(claudePath: "/usr/local/bin/claude", claudeVersion: "2.1.258", models: models,
                     checkedAt: Date(timeIntervalSince1970: 1_790_000_000), effortLevels: EffortLevel.fallback)
    }
}

/// 리뷰 effort. 설정에 없으면 플래그를 붙이지 않아 예전과 똑같이 돈다.
final class EffortTests: XCTestCase {
    /// 단계는 CLI 가 정한다 — 앱이 아는 다섯으로 거르면 CLI 가 새로 알려 준 단계를 골라도 조용히 빠진다.
    func testEffortArgumentTakesAnyLevelWord() {
        XCTAssertNil(EffortLevel.argument(for: ""), "빈 값 = 기본값 = 플래그 없음")
        XCTAssertEqual(EffortLevel.argument(for: "xhigh"), "xhigh")
        XCTAssertEqual(EffortLevel.argument(for: "ultra"), "ultra", "CLI 가 새로 알려 준 단계")
        XCTAssertNil(EffortLevel.argument(for: "HIGH"), "CLI 는 소문자만 받는다")
        XCTAssertNil(EffortLevel.argument(for: "very high"))
        XCTAssertNil(EffortLevel.argument(for: "high;rm"))
    }

    func testLevelsComeFromCatalogWithFallback() {
        XCTAssertEqual(EffortLevel.fallback, ["low", "medium", "high", "xhigh", "max"], "검증한 CLI(2.1.284)의 `--help`")
        XCTAssertEqual(EffortLevel.levels(catalog: nil), EffortLevel.fallback)
        var catalog = ModelCatalog(claudePath: "c", claudeVersion: "v", models: [:], checkedAt: Date(), effortLevels: [])
        XCTAssertEqual(EffortLevel.levels(catalog: catalog), EffortLevel.fallback, "읽었는데 못 찾았으면 기본 단계")
        catalog.effortLevels = ["quick", "deep"]
        XCTAssertEqual(EffortLevel.levels(catalog: catalog), ["quick", "deep"])
    }

    /// Claude 앱처럼 첫 글자를 크게 — `xhigh` 는 `XHigh`.
    func testDisplayNames() {
        XCTAssertEqual(EffortLevel.fallback.map(EffortLevel.displayName), ["Low", "Medium", "High", "XHigh", "Max"])
        XCTAssertEqual(EffortLevel.displayName("ultra"), "Ultra")
    }

    func testInvocationAddsEffortOnlyWhenSet() {
        func invocation(_ effort: String?) -> [String] {
            ClaudeInvocation(claudePath: "/bin/echo", systemPromptPath: "g", schemaJSON: "{}", model: "opus",
                             timeout: 10, workingDirectory: "/tmp", effort: effort).arguments
        }
        let withEffort = invocation("high")
        let index = try? XCTUnwrap(withEffort.firstIndex(of: "--effort"))
        XCTAssertEqual(index.map { withEffort[$0 + 1] }, "high")
        XCTAssertFalse(invocation(nil).contains("--effort"))
    }

    /// 옛 설정 파일에는 effort 키가 없다. 읽혀야 하고, 기본값(플래그 없음)이어야 한다.
    func testOldSettingsDecodeWithDefaultEffort() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"model":"opus"}"#.utf8))
        XCTAssertEqual(settings.model, "opus")
        XCTAssertEqual(settings.effort, "")
    }

    func testEffortRoundTripsThroughSettings() throws {
        var settings = Settings.default
        settings.effort = "max"
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.effort, "max")
    }
}
