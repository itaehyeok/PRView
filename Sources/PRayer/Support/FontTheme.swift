import SwiftUI
import AppKit
import PRayerCore

/// 설정에서 고른 폰트를 SwiftUI Font 로 바꾼다.
/// 지정한 폰트가 설치돼 있지 않으면 조용히 시스템 폰트로 떨어진다(빈 화면보다 낫다).
@MainActor
struct FontTheme {
    let settings: PRayerCore.Settings

    static func isInstalled(_ name: String) -> Bool {
        guard !name.isEmpty else { return true }
        return NSFont(name: name, size: 12) != nil
    }

    /// 코드·diff. 크기를 따로 주면 상대 비율을 유지한 채 그 크기로.
    ///
    /// 코드 글꼴에 없는 한글은 IBM Plex Sans KR 로 **같은 굵기로** 채운다. IBM Plex Mono 와
    /// 한 계열이라 한 줄에 섞여도 획 굵기·글자 높이가 맞는다 — 시스템 한글로 두면 한글만 따로 놀았다.
    /// 굵기를 `.weight()` 로 덧씌우면 영문만 굵어지고 채운 한글은 그대로라서 굵기를 여기서 받는다.
    /// 줄 높이는 달라지지 않는다. SwiftUI 는 대체 글꼴이 섞여도 줄 높이를 코드 글꼴 기준으로 잡는다
    /// (실측 12pt: 영문만 있는 줄·한글이 든 줄 모두 15pt).
    func code(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        let point = size ?? settings.codeFontSize
        if let font = Self.codeFont(named: settings.codeFontName, size: point, weight: weight) {
            return Font(font)
        }
        return .system(size: point, weight: weight, design: .monospaced)
    }

    /// 화면이 그릴 때마다 부르므로(diff 한 줄마다) 만든 글꼴을 재사용한다.
    private static var codeFonts: [String: CTFont] = [:]

    /// 빈 이름은 시스템 고정폭(SF Mono)이다. 이름으로는 찾을 수 없어서(`NSFont(name: "SF Mono")` 는 nil) 시스템에서 받는다.
    private static func codeFont(named name: String, size: CGFloat, weight: Font.Weight) -> CTFont? {
        let key = "\(name)|\(size)|\(weight)"
        if let cached = codeFonts[key] { return cached }
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: nsWeight(weight)]
        let korean = NSFontDescriptor(fontAttributes: [.family: BundledFonts.codeKoreanFamily, .traits: traits])
        let font: NSFont
        if name.isEmpty {
            let base = NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight(weight))
            font = NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [korean]]), size: size) ?? base
        } else {
            guard let base = NSFont(name: name, size: size) else { return nil }
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: base.familyName ?? name,
                .traits: traits,
                .cascadeList: [korean],
            ])
            font = NSFont(descriptor: descriptor, size: size) ?? base
        }
        codeFonts[key] = font
        return font
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// 코멘트·PR 본문 등 사람이 쓴 글.
    func comment(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        font(name: settings.commentFontName, size: size ?? settings.commentFontSize, weight: weight)
    }

    /// 목록·헤더 같은 앱 UI.
    func ui(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        font(name: settings.uiFontName, size: size ?? settings.uiFontSize, weight: weight)
    }

    /// UI 폰트를 기준 크기에서 얼마만큼 줄인 크기(캡션 등).
    func ui(delta: CGFloat, weight: Font.Weight = .regular) -> Font {
        ui(size: max(9, settings.uiFontSize + delta), weight: weight)
    }

    private func font(name: String, size: CGFloat, weight: Font.Weight) -> Font {
        if !name.isEmpty, Self.isInstalled(name) {
            return .custom(name, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

extension AppModel {
    var fonts: FontTheme { FontTheme(settings: settings) }
}
