import Foundation

/// GitHub 마크다운을 블록(제목·목록·인용·코드펜스…)으로 나눈다. 줄 안의 서식은 화면(MarkdownText)이
/// AttributedString 에 맡긴다. 테스트할 수 있게 앱이 아니라 여기 둔다.
public struct MarkdownBlock: Identifiable, Sendable {
    public enum Kind: Sendable {
        case paragraph
        case heading(level: Int)
        case bullet(indent: Int)
        /// `- [ ] 할 일` · `- [x] 한 일`. 화면에서 체크 상자로 그린다(누를 수는 없다 — GitHub 에서도 작성자만 바꾼다).
        case task(indent: Int, done: Bool)
        case ordered(number: Int, indent: Int)
        case quote
        case code(language: String?)
        case rule
        case table(MarkdownTable)
        /// 그림만 있는 줄. 여럿이면 GitHub 처럼 옆으로 나란히 놓는다.
        case images([MarkdownImage])
    }

    public let id = UUID()
    public var kind: Kind
    public var text: String
}

/// 코멘트의 그림 — `![설명](주소)` 또는 `<img src=… width=… alt=…>`.
public struct MarkdownImage: Equatable, Sendable {
    public var url: URL
    public var alt: String
    /// `<img width="600">` 의 폭(pt). 없으면 그림 크기대로(칸 폭까지) 그린다.
    public var width: Double?
    /// 그림을 감싼 링크(`[![…](그림)](링크)`·`<a href>`). 누르면 이 주소를, 없으면 그림 주소를 연다.
    public var link: URL?
}

/// GitHub 표(GFM). 머리 줄 바로 아래 `|---|:---:|` 구분 줄이 와야 표다.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    public var header: [String]
    public var alignments: [Alignment]
    /// 칸 수는 머리 줄에 맞춘다 — 모자라면 빈칸을 채우고 넘치면 버린다(GitHub 과 같다).
    public var rows: [[String]] = []

    /// 머리 줄과 그 아래 줄이 표의 시작이면 만든다. 구분 줄의 칸 수가 머리와 같아야 한다.
    init?(headerLine: String, delimiterLine: String) {
        guard headerLine.contains("|"), delimiterLine.contains("|") else {
            return nil
        }
        let marks = Self.cells(delimiterLine)
        let header = Self.cells(headerLine)
        guard header.count == marks.count,
              marks.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else {
            return nil
        }
        self.header = header
        alignments = marks.map { mark in
            switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    mutating func appendRow(_ line: String) {
        let cells = Self.cells(line)
        rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
    }

    /// 줄을 칸으로 자른다. 양 끝 `|` 는 있어도 없어도 되고, `\|` 는 칸을 나누지 않는 글자 `|` 다.
    /// GitHub 처럼 인라인 코드 안의 `|` 도 칸을 나눈다 — 코드 안에 쓰려면 `\|` 로 쓴다.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") {
            body = body.dropFirst()
        }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") {
            body = body.dropLast()
        }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                // 줄 안 서식이 `\*` 같은 이스케이프를 읽도록 `|` 가 아닌 글자 앞의 `\` 는 남긴다.
                if character != "|" {
                    current.append("\\")
                }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

public enum MarkdownParser {
    public static func blocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        // GitHub 봇들이 남기는 <!-- 마커 --> 는 화면에 보일 이유가 없다.
        var inHTMLComment = false
        var codeLanguage: String?
        var inCode = false
        var table: MarkdownTable?

