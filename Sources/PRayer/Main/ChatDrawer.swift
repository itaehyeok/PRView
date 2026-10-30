import AppKit
import PRayerCore
import SwiftUI

/// 상세 화면 맨 아래 대화창 — 이 PR 을 리뷰한 Claude(·Codex) 대화를 앱 안에서 이어 간다.
///
/// 예전엔 AI 리뷰 탭 왼쪽 열 맨 아래에 `claude --resume <ID>` 를 복사해 터미널에 붙여 넣게 했다. 이제 탭과 상관없이
/// 맨 아래 한 줄에서 바로 묻는다(2026-10-30 사용자 결정 — 항목별 "묻기"·인용 칩 없이 대화창 하나). 리뷰를 기억하는 대화라
/// "필수로 단 두 번 요청 건" 처럼 말로 짚어도 어느 항목인지 안다. 터미널로 이어 가는 길은 머리 줄의 터미널 메뉴로 남겼다.
///
/// 평소엔 입력 한 줄만 있고, 물으면 위로 열린다. 열린 높이는 경계의 손잡이를 끌어 바꾸고 앱이 기억한다. 머리 줄의 최대화는
/// 탭 내용을 가리고 대화만 보인다(PRDetailView 가 `isOpen`·`maximizedKey` 로 탭 내용을 뺀다).
struct ChatDrawer: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// 탭 내용과 대화창이 나눠 쓰는 높이(PRDetailView 가 잰다). 손잡이를 끌어 올릴 수 있는 끝을 여기서 셈한다 —
    /// 예전엔 640pt 로 박아 둬 큰 창에서도 그 이상 못 올렸다. 아직 모르면(0) 그 값을 끝으로 쓴다.
    var availableHeight: CGFloat = 0

    static let expandedKey = "chatDrawerExpanded"
    static let maximizedKey = "chatDrawerMaximized"

    @AppStorage(ChatDrawer.expandedKey) private var expanded = false
    @AppStorage(ChatDrawer.maximizedKey) private var maximized = false
    @AppStorage("chatDrawerHeight") private var height: Double = ChatDrawer.defaultHeight
    /// 끌기 시작할 때의 높이. 끄는 동안의 이동량을 여기에 더한다.
    @State private var dragStartHeight: Double?
    /// 대화 파일이 남아 있는지. 모르는 동안(nil)은 있다고 보고 그린다 — 거의 늘 있어서, 없다고 그렸다가 바꾸면 깜빡인다.
    @State private var transcriptAvailable: Bool?
    @State private var copied: CopiedItem?
    @FocusState private var inputFocused: Bool

    private enum CopiedItem { case command, sessionID }

    private static let minimumHeight: Double = 140
    private static let fallbackMaximumHeight: Double = 640
    private static let defaultHeight: Double = 280
    /// 펼쳤을 때 대화 목록 말고 대화창이 차지하는 높이(손잡이·머리 줄·입력 줄 어림). 끌 수 있는 끝을 셀 때 뺀다.
    private static let chromeHeight: Double = 110
    /// 손잡이로 끌어 올려도 탭 내용은 이만큼 남긴다. 다 가리고 싶으면 최대화를 쓴다 — 끌어서 탭 내용이 0 이 되면
    /// 그 안의 고정 높이 줄들이 넘쳐 대화창 위를 덮는다.
    private static let minimumContentHeight: Double = 120

    /// 끌어 올릴 수 있는 가장 큰 대화 목록 높이.
    private var maximumHeight: Double {
        guard availableHeight > 0 else { return Self.fallbackMaximumHeight }
        return max(Self.minimumHeight, Double(availableHeight) - Self.chromeHeight - Self.minimumContentHeight)
    }

    /// 대화창이 펼쳐져 있는가 — 아래 `drawer(record:)` 와 같은 조건이다. 최대화여도 펼쳐져 있지 않으면 PRDetailView 는
    /// 탭 내용을 그대로 둔다(대화가 없는 PR 로 옮겼을 때 빈 화면이 되지 않게).
    static func isOpen(model: AppModel, pr: PullRequestInfo, expanded: Bool) -> Bool {
        guard expanded, let record = model.record(for: pr) else { return false }
        let busy = model.chatSessionID(for: record).map(model.isChatting) ?? false
        return busy || !(model.chat(for: record)?.messages.isEmpty ?? true)
    }

    var body: some View {
        if let record = model.record(for: pr) {
            drawer(record: record)
                .task(id: record.sessionID) { await checkTranscript(record) }
        }
    }

    private func drawer(record: ReviewRecord) -> some View {
        let sessionID = model.chatSessionID(for: record)
        let chat = model.chat(for: record)
        let busy = sessionID.map(model.isChatting) ?? false
        let hasConversation = !(chat?.messages.isEmpty ?? true) || busy
        let open = Self.isOpen(model: model, pr: pr, expanded: expanded)
        let fills = open && maximized
        return VStack(spacing: 0) {
            if open {
                resizeHandle
                header(record: record, sessionID: sessionID)
                Divider()
                messages(chat: chat, sessionID: sessionID, engine: record.engineKind)
                    .frame(height: fills ? nil : min(height, maximumHeight))
                    .frame(maxHeight: fills ? .infinity : nil)
                Divider()
            } else {
                Divider()
            }
            inputRow(record: record, sessionID: sessionID, busy: busy, hasConversation: hasConversation, open: open)
        }
        .frame(maxHeight: fills ? .infinity : nil)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.18), value: open)
        .animation(.easeOut(duration: 0.18), value: fills)
    }

    // MARK: - 머리 줄

    private func header(record: ReviewRecord, sessionID: String?) -> some View {
        HStack(spacing: 8) {
            Label("\(record.engineKind.displayName) 와 대화", systemImage: "bubble.left.and.text.bubble.right")
                .font(model.fonts.ui(delta: 0, weight: .semibold))
            Text("· #\(record.number) 리뷰 대화 이어서")
                .font(model.fonts.ui(delta: -1))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let sessionID {
                terminalMenu(record: record, sessionID: sessionID)
            }
            Button {
                maximized.toggle()
            } label: {
                Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(maximized ? "원래 높이로" : "최대화 — 탭 내용을 가리고 대화만 봅니다")
            Button {
                expanded = false
                // 접었다 다시 열 때 갑자기 화면을 다 덮지 않게 최대화는 푼다.
                maximized = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("대화창 접기")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// 경계를 위아래로 끌어 높이를 바꾼다. 대화창은 아래에 붙어 있어 위로 끌수록 커진다.
    /// 선만 있으면 끌 수 있는 줄 몰라서(사용자 피드백) 가운데에 손잡이 모양을 얹는다 — 손잡이는 눌림을 받지 않고
    /// 아래 선의 잡는 자리(9pt)가 받는다. 최대화 중에 끌면 최대화를 풀고 지금 보이는 높이에서 이어 끈다.
    private var resizeHandle: some View {
        ResizeDivider(help: "드래그로 대화창 높이 조절 · 더블클릭하면 기본 높이",
                      horizontal: true,
                      onDrag: { distance in
                          let start = dragStartHeight ?? (maximized ? maximumHeight : min(height, maximumHeight))
                          dragStartHeight = start
                          if maximized { maximized = false }
                          height = min(maximumHeight, max(Self.minimumHeight, start - distance))
                      },
                      onDragEnd: { dragStartHeight = nil },
                      onReset: {
                          maximized = false
                          height = Self.defaultHeight
                      })
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 40, height: 5)
                    .allowsHitTesting(false)
            }
            .padding(.bottom, 8)
    }

    /// 터미널·Paseo 같은 다른 곳에서 이어 가는 길. 여기서 나눈 말도 같은 대화에 붙어 있어 그대로 이어진다.
    private func terminalMenu(record: ReviewRecord, sessionID: String) -> some View {
        Menu {
            if let command = ClaudeSession.resumeCommand(sessionID: sessionID, engine: record.engineKind) {
                Button("터미널 명령 복사 — \(command)") { copy(command, as: .command) }
            }
            Button("세션 ID 만 복사 (Paseo 처럼 세션을 불러오는 앱용)") { copy(sessionID, as: .sessionID) }
        } label: {
            Image(systemName: copied == nil ? "terminal" : "checkmark")
                .foregroundStyle(copied == nil ? Color.secondary : Color.green)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("터미널에서 이어 가기 — 명령을 복사합니다. 이 맥에서만 열립니다.")
    }

    // MARK: - 대화

    private func messages(chat: ReviewChat?, sessionID: String?, engine: ReviewEngineKind) -> some View {
        let reply = sessionID.flatMap { model.chatReplies[$0] }
        let list = chat?.messages ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(list) { message in
                        ChatMessageRow(message: message, engine: engine)
                            .id(message.id)
                    }
                    if let reply {
                        ChatReplyRow(text: reply, engine: engine)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: list.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: reply) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private static let bottomID = "chat-bottom"

    // MARK: - 입력 줄

    @ViewBuilder
    private func inputRow(record: ReviewRecord, sessionID: String?, busy: Bool,
                          hasConversation: Bool, open: Bool) -> some View {
        if let sessionID, transcriptAvailable != false {
            let draft = Binding(get: { model.chatDrafts[sessionID] ?? "" },
                                set: { model.chatDrafts[sessionID] = $0 })
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                TextField(open ? "더 물어보기…"
                               : "\(record.engineKind.displayName) 에게 묻기 — 이 PR 을 리뷰한 대화를 이어 갑니다",
                          text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(model.fonts.ui(delta: 0))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { send(record: record, sessionID: sessionID) }
                if !open {
                    Text(modelLabel(record))
                        .font(model.fonts.ui(delta: -2))
                        .foregroundStyle(.tertiary)
                    terminalMenu(record: record, sessionID: sessionID)
                }
                if busy {
                    Button {
                        model.stopChat(sessionID: sessionID)
                    } label: {
                        Label("멈춤", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                    .help("답을 그만 받습니다. 받은 데까지는 남습니다.")
                } else {
                    Button {
                        send(record: record, sessionID: sessionID)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(draft.wrappedValue.isBlank ? Color.secondary : Color.accentColor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("보내기 (Return · 줄 바꿈은 ⌥Return)")
                }
                if !open, hasConversation {
                    Button {
                        expanded = true
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help("대화창 펼치기")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(inputFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.15), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text(unavailableReason(record: record, sessionID: sessionID))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(model.fonts.ui(delta: -1))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func send(record: ReviewRecord, sessionID: String) {
        guard !model.isChatting(sessionID) else { return }
        let text = model.chatDrafts[sessionID] ?? ""
        guard !text.isBlank else { return }
        model.chatDrafts[sessionID] = nil
        expanded = true
        model.sendChat(text, record: record)
    }

    private func modelLabel(_ record: ReviewRecord) -> String {
        switch record.engineKind {
        case .claude: return ClaudeModels.displayName(forModelID: record.model)
        case .codex: return CodexModels.displayName(forModelID: record.model)
        }
    }

    private func unavailableReason(record: ReviewRecord, sessionID: String?) -> String {
        let name = record.engineKind.displayName
        if sessionID == nil {
            return "이 리뷰는 대화를 남기기 전 버전에서 만들어 \(name) 와 이어서 대화할 수 없습니다. 다시 리뷰하면 이어 갈 수 있습니다."
        }
        return "\(name) 가 오래된 대화를 정리해 이 리뷰는 더는 이어서 대화할 수 없습니다. 다시 리뷰하면 이어 갈 수 있습니다."
    }

    private func checkTranscript(_ record: ReviewRecord) async {
        transcriptAvailable = nil
        guard let sessionID = model.chatSessionID(for: record) else { return }
        // README 캡처용 데모 모드는 가짜 세션이라 대화 파일이 없다. 평소 모양으로 보이게 있는 것으로 친다.
        if DemoMode.isOn {
            transcriptAvailable = true
            return
        }
        // 사용자의 ~/.claude/projects 는 폴더가 수백 개일 수 있다. 화면을 붙잡지 않게 밖에서 훑는다.
        let engine = record.engineKind
        transcriptAvailable = await Task.detached(priority: .utility) {
            ClaudeSession.transcriptExists(sessionID: sessionID, engine: engine)
        }.value
    }

    /// 눌렀다는 표시를 2초만 남긴다. 창이나 배너를 띄우지 않는다 — 복사는 되돌릴 일이 없는 동작이다.
    private func copy(_ text: String, as item: CopiedItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = item
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == item { copied = nil }
        }
    }
}

/// 말 한 마디. 내가 한 말은 오른쪽 말풍선, 답은 왼쪽에 마크다운으로(리뷰 코멘트와 같은 글꼴), 실패는 까닭만 흐리게.
private struct ChatMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let engine: ReviewEngineKind

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(model.fonts.ui(delta: 0))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant where message.failed:
            Label(message.text, systemImage: "exclamationmark.circle")
                .font(model.fonts.ui(delta: -1))
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
        case .assistant:
            AssistantRow(engine: engine) {
                MarkdownText(text: message.text)
                    .textSelection(.enabled)
            }
        }
    }
}

/// 답을 받는 중인 자리. 글이 오기 전에는 "답하는 중…"(Codex 는 다 쓴 뒤 한 번에 온다).
private struct ChatReplyRow: View {
    @Environment(AppModel.self) private var model
    let text: String
    let engine: ReviewEngineKind

    var body: some View {
        AssistantRow(engine: engine) {
            if text.isBlank {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("답하는 중…")
                        .font(model.fonts.ui(delta: -1))
                        .foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(text: text)
            }
        }
    }
}

private struct AssistantRow<Content: View>: View {
    let engine: ReviewEngineKind
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .help(engine.displayName)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
