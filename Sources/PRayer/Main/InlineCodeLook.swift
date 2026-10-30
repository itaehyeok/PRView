import SwiftUI
import AppKit

/// 인라인 코드(`이런 것`)의 모양 값 — 글자 색·굵기·크기, 바탕, 테두리, 모서리, 여백.
///
/// 값은 사용자가 앱 안 조절 칸에서 직접 바꿔 보고 정했다(2026-10-28, `standard`). 조절 칸은 정한 뒤 뺐다 —
/// 다시 고칠 때는 `standard` 를 바꾼다.
struct InlineCodeLook: Equatable, Sendable {
    /// sRGB 색. 알파 0 이면 그 칸은 없는 것으로 친다(바탕 없음·테두리 없음).
    struct RGBA: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        init(_ hex: Int, alpha: Double = 1) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
            self.alpha = alpha
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    var textLight: RGBA
    var textDark: RGBA
    var fillLight: RGBA
    var fillDark: RGBA
    var borderLight = RGBA(0x000000, alpha: 0)
    var borderDark = RGBA(0x000000, alpha: 0)
    var borderWidth = 1.0
    var weight = Font.Weight.regular
    /// 본문 글자 대비 크기.
    var fontScale = 0.85
    /// 끄면 본문 글꼴로 쓴다.
    var monospaced = true
    var cornerRadius = 4.0
    /// 상자 안쪽 좌우 여백(글자 크기 대비).
    var horizontalPadding = 0.3
    /// 상자를 글자 높이보다 위아래로 이만큼 더 키운다(글자 크기 대비).
    var verticalPadding = 0.08

    var text: Color { Self.dynamic(textLight, textDark) }
    var fill: Color { Self.dynamic(fillLight, fillDark) }
    var border: Color { Self.dynamic(borderLight, borderDark) }
    var hasBorder: Bool { borderLight.alpha > 0 || borderDark.alpha > 0 }

    private static func dynamic(_ light: RGBA, _ dark: RGBA) -> Color {
        let lightColor = light.nsColor
        let darkColor = dark.nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    /// 기본 — 종이(흰 바탕 · 회색 테두리) 위 파랑 글자, 굵기 중간, 고정폭. 사용자가 조절 칸에서 고른 값(2026-10-28).
    /// 라이트: 글자 #0550AE · 바탕 #FFFFFF · 테두리 #C9D1D9 / 다크: 글자 #79C0FF · 바탕 #0D1117 · 테두리 #30363D.
    /// 고를 때 "고정폭" 은 꺼져 있었지만, 그때는 코드 표시 때문에 꺼도 고정폭으로 그려지던 때라 사용자가 본 모양은 고정폭이었다.
    static let standard: InlineCodeLook = {
        var look = InlineCodeLook(textLight: RGBA(0x0550AE), textDark: RGBA(0x79C0FF),
                                  fillLight: RGBA(0xFFFFFF), fillDark: RGBA(0x0D1117))
        look.borderLight = RGBA(0xC9D1D9)
        look.borderDark = RGBA(0x30363D)
        look.weight = .medium
        return look
    }()
}
