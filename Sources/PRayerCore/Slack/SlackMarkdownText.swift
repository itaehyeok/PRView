import Foundation

/// 보낼 글(마크다운) ↔ 고치는 칸의 글(링크·강조가 속성으로 숨은 글).
///
/// 미리보기를 눌러 고칠 때 마크다운 원문(`[[APP-1] 제목](https://…)`)을 그대로 보이면 고치기 어려웠다. 그래서 칸에는
/// 속성 붙은 글을 보이고, 고칠 때마다 이 함수로 다시 마크다운으로 푼다. **보낼 글이 이것으로 만들어지니** 되돌림이
/// 정확해야 한다 — 고치지 않은 부분은 원래 글과 같아야 한다(테스트가 묶는다). 글꼴은 화면 쪽(앱)이 입힌다.
public enum SlackMarkdownText {
    /// 마크다운 → 속성 글. 링크는 `.link`, 굵게·기울임·코드는 `.inlinePresentationIntent` 로 남는다.
    ///
    /// 맨 주소(`https://…`)는 마크다운이 저절로 링크로 만드는데, 그대로 두면 되돌릴 때 `[주소](주소)` 가 되어 보낼 글이
    /// 바뀐다(고정 형식 글이 주소뿐이다). 그래서 글자가 곧 주소인 링크는 걷어 글자로 둔다 — 주소를 고쳐도 고친 대로 간다.
    public static func parse(_ markdown: String) -> NSAttributedString {
        var parsed = (try? AttributedString(markdown: markdown,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        let autolinks = parsed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link?.absoluteString else { return nil }
            let text = String(parsed[run.range].characters)
            return url == text || url == "http://" + text ? run.range : nil
        }
        for range in autolinks { parsed[range].link = nil }
        return NSAttributedString(parsed)
    }

    /// 속성 글 → 마크다운. 링크 글자의 대괄호는 틀 채우기와 같은 규칙으로 둔다(`SlackTemplate.linkLabel` — 짝이 맞으면
    /// 그대로, 안 맞는 것만 전각). 백슬래시를 붙이면 Claude 가 옮겨 적다 떼어 보내기가 막힌다.
    public static func markdown(from text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = (text.string as NSString).substring(with: range)
            if let intent = intent(attributes[.inlinePresentationIntent]) {
                if intent.contains(.code) { piece = "`\(piece)`" }
                if intent.contains(.emphasized) { piece = "_\(piece)_" }
                if intent.contains(.stronglyEmphasized) { piece = "**\(piece)**" }
            }
            if let link = attributes[linkKey] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                let label = SlackTemplate.linkLabel(piece)
                piece = "[\(label)](\(url))"
            }
            result += piece
        }
        return result
    }

    /// 링크 속성 이름. `.link` 는 AppKit 에 있어서 Foundation 만 쓰는 Core 는 이름으로 부른다(같은 "NSLink").
    static let linkKey = NSAttributedString.Key("NSLink")

    /// `.inlinePresentationIntent` 값 — 숫자(NSNumber)나 그 자체로 온다.
    public static func intent(_ value: Any?) -> InlinePresentationIntent? {
        if let intent = value as? InlinePresentationIntent { return intent }
        if let number = value as? NSNumber { return InlinePresentationIntent(rawValue: number.uintValue) }
        return nil
    }
}
