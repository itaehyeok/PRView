import Foundation

/// 별칭 하나를 CLI 에 물어 알아낸 모델.
public struct ResolvedModel: Codable, Sendable, Hashable {
    /// `claude-opus-5-5` 처럼 CLI 가 실제로 부르는 이름.
    public var modelID: String
    /// `Opus 5.5` 처럼 CLI 가 보여 주는 이름.
    public var displayName: String
    /// `--effort` 를 안 줬을 때 CLI 가 쓰는 effort. CLI 가 밝힐 때만 채운다
    /// (실측: 2.1.258 은 `Opus 5 (effort: medium)` 만 밝히고 나머지는 말이 없다).
    public var defaultEffort: String?

    public init(modelID: String, displayName: String, defaultEffort: String? = nil) {
        self.modelID = modelID
        self.displayName = displayName
        self.defaultEffort = defaultEffort
    }
}

/// 별칭 → 모델 표. CLI 가 바뀔 때만 다시 만든다.
///
/// 별칭이 가리키는 모델은 CLI 안에 든 목록이 정한다(실측 2026-09-29: `opus` 가 2.1.258 에서는
/// Opus 5, 2.1.281 에서는 Opus 5.5). 그래서 경로와 버전이 같으면 다시 물을 이유가 없다.
public struct ModelCatalog: Codable, Sendable, Equatable {
    public var claudePath: String
    public var claudeVersion: String
    /// 별칭 → 모델. 묻다가 실패한 별칭은 빠져 있다.
    public var models: [String: ResolvedModel]
    public var checkedAt: Date
    /// CLI 가 `--help` 의 `--effort` 에 적은 단계(`ModelProbe.effortLevels(inHelp:)`).
    /// nil 이면 단계를 읽기 전(0.4.25 이하)에 만든 표라 다시 묻는다. 읽었는데 못 찾았으면 빈 배열이고,
    /// 화면은 기본 단계(`EffortLevel.fallback`)를 쓴다.
    public var effortLevels: [String]?
    /// 앱이 아는 네 계열 밖에서 CLI 가 알려 준 새 계열 별칭(`ModelProbe.isFamily`). 그 모델은 `models` 에 있다.
    public var extraFamilies: [String]

    public init(claudePath: String, claudeVersion: String, models: [String: ResolvedModel], checkedAt: Date,
                effortLevels: [String]? = nil, extraFamilies: [String] = []) {
        self.claudePath = claudePath
        self.claudeVersion = claudeVersion
        self.models = models
        self.checkedAt = checkedAt
        self.effortLevels = effortLevels
        self.extraFamilies = extraFamilies
    }

    enum CodingKeys: String, CodingKey {
        case claudePath, claudeVersion, models, checkedAt, effortLevels, extraFamilies
    }

    /// 0.4.25 이하가 남긴 표(뒤의 두 칸이 없다)도 읽는다 — 못 읽으면 지난 버전을 이어 받을 앞 표가 사라진다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudePath = try c.decode(String.self, forKey: .claudePath)
        claudeVersion = try c.decode(String.self, forKey: .claudeVersion)
        models = try c.decode([String: ResolvedModel].self, forKey: .models)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        effortLevels = try c.decodeIfPresent([String].self, forKey: .effortLevels)
        extraFamilies = try c.decodeIfPresent([String].self, forKey: .extraFamilies) ?? []
    }

    /// 같은 CLI 면 다시 묻지 않는다. effort 단계를 읽기 전에 만든 표면 한 번 더 묻는다.
    public func matches(path: String, version: String) -> Bool {
        claudePath == path && claudeVersion == version && effortLevels != nil
    }

    /// 새 표에서 다른 모델로 넘어간 별칭의 **앞 모델**. '과거 버전 고르기' 에 남긴다
    /// (CLI 업데이트로 `opus` 가 5.5 → 6 이 되면 5.5 를 계속 고를 수 있게).
    public func replacedModels(by newer: ModelCatalog) -> [String] {
        models.keys.sorted().compactMap { alias in
            guard let old = models[alias], let now = newer.models[alias],
                  ClaudeModels.undatedModelID(old.modelID) != ClaudeModels.undatedModelID(now.modelID) else { return nil }
            return old.modelID
        }
    }
}

/// 토큰을 쓰지 않고 별칭이 가리키는 모델을 CLI 에 묻는 방법.
///
/// `/model` 은 CLI 안에서 처리되는 명령이라 API 를 부르지 않는다(실측 2026-09-29, 2.1.258·2.1.281·2.1.284
/// 네 별칭 모두 total_cost_usd 0 · num_turns 0). 모델 ID 는 `stream-json` 첫 줄(system/init)의
/// `model` 에 실리고, 표시 이름은 결과 문장 "Current model: `Opus 5.5`" 에 있다.
///
/// Anthropic Models API(`/v1/models`)는 쓰지 않는다. API 키가 있어야 하는데, 이 앱은 토큰을
/// 받지 않고 `claude` 로그인을 빌려 쓴다. 게다가 실제로 무엇이 돌지는 API 가 아니라 CLI 가 정한다.
public enum ModelProbe {
    public static let prompt = "/model"

    /// 리뷰와 같은 격리 플래그를 쓴다(CLAUDE.md·플러그인·MCP 를 읽지 않는다). 혹시 CLI 가 `/model` 을
    /// API 로 넘기게 바뀌어도 도구 없이 한 마디로 끝나도록 시스템 프롬프트를 비워 둔다.
    /// `-p` 에서 `stream-json` 은 `--verbose` 가 있어야 받아 준다.
    public static func arguments(alias: String) -> [String] {
        [
            "-p",
            "--safe-mode",
            "--strict-mcp-config",
            "--system-prompt", ".",
            "--tools", "",
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--model", alias,
            "--output-format", "stream-json",
            "--verbose",
        ]
    }

