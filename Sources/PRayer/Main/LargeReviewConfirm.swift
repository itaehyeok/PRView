import SwiftUI
import PRayerCore

/// 변경이 많은 PR 을 리뷰하기 **전에** 한 번 묻는 창.
///
/// 예전에는 큐에 넣고 나서 배너로 "경고 기준을 넘습니다" 라고만 알렸다. 이미 돌기 시작한
/// 뒤라 멈출 길이 취소 버튼뿐이었고, 그때는 이미 토큰을 쓴 뒤다. 물어봐야 할 순간은
/// 누르기 직전이다.
///
/// 기준을 이 창에서 바로 고칠 수 있게 둔 이유: 기준이 안 맞아서 매번 뜨는데 고치려면
/// 설정 창을 따로 열어야 한다면, 사람은 창을 고치는 대신 내용을 안 읽고 누르게 된다.
struct LargeReviewConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PendingLargeReview

    /// 창을 여는 동안 기준을 만지작거려도 저장은 "적용" 한 번으로 끝낸다.
    @State private var warnLines: Int = 0

    private var estimatedTokens: Int {
        PromptBuilder.estimatedTokens(changedLines: request.lines)
    }

    private var modelOption: ReviewModelOption? {
        model.modelOption(id: request.modelID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("수정사항이 너무 많습니다. 리뷰를 그대로 진행하시겠습니까?")
                    .font(.headline)
                Text("#\(String(request.number)) \(request.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    row("변경", "\(request.lines.formatted())줄",
                        note: "경고 기준 \(warnLines.formatted())줄")
                    row("예상 소모", "약 \(tokens(estimatedTokens))",
                        note: modelOption.map { "\($0.label) 로 리뷰" })
                    row("최근 5시간 사용", tokens(model.fiveHourTokens),
                        note: "상한 \(tokens(model.settings.fiveHourTokenCap))",
                        warning: overBudget)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if overBudget {
                Label("이 리뷰까지 더하면 5시간 상한을 넘습니다.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack(spacing: 8) {
                Text("이 창을 띄울 기준")
                    .font(.callout)
                Stepper("\(warnLines.formatted())줄", value: $warnLines, in: 200...20_000, step: 100)
                    .font(.callout.monospacedDigit())
            }
            Text("예상 소모는 변경 줄 수로 어림한 값입니다(줄당 \(PromptBuilder.tokensPerChangedLine)토큰 + 고정분). 실제 값은 리뷰가 끝나야 압니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("취소", role: .cancel) {
                    model.cancelPendingLargeReview()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("그대로 진행") {
                    model.settings.manualSizeWarnLines = warnLines
                    model.confirmPendingLargeReview()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .task { warnLines = model.settings.manualSizeWarnLines }
    }

    /// 이 리뷰까지 더하면 5시간 상한을 넘는가. 넘는다고 막지는 않는다 — 사람이 정한다.
    private var overBudget: Bool {
        model.settings.fiveHourTokenCap > 0
            && model.fiveHourTokens + estimatedTokens > model.settings.fiveHourTokenCap
    }

    private func row(_ title: String, _ value: String, note: String? = nil, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(warning ? Color.orange : Color.primary)
            if let note {
                Text("· \(note)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func tokens(_ value: Int) -> String {
        value >= 1_000 ? "\(value / 1_000)k 토큰" : "\(value) 토큰"
    }
}
