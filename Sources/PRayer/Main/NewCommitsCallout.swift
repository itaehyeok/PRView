import SwiftUI
import PRayerCore

/// AI 리뷰 탭 위쪽 "리뷰한 커밋 이후 새 커밋이 올라왔습니다" 한 줄.
///
/// 알리기만 한다. 다시 리뷰 버튼·모델 칸은 게시 버튼 아래 다시 리뷰 줄 한 곳에 있고, 새 커밋이 있으면 그 줄 끝에도
/// 주황 "새 커밋" 이 붙는다(2026-11-06 시안 B-2 사용자 결정). 예전에는 이 줄 오른쪽에 같은 버튼·모델 칸이 있어,
/// 아래 조작부와 한 화면에 두 벌이 떴다. 그보다 전에는 경고 상자에 버튼 두 개·모델 칸·토큰 설명줄을 세로로 쌓아
/// 세 줄 높이였다(사용자 피드백: 높이가 너무 길다).
/// 버튼이 빠져 폭이 남으니 문장을 줄이지 않고 다 적는다 — 좁으면 두 줄로 접힌다. 토큰 설명은 마우스를 올리면 보인다.
struct NewCommitsCallout: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// 리뷰한 커밋의 짧은 해시.
    let reviewedHead: String

    private var text: String { "리뷰한 커밋(\(reviewedHead)) 이후 새 커밋이 올라왔습니다. 게시 전 다시 리뷰를 권합니다." }

    var body: some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        }
        .help(text + "\n" + ReviewLaunchCaption.text(model: model, pr: pr))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
