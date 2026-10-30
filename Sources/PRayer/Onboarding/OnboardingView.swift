import SwiftUI
import PRayerCore

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, engine, github, repos, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "시작하기"
        case .engine: return "AI 연결"
        case .github: return "GitHub 연결"
        case .repos: return "레포 선택"
        case .done: return "완료"
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: OnboardingStep = DebugLaunch.onboardingStep ?? .welcome

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStep.allCases) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(item == step ? .primary : .secondary)
                        // 단계 이름이 두 줄로 접히면 머리 줄 높이가 들쭉날쭉하다("GitHub 연결"). 줄 사이 선이 대신 줄어든다.
                        .lineLimit(1)
                        .fixedSize()
                }
                if item != .done {
                    Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .engine: EngineCheckStep()
        case .github: GitHubConnectStep()
        case .repos: RepoPickerStep()
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.displayName)
                    .font(.largeTitle.bold())
                Text(AppInfo.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text("팀 PR 을 한눈에 보고, 이 맥에 설치된 Claude Code 나 Codex 로 리뷰 초안을 만들고, 확인한 것만 GitHub 에 올립니다.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("리뷰 초안은 이 맥에만 저장됩니다. \"게시\" 를 눌러야 GitHub 에 올라갑니다.", systemImage: "lock.shield")
                    Label("PR 의 코드와 설명이 리뷰에 고른 AI 의 내 계정을 통해 전송됩니다 — Claude Code 는 Anthropic, Codex 는 OpenAI 로.", systemImage: "arrow.up.forward.app")
                    Label("리뷰는 저절로 돌지 않습니다. 리뷰 버튼을 누른 PR 만 AI 로 갑니다.", systemImage: "hand.tap")
                    Label("AI 프로세스에는 쓰기 도구를 주지 않습니다. 앱만 GitHub 에 씁니다.", systemImage: "hand.raised")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("설정이 끝났습니다", systemImage: "checkmark.seal.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ReviewEngineKind.allCases) { engine in
                        LabeledContent(engine.productName) {
                            Text(engineSummary(model.engineStatus(engine)))
                        }
                    }
                    LabeledContent("기본 리뷰 모델") {
                        Text(model.reviewModelName(model.settings.model))
                    }
                    LabeledContent("GitHub") {
                        Text(model.githubAccount?.login ?? "미연결")
                    }
                    LabeledContent("레포") {
                        Text(model.settings.enabledRepos.isEmpty
                             ? "없음"
                             : model.settings.enabledRepos.map(\.repo.full).joined(separator: ", "))
                    }
                }
                .padding(6)
            }
            Text("PR 요약은 목록을 새로 고칠 때 자동으로 만들어집니다. AI 리뷰는 직접 눌러야 돕니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func engineSummary(_ status: EngineStatus?) -> String {
        guard let status else { return "확인 중" }
        guard status.isReady else { return status.isInstalled ? "로그인 필요" : "연결 안 함 — 설정 › 연결에서 붙일 수 있습니다" }
        var parts: [String] = []
        if let version = status.version { parts.append("v\(version)") }
        if let account = status.accountLabel, !account.isEmpty { parts.append(account) }
        return parts.isEmpty ? "확인 필요" : parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("이전") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            if step == .done {
                Button("대시보드 열기") {
                    Task { await model.finishOnboarding() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else {
                Button("다음") {
                    // 하나만 붙였으면 그쪽을 기본으로 — Codex 만 붙인 사람이 Claude 기본값으로 리뷰를 눌러 실패하지 않게.
                    if step == .engine { Task { await model.adoptReadyEngineIfNeeded() } }
                    step = OnboardingStep(rawValue: step.rawValue + 1) ?? .done
                    if step == .repos { Task { await model.loadRepoOptions() } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
        .padding(16)
    }

    private var canAdvance: Bool {
        switch step {
        // 둘 중 하나만 있어도 된다. 나머지는 나중에 설정 › 연결에서 붙인다.
        case .engine: return !model.readyEngines.isEmpty
        case .github: return model.githubAccount != nil
        // 체크를 끈 레포는 목록에 남아도 고른 것이 아니다(Settings.setRepo).
        case .repos: return !model.settings.enabledRepos.isEmpty
        default: return true
        }
    }
}

/// 리뷰에 쓸 AI 를 붙이는 단계. Claude Code·Codex 중 하나만 있어도 되고, 둘 다 붙이면 리뷰마다 고른다.
struct EngineCheckStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("리뷰에 쓸 AI 를 연결합니다")
                .font(.title2.bold())
            Text("이 맥의 Claude Code 나 Codex 를 그대로 빌려 씁니다. 하나만 있어도 되고, 둘 다 연결하면 리뷰마다 골라 쓸 수 있습니다. 로그인은 각 CLI 가 직접 하므로 앱이 대신하지 않습니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ReviewEngineKind.allCases) { engine in
                card(engine)
            }
            if model.readyEngines.count == 2 {
                defaultEnginePicker
            } else if model.readyEngines.count == 1, let other = ReviewEngineKind.allCases.first(where: { !model.engineReady($0) }) {
                Label("\(other.productName) 는 나중에 설정 › 연결에서 붙일 수 있습니다.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // 처음 보는 맥이면 Codex 를 아직 찾아보지 않았을 수 있다.
            if model.codexStatus?.isInstalled != true { await model.checkCodex(rediscover: true) }
        }
    }

    private func card(_ engine: ReviewEngineKind) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(engine.productName).font(.headline)
                    Text(engine == .claude ? "Claude 계정 · Anthropic" : "ChatGPT 계정 · OpenAI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                EngineStatusLine(engine: engine)
                if model.engineStatus(engine)?.isInstalled == false {
                    switch engine {
                    case .claude: ClaudeInstallHint()
                    case .codex: CodexInstallHint()
                    }
                }
                EngineActions(engine: engine)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 둘 다 붙였으면 처음 고를 엔진을 묻는다. 리뷰할 때마다 바꿀 수 있다.
    private var defaultEnginePicker: some View {
        HStack(spacing: 10) {
            Text("처음엔")
            Picker("", selection: Binding(
                get: { ReviewEngineKind(model: model.settings.model) },
                set: { engine in
                    guard engine != ReviewEngineKind(model: model.settings.model) else { return }
                    model.setDefaultReviewModel(model.defaultModel(for: engine), effort: "")
                })) {
                ForEach(ReviewEngineKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text("로 리뷰합니다. 리뷰할 때마다 바꿀 수 있습니다.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct GitHubConnectStep: View {
    @Environment(AppModel.self) private var model
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GitHub 연결")
                .font(.title2.bold())
            Text("앱은 비밀번호나 토큰을 직접 받지 않습니다. 이미 로그인된 gh CLI 를 그대로 씁니다.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let account = model.githubAccount {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(account.login).bold()
                            Text("로그인됨").foregroundStyle(.secondary)
                        }
                        LabeledContent("권한") {
                            Text(account.scopes.isEmpty ? "확인 불가" : account.scopes.joined(separator: ", "))
                                .font(.caption.monospaced())
                        }
                        if !account.hasRequiredScopes {
                            Label("`repo`, `read:org` 권한이 필요합니다. `gh auth login` 을 다시 실행하세요.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("연결되지 않았습니다").bold()
                        }
                        Text(model.githubError ?? "gh CLI 로그인이 필요합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("gh 경로") {
                        Text(model.settings.ghPath).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Divider()
                    GitHubHostPicker()
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("터미널에서 한 번만") {
                VStack(alignment: .leading, spacing: 6) {
                    CopyableCommand(command: "brew install gh")
                    CopyableCommand(command: "gh auth login")
                    Text("회사 GitHub(Enterprise)이면 `gh auth login --hostname github.회사.com` 으로 붙습니다. 위 칸에서 바로 열 수도 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("다시 확인") {
                    isChecking = true
                    Task {
                        await model.checkGitHub()
                        isChecking = false
                    }
                }
                .disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
            }
        }
    }
}

/// Claude Code CLI 를 못 찾았을 때 할 일. 설정 화면도 같은 안내를 쓴다.
///
/// 되는 사람과 안 되는 사람이 갈리는 이유가 대개 **어떻게 깔았느냐**라서(공식 스크립트·Homebrew 는 잡히고,
/// CLI 없이 데스크톱 앱만 쓰면 없다) 두 갈래를 다 적는다.
struct ClaudeInstallHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이 맥에서 Claude Code CLI 를 찾지 못했습니다. 데스크톱 앱과 별개로 터미널용 CLI 가 있어야 합니다. \"터미널에서 설치\" 가 공식 설치 명령을 실행하고 이어서 로그인합니다.")
            CopyableCommand(command: ClaudeRunner.installCommand)
            Text("이미 깔려 있다면(npm 등) \"경로 변경…\" 으로 그 파일을 고르세요. 위치는 터미널에서 `type -a claude` 로 볼 수 있습니다.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CopyableCommand: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("복사")
        }
    }
}

struct RepoPickerStep: View {
    @Environment(AppModel.self) private var model
    /// 온보딩에서는 제목이 필요하지만, 설정 화면은 섹션 제목이 이미 같은 말을 한다.
    var showsTitle = true
    /// 켜 둔 레포 아래에 전체 리뷰용 로컬 클론 경로 칸을 붙인다. 설정 화면과 레포 관리 팝오버에서 켠다 —
    /// 온보딩은 레포 고르기에 집중하고, 전체 리뷰는 나중에 필요할 때 정해도 된다.
    var showsClonePaths = false
    /// 잠깐 강조할 레포("경로 설정…" 바로 가기로 왔을 때). 목록을 그 줄까지 내린다.
    var highlightedRepo: RepoID?
    /// 레포 관리(⚙︎) 팝오버. 설정 창과 같은 목록을 쓰되, 고른 레포만 보이다가 검색하면 찾은 레포가 아래에 붙는다 —
    /// 팝오버는 켜고 끄려고 자주 여는데, 접근 가능한 레포가 늘 다 깔려 있으면 고른 레포를 찾기 어렵다.
    var compact = false
    @State private var search = ""
    /// 타자가 멈춘 뒤에만 서버로 보내려고 들고 있는 예약.
    @State private var searchTask: Task<Void, Never>?
    /// 팝오버 목록의 실제 높이. 줄이 다 들어가면 그 높이로 두고 스크롤 막대를 숨긴다(compactList).
    @State private var compactContentHeight: CGFloat = 0
    private static let compactMaxHeight: CGFloat = 380

    private var query: RepoQuery { RepoQuery(search) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if showsTitle {
                Text("리뷰할 레포 선택")
                    .font(.title2.bold())
                Text("접속한 GitHub 계정이 접근할 수 있는 레포입니다. 볼 레포를 골라 주세요.")
                    .foregroundStyle(.secondary)
                // 팀원과 같은 레포·규칙으로 시작하는 사람이 많다. 하나씩 고르는 대신 받은 파일에서 고르게 한다.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("팀원에게 받은 \(AppInfo.displayName) 설정 파일이 있으면 레포와 규칙을 골라 한 번에 가져올 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsImportButton(title: "팀원 설정 가져오기…")
                }
            }

            searchField

            // 팝오버는 검색할 때만 안 고른 레포를 보이므로, 그때만 이 안내가 뜻이 있다.
            if model.repoListTruncated, !compact || !query.isEmpty {
                Label("접근 가능한 레포가 많아 최근 push 순으로만 보여줍니다. 안 보이면 이름을 치면 GitHub 에서 찾아옵니다.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 고른 레포를 위로 올려서 **한 목록**으로 본다. 목록을 둘로 나눠 두면
            // 같은 레포가 화면에 두 번 나오고, 고른 것과 안 고른 것을 견주기 어렵다.
            if compact {
                compactList
            } else {
                ScrollViewReader { proxy in
                    List {
                        if rows.isEmpty { emptyRow }
                        ForEach(rows) { option in
                            RepoOptionRow(option: option, config: config(for: option.repo),
                                          showsClonePath: showsClonePaths,
                                          isHighlighted: option.repo == highlightedRepo)
                                .id(option.repo)
                        }
                    }
                    .frame(minHeight: 240)
                    .animation(.easeOut(duration: 0.2), value: model.settings.repos.map(\.repo))
                    .onChange(of: highlightedRepo) { _, repo in
                        guard let repo else { return }
                        withAnimation { proxy.scrollTo(repo, anchor: .center) }
                    }
                }
            }

            // 설정 창(레포 줄 아래 PR 스냅샷이 보이는 곳)에서는 목록 아래 긴 설명을 뺐다(2026-10-23 사용자 결정).
            // 처음 고르는 온보딩과 툴바 팝오버의 짧은 줄은 그대로 둔다.
            if compact || !showsClonePaths {
                Text(compact
                     ? "체크를 끄면 조회·알림만 멈춥니다(설정은 남음) · 아예 빼려면 우클릭 · Approve N명 필요 는 머지 조건"
                     : "고른 레포는 맨 위로 올라옵니다. 체크를 끄면 조회·알림만 멈추고 Approve 수는 남습니다(아예 빼려면 우클릭 → 목록에서 빼기). `Approve N명 필요` 는 GitHub 브랜치 규칙에서 읽은 머지 조건입니다 — 브랜치마다 다르면 PR 마다 그 PR 이 향하는 브랜치의 수를 쓰고, 못 읽으면 직접 정한 값(처음 3명 — 팀 기준에 맞게 고치세요)을 씁니다. 앱을 켤 때와 새로고침할 때 다시 읽습니다.")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 팝오버에서는 목록 틀 없이 줄만 늘어놓는다. 줄이 적으면 그만큼만, 많으면 높이를 묶고 스크롤한다.
    ///
    /// 높이는 재서 정한다. `frame(maxHeight:)` 에 맡겼더니 줄이 둘뿐인데도 몇 pt 가 남아 스크롤 막대가
    /// 늘 떠 있었다(실측 — 마우스를 쓰는 맥은 막대가 항상 보인다).
    private var compactList: some View {
        let fits = compactContentHeight <= Self.compactMaxHeight
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty { emptyRow }
                ForEach(rows) { option in
                    RepoOptionRow(option: option, config: config(for: option.repo),
                                  showsClonePath: showsClonePaths, compact: true)
                    if option.id != rows.last?.id { Divider() }
                }
            }
            .padding(.vertical, 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { compactContentHeight = $0 }
        }
        .scrollDisabled(fits)
        .scrollIndicators(fits ? .never : .automatic)
        .frame(height: min(max(compactContentHeight, 1), Self.compactMaxHeight))
        .animation(.easeOut(duration: 0.2), value: model.settings.repos.map(\.repo))
    }

    private func config(for repo: RepoID) -> RepoConfig? {
        model.settings.repos.first { $0.repo == repo }
    }

    /// 보일 줄. 고른 것이 위, 그 아래 안 고른 것. 팝오버는 검색할 때만 안 고른 것을 붙인다.
    private var rows: [RepoOption] {
        guard !compact || !query.isEmpty else { return picked }
        let selected = Set(model.settings.repos.map(\.repo))
        return picked + filtered.filter { !selected.contains($0.repo) }
    }

    /// 목록에 올려 둔 레포(켜 둔 것과 꺼 둔 것 모두), 이름순. 켜고 끌 때 줄이 자리를 옮기지 않게
    /// 켬·끔으로는 나누지 않는다 — 누른 줄이 움직이면 다음 클릭이 엉뚱한 줄에 간다.
    ///
    /// 고른 레포가 `repoOptions` 에 **없을 수 있다.** 그 목록은 최근 push 순으로 잘려서
    /// 오기 때문에(화면의 "접근 가능한 레포가 많아…" 안내가 그 뜻이다), 한동안 push 가
    /// 없던 레포는 골라 뒀어도 빠진다. 그러면 체크된 줄이 아예 안 그려져서 "선택이
    /// 풀렸나?" 로 보인다(실측). 없으면 설정에서 만들어 채운다.
    private var picked: [RepoOption] {
        var byRepo = [RepoID: RepoOption]()
        for option in model.repoOptions { byRepo[option.repo] = option }

        return model.settings.repos
            .map { config in
                byRepo[config.repo] ?? RepoOption(repo: config.repo, isPrivate: false, isArchived: false,
                                                  isFork: false, defaultBranch: config.prTargetBranch,
                                                  permission: nil)
            }
            .filter { query.matches($0.repo) }
            .sorted { $0.repo.full < $1.repo.full }
    }

    /// 오너·이름 구분 없이 한 칸에서 받는다. 치는 대로 이미 받아 둔 목록을 거르고,
    /// 타자가 멎으면 GitHub 에도 물어본다(검색 버튼이 없다).
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // 폼 안에서는 .plain 이 배경과 구분이 안 가 "칸" 으로 안 읽힌다.
            // 제목도 prompt 로 준다 — 제목으로 주면 macOS 가 칸 밖에 라벨로 그린다.
            TextField(text: $search,
                      prompt: Text("레포 이름 · 오너 · 오너/이름 으로 검색")) {
                Text("레포 검색")
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .onSubmit { runSearch(now: true) }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("검색어 지우기")
            }
            if model.isLoadingRepos { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .onChange(of: search) { _, _ in runSearch(now: false) }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var emptyRow: some View {
        if search.isEmpty, compact {
            // 팝오버는 고른 레포만 보이므로, 비었다는 것은 아직 고른 레포가 없다는 뜻이다.
            Text("위 칸에서 레포를 찾아 체크하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if search.isEmpty {
            Text(model.isLoadingRepos ? "레포를 불러오는 중입니다." : "접근할 수 있는 레포가 없습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.isLoadingRepos {
            Text("\(query.raw) 를 GitHub 에서 찾는 중입니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(query.raw) 로 찾은 레포가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // 검색에 안 잡히는 레포도 있다(권한·개인 계정). 이름을 정확히 쳤으면 길을 열어 준다.
                if let exact = query.exactRepo {
                    Button("그래도 \(exact.full) 추가") { Task { await model.addRepoByName(exact) } }
                        .buttonStyle(.link)
                }
            }
        }
    }

    /// 타자 한 글자마다 GitHub 을 때리지 않는다. 멎고 나서 한 번만 보낸다.
    private func runSearch(now: Bool) {
        searchTask?.cancel()
        let query = self.query
        guard !query.isEmpty else { return }
        searchTask = Task {
            if !now {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await model.searchRepos(query)
        }
    }

    private var filtered: [RepoOption] {
        model.repoOptions.filter { query.matches($0.repo) }
    }
}

/// 레포 한 줄 — 체크박스 + 이름, 고른 레포면 머지에 필요한 Approve 수까지.
///
/// 고르기와 설정을 한 줄에 둔다. 예전에는 고르는 목록과 설정 목록이 따로 있어서
/// 같은 레포가 한 화면에 두 번 나왔다.
struct RepoOptionRow: View {
    @Environment(AppModel.self) private var model
    let option: RepoOption
    /// 목록에 올린 레포면 설정이 있다(켜 뒀든 꺼 뒀든). 없으면 아직 고른 적이 없다.
    let config: RepoConfig?
    /// 켜 둔 레포 아래에 전체 리뷰 클론 줄(PR 스냅샷·예전 연결)을 붙인다(설정 화면·레포 관리 팝오버).
    var showsClonePath = false
    var isHighlighted = false
    /// 레포 관리 팝오버의 줄 — 이름 아래에 Approve 수를 적고, 오른쪽에 목록 건수·숨은 이유를 둔다.
    /// 대상 브랜치를 고치는 칸은 설정 창에만 둔다(한 번 정하면 거의 바꾸지 않는다).
    var compact = false

    /// 이 줄 아래에 펼 이유 — 오른쪽 아이콘·"숨김 N" 에 마우스를 올린 동안(RepoListStatus 가 채운다).
    @State private var hint: String?

    private var isListed: Bool { config != nil }
    /// 체크 — 켜 두고 보는 중인가(`Settings.setRepo` 주석).
    private var isWatched: Bool { config?.enabled ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { isWatched },
                                     set: { on in Task { await model.setRepoWatched(option.repo, on) } })) {
                    label
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                if let config {
                    if !compact {
                        RepoConfigRow(config: config)
                    } else if config.enabled {
                        RepoListStatus(config: config, hint: $hint)
                    }
                }
            }
            if compact, let hint {
                HoverHint(text: hint)
            }
            // 클론은 레포마다 다르다. 레포는 여기서 고르니 그 레포 바로 아래에 있어야 찾는다(사용자 피드백).
            if showsClonePath, isWatched {
                ReviewCloneRow(repo: option.repo, compact: compact)
                    .padding(.leading, 22)
            }
        }
        // 강조는 배경만 바꾼다. 여백까지 바꾸면 줄 높이가 달라져 아래 줄이 들썩인다.
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.15) : .clear)
                .padding(-4)
        }
        // 체크를 끄는 것은 멈추기라, 아예 빼는 길은 따로 둔다.
        .contextMenu {
            if isListed {
                Button("목록에서 빼기") { Task { await model.removeRepo(option.repo) } }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if compact, let config {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(option.repo.name).font(.callout)
                    if option.isPrivate {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(config.enabled ? .primary : .secondary)
                Text(RepoConfigRow.summary(config)
                     + (config.approvalThresholdFromAPI ? "" : " · 직접 정함")
                     + (config.enabled ? "" : " · 꺼 둠"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help(option.repo.full)
        } else {
            HStack(spacing: 6) {
                Text(option.repo.full)
                    .fontWeight(isWatched ? .medium : .regular)
                    .foregroundStyle(isListed && !isWatched ? .secondary : .primary)
                if option.isPrivate {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
                if isListed, !isWatched {
                    Text("꺼 둠").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 설정의 레포 줄 오른쪽 — 머지에 필요한 Approve 수.
///
/// 예전에는 브랜치 이름을 치는 칸, "승인 N" 캡슐, 구름(읽음)·연필(못 읽음) 아이콘이 있었다. 브랜치 칸은 오타가 나도
/// 조용히 기본값(3명)으로 떨어졌고, 사람이 알고 싶은 것은 브랜치가 아니라 "몇 명이 Approve 하면 되나" 였다(사용자 피드백).
/// - 브랜치별 수가 하나로 모이면: "Approve N명 필요" 만. 어느 브랜치 규칙인지는 마우스를 올리면 나온다.
/// - 브랜치마다 다르면: 기준 수 하나만 "Approve 3명 필요" 로 두고, 옆 ⓘ 에 마우스를 올리면 브랜치별 수를 말풍선
///   (팝오버)으로 띄운다 — 버튼 설명 ⓘ(InfoHint)와 같은 모양이다. 예전에는 줄 아래에 폈는데, 펼 때마다 레포 수백 개짜리
///   목록(List)이 통째로 다시 그려져 마우스가 돌았고, 펴진 내용을 보려고 스크롤하면 호버가 풀려 접혔다
///   (사용자 피드백, 2026-10-06). PR 마다 그 PR 이 향하는 브랜치의 수를 쓴다
///   (`Settings.approvalThreshold(for: PullRequestInfo)`). 한때 "Approve 2명(main·release/*·team/**/*)
///   · 1명(docs/*)" 처럼 전부 적었는데, 두 줄로 꺾이고 정작 몇 명인지가 묻혔다(사용자 피드백).
/// - 못 읽었으면: 주황 "직접 정함" + 수를 고르는 칸 + 다시 읽기. 예전에는 3명이라고만 적혀 고칠 곳이 없었다 —
///   팀이 2명이면 다 찬 PR 이 계속 대기에 남았다. 읽어 온 값에는 아이콘을 달지 않는다 — 읽어 온 것이 보통이다.
struct RepoConfigRow: View {
    @Environment(AppModel.self) private var model
    let config: RepoConfig
    @State private var isReading = false
    /// 브랜치별 수 말풍선. ⓘ 에 마우스를 올린 동안 뜬다.
    @State private var showsRules = false

    private var title: String { "Approve \(config.approvalThreshold)명 필요" }

    /// 브랜치마다 수가 다른가 — 그때만 ⓘ 를 단다. 규칙이 하나면 캡슐만으로 다 말한다.
    static func hasBranchRules(_ config: RepoConfig) -> Bool {
        config.approvalThresholdFromAPI && config.approvalGroups.count > 1
    }

    /// 레포 관리 팝오버의 이름 아래 한 줄. 거기에는 브랜치별 수를 펼 자리가 없어 다르다는 것만 적는다.
    static func summary(_ config: RepoConfig) -> String {
        "Approve \(config.approvalThreshold)명 필요" + (hasBranchRules(config) ? " · 브랜치마다 다름" : "")
    }

    var body: some View {
        HStack(spacing: 6) {
            if !config.approvalThresholdFromAPI {
                Label("직접 정함", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 0.5))
                Stepper(title, value: manualBinding, in: 1...10)
                    .font(.caption)
                    .controlSize(.small)
                    .fixedSize()
                    .help("GitHub 에서 Approve 규칙을 읽지 못했거나 규칙이 없어, 처음에는 3명으로 가정합니다. 팀 기준에 맞게 고치세요 — 실제보다 높으면 다 찬 PR 이 'To review' 에 남고, 낮으면 덜 찬 PR 이 'To review' 에서 빠집니다.")
                Button(isReading ? "읽는 중…" : "다시 읽기") { reread() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(isReading)
            } else if Self.hasBranchRules(config) {
                Text(title)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Image(systemName: "info.circle")
                    .foregroundStyle(showsRules ? Color.accentColor : Color.secondary)
                    .onHover { showsRules = $0 }
                    .popover(isPresented: $showsRules, arrowEdge: .bottom) {
                        ApprovalRulesDetail(config: config)
                    }
                    .accessibilityLabel("브랜치별 Approve 수")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showsRules.toggle() }
            } else {
                Text(title)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help(config.approvalGroups.first.map { "\($0.branches.joined(separator: " · ")) 규칙에서 읽었습니다." }
                          ?? "GitHub 규칙에서 읽었습니다.")
                // ⓘ 자리를 비워 둔다 — 위아래 줄의 캡슐 오른쪽 끝이 맞는다(ⓘ 가 있는 줄만 캡슐이 안으로 들어가 보였다).
                Image(systemName: "info.circle")
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .task {
            // 캡처용(DebugLaunch) — 말풍선을 띄워 둔다. 설정 창이 자리를 잡은 뒤에 띄워야 화살표가 ⓘ 를 가리킨다.
            guard DebugLaunch.showApprovalRules, Self.hasBranchRules(config) else { return }
            try? await Task.sleep(for: .seconds(3))
            showsRules = true
        }
    }

    /// 규칙을 못 읽은 레포의 수. 읽어 온 값이 생기면(다시 읽기·앱을 켤 때) 그 값이 이것을 덮는다.
    private var manualBinding: Binding<Int> {
        Binding(get: { config.approvalThreshold },
                set: { model.setManualApprovalThreshold($0, for: config.repo) })
    }

    private func reread() {
        isReading = true
        Task {
            await model.refreshApprovalThreshold(for: config.repo)
            isReading = false
        }
    }
}

/// 브랜치별 Approve 수 말풍선(RepoConfigRow 의 ⓘ 에 마우스를 올리면 뜬다).
///
/// 캡슐에 보이는 기준 수가 든 묶음에 "기준" 을 단다. 기준 수는 규칙에 없는 브랜치로 가는 PR 에도 쓰인다
/// (`Settings.approvalThreshold(for: PullRequestInfo)`). "기본 브랜치" 라고 적지 않는 이유: 기준 묶음은 예전에
/// 메뉴로 고른 묶음일 수도 있어서, 기본 브랜치의 묶음이라고 단정할 수 없다.
struct ApprovalRulesDetail: View {
    let config: RepoConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("브랜치마다 Approve 수가 달라, PR 마다 그 PR 이 향하는 브랜치의 수를 씁니다.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(config.approvalGroups) { group in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(group.count)명")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 30, alignment: .leading)
                    Text(group.branches.joined(separator: " · "))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if group.count == config.approvalThreshold {
                        Text("기준")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            Text("규칙이 없는 브랜치로 가는 PR 은 기준 수(\(config.approvalThreshold)명)로 셉니다. GitHub 브랜치 규칙에서 읽었고, 앱을 켤 때와 새로고침할 때 다시 읽습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(width: 360, alignment: .leading)
        .padding(12)
    }
}
