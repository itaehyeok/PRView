import AppKit
import PRayerCore
import SwiftUI

/// 리뷰 맨 아래 "Claude(·Codex) 에서 이어서 대화하기".
///
/// 이 리뷰를 만든 대화를 여는 명령(`claude --resume`·`codex resume`)을 보여 주고 복사하게 한다. 앱이 터미널을 대신 열지 않는다 —
/// 사람마다 이어 갈 곳(터미널, Paseo 같은 앱)이 달라서, 어디든 붙여 넣을 수 있는 한 줄이 가장 넓게 맞는다.
struct ResumeConversationSection: View {
    let record: ReviewRecord

    /// 대화 파일이 남아 있는지. 처음에는 모른다(nil) — 폴더를 훑는 일은 화면을 그린 뒤에 한다.
    /// 모르는 동안에는 있다고 보고 그린다. 거의 늘 있어서, 없다고 그렸다가 바꾸면 매번 깜빡인다.
    @State private var transcriptAvailable: Bool?
    @State private var copied: CopiedItem?

    private enum CopiedItem { case command, sessionID }

    private var sessionID: String? { record.sessionID.flatMap(ClaudeSession.normalizedID) }
    private var engine: ReviewEngineKind { record.engineKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sessionID, let command = ClaudeSession.resumeCommand(sessionID: sessionID, engine: engine),
               transcriptAvailable != false {
                Label("\(engine.displayName) 에서 이어서 대화하기", systemImage: "terminal")
                    .font(.callout.bold())
                Text("""
                    이 리뷰를 만든 \(engine.displayName) 대화를 그대로 이어 갑니다. 리뷰한 코드와 판단 근거를 기억하고 있어서, \
                    우려사항이 맞는지 따져 보거나 코멘트 문구를 같이 다듬을 수 있습니다. \
                    아래 명령을 복사해 터미널에 붙여 넣으세요.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                commandBox(command)
                HStack(spacing: 4) {
                    Text("이 맥에서만 열립니다.")
                    Text("·")
                    Button(copied == .sessionID ? "세션 ID 복사함" : "세션 ID 만 복사") {
                        copy(sessionID, as: .sessionID)
                    }
                    .buttonStyle(.link)
                    Text("(Paseo 처럼 세션을 불러오는 앱용)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label("\(engine.displayName) 에서 이어서 대화하기", systemImage: "terminal")
                    .font(.callout.bold())
                    .foregroundStyle(.secondary)
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: record.sessionID) {
            guard let sessionID else { return }
            // README 캡처용 데모 모드는 가짜 세션이라 대화 파일이 없다. 평소 모양으로 보이게 있는 것으로 친다.
            if DemoMode.isOn {
                transcriptAvailable = true
                return
            }
            // 사용자의 ~/.claude/projects 는 폴더가 수백 개일 수 있다. 화면을 붙잡지 않게 밖에서 훑는다.
            let engine = engine
            transcriptAvailable = await Task.detached(priority: .utility) {
                ClaudeSession.transcriptExists(sessionID: sessionID, engine: engine)
            }.value
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                copy(command, as: .command)
            } label: {
                Label(copied == .command ? "복사함" : "복사",
                      systemImage: copied == .command ? "checkmark" : "doc.on.doc")
            }
            .foregroundStyle(copied == .command ? Color.green : Color.primary)
            .help("명령을 클립보드에 복사합니다.")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
    }

    private var unavailableReason: String {
        if sessionID == nil {
            return "이 리뷰는 대화를 남기기 전 버전에서 만들어 이어 갈 수 없습니다. 다시 리뷰하면 이어 갈 수 있습니다."
        }
        return "\(engine.displayName) 가 오래된 대화를 정리해 더는 이어 갈 수 없습니다."
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
