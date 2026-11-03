import SwiftUI
import PRayerCore

/// 변경이 큰 PR 을 리뷰하기 **전에** 띄우는 확인 창 — 전체 변경 줄 수, 확인 창 기준, 코드까지 보낼 파일.
///
/// 예전에는 두 창이었다. 한 파일이 1,000줄 넘게 바뀌면 "빼고 리뷰할까요?"(모두/빼고 둘 중 하나), 이어서 변경이 기준보다
/// 많으면 "그대로 진행할까요?". 하나로 합치고 파일마다 고르게 했다(사용자 결정 — 예전엔 고르게 하면 귀찮다고 했지만,
/// 기본이 전부 체크라 그대로 Enter 면 예전처럼 다 보낸다).
///
/// - 체크를 푼 파일은 내용 없이 파일명·줄 수만 간다(`PromptBuilder` 의 files_without_content). 전부 풀면 목록만으로 리뷰한다.
/// - 파일은 바뀐 줄 많은 순으로 5개만 보이고 "5개 더 보기" 로 늘린다 — 큰 파일은 대개 위 몇 개다.
/// - 확인 창 기준은 슬라이더나 숫자로 고치고, 리뷰를 시작할 때 저장한다(취소하면 남기지 않는다).
/// - 이유는 전체 변경 줄 수 한 줄만, 5시간 상한은 적지 않는다(사용자 결정 — 한도에 걸려 멈추면 그때 알림이 간다).
/// - "전부 리뷰" 는 체크를 풀어도 늘 남는다 — 고르다 마음이 바뀌어도 한 번에 무시하고 다 보낼 수 있게.
struct ReviewSizeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PendingReviewSize

    /// 체크를 푼 파일 경로.
    @State private var skipped: Set<String> = []
    @State private var shown = Self.page
    @State private var warnLines = 0
    /// 숫자칸의 글. 치는 동안에도 슬라이더가 따라오게 글로 받아 범위 안이면 바로 기준에 넣는다 — 값(`format:`)으로 받으면
    /// Return 이나 칸을 떠날 때만 들어가서, 치고 바로 리뷰 버튼을 누르면 고친 기준이 빠진다.
    @State private var warnText = ""
    @FocusState private var warnFieldFocused: Bool
    @State private var prepared = false

    private static let page = 5
    private static let warnRange = 200...10_000
    /// 한 줄 높이 어림. 목록 높이를 줄 수에 맞추려고 쓴다(ScrollView 는 받은 높이를 다 차지한다).
    private static let rowHeight: CGFloat = 42
    private static let listMaxHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("변경이 큰 PR")
                .font(.headline)
            reasonBox
            totals
            Text("체크를 풀면 코드 없이 파일명과 줄 수만 보냅니다")
                .font(.caption)
                .foregroundStyle(.secondary)
            fileList
            if shown < request.files.count {
                moreFiles
            }
            buttons
                .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 470)
        .background(InitialFocusSink())
        .onAppear(perform: prepare)
        .onExitCommand(perform: cancel)
        // 슬라이더로 바꾸면 숫자칸도 따라간다. 치는 중에는 덮지 않고, 칸을 떠나면 100 단위로 맞춘 값으로 정리한다.
        .onChange(of: warnLines) { _, value in
            if !warnFieldFocused { warnText = value.formatted() }
        }
        .onChange(of: warnFieldFocused) { _, focused in
            if !focused { warnText = warnLines.formatted() }
        }
    }

    // MARK: - 이유와 기준

    private var reasonBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 창이 뜬 까닭은 한 줄로만 — 한 파일이 1,000줄 넘어 떴을 때도 같다(사용자 결정).
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.orange)
                Text("전체 변경 \(request.totalLines.formatted())줄입니다.")
            }
            HStack(spacing: 8) {
                // step 을 주면 macOS 슬라이더가 눈금을 100개 가까이 그린다. 값만 100 단위로 맞춘다.
                Slider(value: Binding(get: { Double(warnLines) },
                                      set: { warnLines = Self.rounded(Int($0)) }),
                       in: Double(Self.warnRange.lowerBound)...Double(Self.warnRange.upperBound))
                TextField("", text: Binding(get: { warnText }, set: typeWarnLines))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 68)
                    .focused($warnFieldFocused)
                    .onSubmit { warnFieldFocused = false }
                Text("줄 넘으면 확인 창 띄우기")
                    .fixedSize()
            }
            .padding(.leading, 22)
            if prepared, warnLines != model.settings.manualSizeWarnLines {
                Text("다음부터 \(warnLines.formatted())줄 넘을 때만 확인 창을 띄웁니다 (리뷰를 시작하면 저장)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 숫자칸에 친 글. 범위 안의 수가 되는 순간 기준에 넣는다(3,000 을 치는 중 300 에서 한 번 움직인다).
    private func typeWarnLines(_ text: String) {
        warnText = text
        if let value = Int(text.filter(\.isNumber)), Self.warnRange.contains(value) {
            warnLines = Self.rounded(value)
        }
    }

    private static func rounded(_ value: Int) -> Int {
        let clamped = min(max(value, warnRange.lowerBound), warnRange.upperBound)
        return Int((Double(clamped) / 100).rounded()) * 100
    }

    // MARK: - 보낼 양

    private var totals: some View {
        HStack(spacing: 4) {
            Text("보낼 변경")
            Text("\(sentLines.formatted())줄").fontWeight(.medium)
            if removedLines > 0 {
                Text("(−\(removedLines.formatted()))").foregroundStyle(.green)
            }
            Text("·").foregroundStyle(.secondary)
            Text("예상")
            Text(tokens(PromptBuilder.estimatedTokens(changedLines: sentLines))).fontWeight(.medium)
            Text("토큰")
            if savedTokens > 0 {
                Text("(−\(savedTokens)k)").foregroundStyle(.green)
            }
        }
        .font(.callout.monospacedDigit())
    }

    private var sentLines: Int {
        request.files.reduce(0) { $0 + (skipped.contains($1.path) ? 0 : $1.changedLines) }
    }

    private var removedLines: Int { request.totalLines - sentLines }

    /// 줄인 토큰(천 단위). 위 표기처럼 각각 1,000 으로 나눈 몫의 차라 두 숫자를 빼 보면 맞는다.
    private var savedTokens: Int {
        PromptBuilder.estimatedTokens(changedLines: request.totalLines) / 1000
            - PromptBuilder.estimatedTokens(changedLines: sentLines) / 1000
    }

    /// AI 리뷰 탭의 "예상 Nk 토큰" 과 같은 표기(1,000 으로 나눈 몫) — 반올림하면 같은 줄 수인데 창과 뒤 화면의 숫자가
    /// 달라 보였다(실측: 19k 와 20k).
    private func tokens(_ value: Int) -> String {
        value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
    }

    // MARK: - 파일 목록

    private enum Mark { case on, off, mixed }

    private var allOff: Bool { !request.files.isEmpty && skipped.count == request.files.count }

    private var fileList: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                checkbox(skipped.isEmpty ? .on : allOff ? .off : .mixed)
                Text("파일 \(request.files.count.formatted())개 · 많이 바뀐 순")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("바뀐 줄")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))
            .contentShape(Rectangle())
            // 하나라도 체크돼 있으면 전부 풀고, 다 풀려 있으면 전부 체크한다 — 이 칸은 대개 "전체 해제" 로 쓴다.
            .onTapGesture(perform: toggleAll)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(request.files.prefix(shown), id: \.path) { file in
                        row(file)
                        Divider()
                    }
                }
            }
            .frame(height: min(CGFloat(min(shown, request.files.count)) * Self.rowHeight, Self.listMaxHeight))
            .overlay {
                if allOff {
                    listOnlyNotice
                        // 안내가 클릭을 막지 않는다 — 파일 하나만 다시 체크해도 되고, 그러면 안내가 사라진다.
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func row(_ file: DiffFile) -> some View {
        let on = !skipped.contains(file.path)
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        return HStack(alignment: .top, spacing: 8) {
            checkbox(on ? .on : .off)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout.weight(on ? .medium : .regular))
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(file.changedLines.formatted())줄")
                    .font(.callout.monospacedDigit().weight(on ? .medium : .regular))
                Text("+\(file.additions.formatted()) −\(file.deletions.formatted())")
                    .font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .opacity(on ? 1 : 0.6)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { toggle(file.path) }
        .help(file.path)
        // 예전 창의 "다음부터 이 파일들은 묻지 않고 빼기" 를 줄마다 옮겼다. 제외 경로에 들어가 다음부터는 이 창에도 안 나온다.
        .contextMenu {
            Button("이 파일은 앞으로 늘 빼기") { excludeForever(file) }
        }
    }

    private func checkbox(_ mark: Mark) -> some View {
        Image(systemName: mark == .on ? "checkmark.square.fill" : mark == .mixed ? "minus.square.fill" : "square")
            .font(.body)
            .foregroundStyle(mark == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .frame(width: 16)
    }

    private var listOnlyNotice: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.7))
            VStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                // 아래 버튼("목록만으로 리뷰")과 같은 말로 — 카드와 버튼이 같은 동작이라는 게 바로 읽히게.
                Text("코드 없이 목록만으로 리뷰합니다")
                    .font(.callout.weight(.medium))
                Text("PR 제목·본문, 기존 코멘트, 파일명과 줄 수만 보냅니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 0.5))
            .padding(12)
        }
    }

    private var moreFiles: some View {
        let hidden = request.files.dropFirst(shown)
        let hiddenSkipped = hidden.filter { skipped.contains($0.path) }.count
        return VStack(spacing: 4) {
            if !hidden.isEmpty {
                Button("\(min(Self.page, hidden.count))개 더 보기") { shown += Self.page }
                    .controlSize(.small)
                Text(hiddenSkipped == 0
                     ? "나머지 \(hidden.count.formatted())개(\(hidden.reduce(0) { $0 + $1.changedLines }.formatted())줄)는 그대로 보냅니다"
                     : hiddenSkipped == hidden.count
                     ? "나머지 \(hidden.count.formatted())개도 이름과 줄 수만"
                     : "나머지 \(hidden.count.formatted())개 중 \(hiddenSkipped.formatted())개는 이름과 줄 수만")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 버튼

    private var buttons: some View {
        HStack {
            Spacer()
            Button("취소", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            if skipped.isEmpty {
                Button("전부 리뷰") { start(skipping: []) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("전부 리뷰") { start(skipping: []) }
                Button(allOff ? "목록만으로 리뷰" : "\(skipped.count)개 빼고 리뷰") { start(skipping: skipped) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - 동작

    private func prepare() {
        guard !prepared else { return }
        warnLines = model.settings.manualSizeWarnLines
        warnText = warnLines.formatted()
        let paths = Set(request.files.map(\.path))
        skipped = (model.reviewSizeSkips[request.id] ?? []).intersection(paths)
        // 지난번에 푼 파일이 뒤쪽에 있으면 거기까지 펼쳐 둔다 — 안 보이는 곳에서 빠져 있으면 모른다.
        if let last = request.files.lastIndex(where: { skipped.contains($0.path) }) {
            shown = max(Self.page, (last / Self.page + 1) * Self.page)
        }
        prepared = true
    }

    private func toggle(_ path: String) {
        if skipped.contains(path) {
            skipped.remove(path)
        } else {
            skipped.insert(path)
        }
    }

    private func toggleAll() {
        skipped = allOff ? [] : Set(request.files.map(\.path))
    }

    private func excludeForever(_ file: DiffFile) {
        model.addExclusion(ExclusionPattern.file(file.path))
        skipped.insert(file.path)
        model.banner = Banner(kind: .info,
                              message: "\((file.path as NSString).lastPathComponent) 를 대상 제외에 넣었습니다 — 설정 › 대상 제외에서 되돌릴 수 있습니다")
    }

    private func start(skipping paths: Set<String>) {
        model.answerPendingReviewSize(skipped: paths, warnLines: warnLines)
        dismiss()
    }

    private func cancel() {
        model.cancelPendingReviewSize()
        dismiss()
    }
}

/// 시트가 열리면 AppKit 이 첫 글칸(확인 창 기준 숫자칸)에 커서를 넣는다. 그러면 Enter 가 기본 버튼("전부 리뷰") 대신 숫자칸에
/// 먹힌다. 보이지 않는 이 뷰가 대신 첫 응답자가 된다 — 받지 않은 Enter 는 창으로 넘어가 기본 버튼이 받는다.
/// SwiftUI `FocusState` 를 false 로 두는 것으로는 안 됐다(열린 직후엔 아직 false 라 바뀌는 것이 없고, 그 뒤에 AppKit 이 넣는다).
private struct InitialFocusSink: NSViewRepresentable {
    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    func makeNSView(context: Context) -> SinkView { SinkView() }
    func updateNSView(_ nsView: SinkView, context: Context) {}
}
