import Foundation

/// 리뷰에 쓸 수 있는 Claude 모델. `claude -p --model <별칭>` 에 그대로 넘긴다.
///
/// 가격은 두지 않는다(사용자 결정 — 앱 어디에도 비용을 보이지 않는다). 예전에는 정가표를 손으로 고쳐
/// 비용을 어림했는데, CLI 가 가격을 알려 주지 않아 새 모델마다 앱을 고쳐야 했다.
public struct ReviewModelOption: Sendable, Hashable, Identifiable {
    /// CLI 별칭(계열) 또는 버전을 고정한 모델 이름. 설정에 저장되는 값이다.
    public var id: String
    public var label: String
    public var apiID: String

    public init(id: String, label: String, apiID: String) {
        self.id = id
        self.label = label
        self.apiID = apiID
    }
}

public enum ClaudeModels {
    /// 고를 수 있는 계열 — Claude 앱 모델 메뉴와 같은 순서(Opus · Fable · Sonnet · Haiku, 사용자 결정).
    /// `id` 는 CLI 별칭이라 CLI 가 **그 계열의 최신 모델**로 풀어 준다 — 새 버전이 나와도 이 목록은 그대로 두고,
    /// 이름만 `options(catalog:)` 가 CLI 에 물어 갈아 끼운다. 이 밖의 새 계열은 CLI 가 `/model` 에서 알려 주는
    /// 별칭 목록으로 찾는다(`ModelCatalog.extraFamilies`).
    ///
    /// 적어 둔 모델은 CLI 에 아직 묻지 못했을 때의 기본값이다. 검증한 CLI
    /// (`AppInfo.verifiedClaudeVersion`)가 각 별칭을 풀던 모델과 같게 둔다.
    public static let all: [ReviewModelOption] = [
        ReviewModelOption(id: "opus", label: "Opus 5.5", apiID: "claude-opus-5-5"),
        ReviewModelOption(id: "fable", label: "Fable 5.1", apiID: "claude-fable-5-1"),
        ReviewModelOption(id: "sonnet", label: "Sonnet 5.5", apiID: "claude-sonnet-5-5"),
        ReviewModelOption(id: "haiku", label: "Haiku 4.5", apiID: "claude-haiku-4-5"),
    ]

    /// '과거 버전 고르기' 의 씨앗 — 앱이 처음부터 아는 모델 이름. 이 밖의 지난 버전은 CLI 가 계열을 새 버전으로
    /// 넘길 때마다(`ModelCatalog.replacedModels(by:)`), 그리고 '모델 이름 직접 입력' 으로 쓴 이름이 쌓인다
    /// (`AppModel.rememberedModels`).
    static let knownModelIDs = [
        "claude-opus-5-5", "claude-opus-5",
        "claude-fable-5-1",
        "claude-sonnet-5-5", "claude-sonnet-5",
        "claude-haiku-4-5",
    ]

    public static func option(id: String) -> ReviewModelOption? {
        all.first { $0.id == id }
    }

    /// 계열 목록 — CLI 가 알려 준 이름을 입힌 넷과, CLI 가 새로 알려 준 계열. 묻지 못한 계열은 기본값 그대로다.
    public static func options(catalog: ModelCatalog?) -> [ReviewModelOption] {
        let known = all.map { resolve($0, with: catalog?.models[$0.id]) }
        let extra = (catalog?.extraFamilies ?? []).compactMap { alias -> ReviewModelOption? in
            guard option(id: alias) == nil, let model = catalog?.models[alias] else { return nil }
            return ReviewModelOption(id: alias, label: model.displayName, apiID: model.modelID)
        }
        return known + extra
    }

    /// 계열 별칭이면 CLI 가 알려 준 최신으로, 모델 이름(버전 고정)이면 그 버전으로 이름을 채운다.
    public static func option(id: String, catalog: ModelCatalog?) -> ReviewModelOption? {
        if let family = options(catalog: catalog).first(where: { $0.id == id }) { return family }
        // 버전 고정(`claude-opus-5`)이나 직접 입력한 이름. `claude-계열-버전` 꼴이 아니면 이름을 그대로 보인다.
        guard isModelName(id) else { return nil }
        return pinnedOption(modelID: id)
    }

