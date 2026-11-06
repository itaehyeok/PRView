import SwiftUI
import PRayerCore

/// 리뷰 시작 자리의 모델·Effort 두 칸과 "이 PR 만 / 기본값" 스위치 줄(사용자 선택 다안).
///
/// 예전에는 모델을 설정 창에서만 바꿀 수 있었고, PR 하나만 다르게 돌리려면 리뷰 버튼을 우클릭해
/// **한 번만** 다른 모델로 돌려야 했다. 이제 여기서 고른다:
/// - 모델 칸은 계열마다 최신 하나(Opus·Fable·Sonnet·Haiku) — 별칭이라 새 버전이 나오면 저절로 따라간다.
///   지난 버전을 꼭 써야 하면 '과거 버전 고르기' 에서 고른다(그 버전에 고정).
/// - 고르면 **이 PR 에만** 쓴다(그 PR 을 다시 리뷰할 때도). 그러면 아래에 스위치 줄이 나와,
///   켜면 그 값이 앞으로 모든 PR 의 기본값이 된다. 되돌리면 이 PR 도 기본값을 쓴다.
/// diff 리뷰와 전체 리뷰는 같은 모델을 쓴다(사용자 결정 — 둘로 나눌 이유가 없다).
///
/// `leading` 은 두 칸 앞에 붙는 것 — 리뷰한 뒤 화면은 여기에 "다시 리뷰" 버튼을 둔다. 스위치 줄이 버튼까지
/// 포함한 한 덩어리 아래에 오게 하려고 바깥에서 나란히 놓지 않고 안에 받는다.
struct ReviewModelControl<Leading: View>: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// 빈 화면(가운데)과 초안 화면(왼쪽 정렬)에서 함께 쓴다.
    var alignment: HorizontalAlignment = .center
    @ViewBuilder let leading: Leading

    var body: some View {
        let choice = model.reviewModelChoice(for: pr)
        VStack(alignment: alignment, spacing: 5) {
            HStack(spacing: 6) {
                leading
                ReviewModelPills(modelID: choice.model,
                                 effort: choice.effort,
                                 scope: "여기서 고르면 이 PR 에만 씁니다",
                                 chooseModel: { model.chooseReviewModel($0, for: pr) },
                                 chooseEffort: { model.chooseReviewModel(effort: $0, for: pr) })
                if choice.isPRChoice {
                    Text("이 PR만")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.orange)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .help("이 PR 에만 다른 모델을 씁니다. 기본값은 \(defaultLabel) 입니다.")
                }
            }
            if choice.isPRChoice {
                switchLine(choice)
            }
        }
    }

    private var defaultLabel: String {
        model.reviewModelLabel(ReviewModelChoice(model: model.settings.model,
                                                 effort: model.settings.effort, isPRChoice: false))
    }

    /// 다안 — 평소엔 이 PR 만, 스위치를 켜면 기본값까지. 켜면 기본값이 바뀌고 이 PR 의 따로 고른 것은
    /// 없어지므로(기본값과 같아졌다) 이 줄도 사라진다. 바뀐 사실은 창 아래 알림이 알린다.
    private func switchLine(_ choice: ReviewModelChoice) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { false },
                                 set: { on in if on { model.makeDefaultReviewModel(from: pr) } })) {
                Text("앞으로 모든 PR 에도 \(model.reviewModelLabel(choice)) 쓰기")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Text("기본값은 \(defaultLabel)")
                .foregroundStyle(.secondary)
            Button("되돌리기") { model.useDefaultReviewModel(for: pr) }
                .buttonStyle(.link)
                .help("이 PR 도 기본값(\(defaultLabel))을 씁니다.")
        }
        .font(.caption)
        // 스위치 앞 글자가 두 줄로 접히면 무엇을 켜는 스위치인지 끊겨 읽힌다(실측). 한 줄로 둔다.
        .fixedSize()
    }
}

extension ReviewModelControl where Leading == EmptyView {
    /// 리뷰 전 화면 — 시작 버튼은 위 카드에 있어 두 칸만.
    init(pr: PullRequestInfo, alignment: HorizontalAlignment = .center) {
        self.init(pr: pr, alignment: alignment) { EmptyView() }
    }
}

/// 리뷰한 뒤 다시 돌리는 묶음 — `[전체로 다시 리뷰 ▾] [모델 ⌄] [Effort ⌄]`. 무엇을 할지(버튼)가 앞, 어떻게(모델)가
/// 뒤다(2026-11-06 사용자 결정). AI 리뷰 탭 판정 줄 아래 한 줄과 새 커밋 안내 줄이 같이 쓴다 — 두 자리에 같은
/// 모양으로 떠야 같은 일을 하는 줄로 읽힌다.
struct ReviewRelaunchControls: View {
    let pr: PullRequestInfo

    var body: some View {
        ReviewModelControl(pr: pr, alignment: .leading) {
            ReviewLaunchSplitButton(pr: pr, hasRecord: true)
                .fixedSize()
        }
    }
}

