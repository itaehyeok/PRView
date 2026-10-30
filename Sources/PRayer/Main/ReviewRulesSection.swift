import SwiftUI
import PRayerCore

/// 설정 › 리뷰 › 내 리뷰 규칙. 사용자가 쓴 규칙만 받고, 앱의 리뷰 규칙은 보여 주지 않는다(사용자 결정, 2026-10-22).
/// 리뷰할 때 앱 기본 규칙과 앱 형식 규칙 사이에 들어간다(`ReviewGuideText`).
struct ReviewRulesSection: View {
    @Binding var rules: String

    private var count: Int { rules.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var isOver: Bool { count > ReviewGuideText.maxUserRulesCharacters }

    var body: some View {
        Section("내 리뷰 규칙") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $rules)
                    .font(.body)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                if rules.isEmpty {
                    // 무엇을 쓰면 되는지가 칸만 봐서는 안 보인다. 실측에서 결과가 바뀐 말투·길이부터 든다.
                    Text("예) 해요체로 써 주세요.\n코멘트는 두 문장 안으로 짧게 써 주세요.\n테스트가 없는 새 로직은 짚어 주세요.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("리뷰 글의 말투·길이·무엇을 짚을지를 적으면 앱 기본 규칙보다 먼저 따릅니다. 코드 줄·중요도·판정 같은 형식은 앱이 정해서 바뀌지 않습니다. 다음 리뷰부터 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(isOver ? "앞 \(ReviewGuideText.maxUserRulesCharacters.formatted())자만 씁니다"
                            : "\(count.formatted()) / \(ReviewGuideText.maxUserRulesCharacters.formatted())자")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOver ? .red : .secondary)
            }
        }
    }
}
