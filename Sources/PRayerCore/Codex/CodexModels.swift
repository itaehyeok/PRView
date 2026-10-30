import Foundation

/// `codex app-server` 의 `model/list` 가 알려 준 모델 하나.
public struct CodexModel: Codable, Sendable, Hashable {
    /// `gpt-5.6-sol` 처럼 `codex -m` 에 넘기는 이름.
    public var id: String
    /// `GPT-5.6-Sol` 처럼 Codex 가 보여 주는 이름.
    public var displayName: String
    /// Codex 가 붙인 한 줄 설명(영문).
    public var summary: String
    /// `-m` 을 안 줬을 때 Codex 가 쓰는 모델인가.
    public var isDefault: Bool
    /// effort 를 안 줬을 때 이 모델이 쓰는 단계.
    public var defaultEffort: String?
    /// 이 모델이 받는 effort 단계. 모델마다 다르다(실측 0.149.0: Luna 에는 `ultra` 가 없다).
    public var efforts: [String]

    public init(id: String, displayName: String, summary: String = "", isDefault: Bool = false,
                defaultEffort: String? = nil, efforts: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.isDefault = isDefault
        self.defaultEffort = defaultEffort
        self.efforts = efforts
    }
}

/// Codex 가 알려 준 모델 목록. CLI 가 바뀌거나 오래되면 다시 묻는다.
///
/// Claude 와 달리 목록이 CLI 안에만 있지 않다 — Codex 는 서버에서 받은 목록을 **그 CLI 버전이 쓸 수 있는 것만**
/// 걸러 준다(실측 2026-10-29: 0.149.0 은 GPT-5.6 셋, 같은 맥의 더 새 Codex 는 GPT-6 계열까지). 그래서 CLI 를 올리지
/// 않아도 새 모델이 들어올 수 있어, 경로·버전이 같아도 `maxAge` 가 지나면 다시 묻는다. 묻는 데 토큰은 들지 않는다.
public struct CodexCatalog: Codable, Sendable, Equatable {
    public var codexPath: String
    public var codexVersion: String
    /// CLI 가 준 순서 그대로(앞이 Codex 가 앞세우는 모델).
    public var models: [CodexModel]
    /// `codex features list` 의 기능 이름 중 아직 쓰이는 것. 리뷰에서 끌 기능을 이 목록과 맞춰 넘긴다 —
    /// 모르는 이름을 `--disable` 에 넘기면 codex 가 "Unknown feature flag" 로 멈춘다(실측 0.149.0).
    public var features: [String]
    public var checkedAt: Date

    public static let maxAge: TimeInterval = 12 * 3600

    public init(codexPath: String, codexVersion: String, models: [CodexModel], features: [String], checkedAt: Date) {
        self.codexPath = codexPath
        self.codexVersion = codexVersion
        self.models = models
        self.features = features
        self.checkedAt = checkedAt
    }

    public func isFresh(path: String, version: String, now: Date = Date()) -> Bool {
        codexPath == path && codexVersion == version && now.timeIntervalSince(checkedAt) < Self.maxAge
    }

    public func model(_ id: String) -> CodexModel? {
        models.first { $0.id == id }
    }
}

/// 토큰을 쓰지 않고 Codex 에 모델 목록과 기능 이름을 묻는 방법.
///
/// `codex app-server` 는 표준 입출력으로 JSON-RPC 를 받는다. `initialize` → `initialized` → `model/list` 를
/// 보내면 모델마다 표시 이름·기본 effort·받는 effort 단계를 돌려준다(실측 0.149.0, 0.3초). 모델을 부르지 않는다.
/// **표준 입력을 답이 오기 전에 닫으면 답 없이 끝난다**(실측) — 답을 받을 때까지 열어 둔다(`CodexRunner.probeModels`).
public enum CodexModelProbe {
    public static let listRequestID = 2

    public static var requestLines: [String] {
        [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"prview","title":"PRView","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":\#(listRequestID),"method":"model/list","params":{}}"#,
        ]
    }

