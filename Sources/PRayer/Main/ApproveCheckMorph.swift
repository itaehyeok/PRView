import SwiftUI

/// "리뷰 없이 Approve" 가 올라간 순간의 짧은 연출(시안 B, 사용자 선택 2026-10-27). 누른 버튼이 초록 동그라미로
/// 줄어들며 체크가 그려지고 물결이 한 번 퍼진 뒤, 결과 알약("이 커밋에 Approve 했어요")으로 바뀐다.
/// 예전에는 결과 알약으로 뚝 바뀌어 눌러서 무슨 일이 났는지가 한눈에 안 들어왔다.
///
/// 시스템 버튼은 모양·색을 바꿀 수 없어서, 올라간 순간 버튼 자리를 같은 크기의 이 뷰로 바꿔 그린다.
/// 끝나면 `onFinish` — 부르는 쪽이 이 뷰를 걷고 진짜 `PostedStatusLabel` 을 그린다(마지막 모습이 같아 튀지 않는다).
/// 손쉬운 사용의 "동작 줄이기" 가 켜져 있으면 줄고 그려지는 움직임 없이 결과 알약으로 서서히 바뀌기만 한다.
struct ApproveCheckMorph: View {
    /// 바뀌기 전 버튼 크기. 이 자리에서 줄어들기 시작한다.
    let from: CGSize
    let text: String
    /// 시간 배율. 확인 캡처 때 늘린다(`PRAYER_DEBUG_APPROVE_MORPH`).
    var pace: Double = 1
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = false
    @State private var textHidden = false
    @State private var checkDrawn = false
    @State private var pulse = false
    @State private var rippleScale: CGFloat = 0.7
    @State private var rippleOpacity: Double = 0
    @State private var showsLabel = false

    var body: some View {
        let side = max(from.height, 20)
        ZStack {
            ZStack {
                // 동그라미 뒤에 숨어 있다가 체크가 그려질 때 밖으로 퍼진다.
                Circle()
                    .stroke(PostedStatusLabel.fill, lineWidth: 2)
                    .frame(width: side + 8, height: side + 8)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                RoundedRectangle(cornerRadius: collapsed ? side / 2 : 6, style: .continuous)
                    .fill(collapsed ? PostedStatusLabel.fill : Color(nsColor: .controlColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: collapsed ? side / 2 : 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(collapsed ? 0 : 0.12), lineWidth: 0.5)
                    }
                    .frame(width: collapsed ? side : from.width, height: side)
                Text("Approve 올리는 중…")
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .opacity(textHidden ? 0 : 1)
                Checkmark()
                    .trim(from: 0, to: checkDrawn ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.6, height: side * 0.6)
            }
            .scaleEffect(pulse ? 1.14 : 1)
            .scaleEffect(showsLabel ? 0.7 : 1)
            .opacity(showsLabel ? 0 : 1)
            PostedStatusLabel(text: text)
                .opacity(showsLabel ? 1 : 0)
                .offset(y: showsLabel ? 0 : 4)
        }
        .frame(width: from.width, height: from.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { showsLabel = true }
            await wait(0.3)
            onFinish()
            return
        }
        rippleOpacity = 0.9
        // 글자는 먼저 지운다. 같이 지우면 줄어드는 도형 밖으로 글자가 삐져나와 보였다(실측).
        withAnimation(.easeOut(duration: 0.1 * pace)) { textHidden = true }
        withAnimation(.smooth(duration: 0.3 * pace)) { collapsed = true }
        await wait(0.3)
        withAnimation(.easeOut(duration: 0.3 * pace)) { checkDrawn = true }
        withAnimation(.easeOut(duration: 0.52 * pace)) {
            rippleScale = 1.8
            rippleOpacity = 0
        }
        withAnimation(.spring(duration: 0.15 * pace)) { pulse = true }
        await wait(0.15)
        withAnimation(.spring(duration: 0.25 * pace, bounce: 0.4)) { pulse = false }
        await wait(0.55)
        withAnimation(.easeOut(duration: 0.26 * pace)) { showsLabel = true }
        await wait(0.3)
        onFinish()
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds * pace))
    }
}

/// 획 하나로 그리는 체크 — `trim` 으로 왼쪽 아래에서 오른쪽 위로 그려 나간다. 24×24 기준 좌표.
private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: 5 * scale, y: 12.5 * scale))
        path.addLine(to: CGPoint(x: 9.5 * scale, y: 17 * scale))
        path.addLine(to: CGPoint(x: 19 * scale, y: 7.5 * scale))
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