    public struct Outcome: Sendable, Equatable {
        public var model: ResolvedModel?
        /// 명령이 CLI 안에서 끝나지 않고 API 를 불렀는가. 그러면 그 버전에서는 다시 묻지 않는다.
        public var spentTokens: Bool
        /// CLI 가 아는 이름인가. 모르는 이름도 받아는 주지만 표시 이름 없이 그대로 되풀이한다
        /// (실측 2.1.284: `claude-foo-9` → "Current model: `claude-foo-9`"). 문장 꼴이 바뀌어 모르면 true.
        public var recognized: Bool
        /// `/model` 이 "Available:" 에 적은 별칭 중 글자로만 된 것. 새 계열을 찾는 데 쓴다.
        public var availableAliases: [String]

        public init(model: ResolvedModel?, spentTokens: Bool, recognized: Bool = true, availableAliases: [String] = []) {
            self.model = model
            self.spentTokens = spentTokens
            self.recognized = recognized
            self.availableAliases = availableAliases
        }
    }

    public static func parse(streamJSON text: String) -> Outcome {
        var modelID: String?
        var shownName: String?
        var shownEffort: String?
        var available: [String] = []
        var spentTokens = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch (event["type"] as? String, event["subtype"] as? String) {
            case ("system", "init"):
                modelID = (event["model"] as? String)?.trimmingCharacters(in: .whitespaces)
            case ("result", _):
                let turns = (event["num_turns"] as? Int) ?? 0
                let cost = (event["total_cost_usd"] as? Double) ?? 0
                spentTokens = turns > 0 || cost > 0
                let sentence = event["result"] as? String ?? ""
                shownName = currentModelName(in: sentence)
                shownEffort = currentEffort(in: sentence)
                available = availableAliases(in: sentence)
            default:
                continue
            }
        }
        guard let modelID, !modelID.isEmpty else {
            return Outcome(model: nil, spentTokens: spentTokens, availableAliases: available)
        }
        let name = shownName ?? ClaudeModels.displayName(forModelID: modelID)
        return Outcome(model: ResolvedModel(modelID: modelID, displayName: name, defaultEffort: shownEffort),
                       spentTokens: spentTokens,
                       recognized: shownName.map { $0 != modelID } ?? true,
                       availableAliases: available)
    }

    /// 별칭이 **같은 이름의 계열** 모델을 가리키는가. `best`(→ Fable)·`default`(→ Opus)·`opusplan`(→ Sonnet)
    /// 처럼 다른 계열을 빌려 쓰는 별칭은 계열이 아니다(실측 2.1.284).
    public static func isFamily(alias: String, resolvedTo model: ResolvedModel) -> Bool {
        ClaudeModels.family(ofModelID: model.modelID) == alias
    }

    /// "Usage: /model <name>. Available: sonnet, opus, …, default, or a full model ID." 의 별칭 중
    /// 소문자로만 된 것. `sonnet[1m]` 같은 변형과 "a full model ID" 는 뺀다.
    static func availableAliases(in text: String) -> [String] {
        guard let start = text.range(of: "Available:") else { return [] }
        let line = text[start.upperBound...].prefix { !$0.isNewline }
        return line.split(separator: ",").compactMap { piece in
            var word = piece.trimmingCharacters(in: .whitespaces)
            if word.hasPrefix("or ") { word.removeFirst(3) }
            if word.hasSuffix(".") { word.removeLast() }
            guard !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return nil }
            return word
        }
    }

    /// `claude --help` 의 `--effort <level> … (low, medium, high, xhigh, max)` 에서 단계를 읽는다.
    ///
    /// 설명이 다음 줄로 넘어가도 읽는다(실측 2.1.284: 괄호가 둘째 줄). 괄호가 여럿이면 단계 이름이 둘 이상
    /// 나열된 첫 괄호를 쓴다. 못 찾으면 빈 배열 — 화면은 기본 단계를 쓴다.
    public static func effortLevels(inHelp text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = lines.firstIndex(where: { line in
            line.split(separator: " ").prefix(2).contains { $0.trimmingCharacters(in: [","]) == "--effort" }
        }) else { return [] }
        // 옵션 설명은 다음 옵션(`-` 로 시작하는 줄)이나 빈 줄 전까지 이어진다.
        var block = lines[index]
        for line in lines[(index + 1)...] {
            guard !line.isEmpty, !line.hasPrefix("-") else { break }
            block += " " + line
        }
        var rest = block[...]
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let levels = rest[rest.index(after: open)..<close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if levels.count >= 2, levels.allSatisfy({ EffortLevel.argument(for: $0) == $0 }) { return levels }
            rest = rest[rest.index(after: close)...]
        }
        return []
    }

    /// "Current model: `Opus 5` (effort: medium)" 의 괄호 안. effort 단계 이름 꼴일 때만 받는다.
    static func currentEffort(in text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("Current model:") }),
              let start = line.range(of: "(effort: ") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        return EffortLevel.argument(for: rest[..<end].trimmingCharacters(in: .whitespaces))
    }

    /// "Current model: `Opus 5` (effort: medium)" 의 백틱 안. 문장 꼴이 바뀌면 nil 을 돌려주고,
    /// 그때는 모델 ID 로 이름을 만든다.
    static func currentModelName(in text: String) -> String? {
        guard let start = text.range(of: "Current model: `") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "`") else { return nil }
        let name = rest[..<end].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, !name.contains(where: \.isNewline) else { return nil }
        return name
    }
}
