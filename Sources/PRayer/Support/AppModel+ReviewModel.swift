import Foundation
import PRayerCore

/// 리뷰 모델 고르기 — 모델·Effort 두 칸(ReviewModelPills)이 쓴다.
///
/// 모델은 diff 리뷰와 전체 리뷰가 같이 쓴다. AI 리뷰 탭에서 고르면 **이 PR 에만** 쓰고(다음 리뷰에도 기억),
/// 스위치를 켜면 그 값이 앞으로 모든 PR 의 기본값이 된다(사용자 선택 다안: 평소엔 이 PR 만, 켜면 기본값까지).
/// 설정의 같은 두 칸은 기본값을 바로 바꾼다.
extension AppModel {
    func reviewModelChoice(for pr: PullRequestInfo) -> ReviewModelChoice {
        settings.reviewModelChoice(forPRKey: pr.id)
    }

    /// "Opus 5.5 · High" 처럼 모델 이름과(고른 게 있으면) Effort.
    func reviewModelLabel(_ choice: ReviewModelChoice) -> String {
        let effort = ReviewEngineKind(model: choice.model) == .codex
            ? CodexModels.effortArgument(choice.effort, choice: choice.model, catalog: codexCatalog)
            : EffortLevel.argument(for: choice.effort)
        return reviewModelName(choice.model) + (effort.map { " · \(EffortLevel.displayName($0))" } ?? "")
    }

    func reviewModelName(_ id: String) -> String {
        modelOption(id: id)?.label ?? id
    }

    /// 초안에 남은 모델 이름(`ReviewRecord.model`)을 보일 이름으로. Codex 는 실제로 부른 모델(`gpt-5.6-sol`)이 남는다.
    func recordModelName(_ record: ReviewRecord) -> String {
        switch record.engineKind {
        case .claude: return reviewModelName(record.model)
        // 예전 수확 버그로 계열 저장값(`codex:sol`)이 남은 초안도 있다. 앞말을 두 번 붙이지 않는다.
        case .codex: return reviewModelName(CodexModels.stripped(record.model) == nil ? CodexModels.id(record.model) : record.model)
        }
    }

    /// Effort 칸이 보일 단계. 고르지 않았으면(`--effort` 를 안 넘김) CLI 가 밝힌 그 모델의 기본값이고,
    /// 그것도 모르면 nil — 지어내지 않는다(API 기본은 모델마다 다르다).
    /// Codex 는 그 모델이 받지 않는 단계를 골라 뒀으면(엔진을 바꾼 뒤 남은 값) 실제로 돌 기본값을 보인다.
    func shownEffort(model modelID: String, effort: String) -> String? {
        switch ReviewEngineKind(model: modelID) {
        case .claude:
            return EffortLevel.argument(for: effort) ?? modelCatalog?.models[modelID]?.defaultEffort
        case .codex:
            return CodexModels.effortArgument(effort, choice: modelID, catalog: codexCatalog)
                ?? CodexModels.defaultEffort(choice: modelID, catalog: codexCatalog)
        }
    }

    /// 설정의 두 칸 — 기본값을 바꾼다.
    func setDefaultReviewModel(_ modelID: String? = nil, effort: String? = nil) {
        settings.model = modelID ?? settings.model
        settings.effort = effort ?? settings.effort
        forgetPRChoicesMatchingDefault()
        Task { await save() }
    }

    /// 새 기본값과 같은 것을 따로 기억해 둔 PR 은 이제 기본값을 쓰면 된다('이 PR만' 표시도 사라진다).
    private func forgetPRChoicesMatchingDefault() {
        settings.prReviewModels = settings.prReviewModels.filter {
            $0.value.model != settings.model || $0.value.effort != settings.effort
        }
    }

    /// AI 리뷰 탭에서 모델이나 Effort 를 고른 것 — 이 PR 에만 쓴다. 고른 결과가 기본값과 같으면 따로 기억하지 않는다
    /// (기억해 두면 나중에 기본값을 바꿨을 때 이 PR 만 옛 값에 묶인다).
    func chooseReviewModel(_ modelID: String? = nil, effort: String? = nil, for pr: PullRequestInfo) {
        let current = reviewModelChoice(for: pr)
        let next = PRReviewModel(model: modelID ?? current.model, effort: effort ?? current.effort)
        if next.model == settings.model, next.effort == settings.effort {
            settings.prReviewModels[pr.id] = nil
        } else {
            settings.prReviewModels[pr.id] = next
        }
        Task { await save() }
    }

    /// 이 PR 도 기본값을 쓴다(따로 고른 것을 지운다).
    func useDefaultReviewModel(for pr: PullRequestInfo) {
        settings.prReviewModels[pr.id] = nil
        Task { await save() }
    }

    /// 스위치 — 이 PR 에 고른 것을 앞으로 모든 PR 의 기본값으로 올린다.
    func makeDefaultReviewModel(from pr: PullRequestInfo) {
        guard let chosen = settings.prReviewModels[pr.id] else { return }
        settings.model = chosen.model
        settings.effort = chosen.effort
        forgetPRChoicesMatchingDefault()
        banner = Banner(kind: .info,
                        message: "기본 리뷰 모델을 \(reviewModelLabel(reviewModelChoice(for: pr))) 로 바꿨습니다 — 앞으로 모든 PR 에 씁니다.")
        Task { await save() }
    }
}
