import SwiftUI
import PRayerCore

/// "☐ 리뷰에 담기" 를 체크하면 카드가 왼쪽 리뷰 본문의 "담은 줄 코멘트" 로 날아가 내려앉고, 거기서 체크를 끄면 오른쪽
/// 제자리로 날아 돌아간다(사용자 요청, 2026-10-26 · 체크로 바꿈 10-27). 체크만 바뀌면 코멘트가 어디로 갔는지 안 보였다.
///
/// 카드·칸 자체를 옮기지 않고 같은 글을 담은 작은 고스트를 두 칸 **위**에 띄워 옮긴다 — 두 칸은 각자 스크롤되고
/// 둥근 상자로 잘려(`ReviewPanelBox`) 안의 뷰를 옮기면 가장자리에서 사라진다.
///
/// 좁은 창(두 칸 대신 탭)에서는 반대쪽 칸이 화면에 없어 칩(`BasketTabChip`)이 그 탭 버튼으로 날아 들어간다.
enum BasketFlight {
    /// 자리를 재는 좌표 공간 — 두 칸을 담은 틀(두 스크롤 바깥), 좁은 창이면 그 스크롤. 스크롤하면 그 안의 자리 값도 따라 바뀐다.
    static let space = "aiReviewColumns"

    /// 한 번 날아가는 시간. 확인 캡처 때는 `PRAYER_DEBUG_FLIGHT_SECONDS` 로 늘린다.
    static var duration: Double { DebugLaunch.flightSeconds ?? 0.5 }
    /// 좁은 창의 칩이 탭까지 가는 시간 — 목록의 Approve 칩과 같은 움직임이라 시간도 같게 둔다.
    static var tabDuration: Double { DebugLaunch.flightSeconds ?? ApprovalFlight.duration }

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
    /// 좁은 창의 "리뷰 본문" · "코드 코멘트" 탭 글자 묶음. 탭 줄은 스크롤 맨 위에 붙어 늘 보인다.
    var bodyTab: CGRect = .zero
    var commentsTab: CGRect = .zero
}

/// 좁은 창에서 담기·빼기로 반대쪽 탭에 날아가는 칩 하나.
struct BasketTabTrip: Identifiable, Equatable {
    let id = UUID()
    let issue: ReviewIssue
    /// true 면 코드 코멘트 카드 → "리뷰 본문" 탭, false 면 담은 줄 → "코드 코멘트" 탭.
    let intoBasket: Bool
    /// 칩 왼쪽 끝이 설 자리 — 누른 체크 바로 옆.
    let from: CGPoint
    /// 날아갈 탭 버튼.
    let to: CGRect
}

/// 좁은 창 담기·빼기 — 누른 체크 자리에서 "☑ 참고 · 파일:줄" 칩이 떠올라 반대쪽 탭으로 휘어 들어간다(시안 B "칩 포물선",
/// 사용자 선택 2026-11-02). 예전에는 카드가 그 자리에서 사라지기만 해서 어디로 갔는지 몰랐다.
/// 움직임은 목록의 Approve 칩(`ApprovalFlightChip`)과 같다 — 위로 먼저 솟고 옆으로는 늦게 움직여 포물선을 그린다.
/// 탭 줄은 스크롤 맨 위에 붙어 있어(AIReviewView 좁은 창) 내려 읽던 중에도 칩이 보이는 탭에 들어간다.
struct BasketTabChip: View {
    let trip: BasketTabTrip
    let onLanded: () -> Void

    /// 칩 크기. 재기 전에는 띄우지 않는다 — 도착 자리(탭 가운데)에 칩 가운데를 맞추려면 폭이 있어야 한다.
    @State private var size: CGSize = .zero
    @State private var dx: CGFloat = 0
    @State private var dy: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0

    var body: some View {
        chip
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                guard size == .zero, measured.width > 0 else { return }
                size = measured
                fly()
            }
            .scaleEffect(scale)
            .opacity(opacity)
            // 가로·세로를 다른 수식어로 둔다. 한 점으로 두면 두 애니메이션이 같은 값을 두고 겹친다(ApprovalFlightChip 주석).
            .offset(x: dx)
            .offset(y: dy)
            .offset(x: trip.from.x, y: trip.from.y - size.height / 2)
            .allowsHitTesting(false)
    }

    private func fly() {
        let duration = BasketFlight.tabDuration
        let targetX = trip.to.midX - size.width / 2
        let targetY = trip.to.midY - size.height / 2
        opacity = 1
        withAnimation(.timingCurve(0.2, 0.6, 0.35, 1, duration: duration)) {
            dy = targetY - (trip.from.y - size.height / 2)
        }
        withAnimation(.timingCurve(0.55, 0, 0.45, 1, duration: duration)) {
            dx = targetX - trip.from.x
        } completion: {
            onLanded()
        }
        withAnimation(.easeOut(duration: duration * 0.45)) {
            scale = 1.12
        } completion: {
            withAnimation(.easeIn(duration: duration * 0.55)) {
                scale = 0.55
                opacity = 0.85
            }
        }
    }

    /// 담기는 체크된 모양, 빼기는 빈 모양 — 방금 누른 체크가 같이 날아가 보이게(BasketGhost 와 같다).
    private var chip: some View {
        let label = [trip.issue.importance.label, trip.issue.place].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 3) {
            Image(systemName: trip.intoBasket ? "checkmark.square.fill" : "square")
                .font(.caption2)
            Text(verbatim: label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(Color.accentColor)
        // 카드 글자 위를 지나가므로 바탕을 먼저 막고, 그 위에 연한 강조색을 깐다(ApprovalFlightChip 과 같다).
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5))
    }
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
