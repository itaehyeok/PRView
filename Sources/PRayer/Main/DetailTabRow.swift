import SwiftUI

/// 상세 탭 줄 한 줄 — 가운데 탭(DetailTabBar)과, AI 리뷰에서 코드로 건너왔을 때 그 왼쪽 빈자리의 돌아가기 버튼.
///
/// 변경 파일 탭의 코드 코멘트 카드마다 있던 "리뷰에서 보기" 를 이 버튼 하나로 바꿨다(사용자 결정, 2026-10-23
/// 시안 3 "탭 줄 옆 돌아가기 칩"). 탭을 바꿔서 왔으니 탭 옆에서 되돌린다 — 건너온 카드를 diff 에서 다시 찾아
/// 그 카드의 버튼을 누를 필요가 없다. 탭을 눌러 직접 온 변경 파일 탭에는 버튼이 없다(돌아갈 곳이 없다).
struct DetailTabRow<Tabs: View>: View {
    let showsBack: Bool
    let onBack: () -> Void
    @ViewBuilder let tabs: Tabs

    var body: some View {
        CenteredWithLeading {
            if showsBack {
                BackToReviewButton(action: onBack)
            }
            tabs
        }
    }
}

/// 돌아가기 버튼 — 창 툴바 버튼(ToolbarButtonLabel)처럼 아이콘 위·작은 이름 아래, 옅은 파랑 바탕.
///
/// 처음엔 한 줄짜리 옅은 파랑 알약이었는데, 두 줄짜리 탭 칸 옆에서 혼자 낮고 웹 버튼 같았다(사용자: "약간 구려보여").
/// 시안 10개 → 툴바 버튼 모양 → 색 변주 10개 중 "옅은 파랑 바탕" 을 골랐다(사용자 결정, 2026-10-23).
/// 높이는 탭 칸과 같게 맞춘다.
private struct BackToReviewButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // 왼쪽 빈자리가 좁으면 이름을 빼고 아이콘만 — 버튼이 가운데 탭 줄을 덮지 않게.
            ViewThatFits(in: .horizontal) {
                label(showsTitle: true)
                label(showsTitle: false)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // Finder·Safari·Xcode 의 "뒤로" 와 같은 키. 버튼이 있을 때만 먹는다.
        .keyboardShortcut("[", modifiers: .command)
        .help("AI 리뷰 탭의 그 코드 코멘트로 돌아갑니다 (⌘[)")
        .accessibilityLabel("AI 리뷰로 돌아가기")
    }

    private func label(showsTitle: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 14, weight: .medium))
                .frame(height: 17)
            if showsTitle {
                Text("돌아가기")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, showsTitle ? 10 : 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(tintOpacity), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 어두운 바탕에서는 같은 투명도가 거의 안 보여 더 진하게 깐다. 마우스를 올리면 한 단계 진하게.
    private var tintOpacity: Double {
        let base = colorScheme == .dark ? 0.22 : 0.12
        return isHovered ? base + 0.08 : base
    }
}

/// 마지막 뷰(탭 줄)는 늘 가운데, 그 앞의 뷰(버튼)는 왼쪽 빈자리 안 왼쪽 끝. 버튼이 생기고 져도 탭 줄은 제자리에 있다 —
/// HStack 으로 앞에 붙이면 버튼이 뜰 때마다 가운데 놓인 탭 줄 전체가 옆으로 밀린다.
private struct CenteredWithLeading: Layout {
    var gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let center = subviews.last else { return .zero }
        let size = center.sizeThatFits(.unspecified)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? size.height
        return CGSize(width: proposal.width ?? size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let center = subviews.last else { return }
        let size = center.sizeThatFits(.unspecified)
        center.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
        // 버튼에는 탭 줄 왼쪽에 남은 폭만 준다. 버튼(ViewThatFits)이 그 안에 들어가는 모양을 고른다.
        let side = max(0, (bounds.width - size.width) / 2 - gap)
        for leading in subviews.dropLast() {
            leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: side, height: nil))
        }
    }
}
