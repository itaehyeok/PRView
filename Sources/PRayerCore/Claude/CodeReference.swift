import Foundation

/// 코멘트 본문에 나온 코드·파일 언급 중, 이번 diff 안에서 위치를 찾을 수 있는 것.
public struct CodeReference: Sendable, Hashable, Identifiable {
    public var path: String
    public var line: Int?
    /// 화면에 보일 짧은 이름.
    public var label: String
    public var id: String { "\(path)#\(line ?? -1)#\(label)" }

    public init(path: String, line: Int?, label: String) {
        self.path = path
        self.line = line
        self.label = label
    }
}

public enum CodeReferenceScanner {
    /// 코멘트 속 인라인 코드 한 조각(`파일명`·`파일명:줄`·`심볼`)을 diff 안 위치로 바꾼다.
    /// diff 에서 못 찾으면 nil — 눌러도 갈 곳이 없으면 링크로 만들 이유가 없다.
    public static func reference(forCode code: String, in diff: ParsedDiff) -> CodeReference? {
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, !diff.files.isEmpty else { return nil }

        // 1) 파일 이름. 경로째(`Sources/Foo.swift`) 써도, "Foo.swift:516"·"Foo.swift#L516" 처럼 줄 번호가 붙어도 잡는다.
        for file in diff.files {
            let name = (file.path as NSString).lastPathComponent
            guard !name.isEmpty, let range = code.range(of: name) else { continue }
            let before = code[..<range.lowerBound]
            guard before.isEmpty || before.hasSuffix("/") else { continue }
            let line = trailingLineNumber(in: code, after: range.upperBound)
            guard range.upperBound == code.endIndex || line != nil else { continue }
            return CodeReference(path: file.path, line: line, label: code)
        }

        // 2) 심볼. `didChange(previous:current:)` 처럼 인자를 붙여 쓰면 이름만 본다.
        let symbol = code.split(separator: "(", maxSplits: 1).first.map(String.init) ?? code
        guard symbol.count >= 4, symbol.allSatisfy(isSymbolCharacter), symbol.contains(where: \.isLetter),
              !keywords.contains(symbol),
              let hit = firstOccurrence(of: symbol, in: diff) else { return nil }
        return CodeReference(path: hit.path, line: hit.line, label: code)
    }

    /// 어느 diff 에나 흔한 예약어 — `guard` 를 눌러 첫 guard 로 가 봐야 쓸모가 없다.
    static let keywords: Set<String> = [
        "guard", "return", "private", "fileprivate", "public", "internal", "static", "final", "override",
        "func", "class", "struct", "enum", "protocol", "extension", "import", "self", "Self", "super",
        "async", "await", "throws", "throw", "true", "false", "else", "switch", "case", "default",
        "break", "continue", "while", "repeat", "weak", "unowned", "lazy", "let", "var", "init", "deinit",
        "null", "const", "function", "interface", "void", "this", "@MainActor", "@objc",
    ]

    static func isSymbolCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == "$"
            || character == "@"
    }

    /// `:516` 또는 `#L516` 형태의 줄 번호.
    static func trailingLineNumber(in text: String, after index: String.Index) -> Int? {
        var cursor = index
        guard cursor < text.endIndex else { return nil }
        if text[cursor] == ":" {
            cursor = text.index(after: cursor)
        } else if text[cursor] == "#", text.index(after: cursor) < text.endIndex,
                  text[text.index(after: cursor)] == "L" {
            cursor = text.index(cursor, offsetBy: 2)
        } else {
            return nil
        }
        var digits = ""
        while cursor < text.endIndex, text[cursor].isNumber {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return Int(digits)
    }

    /// diff 안에서 심볼이 처음 나오는 위치. 새 코드(추가·문맥)만 본다.
    static func firstOccurrence(of symbol: String, in diff: ParsedDiff) -> (path: String, line: Int?)? {
        for file in diff.files {
            for line in file.lines where line.kind == .addition || line.kind == .context {
                if containsWord(symbol, in: line.text) {
                    return (file.path, line.newLine)
                }
            }
        }
        return nil
    }

    /// 낱말 단위로 찾는다 — `load` 가 `loadTask` 안에서 걸리면 엉뚱한 줄로 간다.
    static func containsWord(_ word: String, in text: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let headOK = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let tailOK = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
            if headOK, tailOK { return true }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