    /// `--model` 에 넘길 만한 이름인가 — 설정 가져오기가 받는 꼴(`Check.model`)과 같다
    /// (`claude-opus-5`·`sonnet[1m]`·날짜 붙은 이름). CLI 가 아는 이름인지는 묻기 전엔 모른다(`ModelProbe`).
    public static func isModelName(_ id: String) -> Bool {
        id.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,79}\z"#, options: .regularExpression) != nil
    }

    /// 계열 별칭인가(그 계열의 최신을 따라간다). 아니면 버전을 고정한 모델 이름이다.
    public static func isFamily(_ id: String, catalog: ModelCatalog? = nil) -> Bool {
        options(catalog: catalog).contains { $0.id == id }
    }

    /// '과거 버전 고르기' 목록 — 계열마다 최신은 위 계열 목록에 있으므로 빼고, 지난 버전만.
    /// `remembered` 는 앱이 쌓아 둔 이름(계열이 넘어간 앞 버전·직접 입력)이다.
    ///
    /// 계열 순서는 `options(catalog:)` 와 같고, 같은 계열은 새 버전이 위다. 계열을 알 수 없는 이름(직접 입력)은 맨 아래.
    public static func pastOptions(catalog: ModelCatalog?, remembered: [String] = []) -> [ReviewModelOption] {
        let families = options(catalog: catalog)
        let latest = Set(families.map { undatedModelID($0.apiID) })
        var seen = Set<String>()
        let ids = (knownModelIDs + remembered).filter { id in
            let key = undatedModelID(id)
            guard !latest.contains(key), seen.insert(key).inserted else { return false }
            return true
        }
        let order = families.map(\.id)
        func rank(_ id: String) -> Int {
            family(ofModelID: id).flatMap { order.firstIndex(of: $0) } ?? order.count
        }
        return ids
            .sorted { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b) : a.compare(b, options: .numeric) == .orderedDescending
            }
            .map(pinnedOption(modelID:))
    }

    /// `remembered` 에 `ids` 를 더한 목록. 씨앗 목록에 있거나 이미 있는 이름(날짜를 떼고 비교)과 계열 별칭은 더하지 않는다.
    public static func remembering(_ ids: [String], into remembered: [String]) -> [String] {
        var keys = Set((knownModelIDs + remembered).map(undatedModelID))
        var result = remembered
        for id in ids where isModelName(id) && option(id: id) == nil && keys.insert(undatedModelID(id)).inserted {
            result.append(id)
        }
        return result
    }

    /// 버전을 고정한 선택 — 새 버전이 나와도 그대로다.
    static func pinnedOption(modelID id: String) -> ReviewModelOption {
        ReviewModelOption(id: id, label: displayName(forModelID: id), apiID: id)
    }

    /// `claude-opus-5-5` → `opus`. 모델 이름 꼴이 아니면 nil.
    public static func family(ofModelID id: String) -> String? {
        let parts = id.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude", parts[1].allSatisfy(\.isLetter) else { return nil }
        return String(parts[1])
    }

    /// 별칭(`id`)은 바꾸지 않는다. 설정에 저장되고 `--model` 로 넘기는 값이라,
    /// 새 모델이 나와도 사용자가 골라 둔 선택이 흐트러지지 않는다.
    static func resolve(_ base: ReviewModelOption, with model: ResolvedModel?) -> ReviewModelOption {
        guard let model else { return base }
        var option = base
        option.label = model.displayName
        option.apiID = model.modelID
        return option
    }

    /// `claude-haiku-4-5-20251001` → `claude-haiku-4-5`. CLI 는 날짜 붙은 이름으로 부르기도 한다
    /// (실측: 2.1.258 의 `haiku`).
    public static func undatedModelID(_ id: String) -> String {
        var parts = id.split(separator: "-", omittingEmptySubsequences: false)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }

    /// CLI 가 이름을 보여 주지 않았을 때 모델 ID 로 만든다. `claude-opus-5-5` → `Opus 5.5`.
    /// 이 꼴이 아니면 ID 를 그대로 돌려준다 — 그럴듯한 이름을 지어내느니 원문을 보인다.
    public static func displayName(forModelID id: String) -> String {
        let parts = undatedModelID(id).split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude",
              parts[1].allSatisfy(\.isLetter),
              parts.dropFirst(2).allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return id }
        return "\(parts[1].capitalized) \(parts.dropFirst(2).joined(separator: "."))"
    }
}

/// `claude --effort` 에 넘기는 값. 설정에는 문자열로 두고, 빈 문자열은 "넘기지 않는다"(Claude Code 기본값)이다.
///
/// 단계는 앱이 정하지 않는다 — CLI 가 `--help` 에 적은 선택지를 쓴다(`EffortHelp`, `ModelCatalog.effortLevels`).
/// 이름이 바뀌거나 단계가 늘어도 그대로 따라간다. 모든 계열에 넘겨도 된다 — CLI 가 effort 를 받지 않는
/// 모델(Haiku 4.5)에는 알아서 빼고 부른다(실측 2026-09-29: `--model haiku --effort high` 정상 응답).
public enum EffortLevel {
    /// CLI 에 아직 묻지 못했을 때의 단계. 검증한 CLI(2.1.284)의 `--effort` 선택지와 같다.
    public static let fallback = ["low", "medium", "high", "xhigh", "max"]

    /// 고를 수 있는 단계 — CLI 가 알려 준 것, 못 받았으면 기본 목록.
    public static func levels(catalog: ModelCatalog?) -> [String] {
        guard let levels = catalog?.effortLevels, !levels.isEmpty else { return fallback }
        return levels
    }

    /// 화면에 보일 이름. `high` → `High`, `xhigh` → `XHigh`(Claude 앱처럼 첫 글자를 크게).
    public static func displayName(_ level: String) -> String {
        guard let first = level.first else { return level }
        if level.count > 1, first == "x", level.dropFirst().allSatisfy(\.isLetter) {
            return "X" + level.dropFirst().prefix(1).uppercased() + level.dropFirst(2)
        }
        return first.uppercased() + level.dropFirst()
    }

    /// 설정값을 CLI 인자로. 비었으면 nil — 플래그를 붙이지 않는다(Claude Code 기본값).
    ///
    /// 단계 이름 꼴(소문자로 시작하는 소문자·숫자·`-`)이면 그대로 넘긴다. 앱이 아는 단계로 거르면 CLI 가 새로
    /// 알려 준 단계를 골라도 조용히 빠진다. 모르는 값은 CLI 가 경고하고 무시한다. 대문자는 받지 않는다(CLI 는 소문자만).
    public static func argument(for stored: String) -> String? {
        let value = stored.trimmingCharacters(in: .whitespaces)
        guard let first = value.first, first.isLowercase,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else { return nil }
        return value
    }
}
