import AppKit
import PRayerCore

/// 정보 창(앱 메뉴 › About). 기본 창은 이름·버전만 보여서 무슨 앱인지 알 수 없다 — 한 줄 설명을 붙인다.
enum AboutPanel {
    @MainActor
    static func show() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSAttributedString(string: AppInfo.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