/// Claude 앱처럼 `[모델 ⌄] [Effort ⌄]` 두 칸(사용자 결정). AI 리뷰 탭(이 PR)과 설정(기본값)이 같이 쓴다.
///
/// - 모델: Claude Code 구역(계열 최신 넷 — CLI 가 새 계열을 알려 주면 그것도)과 Codex 구역(Codex 가 알려 준 계열마다
///   가장 새 것)을 한 메뉴에 둔다(위젯 시안 A, 2026-10-29 사용자 결정 — 엔진 칸을 하나 더 두는 B·엔진 스위치 C·
///   엔진별 하위 메뉴 D 는 보고 고르지 않았다). 고른 모델이 곧 엔진이다(`ReviewEngineKind(model:)`). 연결 안 된 쪽은 "연결하기…" 한 줄로
///   설정 › 연결에 보낸다 — 하나만 붙인 사람이 다른 쪽을 나중에 붙이는 길이다. 그 아래 '과거 버전 고르기'
///   (두 엔진의 지난 버전 + '모델 이름 직접 입력…').
/// - Effort: 단계 이름만. Claude 는 CLI 가 `--help` 에 적은 것, Codex 는 그 모델이 받는다고 알려 준 것 — 바뀌거나 늘어도 따라간다.
///   고르지 않았으면 CLI 가 밝힌 그 모델의 기본값을, 모르면 "Effort" 를 보인다.
/// - 상세 화면 맨 아래 대화창도 같은 두 칸을 쓴다(`chat`, 2026-11-05 시안 A 사용자 결정). 그때는 그 대화를 만든 엔진의
///   모델만 보인다 — 대화 기록이 엔진마다 따로라 Claude 로 리뷰한 대화를 Codex 로 이어 물을 수는 없다.
struct ReviewModelPills: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let modelID: String
    let effort: String
    /// 고른 값이 어디에 쓰이는지 — 칸에 마우스를 올리면 보인다.
    let scope: String
    let chooseModel: (String) -> Void
    let chooseEffort: (String) -> Void
    /// 대화창에서 쓸 때. nil 이면 리뷰 모델 칸(AI 리뷰 탭·설정)이다.
    var chat: ChatContext?
    @State private var enteringModelName = false

    /// 대화창 두 칸이 메뉴에 더 다는 것.
    struct ChatContext {
        /// 그 대화를 만든 엔진 — 이 엔진의 모델만 고를 수 있다.
        let engine: ReviewEngineKind
        /// 리뷰한 모델의 칸 저장값. 메뉴의 그 줄에 "리뷰한 모델" 을 단다.
        let reviewedModel: String
        /// 리뷰와 다르게 골라 둔 것이 있을 때만 — "리뷰한 설정으로 되돌리기".
        let reset: (() -> Void)?
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                modelMenu
            } label: {
                Text(model.reviewModelName(modelID))
            }
            .modifier(PillStyle())
            .help(modelHelp)
            Menu {
                effortMenu
            } label: {
                Text(currentEffort.map(EffortLevel.displayName) ?? "Effort")
            }
            .modifier(PillStyle())
            .help("Effort — 높을수록 더 오래 생각하고 토큰을 더 씁니다. \(scope).")
        }
        .sheet(isPresented: $enteringModelName) {
            ModelNameSheet { chooseModel($0) }
        }
    }

    private var modelHelp: String {
        guard chat != nil else {
            return "리뷰 모델 — Claude Code·Codex 중에서 고릅니다. diff 리뷰와 전체 리뷰가 같이 씁니다. \(scope)."
        }
        return "답할 모델 — \(scope). 리뷰와 다른 모델로 바꾸면 그다음 질문은 지금까지의 대화를 처음부터 다시 읽어 토큰이 더 듭니다."
    }

    private var currentEffort: String? {
        model.shownEffort(model: modelID, effort: effort)
    }

    private func shows(_ engine: ReviewEngineKind) -> Bool {
        chat.map { $0.engine == engine } ?? true
    }

    @ViewBuilder
    private var modelMenu: some View {
        if shows(.claude) {
            engineSection(.claude, options: model.modelOptions)
        }
        if shows(.codex) {
            engineSection(.codex, options: model.codexModelOptions)
        }
        let past = (shows(.claude) ? model.pastModelOptions : []) + (shows(.codex) ? model.codexPastModelOptions : [])
        // '모델 이름 직접 입력' 은 Claude 이름만 받는다(`claude --model` 에 물어 확인한다).
        let canEnterName = shows(.claude)
        if !past.isEmpty || canEnterName {
            Divider()
            Menu("과거 버전 고르기") {
                if !past.isEmpty {
                    ForEach(past) { option in
                        checkItem(title(for: option), isOn: modelID == option.id) { chooseModel(option.id) }
                    }
                    if canEnterName {
                        Divider()
                    }
                }
                if canEnterName {
                    Button("모델 이름 직접 입력…") { enteringModelName = true }
                }
            }
        }
        if chat != nil {
            // 실측(2026-11-05): 모델을 바꾼 첫 질문은 대화 전체를 캐시에 새로 쓴다. Effort 만 바꾸면 캐시가 이어진다.
            Divider()
            Text("다른 모델로 바꾸면 그다음 질문은 대화를 다시 읽어 토큰이 더 듭니다")
        }
    }

    /// 대화창에서는 리뷰한 모델 줄에 표시를 단다 — 바꿨다가 돌아올 자리를 찾게.
    private func title(for option: ReviewModelOption) -> String {
        guard let chat, option.id == chat.reviewedModel else { return option.label }
        return "\(option.label) · 리뷰한 모델"
    }

    /// 엔진 하나의 구역. 연결 안 됐으면(확인을 마쳤는데 준비 안 됨) 모델 대신 "연결하기…" 한 줄 — 지금 고른 모델이
    /// 그 엔진 것이면 목록을 그대로 둔다(고른 게 사라지면 무엇이 골라져 있는지 모른다).
    /// Codex 목록을 아직 못 받았으면(막 연결함) 고를 것이 없으니 그것도 "연결하기…" 대신 안내 한 줄을 둔다.
    @ViewBuilder
    private func engineSection(_ engine: ReviewEngineKind, options: [ReviewModelOption]) -> some View {
        Section(engine.productName) {
            let known = model.engineStatus(engine) != nil
            let usingThis = ReviewEngineKind(model: modelID) == engine
            if known, !model.engineReady(engine), !usingThis {
                Button("\(engine.productName) 연결하기…") {
                    model.settingsFocus = .connection
                    openSettings()
                }
            } else if options.isEmpty {
                Text("모델 목록을 받는 중…")
            } else {
                ForEach(options) { option in
                    checkItem(title(for: option), isOn: modelID == option.id) { chooseModel(option.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var effortMenu: some View {
        let shown = currentEffort
        // 대화창에서는 고르지 않았을 때 답할 단계(그 모델의 CLI 기본값)를 짚어 준다. 리뷰 칸은 예전 그대로 둔다.
        let fallback = chat == nil ? nil : model.shownEffort(model: modelID, effort: "")
        ForEach(model.effortLevels(forModel: modelID), id: \.self) { level in
            let name = EffortLevel.displayName(level)
            checkItem(level == fallback ? "\(name) · 기본" : name, isOn: shown == level) { chooseEffort(level) }
        }
        if let reset = chat?.reset {
            Divider()
            Button("리뷰한 설정으로 되돌리기", action: reset)
        }
    }

    /// 메뉴 줄에 ✓ 를 단다. Picker 는 목록에 없는 값(직접 입력한 이름)을 고르고 있으면 경고를 내서 Toggle 로 그린다.
    private func checkItem(_ title: String, isOn: Bool, choose: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { if $0 { choose() } }))
    }
}

/// 두 칸의 모양 — 테두리 없는 메뉴에 옅은 바탕. 펼침 화살표(⌄)는 메뉴가 글 뒤에 단다
/// (라벨에 화살표 그림을 직접 넣으면 macOS 가 글 **앞**으로 옮긴다 — 실측).
private struct PillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// '모델 이름 직접 입력…' — CLI 에 물어(토큰 0) 아는 이름이면 바로 쓰고, 모르면 한 번 묻는다.
/// 쓴 이름은 '과거 버전 고르기' 에 남는다.
private struct ModelNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let choose: (String) -> Void
    @State private var name = ""
    @State private var checking = false
    /// 확인했더니 바로 쓰기 어려운 이름 — 그래도 쓸지 묻는다.
    @State private var warning: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("모델 이름 직접 입력")
                .font(.headline)
            TextField("예: claude-opus-5", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if warning == nil { Task { await check() } } }
                .onChange(of: name) { warning = nil }
            Text("`claude --model` 에 넣는 이름을 적습니다. 쓴 이름은 ‘과거 버전 고르기’ 에 남습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Claude Code 에 묻는 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if warning != nil {
                    Button("그래도 쓰기") { use(trimmed) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("쓰기") { Task { await check() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ClaudeModels.isModelName(trimmed) || checking)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func check() async {
        let id = trimmed
        guard ClaudeModels.isModelName(id), !checking else { return }
        // 계열 이름을 적었으면 그 계열(최신을 따라감)을 고른 것으로 친다. 지난 버전 목록에 남기지 않는다.
        if model.modelOptions.contains(where: { $0.id == id }) {
            choose(id)
            dismiss()
            return
        }
        checking = true
        let result = await model.checkCustomModel(id)
        checking = false
        // 묻는 사이 이름을 고쳤으면 옛 이름의 결과를 버린다.
        guard id == trimmed else { return }
        switch result {
        case .known:
            use(id)
        case .unknown:
            warning = "Claude Code 가 모르는 이름입니다. 그대로 쓰면 리뷰가 실패할 수 있습니다."
        case .unchecked:
            warning = "Claude Code 에 묻지 못해 이 이름이 맞는지 확인하지 못했습니다."
        }
    }

    private func use(_ id: String) {
        Task { await model.rememberModels([id]) }
        choose(id)
        dismiss()
    }
}
