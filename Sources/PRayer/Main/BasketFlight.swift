import SwiftUI
import PRayerCore

/// "☐ 리뷰에 담기" 를 체크하면 카드가 왼쪽 리뷰 본문의 "담은 줄 코멘트" 로 날아가 내려앉고, 거기서 체크를 끄면 오른쪽
/// 제자리로 날아 돌아간다(사용자 요청, 2026-10-26 · 체크로 바꿈 10-27). 체크만 바뀌면 코멘트가 어디로 갔는지 안 보였다.
///
/// 카드·칸 자체를 옮기지 않고 같은 글을 담은 작은 고스트를 두 칸 **위**에 띄워 옮긴다 — 두 칸은 각자 스크롤되고
/// 둥근 상자로 잘려(`ReviewPanelBox`) 안의 뷰를 옮기면 가장자리에서 사라진다.
enum BasketFlight {
    /// 자리를 재는 좌표 공간 — 두 칸을 담은 틀(두 스크롤 바깥). 칸을 스크롤하면 그 안의 자리 값도 따라 바뀐다.
    static let space = "aiReviewColumns"

    /// 한 번 날아가는 시간. 확인 캡처 때는 `PRAYER_DEBUG_FLIGHT_SECONDS` 로 늘린다.
    static var duration: Double { DebugLaunch.flightSeconds ?? 0.5 }

    /// 고스트가 그 칸 화면 밖으로 날아가지 않게 도착 자리의 윗변을 보이는 자리 안으로 당긴다. 아직 못 쟀으면 그대로.
    static func keepInside(_ target: CGRect, viewport: CGRect, ghostHeight: CGFloat = 72) -> CGRect {
        guard viewport.height > 0 else { return target }
        let lowest = viewport.maxY - min(ghostHeight, viewport.height)
        var moved = target
        moved.origin.y = min(max(target.minY, viewport.minY), lowest)
        return moved
    }

    struct Trip: Equatable {
        let issue: ReviewIssue
        let text: String
        /// true 면 오른쪽 카드 → 왼쪽 담은 목록.
        let intoBasket: Bool
        let from: CGRect
    }
}

/// 카드·담은 줄·본문 상자의 마지막 자리. **관찰하지 않는 상자**라 값이 바뀌어도 화면을 다시 그리지 않는다 —
/// 스크롤·글자 하나마다 카드 수만큼 바뀌는 값이라 `@State` 로 두면 AI 리뷰 탭 전체가 계속 다시 그려진다.
final class BasketFrames {
    var cards: [String: CGRect] = [:]
    var rows: [String: CGRect] = [:]
    var body: CGRect = .zero
    /// 두 칸 스크롤이 보여 주는 자리. 화면 밖으로 날아가지 않게 도착 자리를 이 안으로 당긴다.
    var leftViewport: CGRect = .zero
    var rightViewport: CGRect = .zero
    var twoColumns = false
}

extension View {
    /// 이 뷰의 자리를 `BasketFlight.space` 기준으로 적어 둔다.
    func recordBasketFrame(_ write: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BasketFlight.space)) } action: { write($0) }
    }
}

/// 날아가는 고스트 — 체크 · 중요도 · 자리 · 글 두 줄. 왼쪽 담은 줄과 같은 차림이라 내려앉으면 그 줄이 된 것처럼 보인다.
struct BasketGhost: View {
    let issue: ReviewIssue
    let text: String
    /// 담기는 중이면 체크된 모양, 돌아가는 중이면 빈 모양 — 방금 누른 체크가 같이 날아가 보이게.
    let checked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.callout)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                Text(issue.importance.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(importanceColor(issue.importance))
                if let place = issue.place {
                    Text(place)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}
