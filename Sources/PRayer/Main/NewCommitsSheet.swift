import SwiftUI
import PRayerCore

/// 게시하려는데 새 커밋이 올라와 있을 때 띄우는 확인 창.
///
/// 기본 확인 창(`confirmationDialog`)은 폭이 260pt 쯤으로 고정이라 커밋 제목이 두세 줄로 접혀
/// 무엇이 올라왔는지 읽히지 않았다(시안 비교). 그래서 넓은 시트로 직접 그린다.
/// 엔터는 "그대로 올림" — 이미 이 창에서 한 번 멈췄으니 한 번 더 막지 않는다.
struct NewCommitsSheet: View {
    let prompt: HeadDriftPrompt
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.headline)
                    Text(prompt.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            commitList

            Label {
                Text(prompt.note)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.confirmLabel) {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(prompt.isDestructive ? .red : nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var commitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let empty = prompt.emptyListText {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            ForEach(Array(prompt.commits.enumerated()), id: \.element.id) { index, commit in
                if index > 0 { Divider() }
                // 해시는 제목과 같은 줄에 두지 않는다 — 앞에 붙이면 줄마다 해시부터 읽히고, 뒤에 붙이면 긴 제목에 밀려 잘린다.
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.headline)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(commit.shortOid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if prompt.hiddenCount > 0 {
                Divider()
                Text("외 \(prompt.hiddenCount)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// 확인 창에 넘길 것 한 묶음 — 무엇을 보여 줄지와 "그대로 올림" 을 누르면 할 일.
struct PendingDrift: Identifiable {
    let drift: HeadDrift
    let prompt: HeadDriftPrompt
    let confirm: () -> Void

    var id: String { drift.id }
}
