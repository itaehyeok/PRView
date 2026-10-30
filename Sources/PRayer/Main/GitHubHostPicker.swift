import SwiftUI
import PRayerCore

/// 어느 GitHub 에 물어볼지 고르는 줄.
///
/// 회사 계정(Enterprise)과 개인 계정(github.com)을 한 맥에서 같이 쓰는 일이 흔한데,
/// `gh` 는 호스트별로 따로 로그인한다. 어느 쪽인지 앱이 정하지 않으면 `gh` 의 기본 호스트로
/// 조용히 새어, 회사 레포를 골랐는데 "찾을 수 없습니다" 만 뜬다.
///
/// 로그인된 호스트가 하나뿐이면 고를 게 없으므로 Picker 를 내지 않는다.
/// 로그인 버튼은 여기가 아니라 섹션 맨 아래(`GitHubLoginControls`)에 있다 — Claude 쪽과
/// 자리를 맞춰야 "다시 확인" 옆에서 같이 찾을 수 있다.
struct GitHubHostPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.githubHosts.count > 1 {
            Picker("GitHub 호스트", selection: $model.settings.githubHost) {
                ForEach(hosts) { host in
                    Text(host.label).tag(host.name)
                }
            }
            .onChange(of: model.settings.githubHost) { _, _ in
                Task {
                    await model.save()
                    await model.checkGitHub()
                    // 호스트가 바뀌면 앞 호스트에서 받아 둔 레포 목록은 남의 것이다.
                    await model.loadRepoOptions()
                }
            }
        } else {
            LabeledContent("GitHub 호스트") {
                Text(model.settings.githubHost).font(.callout.monospaced())
            }
        }
    }

    /// 설정에 적힌 호스트가 `gh auth status` 에 없을 수도 있다(로그아웃했거나 직접 적었거나).
    /// Picker 에서 빠지면 선택이 조용히 첫 항목으로 튀므로 그 호스트도 넣어 준다.
    private var hosts: [GitHubHost] {
        var list = model.githubHosts
        if !list.contains(where: { $0.name == model.settings.githubHost }) {
            list.insert(GitHubHost(name: model.settings.githubHost), at: 0)
        }
        return list
    }
}

/// GitHub 섹션 맨 아래 줄 — `[다시 확인] [터미널에서 로그인]`.
/// Claude 섹션과 같은 자리·같은 모양이어야 두 번 찾지 않는다.
struct GitHubLoginControls: View {
    @Environment(AppModel.self) private var model
    @State private var isChecking = false
    @State private var isAdding = false
    @State private var newHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("다시 확인") {
                    isChecking = true
                    Task {
                        await model.checkGitHub()
                        isChecking = false
                    }
                }
                .disabled(isChecking)
                Button("터미널에서 로그인") { isAdding.toggle() }
                if isChecking { ProgressView().controlSize(.small) }
            }
            if isAdding {
                HStack {
                    TextField(text: $newHost, prompt: Text("github.com 또는 github.회사.com")) {
                        Text("호스트")
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { login() }
                    Button("열기") { login() }
                        .disabled(!isValidHost)
                    Button("취소") { isAdding = false; newHost = "" }
                        .buttonStyle(.link)
                }
                Text("터미널이 열리고 `gh auth login --hostname …` 이 실행됩니다. 끝나면 이 창에서 다시 확인하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isValidHost: Bool {
        let trimmed = newHost.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(".") && !trimmed.contains(" ") && !trimmed.contains("/")
    }

    private func login() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard isValidHost else { return }
        if let problem = EngineLogin.openGitHub(ghPath: model.settings.ghPath, host: host) {
            model.banner = Banner(kind: .error, message: problem)
            return
        }
        // 로그인이 끝나면 이 호스트로 붙는 게 사용자의 의도다. 터미널이 끝나는 걸 기다릴 수는
        // 없으므로, 앱으로 돌아왔을 때 checkGitHub 가 실제 로그인 여부를 확인한다.
        model.settings.githubHost = host
        newHost = ""
        isAdding = false
        Task {
            await model.save()
            await model.checkGitHub()
        }
    }
}
