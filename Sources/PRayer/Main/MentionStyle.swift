import SwiftUI
import AppKit
import PRayerCore

/// 나를 부른 자리(@내 아이디)의 모양 — 보라 형광펜(2026-11-04 사용자 결정: 시안 A 형광펜 + 보라, 표기는 "@me").
/// 노랑은 앱이 이미 찾아간 줄 깜빡임·따라가기 강조에 쓰고, 파랑은 목록에서 고른 행 바탕과 겹쳐 그 행의 @me 가 묻혀서
/// 고르지 않았다. 형광펜이라 글자색은 그대로 두고 바탕만 칠한다.
enum MentionStyle {
    /// 형광펜 바탕.
    static let fill = dynamic(light: NSColor(srgbRed: 0x7F / 255, green: 0x77 / 255, blue: 0xDD / 255, alpha: 0.22),
                              dark: NSColor(srgbRed: 0x8F / 255, green: 0x87 / 255, blue: 0xE8 / 255, alpha: 0.36))
    /// "@me" 글자·포커스 테두리.
    static let tint = dynamic(light: NSColor(srgbRed: 0x5B / 255, green: 0x52 / 255, blue: 0xC8 / 255, alpha: 1),
                              dark: NSColor(srgbRed: 0xB4 / 255, green: 0xAE / 255, blue: 0xF0 / 255, alpha: 1))
    static let label = "@me"
    /// 형광펜 상자의 좌우 여백·위아래 키움(글자 크기 대비). 인라인 코드 상자(0.3)보다 좁다 — 이름 하나에 붙는 표시라서.
    static let horizontalPadding: CGFloat = 0.18
    static let verticalPadding: CGFloat = 0.04
    static let cornerRadius: CGFloat = 3

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

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
        Text(MentionStyle.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(MentionStyle.tint)
            .background(MentionStyle.fill, in: RoundedRectangle(cornerRadius: 4))
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
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(MentionButtonStyle(isHovering: isHovering))
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
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(MentionStyle.tint)
            .background(MentionStyle.fill, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(MentionStyle.tint.opacity(isHovering ? 0.6 : 0), lineWidth: 0.8))
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.08 : 1))
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
