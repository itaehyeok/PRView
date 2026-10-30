import SwiftUI
import PRayerCore

/// "확인했고 문제없음" 표시. 우려사항·작성자 질문·코멘트 초안이 같은 것을 쓴다.
///
/// 체크를 끄는 것과는 다르다. 체크를 끄면 항목이 그냥 사라져서, 작성자는 내가 그걸 봤는지조차
/// 알 수 없다. 여기에 담기면 게시 본문의 "확인했고 문제없던 것" 절에 남아, **읽어 보고 넘겼다는
/// 사실**이 전달된다(팀에서 이미 쓰고 있는 형식이다).
struct ClearedControl: View {
    @Environment(AppModel.self) private var model
    /// 기본 문구에 넣을 주제. 사용자가 고쳐 쓰는 것이 전제다.
    let topic: String
    let note: String?
    let onChange: (String?) -> Void

    var body: some View {
        if let note {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    TextField("무엇을 확인했고 왜 문제가 아닌지 한 줄로",
                              text: Binding(get: { note }, set: { onChange($0) }),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(model.fonts.comment(size: max(10, model.settings.commentFontSize - 1)))
                    Text("게시 본문의 '\(PostBuilder.clearedHeading)' 에 이 줄이 들어갑니다")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button("되돌리기") { onChange(nil) }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
        } else {
            Button {
                onChange(PostBuilder.defaultClearedNote(topic: topic))
            } label: {
                Label("문제없음으로 정리", systemImage: "checkmark.seal")
                    .font(.caption2)
            }
            .buttonStyle(.link)
            .help("읽어 보고 문제가 아니라고 판단했을 때 씁니다. 지적으로 올리지 않고, 확인했다는 사실만 본문에 남깁니다.")
        }
    }
}

/// 항목 하나에서 기본 문구에 쓸 주제를 뽑는다.
enum ClearedTopic {
    /// 코멘트 초안은 본문의 첫 백틱 코드를 주제로 쓴다 — `reloadHeaderView()` 처럼
    /// 무엇에 대한 얘기인지 가장 잘 드러낸다. 없으면 자리로 대신한다.
    static func of(_ comment: DraftComment) -> String {
        if let span = RelatedDiscussionBuilder.codeSpans(in: comment.body).first,
           span.count <= 60 {
            return span
        }
        return "\((comment.path as NSString).lastPathComponent):\(comment.line)"
    }

    static func of(_ concern: Concern) -> String { concern.title }

    static func of(_ question: AuthorQuestion) -> String {
        let text = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= 50 ? text : String(text.prefix(50)) + "…"
    }
}
