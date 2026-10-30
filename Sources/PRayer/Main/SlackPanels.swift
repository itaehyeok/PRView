import SwiftUI
import PRayerCore

// 슬랙 리뷰 요청의 판 — 보낼 곳 · 미리보기 · 보내기 상태(연동은 SlackConnection). 글 형식은 고정이다(SlackTemplate).
// 요청 창(SlackRequestSheet)은 보낼 곳을 단추 아래 드롭다운으로 펼치고, 설정 › 슬랙 탭은 한 화면에 늘어놓는다.
// 슬랙 일은 하나하나 Claude 가 커넥터로 하므로 10초쯤 걸린다 — 기다리는 동안 무엇을 하는지 글로 말한다.

/// 2. 보낼 곳 — 내가 속한 채널에서 고른다. 고른 채널이 체크와 함께 맨 위, 치는 대로 그 자리에서 거른다.
///
/// 슬랙 전체 찾기와 나에게(DM)는 뺐다(사용자, 2026-10-20) — 리뷰 요청은 내가 속한 채널로 가고, 나에게 보내기는
/// 보내기 옆 "나에게 테스트로 보내기" 단추가 맡는다. 요청 창은 받는 곳 단추 아래 드롭다운에, 설정 탭은 그대로 늘어놓는다.
struct SlackChannelList: View {
    @Environment(AppModel.self) private var model
    /// 고른 뒤 할 일 — 드롭다운은 닫힌다.
    var onPick: (() -> Void)? = nil
    /// 목록 높이 상한. 드롭다운은 창을 넘지 않게 낮게 잡는다.
    var maxListHeight: CGFloat = 260
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    private var slack: SlackSettings { model.settings.slack }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("채널 검색"))
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onSubmit(pickOnlyMatch)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            list
            footer
        }
        .task {
            // 처음 열 때 내 채널을 받아 둔다. 다음부터는 저장해 둔 목록을 바로 쓴다.
            if slack.myChannels.isEmpty, slack.me != nil { model.loadMySlackChannels() }
            if let debugQuery = DebugLaunch.slackQuery, query.isEmpty { query = debugQuery }
            filterFocused = true
        }
    }

    /// 고른 채널을 맨 위에, 그 아래 내 채널(같은 채널은 한 번만). 나에게(DM)는 넣지 않는다.
    private var candidates: [SlackDestination] {
        var seen = Set<String>()
        var list: [SlackDestination] = []
        if let current = slack.destination, current.kind != .me { list.append(current) }
        list += slack.myChannels
        return list.filter { $0.kind != .me && seen.insert($0.id).inserted && $0.matches(query) }
    }

    @ViewBuilder
    private var list: some View {
        let shown = candidates
        if shown.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, destination in
                        row(destination)
                        // 고른 채널과 나머지 사이에 줄 하나 — 체크된 것이 맨 위라는 것이 보이게.
                        if index == 0, destination.id == slack.destination?.id, shown.count > 1 {
                            Divider().padding(.vertical, 3)
                        }
                    }
                }
            }
            .frame(maxHeight: maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyText: String {
        if model.slackChannelsLoading != nil { return "내 채널을 받는 중… 처음 한 번 1~2분" }
        if !query.isEmpty { return "‘\(query)’ 이 든 채널이 없습니다." }
        return "아직 받은 채널이 없습니다."
    }

    /// 받는 중이면 무엇을 기다리는지, 다 받았으면 몇 개·언제와 다시 받기.
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            if let loading = model.slackChannelsLoading {
                ProgressView().controlSize(.small)
                Text(loading.postedDone ? "들어가 있는 채널도 받는 중… (1분쯤)" : "내 채널을 받는 중… (처음 한 번 1~2분)")
                    .foregroundStyle(.secondary)
            } else {
                Text("내 채널 \(slack.myChannels.count)" + (slack.myChannelsFetchedAt.map { " · \(SlackAgo.text($0)) 받음" } ?? ""))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("다시 받기") { model.loadMySlackChannels() }
                    .buttonStyle(.link)
                    .help("내가 글을 쓴 채널과 들어가 있는 채널을 다시 받습니다(1~2분). 새 채널에 들어갔으면 누르세요.")
            }
        }
        .font(.caption)
        .padding(.horizontal, 4)
        if let channelError = model.slackChannelsError {
            SlackErrorView(error: channelError)
        }
    }

    private func row(_ destination: SlackDestination) -> some View {
        let isChosen = slack.destination?.id == destination.id
        return Button {
            model.updateSlack { $0.choose(destination) }
            onPick?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: destination.kind == .privateChannel ? "lock" : "number")
                    .font(.caption)
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                    .frame(width: 14)
                Text(destination.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(isChosen ? Color.accentColor : .primary)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(isChosen ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// 엔터 — 하나만 걸리면 그것을 고른다.
    private func pickOnlyMatch() {
        let shown = candidates
        guard shown.count == 1, let only = shown.first else { return }
        model.updateSlack { $0.choose(only) }
        onPick?()
    }
}

extension View {
    /// 판 안의 입력 칸. 설정 탭(Form)은 칸 제목을 왼쪽 라벨로 빼고 글을 오른쪽에 붙인다 — 보내기 창과 같게 둔다.
    func slackField() -> some View {
        textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.leading)
    }
}

/// 슬랙에서 보일 모양에 가깝게 — 링크는 글자만, 멘션은 이름으로. 보낼 글은 바꾸지 않는다.
struct SlackMessagePreview: View {
    let message: String
    let people: [SlackPerson]
    /// 테두리 상자째 그릴지. 말풍선(`SlackMessageBubble`) 안에서는 글만.
    var framed = true

    var body: some View {
        let text = SlackTemplate.preview(message, people: people)
        let rendered = (try? AttributedString(markdown: text,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        if framed {
            Text(rendered)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        } else {
            Text(rendered)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 커넥터 오류 + 할 일. 커넥터가 없으면 claude.ai 설정으로 가는 단추를 단다.
struct SlackErrorView: View {
    let error: SlackConnectorError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let guidance = error.guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if error == .connectorMissing || error == .needsAuth {
                Button("claude.ai 커넥터 설정 열기") { NSWorkspace.shared.open(SlackConnectorError.connectorSettingsURL) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .font(.callout)
    }

    static func wrap(_ error: Error) -> SlackConnectorError {
        (error as? SlackConnectorError) ?? .unreadable(error.localizedDescription)
    }
}

/// 보내기 한 번의 상태. 보내기 창과 "나에게 테스트로 보내기" 가 같이 쓴다.
@MainActor
@Observable
final class SlackSendState {
    enum Phase {
        case idle
        case sending(SlackDestination)
        case sent(SlackDestination)
        case failed(SlackConnectorError)
    }

    var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }

    func send(_ message: String, to destination: SlackDestination, model: AppModel,
              onSent: ((String?) -> Void)? = nil) {
        guard !DemoMode.isOn else { return }
        guard !isSending else { return }
        phase = .sending(destination)
        task = Task {
            do {
                let link = try await model.slackConnector.send(message, to: destination,
                                                               unfurlLinks: SlackTemplate.unfurlLinks)
                phase = .sent(destination)
                onSent?(link)
            } catch {
                let failure = SlackErrorView.wrap(error)
                phase = .failed(failure)
                // 문제를 물으면 먼저 problems.json 을 본다 — 슬랙 실패도 거기 남긴다.
                if failure != .cancelled {
                    ProblemLog.shared.record(.other, detail: "슬랙 보내기 실패(\(destination.label)): \(failure.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard !isSending else { return }
        phase = .idle
    }
}

/// 보내기 상태 한 줄.
struct SlackSendStatus: View {
    let state: SlackSendState
    var compact = false

    var body: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .sending(let destination):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(compact ? "보내는 중…" : "\(destination.label) 에 보내는 중 — Claude 가 Slack 커넥터로 보냅니다(10초쯤)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .sent(let destination):
            // "슬랙에서 보기" 링크는 뺐다(사용자, 2026-10-23) — 보낸 곳만 알리면 된다. 주소는 보낸 기록(onSent)에만 남긴다.
            Label("\(destination.label) 에 보냈습니다", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let error):
            if compact {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(error.guidance ?? error.localizedDescription)
            } else {
                SlackErrorView(error: error)
            }
        }
    }
}
