import AppKit
import SwiftUI
import PRayerCore

/// 보낼 글을 그 자리에서 고치는 칸 — 마크다운 원문 대신 **미리보기와 같은 모양**으로 고친다.
///
/// 원문(`[\[APP-1\] 제목](https://…)`)을 그대로 보이면 주소·이스케이프가 섞여 고치기 어려웠다(실측 화면).
/// 링크는 링크 색 글자로만 보이고 주소는 속성에 숨긴다. 고칠 때마다 다시 마크다운으로 풀어 바인딩에 넣는다 —
/// 링크 글자를 고쳐도 링크는 남고, 굵게·기울임·코드도 원래 표시로 되돌린다.
struct SlackMessageEditor: NSViewRepresentable {
    @Binding var markdown: String
    /// 칸 밖을 누르면(초점을 잃으면) 부른다 — 미리보기로 돌아간다.
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.iBeam]
        textView.typingAttributes = Coordinator.baseAttributes
        textView.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        context.coordinator.textView = textView
        context.coordinator.load(markdown)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if markdown != context.coordinator.lastMarkdown { context.coordinator.load(markdown) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SlackMessageEditor
        weak var textView: NSTextView?
        private(set) var lastMarkdown = ""
        private var isLoading = false

        static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        static var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: NSColor.labelColor]
        }

        init(_ parent: SlackMessageEditor) {
            self.parent = parent
        }

        func load(_ markdown: String) {
            guard let storage = textView?.textStorage else { return }
            isLoading = true
            storage.setAttributedString(Self.attributed(markdown))
            lastMarkdown = markdown
            isLoading = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let storage = textView?.textStorage else { return }
            let markdown = Self.markdown(from: storage)
            lastMarkdown = markdown
            if parent.markdown != markdown { parent.markdown = markdown }
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        /// 고치는 칸에서 링크를 눌러도 브라우저로 가지 않는다 — 글자를 고치려고 누른 것이다.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }

        // MARK: 마크다운 ↔ 글 (되돌림은 Core 의 SlackMarkdownText — 테스트가 묶는다)

        static func attributed(_ markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: SlackMarkdownText.parse(markdown))
            let all = NSRange(location: 0, length: result.length)
            result.addAttributes(baseAttributes, range: all)
            // 굵게·기울임·코드는 글꼴로 보인다(되돌릴 때 이 속성을 다시 표시로 바꾼다).
            result.enumerateAttribute(.inlinePresentationIntent, in: all) { value, range, _ in
                guard let intent = SlackMarkdownText.intent(value) else { return }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: range)
                } else if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
                }
            }
            return result
        }

        static func markdown(from text: NSAttributedString) -> String {
            SlackMarkdownText.markdown(from: text)
        }
    }
}
