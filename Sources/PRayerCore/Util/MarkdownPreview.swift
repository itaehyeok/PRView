import Foundation

/// 접힌 줄에 보일 미리보기 글. 마크다운 꾸밈을 걷어 내고 앞부분을 한 줄로 잇는다.
///
/// 개요·스레드 탭은 처음에 본문과 대화를 접어 둔다(사용자 요청). 접힌 줄만 보고 펼칠지 정하려면 무슨
/// 이야기인지 바로 읽혀야 하는데, 원문을 그대로 자르면 `## 배경`·`- [ ]`·`<!-- … -->`·코드 블록 같은
/// 꾸밈이 앞을 차지해 정작 내용이 안 보인다.
public enum MarkdownPreview {
    /// - Parameter maxLength: 이만큼에서 자른다. 화면은 어차피 줄 수로 자르지만 긴 본문을 통째로 넘기지 않는다.
    public static func text(_ markdown: String, maxLength: Int = 280) -> String {
        // 숨은 주석(앱 마커·PR 템플릿 안내)은 여러 줄에 걸쳐 있어 줄로 나누기 전에 걷는다.
        let visible = markdown.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "\n",
                                                    options: .regularExpression)
        var parts: [String] = []
        var length = 0
        var inFence = false
        for raw in visible.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 코드 블록(mermaid 포함)은 미리보기에서 읽히지 않는다 — 통째로 건너뛴다.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let cleaned = clean(line)
            guard !cleaned.isEmpty else { continue }
            parts.append(cleaned)
            length += cleaned.count + 3
            if length >= maxLength { break }
        }
        let joined = parts.joined(separator: " · ")
        return joined.count > maxLength ? String(joined.prefix(maxLength)) + "…" : joined
    }

    /// 꾸밈만 걷은 한 줄. 꾸밈만 있던 줄(가로줄·표 구분 줄)은 빈 문자열.
    static func clean(_ line: String) -> String {
        if matches(line, #"^\|?\s*:?-{3,}"#) || matches(line, #"^([-*_]\s*){3,}$"#) { return "" }
        var s = line
        // 앞 꾸밈: 제목·인용·목록·번호·체크박스.
        s = replace(s, #"^(#{1,6}\s+|>\s?)+"#, "")
        s = replace(s, #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, "")
        // 그림은 버리고 링크는 글자만 남긴다.
        s = replace(s, #"!\[[^\]]*\]\([^)]*\)"#, "")
        s = replace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        // 흔한 HTML 태그만 걷는다. 아무 `<…>` 나 지우면 `Array<String>` 같은 코드 이름이 깨진다.
        s = replace(s, #"(?i)</?(br|details|summary|p|div|img|sub|sup|b|i|a|span|kbd|code|pre|table|thead|tbody|tr|td|th|ul|ol|li|h[1-6]|hr|em|strong)\b[^>]*>"#, " ")
        s = replace(s, #"\*\*|__|~~"#, "")
        s = s.replacingOccurrences(of: "`", with: "")
        if s.hasPrefix("|") { s = s.replacingOccurrences(of: "|", with: " ") }
        s = replace(s, #"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