        /// 쌓던 문단(또는 표)을 블록으로 내보낸다.
        func flushParagraph() {
            if let finished = table {
                blocks.append(MarkdownBlock(kind: .table(finished), text: ""))
                table = nil
            }
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            guard !joined.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph, text: joined))
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inHTMLComment {
                if trimmed.contains("-->") { inHTMLComment = false }
                continue
            }
            if trimmed.hasPrefix("<!--") {
                if !trimmed.contains("-->") { inHTMLComment = true }
                continue
            }

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(MarkdownBlock(kind: .code(language: codeLanguage),
                                                text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            // 표는 `|` 가 든 줄이 이어지는 동안 계속된다. 빈 줄이나 `|` 없는 줄에서 끝난다.
            if table != nil {
                if trimmed.contains("|") {
                    table?.appendRow(trimmed)
                    continue
                }
                flushParagraph()
            }
            // 구분 줄을 만나야 바로 앞 줄이 표 머리였다는 걸 안다 — 문단에 넣어 둔 그 줄을 도로 꺼낸다.
            if let headerLine = paragraph.last,
               let started = MarkdownTable(headerLine: headerLine, delimiterLine: trimmed) {
                paragraph.removeLast()
                flushParagraph()
                table = started
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .rule, text: ""))
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(MarkdownBlock(kind: .heading(level: hashes),
                                                text: String(trimmed.dropFirst(hashes + 1))))
                    continue
                }
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote, text: String(trimmed.dropFirst(2))))
                continue
            }
            if let marker = bulletMarker(trimmed) {
                flushParagraph()
                let indent = indentLevel(line)
                let item = String(trimmed.dropFirst(marker))
                if let (done, rest) = taskMarker(item) {
                    blocks.append(MarkdownBlock(kind: .task(indent: indent, done: done), text: rest))
                } else {
                    blocks.append(MarkdownBlock(kind: .bullet(indent: indent), text: item))
                }
                continue
            }
            if let (number, prefixLength) = orderedMarker(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .ordered(number: number, indent: indentLevel(line)),
                                            text: String(trimmed.dropFirst(prefixLength))))
                continue
            }
            // 그림만 있는 줄은 그림 블록. 글과 섞인 그림은 문단에 남아 설명 글로 보인다.
            if let images = imageLine(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .images(images), text: ""))
                continue
            }
            paragraph.append(line)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(MarkdownBlock(kind: .code(language: codeLanguage),
                                        text: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        renumberOrderedLists(&blocks)
        return blocks
    }

    /// GitHub 처럼 번호는 목록 첫 항목의 번호부터 하나씩 늘린다 — `1.` 만 되풀이해 써도 1·2·3 으로 보인다.
    /// 같은 단계의 번호 항목이 이어지는 동안(사이에 더 깊은 항목이 와도) 한 목록이다. 같거나 얕은 단계의 글머리
    /// 항목, 또는 목록이 아닌 블록이 오면 끝난다.
    private static func renumberOrderedLists(_ blocks: inout [MarkdownBlock]) {
        var next: [Int: Int] = [:]
        for index in blocks.indices {
            switch blocks[index].kind {
            case .ordered(let number, let indent):
                let shown = next[indent] ?? number
                blocks[index].kind = .ordered(number: shown, indent: indent)
                next = next.filter { $0.key < indent }
                next[indent] = shown + 1
            case .bullet(let indent), .task(let indent, _):
                next = next.filter { $0.key < indent }
            default:
                next.removeAll()
            }
        }
    }

    private static func bulletMarker(_ trimmed: String) -> Int? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return marker.count
        }
        return nil
    }

    /// 줄 전체가 그림(들)이면 그 그림들. 그림을 감싸는 링크·`<p align>`·`<a>`·`<br>` 태그는 있어도 된다.
    /// 그 밖의 글이 하나라도 있거나 주소가 온전하지 않으면 nil.
    static func imageLine(_ trimmed: String) -> [MarkdownImage]? {
        guard let first = trimmed.first, "![<".contains(first) else {
            return nil
        }
        // `[![설명](그림)](링크)` · `![설명](그림 "제목")` · `<img …>` · 감싸는 태그.
        let linked = #"^\[!\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#
        let plain = #"^!\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#
        let tag = #"^<img\b[^>]*>"#
        let wrapper = #"^</?(?:p|div|a|br|picture|source)\b[^>]*>"#

        var images: [MarkdownImage] = []
        var rest = trimmed[...]
        var wrappingLink: URL?
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else {
                break
            }
            if let groups = match(linked, in: rest, consuming: &rest) {
                guard let url = URL(string: groups[2]) else {
                    return nil
                }
                images.append(MarkdownImage(url: url, alt: groups[1], link: URL(string: groups[3])))
            } else if let groups = match(plain, in: rest, consuming: &rest) {
                guard let url = URL(string: groups[2]) else {
                    return nil
                }
                images.append(MarkdownImage(url: url, alt: groups[1], link: wrappingLink))
            } else if let groups = match(tag, in: rest, consuming: &rest) {
                let attributes = htmlAttributes(groups[0])
                guard let source = attributes["src"], let url = URL(string: source) else {
                    return nil
                }
                images.append(MarkdownImage(url: url, alt: attributes["alt"] ?? "",
                                            width: attributes["width"].flatMap(Double.init), link: wrappingLink))
            } else if let groups = match(wrapper, in: rest, consuming: &rest) {
                let opening = groups[0].lowercased()
                if opening.hasPrefix("<a") {
                    wrappingLink = htmlAttributes(groups[0])["href"].flatMap(URL.init(string:))
                } else if opening.hasPrefix("</a") {
                    wrappingLink = nil
                }
            } else {
                return nil
            }
        }
        return images.isEmpty ? nil : images
    }

    /// `text` 맨 앞이 `pattern` 에 맞으면 잡은 묶음들(0 = 전체)을 주고 `rest` 를 그 뒤로 옮긴다.
    private static func match(_ pattern: String, in text: Substring, consuming rest: inout Substring) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let source = String(text)
        let whole = NSRange(source.startIndex..., in: source)
        guard let found = regex.firstMatch(in: source, options: [.anchored], range: whole),
              let matched = Range(found.range, in: source) else {
            return nil
        }
        rest = text.dropFirst(source.distance(from: source.startIndex, to: matched.upperBound))
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: source).map { String(source[$0]) } ?? ""
        }
    }

    /// HTML 태그의 속성(이름은 소문자). 따옴표 없는 값도 읽는다. `&amp;` 만 푼다 — 주소에 흔하다.
    private static func htmlAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else {
            return [:]
        }
        var attributes: [String: String] = [:]
        for found in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(found.range(at: 1), in: tag) else {
                continue
            }
            let value = (2...4).lazy.compactMap { Range(found.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            attributes[tag[name].lowercased()] = value.replacingOccurrences(of: "&amp;", with: "&")
        }
        return attributes
    }

    /// 목록 항목 맨 앞 `[ ] `·`[x] `. GitHub 처럼 상자 뒤에 빈칸이 있어야 한다(`[x]글` 은 그냥 글).
    private static func taskMarker(_ item: String) -> (done: Bool, rest: String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(marker) {
            return (done, String(item.dropFirst(marker.count)))
        }
        return nil
    }

    /// `1. ` 과 `1) ` 둘 다 번호다(GitHub 과 같다).
    private static func orderedMarker(_ trimmed: String) -> (Int, Int)? {
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, digits.count + 2)
    }

    /// 목록 줄의 들여쓰기 단계. 빈칸 둘을 한 단계로 친다 — 번호 아래 항목(`1. ` 뒤 세 칸)도 한 단계가 된다.
    /// 탭은 빈칸 넷이다. 화면이 너무 밀리지 않게 세 단계에서 멈춘다.
    private static func indentLevel(_ line: String) -> Int {
        let spaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return min(spaces / 2, 3)
    }
}
