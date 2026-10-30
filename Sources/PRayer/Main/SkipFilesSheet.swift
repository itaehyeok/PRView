import SwiftUI
import PRayerCore

/// 리뷰 버튼을 눌렀을 때 한 파일이 1,000줄 넘게 바뀌었으면 한 번 묻는다(SkippableFiles — 어떤 파일을 묻는지는 거기).
///
/// 파일마다 고르게 하지 않는다 — 사용자 결정: 고르게 하면 귀찮다. [모두 리뷰]/[빼고 리뷰] 둘 중 하나로 답하고,
/// "다음부터 이 파일들은 묻지 않고 빼기" 를 켜면 그 파일 경로가 제외 목록(설정 › 대상 제외)에 들어간다.
/// 잠금 파일은 여기 오기 전에 이미 빠져 있다(LockFiles). Esc 는 리뷰를 시작하지 않고 닫는다.
struct SkipFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PendingSkipFiles
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 파일 \(request.files.count)개는 빼고 리뷰할까요?")
                .font(.headline)
            Text("한 파일에 \(SkippableFiles.minLines.formatted())줄 넘게 바뀐 파일입니다. 빼면 리뷰할 변경이 \(request.totalLines.formatted())줄에서 \(keptLines.formatted())줄로, 예상 \(tokens(request.totalLines))에서 \(tokens(keptLines)) 토큰으로 줄어듭니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(request.files, id: \.path) { file in
                        HStack(spacing: 8) {
                            Text(file.path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(file.path)
                            Spacer(minLength: 8)
                            Text("+\(file.additions.formatted())").foregroundStyle(.green)
                            Text("−\(file.deletions.formatted())").foregroundStyle(.red)
                        }
                        .font(.callout.monospacedDigit())
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            // 파일이 많으면 창이 화면을 넘지 않게 목록만 민다.
            .frame(maxHeight: min(CGFloat(request.files.count) * 30, 240))

            Toggle("다음부터 이 파일들은 묻지 않고 빼기", isOn: $remember)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("모두 리뷰") { answer(skip: false) }
                Button("빼고 리뷰") { answer(skip: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 460)
        .onExitCommand {
            model.cancelPendingSkipFiles()
            dismiss()
        }
    }

    private var keptLines: Int { request.totalLines - request.skippedLines }

    /// AI 리뷰 탭의 "예상 Nk 토큰" 과 같은 어림·같은 표기(PromptBuilder.estimatedTokens, 1,000 으로 나눈 몫) —
    /// 반올림하면 같은 줄 수인데 창과 뒤 화면의 숫자가 달라 보였다(실측: 19k 와 20k).
    private func tokens(_ lines: Int) -> String {
        "\(PromptBuilder.estimatedTokens(changedLines: lines) / 1000)k"
    }

    private func answer(skip: Bool) {
        // "모두 리뷰" 를 눌렀는데 '묻지 않고 빼기' 가 켜져 있으면 뺀다는 뜻이 아니므로 기억하지 않는다.
        model.answerPendingSkipFiles(skip: skip, remember: skip && remember)
        dismiss()
    }
}
