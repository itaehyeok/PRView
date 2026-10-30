import SwiftUI
import AppKit
import PRayerCore

/// 코멘트 속 코드 표기를 diff 로 잇는 데 필요한 것. 개요 탭의 대화 줄이 환경 값으로 내려 주고,
/// 있으면 MarkdownText 가 diff 에서 찾은 인라인 코드를 누를 수 있게 만든다.
struct CodeLinkContext {
    let pr: PullRequestInfo
    /// `path#RIGHT#line` 꼴의 diff 위치로 간다.
    let onJump: (String) -> Void
}

private struct CodeLinkContextKey: EnvironmentKey {
    static var defaultValue: CodeLinkContext? { nil }
}

extension EnvironmentValues {
    var codeLinks: CodeLinkContext? {
        get { self[CodeLinkContextKey.self] }
        set { self[CodeLinkContextKey.self] = newValue }
    }
}

/// 코드 위치로 가는 자리. 마우스를 잠시 올려 두면 그 자리 코드가 뜨고, 누르면 diff 의 그 줄로 간다.
/// 모양은 부르는 쪽이 정한다 — 올렸는지(`isHovering`)를 받아 그린다.
struct CodeLink<Label: View>: View {
    /// 올리자마자 띄우면 글을 읽으며 지나가기만 해도 창이 튀어나와 거슬렸다(사용자 요청, 2026-10-28).
    static var showDelay: Duration { .seconds(0.5) }

    let reference: CodeReference
    let context: CodeLinkContext
    @ViewBuilder let label: (_ isHovering: Bool) -> Label
    @State private var isHovering = false
    @State private var isShowingCode = false
    @State private var pendingShow: Task<Void, Never>?

    var body: some View {
        label(isHovering)
            .contentShape(Rectangle())
            .onTapGesture {
                pendingShow?.cancel()
                isShowingCode = false
                context.onJump("\(reference.path)#RIGHT#\(reference.line ?? 1)")
            }
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                pendingShow?.cancel()
                if inside {
                    pendingShow = Task {
                        try? await Task.sleep(for: Self.showDelay)
                        if !Task.isCancelled { isShowingCode = true }
                    }
                } else {
                    isShowingCode = false
                }
            }
            // 누르면 탭이 바뀌어 올린 채로 사라진다 — 그때는 나갔다는 알림이 없어 손 모양 커서가 남는다.
            .onDisappear {
                pendingShow?.cancel()
                if isHovering { NSCursor.pop() }
            }
            .popover(isPresented: $isShowingCode, arrowEdge: .bottom) {
                CodeSnippetPreview(reference: reference, pr: context.pr)
                    // 팝오버는 띄운 자리의 환경을 물려받는다. 제목 속 코드면 제목 글꼴(2em·semibold)이 따라와, 색칠 규칙이 없는
                    // 파일(.md 등)의 줄이 그 글꼴로 그려져 창 폭만큼 커졌다. 기본 글꼴·줄 간격으로 되돌린다.
                    .font(.body)
                    .lineSpacing(0)
                    .foregroundStyle(.primary)
                    .padding(10)
                    // 긴 줄은 자른다 — 끝까지 보려면 눌러서 diff 로 간다.
                    .frame(minWidth: 320, maxWidth: 560)
            }
            .task {
                if DebugLaunch.hoverCode == reference.label {
                    try? await Task.sleep(for: .seconds(1))
                    isShowingCode = true
                }
            }
            .accessibilityAddTraits(.isLink)
    }
}

/// diff 에서 그 줄 앞뒤 3줄. 가리킨 줄은 주황으로 칠한다.
struct CodeSnippetPreview: View {
    @Environment(AppModel.self) private var model
    let reference: CodeReference
    let pr: PullRequestInfo

    var body: some View {
        let lines = snippetLines
        VStack(alignment: .leading, spacing: 4) {
            // 누르면 diff 로 간다는 안내. 예전엔 도움말 풍선(.help)이었는데, 미리보기가 뜬 뒤 그 위에 또 떴다.
            HStack(spacing: 8) {
                Text(reference.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("누르면 diff 로 이동")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if lines.isEmpty {
                Text("이 커밋의 diff 에서 해당 줄을 찾지 못했습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let profile = CodeSyntax.profile(forPath: reference.path)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 6) {
                            Text(line.newLine.map(String.init) ?? "")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 34, alignment: .trailing)
                            CodeLineText(text: line.text, profile: profile,
                                         font: .system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(line.newLine == reference.line ? Color.orange.opacity(0.22) : .clear)
                    }
                }
            }
        }
    }

    private var snippetLines: [DiffLine] {
        guard let diff = model.parsedDiff(for: pr),
              let file = diff.files.first(where: { $0.path == reference.path }) else { return [] }
        guard let line = reference.line else { return Array(file.lines.filter { $0.kind != .meta }.prefix(6)) }
        return file.snippet(around: line, side: .right, context: 3)
    }
}
