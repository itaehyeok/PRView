import SwiftUI
import PRayerCore

/// AI 리뷰 탭 위쪽 "리뷰한 커밋 이후 새 커밋이 올라왔습니다" 한 줄.
///
/// 예전에는 경고 상자 오른쪽에 버튼 두 개 · 모델 칸 · 토큰 설명줄을 세로로 쌓아 상자가 세 줄 높이였다
/// (사용자 피드백: 높이가 너무 길다). 다시 리뷰는 분할 버튼 하나로, 모델은 알약 두 칸으로 줄여 한 줄에 둔다.
/// 이 줄은 판정 줄 아래 다시 리뷰 줄 자리에 대신 뜬다 — 그래서 같은 묶음(`ReviewRelaunchControls`)을 쓴다.
/// 이 PR 에만 다른 모델을 골랐을 때의 "앞으로 모든 PR 에도" 스위치도 그 묶음을 따라 여기 온다.
/// 토큰 설명줄(ReviewLaunchCaption)은 뺀다 — 마우스를 올리면 보인다.
/// 한 줄에 안 들어가면 먼저 권하는 문장("게시 전 다시 리뷰를 권합니다")을 마우스를 올렸을 때 보이는 설명으로
/// 돌리고(버튼 이름이 이미 그 말을 한다), 그래도 안 되면 버튼 줄만 아래로 내린다(ViewThatFits).
/// 실측(AI 리뷰 탭 안쪽 폭 약 540pt): 두 문장은 140pt 남짓, 해시를 넣은 앞 문장만도 3pt 쯤 넘쳤다 —
/// 그래서 해시까지 뺀 가장 짧은 문장 단계를 하나 더 둔다.
struct NewCommitsCallout: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// 리뷰한 커밋의 짧은 해시.
    let reviewedHead: String

    private var fact: String { "리뷰한 커밋(\(reviewedHead)) 이후 새 커밋이 올라왔습니다." }
    private let advice = "게시 전 다시 리뷰를 권합니다."

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneLine(fact + " " + advice)
            oneLine(fact)
            // 해시는 바로 위 머리 줄("커밋 1a2b3c4")에 있어 가장 좁을 때는 뺀다.
            oneLine("리뷰 이후 새 커밋이 올라왔습니다.")
            VStack(alignment: .leading, spacing: 6) {
                label(fact + " " + advice)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func oneLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            label(text).fixedSize()
            Spacer(minLength: 12)
            controls
        }
    }

    private func label(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        }
        // 줄여 보일 때 빠진 문장과 토큰 설명은 여기서 본다.
        .help(fact + " " + advice + "\n" + ReviewLaunchCaption.text(model: model, pr: pr))
    }

    private var controls: some View {
        ReviewRelaunchControls(pr: pr)
            .fixedSize()
    }
}
