import AppKit
import PRayerCore
import SwiftUI

/// 엔진 하나의 연결 상태 — 온보딩 카드와 설정 › 연결이 같이 쓴다.
///
/// 둘 중 하나만 있어도 된다. 그래서 쓰지 않는 쪽이 "설치 안 됨" 이어도 빨갛게 그리지 않는다 —
/// 다른 쪽이 준비돼 있으면 회색 "연결 안 됨" 이고, 둘 다 안 됐을 때만 경고색이다.
struct EngineStatusLine: View {
    @Environment(AppModel.self) private var model
    let engine: ReviewEngineKind

    var body: some View {
        let status = model.engineStatus(engine)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol(status))
                    .foregroundStyle(color(status))
                Text(headline(status))
                    .foregroundStyle(color(status))
            }
            if let detail = detail(status) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var otherReady: Bool {
        model.readyEngines.contains { $0 != engine }
    }

    private func headline(_ status: EngineStatus?) -> String {
        guard let status else { return "확인 중" }
        if status.isReady { return "사용 가능" }
        if status.isInstalled { return "로그인 필요" }
        return "연결 안 됨"
    }

    private func detail(_ status: EngineStatus?) -> String? {
        guard let status else { return nil }
        if status.isReady {
            return [status.version.map { "v\($0)" }, status.accountLabel].compactMap { $0 }.joined(separator: " · ")
        }
        if status.isInstalled {
            return "\(status.version.map { "v\($0) · " } ?? "")터미널에서 로그인하면 바로 씁니다."
        }
        return "이 맥에서 \(engine.productName) CLI 를 찾지 못했습니다."
    }

    private func symbol(_ status: EngineStatus?) -> String {
        guard let status else { return "circle.dotted" }
        if status.isReady { return "checkmark.circle.fill" }
        return status.isInstalled ? "exclamationmark.circle.fill" : "circle"
    }

    private func color(_ status: EngineStatus?) -> Color {
        guard let status else { return .secondary }
        if status.isReady { return .green }
        // 다른 쪽으로 리뷰할 수 있으면 이쪽은 선택 사항이다 — 경고색을 쓰지 않는다.
        return otherReady ? .secondary : .orange
    }
}

/// 설치·로그인·다시 확인 버튼 줄. 경로를 고를 수 있게 한다(npm·nvm 은 숨은 폴더에 깔린다).
struct EngineActions: View {
    @Environment(AppModel.self) private var model
    let engine: ReviewEngineKind
    @State private var isChecking = false

    var body: some View {
        let status = model.engineStatus(engine)
        HStack {
            // 로그인돼 있어도 로그인 버튼을 둔다 — 다른 계정으로 바꿀 때 쓴다(예전 Claude 칸과 같다).
            if status?.isInstalled == false {
                Button("터미널에서 설치") { model.openEngineInstall(engine) }
            } else {
                Button("터미널에서 로그인") { model.openEngineLogin(engine) }
            }
            Button("다시 확인") {
                isChecking = true
                Task {
                    switch engine {
                    case .claude: await model.checkClaude()
                    case .codex: await model.checkCodex(rediscover: true)
                    }
                    await model.adoptReadyEngineIfNeeded()
                    isChecking = false
                }
            }
            .disabled(isChecking)
            Button("경로 변경…") { choosePath() }
            if isChecking { ProgressView().controlSize(.small) }
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let current = engine == .claude ? model.settings.claudePath : model.settings.codexPath
        panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        // npm(nvm)·예전 로컬 설치는 숨은 폴더에 있다. 안 보이면 못 고른다.
        panel.showsHiddenFiles = true
        // `~/.local/bin/claude`·npm 의 `codex` 는 버전 폴더를 가리키는 링크다. 링크를 풀어 저장하면 CLI 를 올리는 순간 경로가 사라진다.
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch engine {
        case .claude: model.settings.claudePath = url.path
        case .codex: model.settings.codexPath = url.path
        }
        Task {
            await model.save()
            switch engine {
            case .claude: await model.checkClaude()
            case .codex: await model.checkCodex()
            }
            await model.adoptReadyEngineIfNeeded()
        }
    }
}

/// Codex CLI 를 못 찾았을 때 할 일. Claude 의 `ClaudeInstallHint` 와 같은 자리에 쓴다.
struct CodexInstallHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex CLI 를 깔고 ChatGPT 계정으로 로그인하면 됩니다. \"터미널에서 설치\" 가 아래 명령을 실행하고 이어서 로그인합니다.")
            CopyableCommand(command: CodexRunner.installCommand)
            Text("Homebrew 를 쓰면 `brew install codex` 도 됩니다. 이미 깔려 있다면 \"경로 변경…\" 으로 그 파일을 고르세요 — 위치는 터미널에서 `type -a codex` 로 볼 수 있습니다.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 설정 › 연결의 엔진 칸 하나. 하나만 붙인 사람도 여기서 다른 쪽을 붙인다.
struct EngineConnectionSection: View {
    @Environment(AppModel.self) private var model
    let engine: ReviewEngineKind

    var body: some View {
        @Bindable var model = model
        let status = model.engineStatus(engine)
        Section {
            LabeledContent("상태") {
                EngineStatusLine(engine: engine)
            }
            switch engine {
            case .claude:
                TextField("실행 파일 경로", text: $model.settings.claudePath)
                    .onSubmit { Task { await model.save(); await model.checkClaude() } }
            case .codex:
                TextField("실행 파일 경로", text: $model.settings.codexPath)
                    .onSubmit { Task { await model.save(); await model.checkCodex() } }
            }
            EngineActions(engine: engine)
            if let status, !status.isInstalled {
                switch engine {
                case .claude: ClaudeInstallHint()
                case .codex: CodexInstallHint()
                }
            }
            if engine == .claude, let status, status.isInstalled, !status.versionVerified {
                Text("검증한 버전(\(AppInfo.verifiedClaudeVersion))과 달라 플래그 동작이 바뀔 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(engine.productName)
        } footer: {
            if engine == .codex, status?.isReady != true {
                Text("붙이면 리뷰 모델에서 Codex 를 고를 수 있습니다. PR 내용은 ChatGPT 계정을 통해 OpenAI 로 갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
