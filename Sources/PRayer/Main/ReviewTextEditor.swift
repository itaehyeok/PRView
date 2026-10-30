import SwiftUI

/// 리뷰 본문의 글 하나(요약·잘된 점·우려사항 제목·질문)를 고치는 편집기.
///
/// 글을 눌러 바로 고치는 방식은 쓰지 않는다(사용자 결정). 우려사항·질문 줄에는 코드 링크·태그·정리 버튼이
/// 붙어 있어 글자 클릭과 링크 클릭이 몇 px 차이로 갈리고, 복사하려고 끌어도 편집이 열린다.
/// 그래서 "수정" 을 눌렀을 때만 이 편집기가 열리고, 저장·취소가 늘 같은 자리에 있다.
struct ReviewTextEditor: View {
    /// AI 가 쓴 원문. "AI 원문으로" 가 이 글로 되돌린다.
    let original: String
    var hint: String?
    var minHeight: CGFloat = 54
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(original: String, current: String, hint: String? = nil, minHeight: CGFloat = 54,
         onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.hint = hint
        self.minHeight = minHeight
        self.onSave = onSave
        self.onCancel = onCancel
        // 편집기는 "수정" 을 누를 때마다 새로 만들어지므로, 여는 순간의 값으로 시작하면 된다.
        _text = State(initialValue: current)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.callout)
                .focused($focused)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
            HStack(spacing: 8) {
                Text(trimmed.isEmpty ? "비워 둘 수는 없습니다. 본문에서 빼려면 체크를 끄세요." : (hint ?? ""))
                    .font(.caption)
                    .foregroundStyle(trimmed.isEmpty ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Button("AI 원문으로") { text = original }
                        .help("AI 가 쓴 글로 되돌립니다. 저장해야 반영됩니다.")
                }
                Button("취소", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("저장") { onSave(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
                    .help("저장합니다(⌘↩)")
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }
}

/// 사용자가 고친 글이라는 표시. 원문과 같아지면 사라진다(`ReviewRecord.setSummaryEdit` 등).
struct EditedMark: View {
    var body: some View {
        Text("수정함")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .help("AI 가 쓴 글을 고쳤습니다. 이 글로 올라갑니다.")
    }
}

/// 절·항목의 "수정" 버튼. 게시한 뒤에는 그리지 않는다(이미 올라간 글이다).
/// 항목 줄에서도 글자를 붙인다 — 연필만 두었더니 절 머리 줄의 "수정" 과 같은 버튼으로 안 읽혔다(사용자 피드백).
struct EditTextButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("수정", systemImage: "pencil")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .help("이 글을 고칩니다. AI 원문은 남아 있어 언제든 되돌릴 수 있습니다.")
    }
}
