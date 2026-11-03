import SwiftUI
import PRayerCore

/// 리뷰 전(Not reviewed) PR 행에 마우스를 올리면 시각 자리에 뜨는 버튼 둘. 누르면 PR 을 열지 않고 그 자리에서 리뷰를 건다
/// (시안 G, 2026-11-03 사용자 결정). 예전에는 목록에서 리뷰를 시작하려면 눈에 안 보이는 우클릭 메뉴를 쓰거나 PR 을 열어
/// AI 리뷰 탭의 카드까지 가야 했다.
///
/// 칩에 마우스를 올리면 말풍선이 뜨는 안(시안 A)을 먼저 써 봤는데, 기다리게 하면 굼뜨고 바로 띄우면 목록을 훑을 때마다
/// 튀었다. 행 안의 작은 버튼이라 기다릴 것도 튈 것도 없고, 누를 자리가 칩보다 넓다.
///
/// - 같이 고른 행이 여럿이어도 이 버튼은 이 PR 하나만 리뷰한다(우클릭 메뉴는 고른 것 전부 — reviewFromList).
/// - 시작은 우클릭 메뉴와 같은 `reviewNow` 라서 첫 클론 확인·변경이 많을 때의 리뷰 전 창이 그대로 걸린다.
/// - 버튼이 행의 누르기를 가져가므로 버튼을 눌러도 행은 고르지 않는다 — 리뷰가 돌면 배지가 Reviewing 으로 바뀌어 보인다.
struct RowReviewButtons: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    var body: some View {
        HStack(spacing: 4) {
            // 전체 리뷰를 앞에 둔다 — 더 꼼꼼한 쪽이다(우클릭 메뉴·리뷰 전 카드와 같은 순서). diff 는 폭을 아끼려고 아이콘을 뺐다.
            button(.worktree, title: "전체 리뷰", showsSymbol: true)
            button(.diff, title: "diff", showsSymbol: false)
        }
        .fixedSize()
    }

    private func button(_ launch: ReviewLaunch, title: String, showsSymbol: Bool) -> some View {
        Button {
            model.reviewNow(pr: pr, deep: launch == .worktree)
        } label: {
            HStack(spacing: 3) {
                if showsSymbol {
                    Image(systemName: launch.symbol)
                        .font(.system(size: 9))
                }
                Text(title)
                    .font(.caption2.weight(.medium))
            }
        }
        .buttonStyle(RowReviewButtonStyle())
        // 무엇이 다른지·어느 모델로 도는지·어디에 남는지는 버튼에 다 못 적어 툴팁으로(리뷰 전 카드와 같은 말).
        .help("\(launch.cardPoints.first?.text ?? "") · \(model.reviewModelLabel(model.reviewModelChoice(for: pr))) · 초안만 이 맥에 만듭니다")
    }
}

/// 리뷰가 도는 중이거나 큐에서 기다리는 PR 행에 마우스를 올리면 같은 자리에 뜨는 취소 버튼. 우클릭 메뉴의 "리뷰 취소" 와
/// 같은 일을 한다 — 우클릭은 눈에 안 보여서, 리뷰를 건 자리에서 바로 거둘 수 있게 했다(사용자, 2026-11-03).
/// 확인은 묻지 않는다 — 초안은 리뷰가 끝나야 저장되므로 취소해서 잃는 것은 그때까지 쓴 토큰뿐이고, 전에 만든 초안은
/// 그대로 남는다(우클릭 취소와 같다).
struct RowCancelReviewButton: View {
    @Environment(AppModel.self) private var model
    let jobID: String
    let isQueued: Bool

    var body: some View {
        Button {
            model.cancel(jobID: jobID)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                Text("리뷰 취소")
                    .font(.caption2.weight(.medium))
            }
        }
        .buttonStyle(RowReviewButtonStyle(tint: .red))
        .fixedSize()
        .help(isQueued ? "큐에서 뺍니다 — 아직 시작하지 않았습니다" : "도는 리뷰를 멈춥니다 — 이번 리뷰의 초안은 만들어지지 않습니다")
    }
}

/// 행 버튼 모양. 평소엔 회색 테두리만, 올리면 `tint` 색 — 행 안에서 시각 글자 자리를 차지하므로 튀지 않게 옅게 그린다.
/// 높이는 상태 칩보다 낮게 둬서 버튼이 떠도 행 높이가 바뀌지 않는다.
private struct RowReviewButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, tint: tint)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5)
            configuration.label
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(isHovering ? tint : Color.secondary)
                .background(shape.fill(tint.opacity(configuration.isPressed ? 0.22 : (isHovering ? 0.12 : 0))))
                .overlay(shape.strokeBorder(isHovering ? tint.opacity(0.55) : Color.primary.opacity(0.18),
                                            lineWidth: 0.5))
                .contentShape(shape)
                .onHover { isHovering = $0 }
        }
    }
}