    /// `model/list` 응답 줄이면 모델 목록, 아니면 nil. 숨김 모델은 뺀다.
    public static func models(inResponseLine line: String) -> [CodexModel]? {
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["id"] as? Int) == listRequestID,
              let result = root["result"] as? [String: Any],
              let items = result["data"] as? [[String: Any]] else { return nil }
        return items.compactMap { item -> CodexModel? in
            guard (item["hidden"] as? Bool) != true,
                  let id = (item["model"] as? String) ?? (item["id"] as? String),
                  CodexModels.isModelName(id) else { return nil }
            let efforts = (item["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
                .compactMap(EffortLevel.argument(for:))
            return CodexModel(id: id,
                              displayName: (item["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                  ?? CodexModels.displayName(forModelID: id),
                              summary: item["description"] as? String ?? "",
                              isDefault: item["isDefault"] as? Bool ?? false,
                              defaultEffort: (item["defaultReasoningEffort"] as? String).flatMap(EffortLevel.argument(for:)),
                              efforts: efforts)
        }
    }

    /// `codex features list` 의 "이름  단계  켜짐" 줄에서 이름만. 단계가 `removed` 인 것은 뺀다 — 이름은 받아 주지만
    /// 끌 것이 남아 있지 않다.
    public static func features(inList text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = columns.first, columns.count >= 2,
                  name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }),
                  !line.contains(" removed ") else { return nil }
            return String(name)
        }
    }

    /// `codex-cli 0.149.0` → `0.149.0`.
    public static func version(inVersionOutput text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .last
            .map(String.init)
            .flatMap { $0.first?.isNumber == true ? $0 : nil }
    }
}

/// 리뷰 모델 칸의 Codex 쪽. 저장값은 `codex:` 앞말 + 계열(`codex:sol`) 또는 버전을 고정한 모델(`codex:gpt-5.6-sol`).
///
/// Codex 에는 Claude 의 `opus` 같은 별칭이 없다. 대신 이름이 `gpt-<버전>-<계열>` 꼴이라(`gpt-5.6-sol`·`gpt-6.1-sol`)
/// 앱이 계열을 읽어 **목록에 있는 가장 새 버전**으로 푼다. 그래서 Codex 가 새 버전을 내놓으면 고른 계열이 저절로 따라가고,
/// 계열 목록·이름·effort 단계도 전부 Codex 가 알려 준 것을 쓴다 — 앱에 박아 둔 모델 이름은 없다.
public enum CodexModels {
    public static let prefix = "codex:"

    /// 저장값에서 앞말을 뗀 것. Codex 선택이 아니면 nil. `codex:` 만 있으면 빈 문자열(Codex 기본 모델).
    public static func stripped(_ id: String) -> String? {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }

    public static func id(_ name: String) -> String { prefix + name }

    /// `-m` 에 넘길 만한 이름인가 — 셸이 아니라 인자로 넘기지만 설정 가져오기로도 들어오는 값이라 꼴을 본다.
    public static func isModelName(_ name: String) -> Bool {
        name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z"#, options: .regularExpression) != nil
    }

    /// `gpt-5.6-sol` → 버전 `[5, 6]` · 계열 `sol`. 이 꼴이 아니면 nil(계열 없이 그 모델 하나로 다룬다).
    static func parse(_ modelID: String) -> (version: [Int], family: String)? {
        let parts = modelID.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "gpt",
              let first = parts[2].first, first.isLetter, parts[2].allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else { return nil }
        let version = parts[1].split(separator: ".").compactMap { Int($0) }
        guard !version.isEmpty, version.count == parts[1].split(separator: ".").count else { return nil }
        return (version, parts[2])
    }

    public static func family(ofModelID modelID: String) -> String? {
        parse(modelID)?.family
    }

    /// 계열마다 가장 새 모델. 순서는 Codex 가 준 목록에서 그 계열이 처음 나온 자리다.
    static func latestByFamily(_ catalog: CodexCatalog?) -> [(key: String, model: CodexModel)] {
        var order: [String] = []
        var best: [String: (version: [Int], model: CodexModel)] = [:]
        for model in catalog?.models ?? [] {
            // 계열을 못 읽는 이름은 그 이름이 곧 한 칸이다.
            let parsed = parse(model.id)
            let key = parsed?.family ?? model.id
            let version = parsed?.version ?? []
            if let current = best[key] {
                if version.lexicographicallyPrecedes(current.version) || version == current.version { continue }
            } else {
                order.append(key)
            }
            best[key] = (version, model)
        }
        return order.compactMap { key in best[key].map { (key, $0.model) } }
    }

    /// 모델 칸의 Codex 목록 — 계열마다 가장 새 것 하나. 저장값은 계열(`codex:sol`)이라 새 버전을 따라간다.
    public static func options(catalog: CodexCatalog?) -> [ReviewModelOption] {
        latestByFamily(catalog).map { entry in
            ReviewModelOption(id: id(entry.key), label: entry.model.displayName, apiID: entry.model.id)
        }
    }

