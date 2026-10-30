import SwiftUI
import PRayerCore

/// AI 리뷰 탭 두 패널(왼쪽 리뷰 본문 · 오른쪽 코드 코멘트)의 공통 틀. GitHub 코멘트 상자처럼 회색 머리 줄 + 내용이다.
///
/// 예전에는 왼쪽만 상자에 머리 줄이 있고 오른쪽은 맨 글씨 제목이라, 두 패널이 다른 높이에서 다른 모양으로
/// 시작했다(사용자 피드백). 머리 줄 높이를 고정해 두 패널의 머리 줄과 내용이 같은 줄에서 시작한다.
struct ReviewPanelBox<Header: View, Content: View>: View {
    /// 테두리를 점선으로 — 오른쪽 코드 코멘트 칸. 왼쪽 리뷰 본문이 실제로 올라가는 자리이고 오른쪽은 거기에 담을 것을
    /// 고르는 자리라, 두 칸이 같은 무게로 보이지 않게 오른쪽만 "아직 고르는 중" 꼴로 둔다(사용자 결정, 2026-10-28 시안 D).
    var isDashed = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) { header() }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: reviewPanelHeaderHeight,
                       maxHeight: reviewPanelHeaderHeight, alignment: .leading)
                .background(.quinary)
            Divider()
            content()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(shape)
        .overlay {
            if isDashed {
                shape.strokeBorder(Color(nsColor: .tertiaryLabelColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                shape.strokeBorder(Color(nsColor: .separatorColor))
            }
        }
    }
}

/// 두 패널 머리 줄의 높이. 같아야 두 패널이 같은 줄에서 시작한다.
let reviewPanelHeaderHeight: CGFloat = 34

/// 코멘트가 붙는 자리의 코드 몇 줄. 그 줄을 칠한다. GitHub 의 줄 코멘트 위에 보이는 코드와 같은 자리다.
struct CodeSnippetView: View {
    @Environment(AppModel.self) private var model
    let lines: [DiffLine]
    let targetLine: Int
    let side: DiffSide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                let number = side == .right ? line.newLine : line.oldLine
                let isTarget = number == targetLine
                HStack(spacing: 6) {
                    Text(number.map(String.init) ?? "")
                        .font(model.fonts.code(size: max(9, model.settings.codeFontSize - 1)))
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .trailing)
                    Text(prefix(line) + line.text)
                        .font(model.fonts.code())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(isTarget ? Color.orange.opacity(0.25) : Color.clear)
            }
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: return "+ "
        case .deletion: return "− "
        default: return "  "
        }
    }
}

/// 글 길이만큼 키가 자라는 입력칸. 오른쪽 코드 코멘트 말풍선과 왼쪽 본문 칸이 같이 쓴다.
///
/// `TextEditor` 는 받은 높이를 다 채운다. 두 패널을 나란히 두면 짧은 칸이 옆 패널 높이만큼 늘어나 빈 칸이 컸고,
/// 높이를 묶으면 긴 글이 칸 안에서 스크롤됐다. 같은 글을 보이지 않게 깔아 그 높이를 칸의 높이로 쓴다.
struct GrowingTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 44
    /// 빈 줄을 고치는 동안에만 둔다. 테두리 없는 칸(코드 코멘트 카드)은 그 빈 줄이 글 아래 틈으로 보인다.
    var spareLineOnlyWhileEditing = false

    @FocusState private var isEditing: Bool

    var body: some View {
        // 끝에 빈 줄을 하나 더 둬서 새 줄을 치는 순간 칸이 먼저 자라게 한다(아니면 한 박자 늦게 스크롤된다).
        let spareLine = !spareLineOnlyWhileEditing || isEditing
        Text(text.isEmpty ? " " : text + (spareLine ? "\n" : ""))
            .font(.callout)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .overlay {
                TextEditor(text: $text)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .focused($isEditing)
            }
    }
}

extension View {
    /// 두 패널 입력칸의 모양 — 테두리만 있는 둥근 칸. 왼쪽 코드 코멘트 말풍선과 오른쪽 본문 칸이 같은 모양이어야
    /// 한 화면으로 읽힌다(예전엔 한쪽은 테두리, 한쪽은 회색 바탕이라 다른 물건처럼 보였다 — 사용자 피드백).
    func reviewFieldBox() -> some View {
        padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// 고친 칸을 처음 글로 되돌리는 버튼. 두 패널이 같이 쓴다.
struct ResetTextButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.counterclockwise")
                Text("초기화")
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("고친 글을 지우고 AI 가 쓴 처음 글로 되돌립니다")
    }
}

