import SwiftUI
import PRayerCore

/// Approve 한 PR 이 리뷰 대기 목록에서 빠질 때, 그 행의 배지 자리에서 "✓ #번호" 칩이 떠올라 목록 위 Approved 탭으로
/// 날아 들어간다(시안 A "칩 날리기", 사용자 선택 2026-10-28). 예전에는 5초 고리와 함께 흐려지다 제자리에서 사라져서,
/// 방금 Approve 한 PR 이 어디로 갔는지가 안 보였다.
///
/// 행을 옮기지 않고 탭 줄과 목록을 함께 덮는 층(`ApprovalFlightLayer`)에 작은 칩을 띄운다 — 목록은 스크롤 안이라
/// 행 뷰를 그대로 옮기면 스크롤 가장자리에서 잘린다(`BasketFlight` 와 같은 이유).
///
/// 목록을 새로 받을 때 빠지는 PR 도 같은 칩으로 그 PR 이 이제 있는 탭에 날린다 — 웹에서 Approve 한 것은 Approved,
/// 머지·닫힘은 All PRs(`ListRefreshChange.destination`, 사용자 요청 2026-10-28).
struct ApprovalFlight: Identifiable, Equatable {
    let id = UUID()
    let prKey: String
    let number: Int
    /// 날아갈 탭.
    var destination: PRListScopeKind = .myApprovals
    /// 같은 탭으로 함께 가는 PR 이 더 있으면 그 수 — 한꺼번에 많이 빠질 때 칩 하나로 묶는다("#12 외 2").
    var others = 0
    /// 시간 배율. 확인 캡처 때 늘린다(`PRAYER_DEBUG_APPROVE_FLIGHT`·`PRAYER_DEBUG_REFRESH_FLIGHT`).
    var pace: Double = 1

    /// 배지가 Approved 로 바뀐 것을 볼 틈. 그 뒤에 칩이 뜬다.
    static let beat: Double = 0.45
    /// 칩이 뜬 뒤 행을 접기 시작하기까지. 같이 접으면 칩이 어디서 나왔는지 놓친다.
    static let rowDelay: Double = 0.14
    /// 칩이 탭까지 가는 시간.
    static let duration: Double = 0.64

    /// 날아갈 때 — 리뷰 대기 탭에서만. 다른 탭에서는 Approve 해도 그 탭에 남거나(전체 PR) 이미 Approved 탭이라
    /// 날아갈 곳이 없다. 손쉬운 사용의 "동작 줄이기" 가 켜져 있으면 예전처럼 흐려지며 빠진다.
    @MainActor
    static func applies(to scope: PRListScopeKind) -> Bool {
        scope == .open && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// 칩이 탭에 닿은 것. 탭이 이 값이 바뀌는 것을 보고 한 번 반짝이며 "+N" 을 띄운다.
struct TabLanding: Equatable {
    var serial = 0
    /// 이번에 닿은 PR 수(묶은 칩이면 여럿).
    var count = 1
}

/// 칩의 출발 자리(날 차례인 행의 배지)와 도착 자리(탭).
///
/// 출발 자리는 날 차례인 행만 적는다 — 나머지 행은 빈 값이라 스크롤해도 목록 위 층이 다시 그려지지 않는다.
struct ApprovalFlightAnchors {
    var sources: [String: Anchor<CGRect>] = [:]
    var tabs: [PRListScopeKind: Anchor<CGRect>] = [:]
}

struct ApprovalFlightAnchorsKey: PreferenceKey {
    static let defaultValue = ApprovalFlightAnchors()
    static func reduce(value: inout ApprovalFlightAnchors, nextValue: () -> ApprovalFlightAnchors) {
        let next = nextValue()
        value.sources.merge(next.sources) { $1 }
        value.tabs.merge(next.tabs) { old, _ in old }
    }
}

/// 탭 줄과 목록을 덮는 층. 지금 날아가는 칩을 그린다.
struct ApprovalFlightLayer: View {
    @Environment(AppModel.self) private var model
    let anchors: ApprovalFlightAnchors

    var body: some View {
        GeometryReader { proxy in
            ForEach(model.approvalFlights) { flight in
                ApprovalFlightChip(flight: flight,
                                   from: anchors.sources[flight.prKey].map { proxy[$0] },
                                   to: anchors.tabs[flight.destination].map { proxy[$0] })
            }
        }
        .allowsHitTesting(false)
    }
}

/// 날아가는 칩. 위로 먼저 솟고 옆으로는 늦게 움직여 포물선을 그린다 — 가로·세로를 서로 다른 곡선으로 움직인다.
/// 가는 동안 조금 커졌다가 탭에 닿을 즈음 작아진다.
private struct ApprovalFlightChip: View {
    @Environment(AppModel.self) private var model
    let flight: ApprovalFlight
    let to: CGRect?

    /// 출발 자리는 뜬 순간의 것만 쓴다. 칩이 뜬 뒤 행이 접히며 자리가 바뀌고, 다 접히면 아예 사라진다.
    @State private var from: CGRect?
    @State private var dx: CGFloat = 0
    @State private var dy: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 1

    init(flight: ApprovalFlight, from: CGRect?, to: CGRect?) {
        self.flight = flight
        self.to = to
        _from = State(initialValue: from)
    }

    var body: some View {
        if let from, let to {
            chip
                .scaleEffect(scale)
                .opacity(opacity)
                // 가로·세로를 다른 수식어로 둔다. 한 점(CGPoint)으로 두면 두 애니메이션이 같은 값을 두고 겹친다.
                .offset(x: dx)
                .offset(y: dy)
                .position(x: from.midX, y: from.midY)
                .onAppear { fly(by: CGSize(width: to.midX - from.midX, height: to.midY - from.midY)) }
        } else {
            // 출발 자리를 못 쟀다 — 스크롤해 안 보이는 행이다. 날지 않고 탭만 반짝인다.
            Color.clear
                .onAppear { model.landApprovalFlight(flight.id) }
        }
    }

    private func fly(by distance: CGSize) {
        let duration = ApprovalFlight.duration * flight.pace
        // 세로는 처음에 빨리, 가로는 나중에 빨리 — 둘을 합치면 위로 솟았다가 탭 쪽으로 휘어 들어간다.
        withAnimation(.timingCurve(0.2, 0.6, 0.35, 1, duration: duration)) {
            dy = distance.height
        }
        withAnimation(.timingCurve(0.55, 0, 0.45, 1, duration: duration)) {
            dx = distance.width
        } completion: {
            model.landApprovalFlight(flight.id)
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

    /// Approved 탭으로 가면 목록의 Approved 배지와 같은 차림(아이콘만 같고 글자는 PR 번호), All PRs 탭으로 가면
    /// 탭 색인 파랑에 번호만 — 머지인지 닫힘인지는 받은 목록만으로는 모른다.
    private var chip: some View {
        let approved = flight.destination == .myApprovals
        let tint = approved ? Color.green : Color.accentColor
        return HStack(spacing: 3) {
            if approved {
                Image(systemName: PRBadge.approved.symbolName)
                    .font(.caption2)
            }
            // 자릿수 구분자가 붙지 않게 verbatim(PRDetailView 주석 참고).
            Text(verbatim: "#\(flight.number)" + (flight.others > 0 ? " 외 \(flight.others)" : ""))
                .font(.caption2.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        // 목록 글자 위를 지나가므로 바탕을 먼저 막고, 그 위에 배지와 같은 연한 색을 깐다.
        .background(Capsule().fill(tint.opacity(0.14)))
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
    }
}
