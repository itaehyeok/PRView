import SwiftUI
import UserNotifications
import PRayerCore

/// 설정 창을 열면서 곧장 보여 줄 자리.
///
/// 설정 창은 늘 "연결" 탭으로 열린다. 그래서 다른 탭의 칸을 가리키며 "설정 열기" 를 누르면 그 칸이 없는
/// 탭이 떠서 칸이 사라진 것처럼 보였다. 그래서 여는 쪽이 목적지를 같이 넘긴다.
enum SettingsFocus: Equatable {
    /// "레포·팀 규칙" 탭에서 이 레포 줄(바로 아래에 PR 스냅샷 줄이 있다). nil 이면 탭만 연다.
    case clonePath(RepoID?)
    /// "연결" 탭 — 리뷰 모델 메뉴의 "Codex 연결하기…" 처럼 안 붙인 엔진을 붙이러 올 때.
    case connection
}

/// 설정 창을 그 자리로 연다. `SettingsLink` 는 목적지를 넘길 수 없어서 버튼으로 만든다.
struct OpenSettingsButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let title: String
    let focus: SettingsFocus

    var body: some View {
        Button(title) {
            model.settingsFocus = focus
            openSettings()
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = DebugLaunch.settingsTab ?? "연결"

    var body: some View {
        TabView(selection: $selection) {
            ConnectionSettings().tabItem { Label("연결", systemImage: "link") }.tag("연결")
            ReposSettings().tabItem { Label("레포·팀 규칙", systemImage: "shippingbox") }.tag("레포")
            ReviewSettings().tabItem { Label("리뷰", systemImage: "sparkles") }.tag("리뷰")
            ExclusionSettings().tabItem { Label("대상 제외", systemImage: "line.3.horizontal.decrease.circle") }.tag("제외")
            // 내 PR 우클릭 "슬랙 리뷰 요청 글 만들기" 의 연동·보낼 곳(글 형식은 고정이라 칸이 없다).
            SlackSettingsTab().tabItem { Label("슬랙", systemImage: "paperplane") }.tag("슬랙")
            NotificationSettings().tabItem { Label("알림·기타", systemImage: "bell") }.tag("알림")
            FontSettings().tabItem { Label("글꼴", systemImage: "textformat") }.tag("글꼴")
            // 예전에는 ‘알림·기타’ 탭 안의 한 섹션이었는데, 찾기 어려웠다(사용자 피드백). 탭으로 뺀다.
            SharingSettings().tabItem { Label("설정 공유", systemImage: "square.and.arrow.up.on.square") }.tag("공유")
        }
        .padding(12)
        // 이미 열려 있는 설정 창에도 먹도록 값이 바뀔 때마다 탭을 옮긴다.
        .onChange(of: model.settingsFocus, initial: true) { _, focus in
            if case .clonePath = focus { selection = "레포" }
            if focus == .connection { selection = "연결" }
        }
    }
}

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            // 리뷰 엔진 둘 — 하나만 붙여도 되고, 나중에 여기서 다른 쪽을 붙인다.
            EngineConnectionSection(engine: .claude)
            EngineConnectionSection(engine: .codex)

            Section("GitHub") {
                // 엔진 섹션과 같은 모양이어야 두 번 읽지 않는다: 상태 → 고를 것 → 버튼.
                LabeledContent("상태") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.githubAccount == nil ? "확인 필요" : "사용 가능")
                            .foregroundStyle(model.githubAccount == nil ? .orange : .green)
                        if let account = model.githubAccount {
                            Text("\(account.login) · \(model.settings.githubHost)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = model.githubError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // 호스트가 하나뿐이면 위 상태 줄("아이디 · 호스트")과 같은 말이라 뺀다. 로그인이 안 돼 상태 줄에
                // 호스트가 안 보일 때는 남긴다(2026-10-23 사용자 결정 — 아래 안내 문구도 같이 뺐다).
                if model.githubHosts.count > 1 || model.githubAccount == nil {
                    GitHubHostPicker()
                }
                // 버튼 줄은 Claude 섹션과 같은 자리(맨 아래)에 둔다.
                GitHubLoginControls()
            }

            Section {
                Button("온보딩 다시 실행") { model.showOnboarding = true }
                Button("로그 파일 열기") { model.openLogFile() }
            }
        }
        .formStyle(.grouped)
    }
}

