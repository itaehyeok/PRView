import SwiftUI
import PRayerCore

/// 내 PR 우클릭 → "슬랙 리뷰 요청 글 만들기". 고른 PR(여러 개도)로 글을 만들어 보여 주고, "보내기" 를 누른 그 글만 보낸다.
///
/// 한 화면이다(2026-10-20 사용자가 시안 B 를 골랐다 — 단계형은 처음 쓸 때 세 번을 넘겨야 보낼 글이 보였다).
/// 창이 뜨면 저절로 연동부터 확인하고(전에 연결된 적이 있으면 묻지 않고 바로), 연결되면 받는 곳 · 미리보기 · 보내기가
/// 한 화면에 있다. 받는 곳은 단추 아래로 겹쳐 펼쳐지는 드롭다운(내가 속한 채널, 고른 것이 맨 위) — 창 크기는 그대로다.
/// 미리보기는 누르면 그 자리에서 이번 글만 고친다. 글 형식은 고정이다(`SlackTemplate`) — "포맷 바꾸기" 화면은 뺐다
/// (2026-10-23 사용자 결정, 사람마다 글이 달라지지 않게). 나에게 보내기는 보내기 옆 단추.
struct SlackRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: SlackRequestDraft

    @State private var connection: SlackConnectionState = .checking
    @State private var didStart = false
    @State private var showsDestinations = false
    /// 이번 글만 손으로 고친 것. nil 이면 정해진 형식대로 만든 글을 보낸다.
    @State private var editedMessage: String?
    @State private var isEditing = false
    @State private var sendState = SlackSendState()
    /// "나에게 테스트로 보내기" — 보내기와 따로 상태를 둔다(결과를 메시지 아래에 보인다).
    @State private var testState = SlackSendState()

    private var slack: SlackSettings { model.settings.slack }
    /// 시험 창(DEBUG `PRAYER_DEBUG_SLACK_FAIL`)은 PR 없이 열 수 있다 — 그때는 내 PR 이나 가짜 PR 로 글을 보인다.
    private var items: [SlackPRItem] { model.slackPreviewItems(draft.prs) }
    private var generated: String { SlackTemplate.message(items: items) }
    private var finalMessage: String { editedMessage ?? generated }
    private var isEdited: Bool { editedMessage != nil && editedMessage != generated }
    private var people: [SlackPerson] { [slack.me].compactMap { $0 } }
    private var isBusy: Bool { sendState.isSending || testState.isSending }
    private var messageIsSendable: Bool { !finalMessage.isEmpty && finalMessage.count <= SlackTemplate.maxLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                content
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 드롭다운이 창 안에 다 들어오게 몸통을 이만큼은 둔다 — 드롭다운은 창을 키우지 않고 위에 겹친다.
            .frame(minHeight: 330, maxHeight: 560)
            Divider()
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: 620)
        .overlayPreferenceValue(DestinationButtonAnchor.self) { anchor in
            GeometryReader { proxy in
                if showsDestinations, connection.isConnected, let anchor {
                    destinationDropdown(below: proxy[anchor])
                }
            }
        }
        // 보내는 동안 닫으면 결과를 볼 곳이 없다. 다 보낸 뒤에 닫는다.
        .interactiveDismissDisabled(isBusy)
        .onAppear(perform: start)
        // claude.ai 에서 Slack 을 연결하고 돌아오면 저절로 다시 확인한다 — "다시 확인" 을 찾아 누르지 않아도 되게.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if connection.isFailed { check() }
        }
    }

    private func start() {
        guard !didStart else { return }
        didStart = true
        connection = .initial(saved: slack.me, simulated: draft.simulatedFailure)
        if let stage = DebugLaunch.slackStage {
            showsDestinations = stage == "destination"
            isEditing = stage == "edit"
            if stage == "connect" { connection = .checking }
        }
        if connection == .checking {
            check()
        } else {
            openDestinationsIfUnset()
        }
    }

    private func check() {
        connection = .checking
        Task {
            connection = await model.checkSlackConnection()
            openDestinationsIfUnset()
        }
    }

    /// 받는 곳을 아직 안 골랐으면 처음부터 펼쳐 둔다 — 고를 것이 무엇인지 보여야 한다.
    private func openDestinationsIfUnset() {
        if connection.isConnected, slack.destination == nil || slack.destination?.kind == .me { showsDestinations = true }
    }

    // MARK: - 머리

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "paperplane")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                // 메뉴 이름과 같게 — 이 창은 글을 만들고, 보내기는 아래 단추가 한다.
                Text("슬랙 리뷰 요청 글 만들기")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if case .connected(let me) = connection {
                SlackConnectedLabel(me: me)
                    .font(.caption)
            }
        }
    }

    private var subtitle: String {
        switch draft.prs.count {
        case 0: return "연동 화면 시험"
        case 1: return "#\(draft.prs[0].number) \(draft.prs[0].title)"
        default: return "PR \(draft.prs.count)건 — " + draft.prs.map { "#\($0.number)" }.joined(separator: " · ")
        }
    }

    // MARK: - 몸통

    @ViewBuilder
    private var content: some View {
        switch connection {
        case .checking:
            VStack(alignment: .leading, spacing: 10) {
                SlackConnectionStatusView(state: connection, retry: check)
                Text("받는 곳 · 미리보기는 확인이 끝나면 나옵니다")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            SlackConnectionStatusView(state: connection, retry: check)
        case .connected:
            compose
        }
    }

    /// 받는 곳으로 고를 수 있는 것 — 나에게(DM)는 받는 곳이 아니다(보내기 옆 "나에게 테스트로 보내기").
    private var chosenChannel: SlackDestination? {
        guard let destination = slack.destination, destination.kind != .me else { return nil }
        return destination
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("받는 곳")
                    .foregroundStyle(.secondary)
                Button {
                    showsDestinations.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if let channel = chosenChannel {
                            Image(systemName: channel.kind == .privateChannel ? "lock" : "number")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(channel.name)
                        } else {
                            Text("받는 곳 고르기").foregroundStyle(.secondary)
                        }
                        Image(systemName: showsDestinations ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(showsDestinations ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                                      lineWidth: showsDestinations ? 1 : 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .anchorPreference(key: DestinationButtonAnchor.self, value: .bounds) { $0 }
                Spacer(minLength: 0)
            }
            previousRequestsNote
            SlackMessageBubble(message: finalMessage, people: people, sender: slack.me,
                               text: Binding(get: { editedMessage ?? generated }, set: { editedMessage = $0 }),
                               isEditing: $isEditing, isEdited: isEdited)
                .disabled(isBusy)
                .onChange(of: isEditing) { _, editing in
                    // 고치다 그대로 두었으면 고친 글이 아니다.
                    if !editing, editedMessage == generated { editedMessage = nil }
                }
            HStack(spacing: 10) {
                if isEdited {
                    Button("원래 글로 되돌리기") {
                        editedMessage = nil
                        isEditing = false
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 8)
                Text("\(finalMessage.count)자")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(finalMessage.count > SlackTemplate.maxLength ? .red : .secondary)
            }
            .font(.caption)
            .disabled(isBusy)
            SlackSendStatus(state: testState)
            if case .failed = sendState.phase {
                SlackSendStatus(state: sendState)
            }
            Text("슬랙이 커넥터로 보낸 글 끝에 ‘Claude 를 사용하여 보냄’ 을 붙입니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 받는 곳 드롭다운 — 단추 바로 아래에 겹쳐 뜬다(창은 그대로). 바깥을 누르면 닫힌다.
    private func destinationDropdown(below button: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { showsDestinations = false }
            SlackChannelList(onPick: { showsDestinations = false }, maxListHeight: 200)
                .padding(8)
                .frame(width: 310)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .offset(x: button.minX, y: button.maxY + 4)
        }
    }

    /// 전에 요청한 PR 이 섞여 있으면 언제·어디에 보냈는지 — 같은 요청을 모르고 또 보내지 않게.
    @ViewBuilder
    private var previousRequestsNote: some View {
        let previous = model.previousSlackRequests(draft.prs)
        if !previous.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(previous, id: \.pr.id) { item in
                    Text("#\(item.pr.number) · \(SlackAgo.text(item.entry.sentAt)) \(item.entry.destination.label) 에 이미 요청했습니다")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    // MARK: - 바닥

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch connection {
            case .checking:
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("보내기") {}
                    .disabled(true)
            case .failed:
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("다시 확인", action: check)
                    .keyboardShortcut(.defaultAction)
            case .connected:
                composeFooter
            }
        }
    }

    @ViewBuilder
    private var composeFooter: some View {
        switch sendState.phase {
        case .sending:
            SlackSendStatus(state: sendState)
            Spacer()
            Button("멈추기") { sendState.cancel() }
                .help("이미 보내졌을 수 있습니다 — 멈춘 뒤 슬랙에서 확인하세요.")
        case .sent:
            SlackSendStatus(state: sendState)
            Spacer()
            Button("닫기") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .idle, .failed:
            // 드롭다운이 열려 있으면 Esc 는 드롭다운만 닫는다.
            Button("취소") {
                if showsDestinations { showsDestinations = false } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            // 보내기 바로 왼쪽(사용자가 시안 A 를 골랐다). 받는 곳을 안 골라도 누를 수 있다.
            if let me = slack.me {
                Button {
                    isEditing = false
                    testState.send(finalMessage, to: .me(me), model: model)
                } label: {
                    Label("나에게 테스트로 보내기", systemImage: "person")
                }
                .disabled(isBusy || !messageIsSendable)
                .help("지금 글을 내 DM 으로 보냅니다 — 슬랙에서 어떻게 보이는지 먼저 확인하세요.")
            }
            Button("보내기", action: send)
                .keyboardShortcut(.defaultAction)
                .disabled(chosenChannel == nil || !messageIsSendable || isBusy)
        }
    }

    private func send() {
        guard let destination = chosenChannel else {
            showsDestinations = true
            return
        }
        isEditing = false
        showsDestinations = false
        let prs = draft.prs
        sendState.send(finalMessage, to: destination, model: model) { link in
            model.recordSlackRequest(prs, destination: destination, link: link)
        }
    }
}

/// 받는 곳 단추의 자리 — 드롭다운을 그 바로 아래, 창 맨 위 층에 겹쳐 그리려고 넘긴다.
private struct DestinationButtonAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// 미리보기 — 슬랙에서 보일 모양에 가깝게 내 이름·머리글자를 붙인다. 누르면 그 자리에서 이번 글만 고친다
/// ("이번 글만 고치기" 단추는 뺐다 — 사용자, 2026-10-20). 고친 글은 이번에 보낼 때만 쓴다.
struct SlackMessageBubble: View {
    let message: String
    let people: [SlackPerson]
    let sender: SlackPerson?
    @Binding var text: String
    @Binding var isEditing: Bool
    var isEdited = false
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sender?.name ?? "나").fontWeight(.semibold)
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(isEditing || isEdited ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    Spacer(minLength: 0)
                    if !isEditing, isHovering {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isEditing {
                    // 마크다운 원문이 아니라 미리보기와 같은 모양으로 고친다(링크 주소는 숨김).
                    SlackMessageEditor(markdown: $text, onEndEditing: { isEditing = false })
                        .frame(minHeight: 96, maxHeight: 200)
                } else {
                    SlackMessagePreview(message: message, people: people, framed: false)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isEditing ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(isHovering ? 0.45 : 0.25)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if !isEditing { isEditing = true } }
        .help(isEditing ? "" : "누르면 이번 글만 고칩니다")
    }

    private var stateLabel: String {
        if isEditing { return "고치는 중 — 이번 글에만 씁니다" }
        if isEdited { return "고친 글" }
        return "미리보기 · 누르면 고치기"
    }

    /// "Alex Kim" → "AL". 첫 낱말의 앞 두 글자.
    private var initials: String {
        let first = sender?.name.split(separator: " ").first.map(String.init) ?? "나"
        return String(first.prefix(2)).uppercased()
    }
}

/// 설정 › 슬랙 — 연동 · 보낼 곳을 한 화면에. 글 형식은 고정이라 고칠 칸이 없다(`SlackTemplate`).
struct SlackSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var connection: SlackConnectionState = .checking
    @State private var didStart = false

    var body: some View {
        Form {
            Section {
                switch connection {
                case .connected(let me):
                    HStack {
                        SlackConnectedLabel(me: me)
                        Spacer()
                        Button("다시 확인", action: check)
                    }
                case .checking, .failed:
                    SlackConnectionStatusView(state: connection, retry: check)
                    if connection.isFailed {
                        HStack {
                            Spacer()
                            Button("다시 확인", action: check)
                        }
                    }
                }
            } header: {
                Text("연동")
            }
            // "연동 실패 화면 시험" 메뉴(개발 확인용)와 보낼 곳 아래 사용법 문구는 뺐다(2026-10-23 사용자 결정).
            // 실패 화면은 DEBUG 의 `PRAYER_DEBUG_SLACK_FAIL` 로 띄운다.
            Section("보낼 곳") {
                SlackChannelList(maxListHeight: 300)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !didStart else { return }
            didStart = true
            connection = .initial(saved: model.settings.slack.me, simulated: nil)
            if connection == .checking { check() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if connection.isFailed { check() }
        }
    }

    private func check() {
        connection = .checking
        Task { connection = await model.checkSlackConnection() }
    }
}
