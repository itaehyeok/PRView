import SwiftUI
import AppKit
import PRayerCore

/// "@me" 칩·형광펜의 모양 값 한 벌. 평소에는 `standard` 그대로고, 개발 빌드의 조절 창(MentionTunerPanel)이 바꿔 가며
/// 화면에서 바로 본다 — 크기·색을 말로 주고받으며 빌드를 여러 번 도는 대신(2026-11-04 사용자 요청).
///
/// 색은 바탕색 하나만 고르고 글자색·다크 모드 색은 거기서 끌어낸다. 고를 값이 줄어 창에서 바꿔 보기 쉽다.
struct MentionLook: Equatable, Sendable {
    /// 바탕색(sRGB 0~1). 형광펜 바탕·칩 바탕·글자색이 모두 이 색에서 나온다.
    var red = 0x7F / 255.0
    var green = 0x77 / 255.0
    var blue = 0xDD / 255.0
    /// 라이트 모드 바탕 진하기. 다크 모드는 어두운 바탕에서 묻혀 1.65배로 칠한다.
    var fillOpacity = 0.22
    var chipFontSize: CGFloat = 10
    var chipWeight = ChipWeight.semibold
    var chipHorizontalPadding: CGFloat = 3.5
    /// 칩 바탕을 글자 위아래로 이만큼 더 칠한다. 자리는 잡지 않는다 — 자리를 잡으면 @me 가 붙은 활동 줄만 높아져
    /// 줄 간격이 들쭉날쭉했다(실측).
    var chipVerticalPadding: CGFloat = 0
    var chipCornerRadius: CGFloat = 3
    /// 끄면 칩 글자를 바탕색에서 끌어낸 색 대신 보통 글자색으로 쓴다.
    var tintedText = true

    /// 보라 형광펜(2026-11-04 사용자 결정: 시안 A 형광펜 + 보라, 표기 "@me"). 노랑은 찾아간 줄 깜빡임·따라가기 강조에
    /// 이미 쓰고, 파랑은 목록에서 고른 행 바탕과 겹쳐 그 행의 @me 가 묻혀서 고르지 않았다. 칩은 처음(10pt·위아래 1pt
    /// 여백)보다 작게 — 키워 본 11.5pt 는 컸고, 처음 것도 크다는 지적에 위아래 여백을 걷고 좌우를 좁혔다.
    static let standard = MentionLook()

    enum ChipWeight: String, CaseIterable, Sendable {
        case regular, medium, semibold, bold

        var weight: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    var chipFont: Font { .system(size: chipFontSize, weight: chipWeight.weight) }

    private var base: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// 형광펜·칩 바탕.
    var fill: Color {
        Self.dynamic(light: base.withAlphaComponent(fillOpacity),
                     dark: Self.shifted(base, saturation: 0.91, brightness: 1.05).withAlphaComponent(min(1, fillOpacity * 1.65)))
    }

    /// "@me" 글자·포커스 테두리 — 바탕색을 라이트에서는 짙고 진하게, 다크에서는 밝고 옅게.
    var tint: Color {
        Self.dynamic(light: Self.shifted(base, saturation: 1.28, brightness: 0.9),
                     dark: Self.shifted(base, saturation: 0.6, brightness: 1.1))
    }

    var chipText: Color { tintedText ? tint : .primary }

