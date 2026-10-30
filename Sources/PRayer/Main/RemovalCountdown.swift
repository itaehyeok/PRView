import SwiftUI

/// 목록에서 곧 빠질 항목에 붙는 줄어드는 고리.
///
/// 1초 시계로 그리면 다섯 칸씩 뚝뚝 끊긴다. `TimelineView(.animation)` 으로 화면 주사율에
/// 맞춰 다시 그려서 실제로 줄어드는 것처럼 보이게 한다.
struct RemovalCountdown: View {
    let deadline: Date
    var total: TimeInterval = 5
    var size: CGFloat = 15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let fraction = total > 0 ? min(1, remaining / total) : 0
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: size * 0.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .help("처리를 마쳐 목록에서 빠집니다")
        }
    }
}

/// 곧 빠질 행을 남은 시간에 걸쳐 서서히 흐리게 만든다.
///
/// 고리만으로는 "이 줄이 사라지는 중" 이 눈에 안 들어온다. 15pt 짜리 작은 조각이라
/// 목록을 훑는 중에는 지나친다. 행 전체가 옅어지면 시선을 주지 않아도 주변시로 잡히고,
/// 아래 행들이 갑자기 위로 튀어 오를 때 그게 왜 일어났는지가 설명된다.
///
/// `RemovalCountdown` 처럼 `TimelineView` 로 매 프레임 다시 그리지 않는 이유:
/// 고리는 15pt 짜리 하나지만 이건 행 전체라, 목록에 걸린 행마다 초당 30번씩 다시 그리면
/// 스크롤이 걸린다. 불투명도를 **한 번만** 바꾸고 나머지는 SwiftUI 에 맡긴다.
struct LeavingFade: ViewModifier {
    /// 이 행이 목록에서 빠지는 시각. `nil` 이면 빠지지 않는다(= 원래 밝기).
    let deadline: Date?

    /// 다 사라지기 전에 멈추는 값. 0 까지 내리면 행이 아직 목록에 자리를 차지하는데
    /// 보이지는 않아서, 마지막 순간에 "빈 칸이 하나 있는" 이상한 상태가 된다.
    private static let floor = 0.12

    @State private var faded = false

    func body(content: Content) -> some View {
        content
            .opacity(faded ? Self.floor : 1)
            // `onAppear` 가 아니라 `onChange(initial:)` 인 이유: 목록이 같은 식별자의
            // 행 뷰를 재사용하면 `onAppear` 가 다시 불리지 않는다. 값을 보고 반응해야 한다.
            .onChange(of: deadline, initial: true) { _, next in
                guard let next else {
                    // 다시 조건에 맞아 살아난 행. 흐린 채로 남겨 두면 안 된다.
                    faded = false
                    return
                }
                let remaining = max(0, next.timeIntervalSinceNow)
                // 이미 지난 뒤에 그려졌다면(스크롤해서 막 들어온 행) 애니메이션 없이 바로 흐리게.
                guard remaining > 0 else {
                    faded = true
                    return
                }
                // easeIn: 앞부분은 천천히 흐려져 고리의 숫자를 읽을 시간이 남고,
                // 끝에서 빠르게 떨어져 "사라진다" 는 느낌이 분명해진다.
                withAnimation(.easeIn(duration: remaining)) { faded = true }
            }
    }
}

extension View {
    /// - Parameter deadline: `AppModel.leavingDeadline(for:)` 결과를 그대로 넘긴다.
    func leavingFade(deadline: Date?) -> some View {
        modifier(LeavingFade(deadline: deadline))
    }
}