    /// 저장값 → 칸에 보일 것. 고정한 버전이면 그 버전 이름을 보인다.
    public static func option(id choice: String, catalog: CodexCatalog?) -> ReviewModelOption? {
        guard let name = stripped(choice) else { return nil }
        if let family = options(catalog: catalog).first(where: { $0.id == choice }) { return family }
        if name.isEmpty {
            let fallback = catalog?.models.first(where: \.isDefault) ?? catalog?.models.first
            return ReviewModelOption(id: choice, label: fallback?.displayName ?? "Codex 기본", apiID: fallback?.id ?? "")
        }
        guard isModelName(name) else { return nil }
        return ReviewModelOption(id: choice,
                                 label: catalog?.model(name)?.displayName ?? displayName(forModelID: name),
                                 apiID: name)
    }

    /// '과거 버전 고르기' 의 Codex 몫 — 목록에 있지만 계열의 가장 새 것이 아닌 모델과, 앱이 기억해 둔 이름.
    public static func pastOptions(catalog: CodexCatalog?, remembered: [String] = []) -> [ReviewModelOption] {
        let latest = Set(latestByFamily(catalog).map(\.model.id))
        var seen = Set<String>()
        let names = (catalog?.models.map(\.id) ?? []) + remembered.compactMap(stripped)
        return names
            .filter { !$0.isEmpty && isModelName($0) && !latest.contains($0) && seen.insert($0).inserted }
            .sorted { a, b in
                let pa = parse(a), pb = parse(b)
                if pa?.family != pb?.family { return (pa?.family ?? a) < (pb?.family ?? b) }
                return (pb?.version ?? []).lexicographicallyPrecedes(pa?.version ?? [])
            }
            .map { name in
                ReviewModelOption(id: id(name), label: catalog?.model(name)?.displayName ?? displayName(forModelID: name),
                                  apiID: name)
            }
    }

    /// 처음 Codex 로 바꿀 때 고를 값 — Codex 가 기본으로 쓰는 모델의 계열.
    public static func defaultChoice(catalog: CodexCatalog?) -> String {
        guard let model = catalog?.models.first(where: \.isDefault) ?? catalog?.models.first else { return prefix }
        return id(family(ofModelID: model.id) ?? model.id)
    }

    /// 저장값 → 실제로 `-m` 에 넘길 모델. 계열이면 목록의 가장 새 버전, 고정이면 그 이름 그대로.
    /// 계열인데 목록에 없으면(아직 묻지 못함·계열이 사라짐) nil — `-m` 없이 Codex 기본 모델로 돈다.
    public static func resolve(_ choice: String, catalog: CodexCatalog?) -> String? {
        guard let name = stripped(choice), !name.isEmpty else { return nil }
        if let entry = latestByFamily(catalog).first(where: { $0.key == name }) { return entry.model.id }
        if catalog?.model(name) != nil { return name }
        // 목록에 없는 계열 이름(`codex:sol`)은 모델 이름이 아니다. 그대로 넘기면 Codex 가 모른다.
        // 버전까지 적힌 이름(지난 버전·직접 입력)만 그대로 넘긴다.
        guard parse(name) != nil, isModelName(name) else { return nil }
        return name
    }

    /// Codex 에 아직 묻지 못했을 때의 단계 — 0.149.0 의 모델들이 공통으로 받는 것.
    public static let fallbackEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// 그 모델이 받는 effort 단계.
    public static func effortLevels(choice: String, catalog: CodexCatalog?) -> [String] {
        guard let modelID = resolve(choice, catalog: catalog) ?? catalog?.models.first(where: \.isDefault)?.id,
              let model = catalog?.model(modelID), !model.efforts.isEmpty else { return fallbackEfforts }
        return model.efforts
    }

    /// effort 를 안 넘겼을 때 그 모델이 쓰는 단계.
    public static func defaultEffort(choice: String, catalog: CodexCatalog?) -> String? {
        let modelID = resolve(choice, catalog: catalog) ?? catalog?.models.first(where: \.isDefault)?.id
        return modelID.flatMap { catalog?.model($0)?.defaultEffort }
    }

    /// 저장된 effort → `model_reasoning_effort` 값. 그 모델이 받지 않는 단계면 nil(모델 기본값으로 돈다) —
    /// Claude 에서 고른 단계가 Codex 로 바꾼 뒤에도 남아 있을 수 있다.
    public static func effortArgument(_ stored: String, choice: String, catalog: CodexCatalog?) -> String? {
        guard let effort = EffortLevel.argument(for: stored) else { return nil }
        return effortLevels(choice: choice, catalog: catalog).contains(effort) ? effort : nil
    }

    /// Codex 가 이름을 보여 주지 않았을 때 모델 ID 로 만든다. `gpt-5.6-sol` → `GPT-5.6-Sol`.
    public static func displayName(forModelID modelID: String) -> String {
        let parts = modelID.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "gpt" else { return modelID }
        return (["GPT"] + parts.dropFirst().map { $0.first?.isLetter == true ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 })
            .joined(separator: "-")
    }
}