    /// 조절 창의 "값 복사" — 정한 값을 그대로 말로 옮길 수 있게.
    var summary: String {
        let hex = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        return "@me 칩: 글자 \(Self.number(chipFontSize))pt \(chipWeight.rawValue) · 좌우 여백 \(Self.number(chipHorizontalPadding))"
            + " · 위아래 바탕 \(Self.number(chipVerticalPadding)) · 모서리 \(Self.number(chipCornerRadius))"
            + " · 색 \(hex) · 바탕 진하기 \(Int((fillOpacity * 100).rounded()))%"
            + (tintedText ? "" : " · 글자 보통색")
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func shifted(_ color: NSColor, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(1, sat * saturation), brightness: min(1, bri * brightness), alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// 지금 쓰는 @me 모양. 배포판에서는 `standard` 에서 바뀌지 않는다 — 바꾸는 곳은 개발 빌드의 조절 창뿐이다.
@MainActor @Observable
final class MentionTuner {
    static let shared = MentionTuner()
    var look = MentionLook.standard
}

/// 나를 부른 자리(@내 아이디)의 모양. 형광펜이라 글자색은 그대로 두고 바탕만 칠한다.
enum MentionStyle {
    @MainActor static var look: MentionLook { MentionTuner.shared.look }
    /// 형광펜 바탕.
    @MainActor static var fill: Color { look.fill }
    /// "@me" 글자·포커스 테두리.
    @MainActor static var tint: Color { look.tint }
    static let label = "@me"
    /// 형광펜 상자의 좌우 여백·위아래 키움(글자 크기 대비). 인라인 코드 상자(0.3)보다 좁다 — 이름 하나에 붙는 표시라서.
    static let horizontalPadding: CGFloat = 0.18
    static let verticalPadding: CGFloat = 0.04
    static let cornerRadius: CGFloat = 3

    /// 글(AttributedString)에서 `@내아이디` 자리. 글자 수로 옮겨 잡는다 — 마크다운을 푼 글은 원문과 글자 자리가 달라서
    /// 원문의 범위를 그대로 쓸 수 없다. `excluding` 과 겹치는 것(인라인 코드 안)은 뺀다.
    static func ranges(in text: AttributedString, viewer: String?,
                       excluding: [Range<AttributedString.Index>] = []) -> [Range<AttributedString.Index>] {
        guard let viewer, !viewer.isEmpty else { return [] }
        let plain = String(text.characters)
        return MyMentions.ranges(in: plain, viewer: viewer).compactMap { found in
            let start = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let length = plain.distance(from: found.lowerBound, to: found.upperBound)
            let lower = text.characters.index(text.startIndex, offsetBy: start)
            let range = lower..<text.characters.index(lower, offsetBy: length)
            return excluding.contains { $0.overlaps(range) } ? nil : range
        }
    }

    /// 한 줄짜리 글(접힌 미리보기)에 형광펜을 칠한다. 둥근 상자는 렌더러가 있는 본문(MarkdownText)에서만 그리고,
    /// 작은 미리보기는 글자 바탕색으로 대신한다.
    @MainActor
    static func highlighted(_ plain: String, viewer: String?) -> AttributedString {
        var text = AttributedString(plain)
        for range in ranges(in: text, viewer: viewer) {
            text[range].backgroundColor = fill
            text[range].foregroundColor = .primary
            text[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}

/// 인라인 형광펜 표시. 상자 겹의 TextRenderer(InlineCodeBoxes)가 이 표시가 붙은 줄 조각 뒤에 보라 상자를 그린다.
struct MentionAttribute: TextAttribute {}

/// 개요 대화 상자 머리·본문 카드 머리의 "@me" — 이 글이 나를 불렀다.
struct MentionTag: View {
    var body: some View {
        let look = MentionStyle.look
        let shape = RoundedRectangle(cornerRadius: look.chipCornerRadius)
        Text(MentionStyle.label)
            .font(look.chipFont)
            .padding(.horizontal, look.chipHorizontalPadding)
            .foregroundStyle(look.chipText)
            .background(shape.fill(look.fill).padding(.vertical, -look.chipVerticalPadding))
            .fixedSize()
            .help("나를 멘션한 글입니다")
    }
}

/// 누르는 "@me" — 목록 활동 줄(그 글로 가기)과 개요 대화 머리(다음 멘션으로). 모양은 MentionTag 와 같고,
/// 올리면 살짝 커지며 손 모양 커서가 된다(답글 칩과 같은 규칙 — 크기를 바꾸면 줄이 밀려 배율로만 키운다).
struct MentionButton: View {
    var title = MentionStyle.label
    var systemImage: String?
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let look = MentionStyle.look
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: max(7, look.chipFontSize - 2), weight: .bold))
                }
            }
            .font(look.chipFont)
            .lineLimit(1)
        }
        .buttonStyle(MentionButtonStyle(look: look, isHovering: isHovering))
        .fixedSize()
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // 누르면 다른 PR 로 옮겨 가 이 줄이 사라질 수 있다 — 나갔다는 알림이 없어 손 모양 커서가 남는다(ReplyChip 과 같다).
        .onDisappear {
            if isHovering { NSCursor.pop() }
        }
        .help(help)
    }
}

private struct MentionButtonStyle: ButtonStyle {
    let look: MentionLook
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: look.chipCornerRadius)
        // 위아래 바탕(chipVerticalPadding)은 자리를 잡지 않고 그림만 늘린다 — MentionLook 주석.
        return configuration.label
            .padding(.horizontal, look.chipHorizontalPadding)
            .foregroundStyle(look.chipText)
            .background(shape.fill(look.fill).padding(.vertical, -look.chipVerticalPadding))
            .overlay(shape.stroke(look.tint.opacity(isHovering ? 0.6 : 0), lineWidth: 0.8)
                .padding(.vertical, -look.chipVerticalPadding))
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.08 : 1))
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
