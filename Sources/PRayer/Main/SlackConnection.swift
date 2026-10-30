import SwiftUI
import PRayerCore

/// Slack 연동 상태 — 요청 창과 설정 › 슬랙 탭이 같이 쓴다.
///
/// 연동은 claude.ai 에서 한다(토큰도 거기 있다). 앱이 하는 일은 셋이다: 창이 뜨면 저절로 확인하기,
/// 안 되면 어디서 무엇을 누르면 되는지 말하고 그 화면을 열어 주기, 돌아오면 저절로 다시 확인하기.
enum SlackConnectionState: Equatable {
    case checking
    case connected(SlackPerson)
    /// `simulated` 는 연동 실패 화면 시험(DEBUG `PRAYER_DEBUG_SLACK_FAIL`)으로 띄운 것 — 실제로는 연결돼 있을 수 있다.
    case failed(SlackConnectorError, simulated: Bool)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 처음 상태 — 시험이면 그 실패, 전에 연결된 적이 있으면 바로 연결됨(다시 묻지 않는다), 아니면 확인부터.
    static func initial(saved me: SlackPerson?, simulated: SlackConnectorError?) -> SlackConnectionState {
        if let simulated { return .failed(simulated, simulated: true) }
        if let me { return .connected(me) }
        return .checking
    }
}

extension AppModel {
    /// 연동 확인 한 번 — 성공하면 나를 저장한다. 로그인이 끊겼으면 툴바의 엔진 상태도 다시 본다.
    func checkSlackConnection() async -> SlackConnectionState {
        guard !DemoMode.isOn else { return .failed(.unreadable("데모 모드"), simulated: true) }
        do {
            let me = try await slackConnector.checkConnection()
            updateSlack { $0.me = me }
            return .connected(me)
        } catch {
            let failure = SlackErrorView.wrap(error)
            if failure == .loginRequired { Task { await checkEngines() } }
            ProblemLog.shared.record(.other, detail: "슬랙 연동 확인 실패: \(failure.localizedDescription)")
            return .failed(failure, simulated: false)
        }
    }
}

/// 확인 중 · 실패 안내. 연결됨은 부르는 쪽이 그린다(요청 창은 머리 오른쪽, 설정은 한 줄).
struct SlackConnectionStatusView: View {
    @Environment(AppModel.self) private var model
    let state: SlackConnectionState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .checking:
            box(tint: .secondary, background: Color.secondary.opacity(0.08)) {
                ProgressView().controlSize(.small)
            } content: {
                Text("Claude 와 Slack 연동을 확인하는 중…")
                Text("Claude Code 에 연결된 Slack 커넥터로 내 이름으로 보냅니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .connected:
            EmptyView()
        case .failed(let error, let simulated):
            VStack(alignment: .leading, spacing: 8) {
                failure(error)
                if simulated {
                    Text("시험 화면입니다 — 다시 확인을 누르면 실제로 확인합니다.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func failure(_ error: SlackConnectorError) -> some View {
        switch error.failureKind {
        case .connector:
            VStack(alignment: .leading, spacing: 10) {
                box(tint: .orange, background: Color.orange.opacity(0.12)) {
                    Image(systemName: "powerplug").font(.title3)
                } content: {
                    Text(error == .needsAuth ? "Slack 연결이 만료됐어요" : "Slack 연동이 필요해요")
                        .fontWeight(.semibold)
                    Text(error == .needsAuth
                         ? "Claude Code 가 쓰는 Slack 커넥터를 claude.ai 에서 다시 연결해 주세요."
                         : "Claude Code 에 커넥터로 Slack 이 연동되어 있어야 합니다. claude.ai 에서 한 번만 연결하면 돼요.")
                        .font(.callout)
                    if case .connectorFailed = error {
                        Text(error.localizedDescription).font(.caption)
                    }
                }
                step(1) {
                    Text("claude.ai 커넥터 설정을 엽니다")
                    Spacer(minLength: 8)
                    Button("claude.ai 열기") { NSWorkspace.shared.open(SlackConnectorError.connectorSettingsURL) }
                }
                step(2) {
                    Text("Slack 옆 ") + Text(error == .needsAuth ? "다시 연결" : "연결").bold()
                        + Text(" → 슬랙 화면에서 ") + Text("허용").bold()
                }
                step(3) {
                    Text("PRView 로 돌아오면 자동으로 다시 확인합니다")
                }
                Text("회사에서 Claude 의 Slack 커넥터를 막아 두었으면 연결할 수 없어요 — 관리자에게 문의하세요.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        case .claudeLogin:
            box(tint: .red, background: Color.red.opacity(0.1)) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title3)
            } content: {
                Text("Claude Code 에 로그인돼 있지 않아요").fontWeight(.semibold)
                Text("Slack 연동은 Claude Code 로그인 위에서 돌아갑니다. 로그인한 뒤 다시 확인하세요.")
                    .font(.callout)
            } trailing: {
                Button("로그인") { model.openEngineLogin() }
            }
        case .claudeMissing:
            box(tint: .red, background: Color.red.opacity(0.1)) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title3)
            } content: {
                Text("Claude Code 를 찾을 수 없어요").fontWeight(.semibold)
                Text("Slack 연동은 이 맥의 Claude Code(터미널용 CLI)로 돌아갑니다.")
                    .font(.callout)
            } trailing: {
                Button("설치 안내") { model.openEngineInstall() }
            }
        case .other:
            box(tint: .red, background: Color.red.opacity(0.1)) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title3)
            } content: {
                Text(error == .timedOut ? "응답이 없어 멈췄어요" : "Slack 연동을 확인하지 못했어요")
                    .fontWeight(.semibold)
                Text(error == .timedOut ? "잠시 뒤 다시 확인해 주세요." : error.localizedDescription)
                    .font(.callout)
            } trailing: {
                Button("다시 확인", action: retry)
            }
        }
    }

    private func box<Icon: View, Content: View>(tint: Color, background: Color,
                                                @ViewBuilder icon: () -> Icon,
                                                @ViewBuilder content: () -> Content) -> some View {
        box(tint: tint, background: background, icon: icon, content: content) { EmptyView() }
    }

    private func box<Icon: View, Content: View, Trailing: View>(tint: Color, background: Color,
                                                               @ViewBuilder icon: () -> Icon,
                                                               @ViewBuilder content: () -> Content,
                                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            icon().foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) { content() }
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5))
            content()
        }
        .font(.callout)
        .padding(.leading, 4)
    }
}

/// 연결됨 한 줄 — "연결됨 — Alex Kim".
struct SlackConnectedLabel: View {
    let me: SlackPerson

    var body: some View {
        Label("연결됨 — \(me.name)", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}
