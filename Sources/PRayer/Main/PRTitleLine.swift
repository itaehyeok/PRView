import AppKit
import PRayerCore
import SwiftUI

/// PR 머리 줄 맨 윗줄 — "#번호 제목" 과 그 옆 복사 버튼.
///
/// 제목을 누르면 GitHub 에서 PR 을 연다. 예전엔 머리 줄 오른쪽 끝에 "GitHub에서 보기" 버튼이 따로 있었는데, 제목이 곧
/// 그 PR 의 이름이라 GitHub 웹처럼 제목을 링크로 두고 버튼은 뺐다(사용자 요청, 2026-10-28). 글자색은 그대로 두고 올렸을 때만
/// 밑줄·손 모양 커서를 낸다 — 늘 파랗게 칠하면 머리 줄에서 제목만 튄다.
///
/// 올렸을 때만 보이는 밑줄로는 처음 쓰는 사람이 제목이 링크인 줄 몰라서, 번호를 GitHub 로고와 함께 테두리 칩으로
/// 묶었다(사용자 요청, 2026-10-28 시안 C). 칩도 같은 버튼 안이라 칩을 눌러도 제목을 눌러도 같은 PR 이 열린다.
///
/// 번호·제목을 끌어 고르던 텍스트 선택은 뺐다. 고르던 이유가 "번호와 제목을 같이 붙여 넣기" 였는데 복사 버튼이 한 번에
/// 한다. 남기면 끌어 고르는 것과 눌러 여는 것이 한 자리에서 겹친다.
struct PRTitleLine: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    @State private var hovering = false
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    /// 붙여 넣는 꼴. 대화·슬랙·커밋 메시지에 PR 을 손으로 적던 꼴 그대로다.
    /// `"#\(n)"` 을 문자열 보간으로 만든다 — `Text` 의 LocalizedStringKey 보간처럼 자릿수 구분자가 붙지 않는다.
    static func copyText(for pr: PullRequestInfo) -> String { "#\(pr.number) \(pr.title)" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: openOnGitHub) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    numberChip
                    Text(pr.title)
                        .font(.title3.bold())
                        .underline(hovering)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // 올린 채로 다른 PR 을 고르면 나갔다는 알림 없이 사라져 손 모양 커서가 남는다(CodeLink 와 같은 까닭).
            .onDisappear {
                if hovering { NSCursor.pop() }
            }
            .help("\(GitHubLink.title) — 이 PR 을 브라우저에서 엽니다")
            .accessibilityAddTraits(.isLink)

            copyButton
                .fixedSize()
            Spacer(minLength: 0)
        }
        // 복사함 표시가 남은 채 다른 PR 로 넘어가면 그 PR 도 복사한 것처럼 보인다.
        .onChange(of: pr.id) {
            copyReset?.cancel()
            copied = false
        }
    }

    /// [GitHub 로고] #번호 — 테두리 칩. 올리면 제목 밑줄과 함께 글자·테두리가 진해진다.
    private var numberChip: some View {
        HStack(alignment: .center, spacing: 4) {
            GitHubMark(size: 12)
            // `Text("#\(n)")` 는 LocalizedStringKey 보간이라 정수에 자릿수 구분자가 붙었다 — "#1,234".
            Text(verbatim: "#\(pr.number)")
                .font(.body.monospacedDigit())
        }
        .foregroundStyle(hovering ? .primary : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: hovering ? .secondaryLabelColor : .tertiaryLabelColor), lineWidth: 1)
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            // 이미지를 Text 에 넣어야 제목과 첫 줄 글자 바닥선이 맞는다 — Image 만 두면 바닥이 아래 끝이라 위로 뜬다.
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Image(systemName: copied ? "checkmark" : "doc.on.doc"))
                if copied {
                    Text("복사함")
                }
            }
            .font(.callout)
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("PR 번호와 제목을 복사합니다 — \(Self.copyText(for: pr))")
        .accessibilityLabel(copied ? "복사함" : "PR 번호와 제목 복사")
    }

    private func openOnGitHub() {
        if let url = pr.htmlURL(host: model.settings.githubHost) { NSWorkspace.shared.open(url) }
    }

    /// 눌렀다는 표시를 2초만 남긴다(ResumeConversationSection 과 같다). 복사는 되돌릴 일이 없어 창을 띄우지 않는다.
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.copyText(for: pr), forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