/// 레포 줄 아래의 전체 리뷰 클론 한 줄 — PR 스냅샷의 크기·지우기, 또는 예전에 연결한 내 클론과 "연결 끊기".
///
/// 예전에는 여기서 클론 폴더를 직접 골랐다(경로 칸·찾기·확인). 이제 클론은 PRayer 폴더에 레포마다 PR 스냅샷으로
/// 늘 같은 자리에 받으니 고를 게 없다(사용자 결정, 2026-10-06 — ReviewClone). 예전 버전에서 연결해 둔 사람만
/// 그 경로와 "연결 끊기" 가 남고, 끊으면 PR 스냅샷으로 넘어간다.
struct ReviewCloneRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoID
    /// 레포 관리 팝오버처럼 좁은 곳에서는 한 줄로. 확인 창은 본창이 띄운다(PendingCloneAction 주석).
    var compact = false

    @State private var size: Int64?
    @State private var linked: LinkedStatus = .unknown
    /// 지금 할 수 없는 까닭(리뷰 중 등). 누른 자리 바로 아래에 보인다 — 버튼을 꺼 두면 왜 안 되는지 모른다.
    @State private var problem: String?
    /// 설정 창의 확인 창.
    @State private var confirming: PendingCloneAction?

    enum LinkedStatus: Equatable {
        case unknown
        case ok(root: String)
        case wrongRepository(origin: String?)
        case missing
        case failed(String)
    }

    private var linkedPath: String? { model.settings.deepReviewPath(for: repo) }
    private var snapshotExists: Bool { ReviewClone.exists(repo) }
    /// 이 레포의 PR 스냅샷을 지금 처음 받는 잡의 진행.
    private var cloningFraction: Double? {
        model.jobs.last { $0.repo == repo && $0.clonedSnapshot }?.cloneFraction
    }
    /// 크기를 다시 잴 때 — 스냅샷이 생기거나 사라지거나, 받던 클론이 끝났을 때.
    private var sizeKey: String { "\(snapshotExists)-\(cloningFraction == nil)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let linkedPath {
                linkedRow(linkedPath)
            } else {
                snapshotRow
            }
            if let problem {
                Text(problem)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: sizeKey) { await measure() }
        .task(id: linkedPath) { await verify() }
        .alert(confirming?.title ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { action in
            Button(action.confirmTitle, role: .destructive) { Task { await perform(action) } }
            Button("취소", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: PR 스냅샷

    @ViewBuilder
    private var snapshotRow: some View {
        if let fraction = cloningFraction {
            line(key: "PR 스냅샷", value: "클론 중 \(Int((fraction * 100).rounded()))%")
        } else if snapshotExists {
            line(key: "PR 스냅샷", value: [size.map(ByteSizeText.short), receivedText].compactMap { $0 }.joined(separator: " · "),
                 action: ("지우기", { ask(.deleteSnapshot) }))
        } else {
            line(key: "PR 스냅샷", value: compact ? "없음 — 전체 리뷰 때 클론" : "없음 — 전체 리뷰를 처음 누를 때 클론합니다",
                 muted: true)
        }
    }

    /// "오늘 받음" · "3일 전 받음".
    private var receivedText: String? {
        guard let created = ReviewClone.createdAt(repo) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: created),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return "오늘 받음"
        case 1: return "어제 받음"
        default: return "\(days)일 전 받음"
        }
    }

    // MARK: 예전에 연결한 내 클론

    @ViewBuilder
    private func linkedRow(_ path: String) -> some View {
        let shown = (path as NSString).abbreviatingWithTildeInPath
        line(key: "전체 리뷰 폴더", value: shown, mono: true, status: linkedIcon,
             action: ("연결 끊기", { ask(.unlink(path: path)) }))
        if let note = linkedNote {
            Text(note)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(linkedNoteIsProblem ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !compact, case .ok(let root) = linked {
            HStack(spacing: 6) {
                Text("예전에 연결한 내 클론을 그대로 씁니다 · 리뷰 워크트리 \((WorktreeManager.poolPath(root: root, index: 1).path as NSString).abbreviatingWithTildeInPath)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("리뷰 워크트리 정리") { Task { await cleanPool(root: root) } }
                    .buttonStyle(.link)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var linkedIcon: (symbol: String, color: Color, help: String)? {
        switch linked {
        case .ok: return ("checkmark.circle.fill", .green, "git 저장소 확인")
        case .wrongRepository: return ("xmark.octagon.fill", .red, "다른 저장소입니다 — 전체 리뷰가 차단됩니다.")
        case .missing, .failed: return ("exclamationmark.triangle.fill", .orange, "폴더를 쓸 수 없습니다")
        case .unknown: return nil
        }
    }

    private var linkedNote: String? {
        switch linked {
        case .wrongRepository(let origin):
            return "다른 저장소입니다(origin: \(origin ?? "없음")) — 전체 리뷰가 차단됩니다. 연결을 끊으면 PR 스냅샷으로 리뷰합니다."
        case .missing:
            return "폴더가 없습니다 — 다음 전체 리뷰는 PR 스냅샷으로 합니다."
        case .failed(let message):
            return message
        case .ok, .unknown:
            return nil
        }
    }

    private var linkedNoteIsProblem: Bool {
        if case .wrongRepository = linked { return true }
        return false
    }

    // MARK: 줄 모양

    /// 설정 창은 "이름 칸 · 값 · 버튼", 팝오버는 같은 것을 작은 글씨로.
    private func line(key: String, value: String, muted: Bool = false, mono: Bool = false,
                      status: (symbol: String, color: Color, help: String)? = nil,
                      action: (title: String, run: () -> Void)? = nil) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Text(key)
                .font(compact ? .caption : .callout)
                .foregroundStyle(compact ? Color.secondary : Color.primary)
                .frame(minWidth: compact ? nil : 96, alignment: .leading)
                .fixedSize()
            Text(value)
                .font(mono ? (compact ? .caption.monospaced() : .callout.monospaced()) : (compact ? .caption : .callout))
                .foregroundStyle(muted ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            if let status {
                Image(systemName: status.symbol)
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .help(status.help)
            }
            Spacer(minLength: 4)
            if let action {
                if compact {
                    Button(action.title, action: action.run)
                        .buttonStyle(.link)
                        .font(.caption)
                        .fixedSize()
                } else {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: 동작

    private func ask(_ kind: PendingCloneAction.Kind) {
        problem = nil
        if model.cloneInUse(repo) {
            problem = "이 레포를 리뷰하는 중이라 끝난 뒤 할 수 있습니다."
            return
        }
        let action = PendingCloneAction(repo: repo, kind: kind, size: size)
        if compact {
            model.pendingCloneAction = action
        } else {
            confirming = action
        }
    }

    private func perform(_ action: PendingCloneAction) async {
        problem = await model.perform(action)
        await measure()
        await verify()
    }

    private func measure() async {
        guard snapshotExists, cloningFraction == nil else { size = nil; return }
        let repo = repo
        size = await Task.detached { ReviewClone.size(of: repo) }.value
    }

    private func verify() async {
        guard let path = linkedPath else { linked = .unknown; return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            linked = .missing
            return
        }
        let manager = WorktreeManager()
        do {
            let root = try await manager.repositoryRoot(of: path)
            if await manager.originMatches(root: root, repo: repo) {
                linked = .ok(root: root)
            } else {
                linked = .wrongRepository(origin: await manager.originURL(root: root))
            }
        } catch {
            linked = .failed(error.localizedDescription)
        }
    }

    private func cleanPool(root: String) async {
        let removed = await WorktreeManager().removePool(repoPath: root)
        model.banner = Banner(kind: .info,
                              message: removed > 0 ? "리뷰 워크트리 \(removed)개를 지웠습니다."
                                                   : "지울 리뷰 워크트리가 없습니다.")
    }
}

struct ReposSettings: View {
    @Environment(AppModel.self) private var model
    @State private var highlightedRepo: RepoID?

    var body: some View {
        Form {
            Section("리뷰할 레포") {
                // 고른 것과 안 고른 것을 한 목록에서 본다. 섹션을 둘로 나눠 두면 같은 레포가
                // 한 화면에 두 번 나오고, 고른 것을 다른 후보와 견줄 수 없다.
                // 전체 리뷰의 PR 스냅샷(크기·지우기)도 고른 레포 바로 아래에 보인다.
                RepoPickerStep(showsTitle: false, showsClonePaths: true, highlightedRepo: highlightedRepo)
                    .frame(minHeight: 360)
            }
            MemberNamesSection()
        }
        .formStyle(.grouped)
        .task { await model.loadRepoOptions() }
        // 레포 고르기는 누를 때마다 저장되지만, 이 탭에서 바꾼 다른 칸(팀원 이름 등)은 닫힐 때 한 번에 저장한다.
        .onDisappear { Task { await model.save() } }
        .onChange(of: model.settingsFocus, initial: true) { _, focus in
            reveal(focus)
        }
    }

    /// 바로 가기로 왔으면 그 레포 줄을 잠깐 강조한다. 한 번 보여 주면 목적지를
    /// 지운다 — 남겨 두면 다음에 이 탭을 열 때마다 멋대로 스크롤된다.
    private func reveal(_ focus: SettingsFocus?) {
        guard case .clonePath(let repo)? = focus else { return }
        model.settingsFocus = nil
        guard let repo else { return }
        Task { @MainActor in
            // 탭이 막 바뀐 참이면 줄이 아직 안 그려져 scrollTo 가 헛돈다. 한 박자 늦게 민다.
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation { highlightedRepo = repo }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if highlightedRepo == repo { highlightedRepo = nil } }
        }
    }
}

/// 팀원 로그인(riley-park-acme)은 길어서 목록에서 자리를 많이 먹는다.
/// 기본은 첫 하이픈 앞까지 자르고, 규칙이 안 맞는 사람은 여기서 직접 고친다.
struct MemberNamesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("팀원 이름 표시") {
            Toggle("이름 짧게 보이기", isOn: $model.settings.abbreviateMemberNames)
            Text("기본 규칙은 첫 하이픈 앞까지입니다. riley-park-acme → riley")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.knownMembers.isEmpty {
                Text("PR 을 한 번 불러오면 팀원 목록이 채워집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.knownMembers, id: \.self) { login in
                LabeledContent {
                    HStack(spacing: 6) {
                        // `TextField("제목", text:)` 은 macOS 폼에서 제목을 칸 **밖에** 라벨로
                        // 그린다. 그러면 기본 이름이 칸 오른쪽에 따로 떠서, 빈 칸이 무엇을
                        // 받는 자리인지 안 보인다(실측). prompt 로 줘야 칸 안에 들어간다.
                        TextField(text: nickname(login),
                                  prompt: Text(MemberNames.defaultShort(login))) {
                            Text("표시 이름")
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        Button {
                            model.settings.memberNicknames[login] = nil
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.settings.memberNicknames[login] == nil)
                        .help("기본 규칙으로 되돌리기")
                    }
                } label: {
                    Text(login).font(.callout.monospaced())
                }
            }
            .disabled(!model.settings.abbreviateMemberNames)
        }
    }

    private func nickname(_ login: String) -> Binding<String> {
        Binding(
            get: { model.settings.memberNicknames[login] ?? "" },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespaces)
                model.settings.memberNicknames[login] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}

struct ReviewSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("기본 리뷰 모델") {
                // AI 리뷰 탭의 두 칸과 같은 모양·같은 목록이다. 여기서 고르면 기본값이 바로 바뀐다.
                LabeledContent("모든 PR 에 쓸 모델") {
                    ReviewModelPills(modelID: model.settings.model,
                                     effort: model.settings.effort,
                                     scope: "여기서 고르면 모든 PR 의 기본값이 바뀝니다",
                                     chooseModel: { model.setDefaultReviewModel($0) },
                                     chooseEffort: { model.setDefaultReviewModel(effort: $0) })
                }
            }

            ReviewRulesSection(rules: $model.settings.reviewRules)

            // "전체 리뷰"(기본 모델을 같이 쓴다·PR 스냅샷 위치·동작 방식)와 "코멘트·게시"(상한·게시 방식) 설명 절은
            // 뺐다 — 고칠 칸 없이 설명만 있었다(2026-10-23 사용자 결정). PR 스냅샷은 '레포·팀 규칙' 탭의 각 레포 아래에 있다.
        }
        .formStyle(.grouped)
        .onDisappear { Task { await model.save() } }
    }
}

struct ExclusionSettings: View {
    @Environment(AppModel.self) private var model
    /// 규칙마다 레포 파일·최근 PR 몇 개를 거는지. 규칙 하나에 경로 수만 개를 훑어서, 칸에 글자를 칠 때마다 다시 세지
    /// 않게 재료나 규칙이 바뀔 때만 센다.
    @State private var ruleStats: [String: (repoFiles: Int, prCount: Int)] = [:]

    var body: some View {
        @Bindable var model = model
        Form {
            Section("크기 상한") {
                Stepper("'큼' 표시 기준 \(model.settings.autoSizeCapLines)줄",
                        value: $model.settings.autoSizeCapLines, in: 100...5000, step: 100)
                Stepper("리뷰 전 경고 \(model.settings.manualSizeWarnLines)줄",
                        value: $model.settings.manualSizeWarnLines, in: 200...10000, step: 100)
                Text("리뷰에서 빼는 파일(아래)을 뺀 뒤의 변경 줄 수로 판단합니다. 상한을 넘으면 '큼' 표시만 붙고, 리뷰는 그대로 돌릴 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 잠금 파일은 앱이 늘 뺀다(LockFiles). 그 밖의 규칙은 여기서 적는다 — 베타 6 에서 칸을 없앴다가(고르게 하면
            // 귀찮다) 레포 파일 기준 자동완성과 함께 되살렸다(사용자 결정, 2026-10-06). 처음 쓰는 사람은 비어 있다.
            Section("리뷰에서 빼는 파일") {
                Text(verbatim: "잠금 파일은 늘 뺍니다 — package-lock.json · yarn.lock · Package.resolved · Podfile.lock · go.sum · Cargo.lock · Gemfile.lock 등 \(LockFiles.names.count)종. 변경 파일 탭에서는 ‘제외됨’ 아래에서 볼 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ExclusionRuleField()
                ForEach(model.settings.excludedPathPatterns, id: \.self) { pattern in
                    HStack {
                        // 규칙에 `*` 가 들어 있다 — Text("…") 는 마크다운으로 읽어 별표를 지운다(실측).
                        Text(verbatim: pattern).font(.callout.monospaced())
                        Spacer()
                        if let stats = ruleStats[pattern] {
                            Text(ExclusionRuleField.countText(repoFiles: stats.repoFiles, prCount: stats.prCount))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            model.removeExclusions([pattern])
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("이 규칙 지우기 — 걸려 있던 파일이 다시 리뷰에 들어갑니다")
                    }
                }
            }

            Section("사용량 방어") {
                // 최근 5시간 사용량은 툴바 "상태" 메뉴에 있어 여기서는 뺐다(설명 문구도 — 2026-10-23 사용자 결정).
                Stepper("5시간 토큰 상한 \(model.settings.fiveHourTokenCap / 1000)k",
                        value: $model.settings.fiveHourTokenCap, in: 50_000...2_000_000, step: 50_000)
            }
        }
        .formStyle(.grouped)
        .onDisappear { Task { await model.save() } }
        .task { await model.loadExclusionCatalog() }
        .task(id: statsKey) { await measureRules() }
    }

    private var statsKey: String {
        "\(String(describing: model.exclusionCatalogState))|\(model.settings.excludedPathPatterns.joined(separator: "\u{1}"))"
    }

    private func measureRules() async {
        guard let catalog = model.exclusionCatalog else { ruleStats = [:]; return }
        let rules = model.settings.excludedPathPatterns
        ruleStats = await Task.detached {
            Dictionary(uniqueKeysWithValues: rules.map { ($0, catalog.stats(for: $0)) })
        }.value
    }
}

/// 제외 규칙 칸 — 치는 동안 레포 파일 기준 후보를 아래에 띄운다(ExclusionCatalog, 사용자 시안).
/// ↑↓ 로 고르고 Return 이면 고른 후보를, "추가" 버튼이면 친 글자 그대로를 더한다 — 후보에 없는 꼴(`Generated/*`)도
/// 적을 수 있게. 최근 PR 에서 자주 바뀐 것이 위로 온다(사용자 결정).
struct ExclusionRuleField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var selected = 0
    @State private var problem: String?

    private var suggestions: [ExclusionCatalog.Suggestion] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return model.exclusionCatalog?.suggestions(for: text) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 제목은 감추고 예시는 칸 안에 둔다 — 그룹 폼은 제목을 왼쪽 글자로 그리고 칸 폭을 0 으로 만든다(베타 4 실측).
            HStack(spacing: 8) {
                TextField("제외 규칙", text: $text,
                          prompt: Text(verbatim: "규칙 추가 — *.plist · Info.plist · *.xcassets/*"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onSubmit(addSelectedOrTyped)
                    .onChange(of: text) {
                        selected = 0
                        problem = nil
                    }
                    .onAppear { if let query = DebugLaunch.exclusionQuery { text = query } }
                Button("추가") { add(text) }
            }
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        row(suggestion, highlighted: index == selected)
                    }
                }
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            status
        }
    }

    private func row(_ suggestion: ExclusionCatalog.Suggestion, highlighted: Bool) -> some View {
        let already = model.settings.excludedPathPatterns.contains(suggestion.pattern)
        return HStack(spacing: 8) {
            Text(verbatim: suggestion.pattern)
                .font(.callout.monospaced())
            Text(suggestion.kind.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            if suggestion.isCode {
                Text("코드 파일 — 리뷰에서 빠집니다")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Text(already ? "추가됨" : Self.countText(repoFiles: suggestion.repoFiles, prCount: suggestion.prCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(highlighted ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { add(suggestion.pattern) }
    }

    @ViewBuilder
    private var status: some View {
        switch model.exclusionCatalogState {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("레포 파일 목록 받는 중 — 자동완성은 잠시 뒤에 뜹니다")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .loaded(_, let repos, let failed):
            Text("레포 파일 기준(보는 레포 \(repos)개의 기본 브랜치) · 최근 PR 에서 자주 바뀐 것부터 · ↑↓ 로 고르고 Return 으로 추가, 버튼은 친 그대로"
                 + (failed > 0 ? " · 레포 \(failed)개는 목록을 못 받았습니다" : ""))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            HStack(spacing: 6) {
                Text(message)
                Button("다시 받기") { Task { await model.loadExclusionCatalog(force: true) } }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.orange)
        case .idle:
            Text("보는 레포가 없어 자동완성이 없습니다 — 규칙은 그대로 적을 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// "PR 12건 · 파일 86개" — 최근 PR 에서 바뀐 적이 없으면 파일 수만.
    static func countText(repoFiles: Int, prCount: Int) -> String {
        let files = repoFiles > 0 ? "파일 \(repoFiles.formatted())개" : "지금 맞는 파일 없음"
        return prCount > 0 ? "PR \(prCount)건 · \(files)" : files
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        selected = min(max(selected + step, 0), suggestions.count - 1)
        return .handled
    }

    private func addSelectedOrTyped() {
        if suggestions.indices.contains(selected) {
            add(suggestions[selected].pattern)
        } else {
            add(text)
        }
    }

    private func add(_ raw: String) {
        let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else {
            problem = "규칙을 적어 주세요."
            return
        }
        guard model.addExclusion(rule) else {
            problem = "이미 있는 규칙입니다."
            return
        }
        text = ""
        selected = 0
        problem = nil
    }
}

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    private var authorizationText: String {
        switch model.notificationStatus {
        case .authorized: return "허용"
        case .provisional: return "임시 허용"
        case .denied: return "거부됨 — 시스템 설정에서 켜세요"
        case .notDetermined: return "아직 켜지 않음"
        default: return "확인 불가"
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("알림") {
                LabeledContent("시스템 권한") {
                    HStack(spacing: 6) {
                        Circle().fill(model.notificationsEnabled ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(authorizationText)
                    }
                }
                if !model.notificationsEnabled {
                    HStack {
                        if model.notificationStatus == .notDetermined {
                            Button("알림 켜기") { Task { await model.enableNotifications() } }
                        }
                        Button("시스템 설정 열기") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            // 스위치 이름은 알림에 뜨는 말(NotificationText)과 같게, 절 이름 앞에는 그 알림의 갈래 표시를 둔다
            // (사용자 결정, 2026-10-30). '머지 가능'·'충돌' 처럼 누구 PR 인지 안 보이는 것은 "내 PR" 절에 모은다.
            Section("✨ AI 리뷰 알림") {
                Toggle("AI 리뷰 완료", isOn: $model.settings.notifyOnReviewDone)
                Toggle("AI 리뷰 실패 · 사용 한도 도달", isOn: $model.settings.notifyOnFailure)
            }

            Section("📥 리뷰할 PR 알림") {
                Toggle("새 PR", isOn: $model.settings.prChangeNotifications.newPR)
                Toggle("나에게 리뷰 요청이 온 것만", isOn: $model.settings.prChangeNotifications.newPROnlyWhenReviewRequested)
                    .disabled(!model.settings.prChangeNotifications.newPR)
                    .padding(.leading, 18)
                Toggle("리뷰어 지정", isOn: $model.settings.prChangeNotifications.reviewRequested)
                    .help("이미 열린 PR 에 나를 리뷰어로 넣었을 때. PR 을 올리면서 넣으면 '새 PR' 로 옵니다.")
                Toggle("재리뷰 요청", isOn: $model.settings.prChangeNotifications.reReviewRequested)
                Toggle("리뷰한 PR 새 커밋", isOn: $model.settings.prChangeNotifications.newCommitsOnReviewed)
            }

            Section("📥 내 PR 알림") {
                Toggle("내 PR 새 코멘트", isOn: $model.settings.prChangeNotifications.commentsOnMyPR)
                Toggle("머지 가능", isOn: $model.settings.prChangeNotifications.approvalsReached)
                Toggle("충돌", isOn: $model.settings.prChangeNotifications.conflict)
                Toggle("CI 실패", isOn: $model.settings.prChangeNotifications.checksFailed)
                Toggle("머지 완료", isOn: $model.settings.prChangeNotifications.merged)
                Text("\(model.settings.pollSeconds)초마다 확인합니다. 한 번에 4건 이상 바뀌면 'PR 소식 N건' 하나로 묶어 알립니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task { await model.refreshNotificationStatus() }
            Section("폴링") {
                Stepper("\(model.settings.pollSeconds)초마다 갱신",
                        value: $model.settings.pollSeconds, in: 30...600, step: 30)
            }
            // "기존 알림 스크립트"(pr-review-notify 끄기 명령) 절은 뺐다 — 한 맥에서만 맞는 안내였다(2026-10-23 사용자 결정).
            Section("데이터") {
                LabeledContent("초안·설정 위치") {
                    Text(AppPaths.support.path).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Button("폴더 열기") { NSWorkspace.shared.open(AppPaths.support) }
            }
        }
        .formStyle(.grouped)
        .onDisappear { Task { await model.save() } }
    }
}

/// 설정을 파일로 건네고 받는 탭. 무엇을 담고 어떻게 합치는지는 `SettingsTransfer`(Core)가 정한다.
///
/// "파일에 담기지 않는 것"·"되돌리기" 절은 뺐다 — 내보내기 창이 항목마다 담기는 것을 보이고, 가져온 직후 결과 창에
/// "되돌리기" 가 있다(2026-10-23 사용자 결정). 가져오기 직전 설정 파일은 그대로 남긴다(`AppPaths.settingsBeforeImportFile`).
struct SharingSettings: View {
    var body: some View {
        Form {
            Section("내보내기") {
                Text("내 설정을 파일(.json)로 저장해 팀원에게 건넵니다. 저장하기 전에 담을 항목을 고르고, 항목마다 무엇이 담기는지 봅니다.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsExportButton()
            }
            Section("가져오기") {
                Text("팀원에게 받은 \(AppInfo.displayName) 설정 파일을 엽니다. 바로 바뀌지 않고, 지금 값과 견줘 보며 가져올 항목을 고르는 창이 먼저 뜹니다. 목록(레포·라벨·사람·제외 경로)은 합치기만 하고 내 것을 지우지 않습니다.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsImportButton()
            }
        }
        .formStyle(.grouped)
    }
}
