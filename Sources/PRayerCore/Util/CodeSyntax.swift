import Foundation

/// 파일 종류별 색칠 규칙. 컴파일러 수준의 정확도가 아니라 "읽기 편한 정도" 가 목적이다.
public struct SyntaxProfile: Sendable, Hashable {
    /// 캐시 키로도 쓴다.
    public var id: String
    public var lineComments: [String]
    public var blockComment: BlockComment?
    public var stringDelimiters: [Character]
    /// Swift 의 """ 처럼 세 겹 따옴표를 쓰는가.
    public var tripleQuoted: Bool
    public var keywords: Set<String>
    /// 대문자로 시작하는 식별자를 타입으로 볼 것인가(Swift·ObjC·Java 계열).
    public var capitalizedIsType: Bool
    public var attributePrefixes: [Character]

    // 아래는 마크다운 코드 블록 프로파일(CodeSyntax+Languages)만 쓴다. 기본값이면 예전 스캐너와 똑같이 칠한다 —
    // 변경 파일 탭의 diff 화면 프로파일은 이 값을 쓰지 않아 모양이 그대로다.
    /// 키워드보다 먼저 보는 값(true·nil…). 이 칸에 있으면 `.constant`.
    public var constants: Set<String> = []
    /// 소문자라도 타입으로 칠할 이름(int·string·u32…).
    public var types: Set<String> = []
    /// SQL 처럼 대소문자를 가리지 않는 키워드인가.
    public var caseInsensitive = false
    /// 바로 뒤에 `(` 가 오는 이름을 함수로 칠하는가.
    public var marksFunctions = false
    /// 이 글자 앞의 이름·문자열을 키로 친다(JSON·CSS·YAML 은 `:`, HTML 속성은 `=`).
    public var keyMarker: Character?
    public var keyKind: SyntaxKind = .property
    /// CSS 속성·YAML 키처럼 이름 안에 `-` 가 들어가는가.
    public var hyphenatedWords = false
    /// `<이름` 의 이름을 태그로 칠하는가(HTML·XML).
    public var marksTags = false
    /// ```diff — 줄 머리(`+`·`-`·`@@`)로만 칠한다.
    public var isDiff = false

    public struct BlockComment: Sendable, Hashable {
        public var open: String
        public var close: String
        public var nests: Bool
    }
}

public enum CodeSyntax {
    // MARK: - 프로파일

    public static let swift = SyntaxProfile(
        id: "swift",
        lineComments: ["//"],
        blockComment: .init(open: "/*", close: "*/", nests: true),
        stringDelimiters: ["\""],
        tripleQuoted: true,
        keywords: SwiftSyntax.keywords,
        capitalizedIsType: true,
        attributePrefixes: ["@"])

    public static let cLike = SyntaxProfile(
        id: "clike",
        lineComments: ["//"],
        blockComment: .init(open: "/*", close: "*/", nests: false),
        stringDelimiters: ["\"", "'"],
        tripleQuoted: false,
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
            "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
            "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
            "unsigned", "void", "volatile", "while", "bool", "true", "false", "nil", "NULL", "nullable",
            "nonnull", "id", "self", "super", "instancetype", "class", "public", "private", "protected",
            "interface", "implementation", "protocol", "property", "synthesize", "import", "include",
            "new", "delete", "this", "namespace", "template", "typename", "using", "try", "catch",
            "throw", "final", "override", "virtual", "let", "var", "func", "fun", "val", "async",
            "await", "export", "import", "function", "const", "yield", "package", "extends", "implements",
        ],
        capitalizedIsType: true,
        attributePrefixes: ["@", "#"])

    public static let script = SyntaxProfile(
        id: "script",
        lineComments: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        tripleQuoted: false,
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in",
            "function", "return", "local", "export", "set", "echo", "exit", "source", "and", "or",
            "not", "def", "class", "import", "from", "as", "with", "try", "except", "finally", "pass",
            "raise", "lambda", "None", "True", "False", "end", "module", "require", "yield", "unless",
            "elsif", "begin", "rescue", "ensure", "self", "nil", "true", "false", "null",
        ],
        capitalizedIsType: false,
        attributePrefixes: [])

    public static let json = SyntaxProfile(
        id: "json",
        lineComments: [],
        blockComment: nil,
        stringDelimiters: ["\""],
        tripleQuoted: false,
        keywords: ["true", "false", "null"],
        capitalizedIsType: false,
        attributePrefixes: [])

    public static let markup = SyntaxProfile(
        id: "markup",
        lineComments: [],
        blockComment: .init(open: "<!--", close: "-->", nests: false),
        stringDelimiters: ["\"", "'"],
        tripleQuoted: false,
        keywords: [],
        capitalizedIsType: false,
        attributePrefixes: [])

    /// 파일 경로로 프로파일을 고른다. 모르는 확장자는 색칠하지 않는다(잘못 칠하는 것보다 낫다).
    public static func profile(forPath path: String) -> SyntaxProfile? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            // Podfile, Gemfile, Fastfile, Makefile 처럼 확장자가 없는 것들.
            let known = ["podfile", "gemfile", "fastfile", "makefile", "rakefile", "brewfile", "dockerfile"]
            return known.contains(name.lowercased()) ? script : nil
        }
        return profile(forExtension: ext)
    }

    public static func profile(forExtension ext: String) -> SyntaxProfile? {
        switch ext.lowercased() {
        case "swift": return swift
        case "h", "m", "mm", "c", "cc", "cpp", "hpp", "java", "kt", "kts", "js", "jsx", "ts", "tsx",
             "go", "rs", "scala", "groovy", "gradle", "cs", "php":
            return cLike
        case "sh", "bash", "zsh", "rb", "py", "yml", "yaml", "toml", "cfg", "conf", "ini", "env",
             "podspec", "gemspec", "properties":
            return script
        case "json", "jsonc", "lock":
            return json
        case "xml", "html", "htm", "plist", "storyboard", "xib", "svg", "xcscheme", "entitlements", "pbxproj":
            return markup
        default:
            return nil
        }
    }

    /// 언어 태그(마크다운 펜스 등)로 프로파일을 고른다. 코드 블록용 언어별 프로파일을 먼저 본다(CodeSyntax+Languages).
    public static func profile(forLanguage language: String?) -> SyntaxProfile? {
        guard let language else { return nil }
        let normalized = language.trimmingCharacters(in: .whitespaces).lowercased()
        if let fence = fenceProfile(forLanguage: normalized) {
            return fence
        }
        switch normalized {
        case "swift": return swift
        case "objc", "objective-c", "c", "cpp", "c++", "java", "kotlin", "js", "javascript",
             "ts", "typescript", "go", "rust":
            return cLike
        case "sh", "bash", "zsh", "shell", "console", "ruby", "python", "py", "yaml", "yml":
            return script
        case "json": return json
        case "xml", "html", "plist": return markup
        default: return profile(forExtension: normalized)
        }
    }

    // MARK: - 스캐너

    /// 한 줄씩 색칠하되 블록 주석 상태만 다음 줄로 넘긴다.
    /// diff 는 줄이 연속이 아니라 전체를 한 덩어리로 파싱할 수 없다.
    public static func highlight(lines: [String], profile: SyntaxProfile) -> [[SyntaxSpan]] {
        var inBlockComment = false
        var result: [[SyntaxSpan]] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            let (spans, ended) = spans(in: line, profile: profile, startingInBlockComment: inBlockComment)
            inBlockComment = ended
            result.append(spans)
        }
        return result
    }

    public static func spans(in source: String, profile: SyntaxProfile) -> [SyntaxSpan] {
        spans(in: source, profile: profile, startingInBlockComment: false).spans
    }

    static func spans(in source: String,
                      profile: SyntaxProfile,
                      startingInBlockComment: Bool) -> (spans: [SyntaxSpan], endsInBlockComment: Bool) {
        if profile.isDiff {
            return (diffSpans(in: source), false)
        }
        let characters = Array(source)
        var spans: [SyntaxSpan] = []
        var index = 0
        var blockDepth = startingInBlockComment ? 1 : 0

        func matches(_ token: String, at position: Int) -> Bool {
            let tokenCharacters = Array(token)
            guard position + tokenCharacters.count <= characters.count else { return false }
            for (offset, character) in tokenCharacters.enumerated()
            where characters[position + offset] != character { return false }
            return true
        }

        /// 빈칸·탭을 건너뛴 다음 글자. 키(`이름:`)를 가릴 때 쓴다.
        func nextNonSpace(after position: Int) -> Character? {
            var cursor = position
            while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" { cursor += 1 }
            return cursor < characters.count ? characters[cursor] : nil
        }

        // 이전 줄에서 열린 블록 주석을 닫는다.
        if blockDepth > 0, let block = profile.blockComment {
            let start = index
            while index < characters.count {
                if block.nests, matches(block.open, at: index) {
                    blockDepth += 1
                    index += block.open.count
                    continue
                }
                if matches(block.close, at: index) {
                    blockDepth -= 1
                    index += block.close.count
                    if blockDepth == 0 { break }
                    continue
                }
                index += 1
            }
            spans.append(SyntaxSpan(start: start, length: index - start, kind: .comment))
        }

        var lastIndex = -1
        while index < characters.count {
            // 어느 갈래든 한 바퀴에 한 글자는 먹어야 한다. 못 먹은 갈래가 생기면 같은 자리를 영원히 돌아
            // 화면 전체가 멈춘다(위 숫자 갈래 실측). 그런 갈래가 다시 생겨도 한 글자 건너뛰고 지나가게 막는다.
            if index == lastIndex {
                index += 1
                continue
            }
            lastIndex = index
            let character = characters[index]

            if profile.lineComments.contains(where: { matches($0, at: index) }) {
                // 여러 줄을 한 번에 받을 수도 있다(마크다운 코드 블록). 줄 끝에서 끊는다.
                let start = index
                while index < characters.count, characters[index] != "\n" { index += 1 }
                spans.append(SyntaxSpan(start: start, length: index - start, kind: .comment))
                continue
            }

            if let block = profile.blockComment, matches(block.open, at: index) {
                let start = index
                blockDepth = 1
                index += block.open.count
                while index < characters.count {
                    if block.nests, matches(block.open, at: index) {
                        blockDepth += 1
                        index += block.open.count
                        continue
                    }
                    if matches(block.close, at: index) {
                        blockDepth -= 1
                        index += block.close.count
                        if blockDepth == 0 { break }
                        continue
                    }
                    index += 1
                }
                spans.append(SyntaxSpan(start: start, length: index - start, kind: .comment))
                continue
            }

            if profile.stringDelimiters.contains(character) {
                let start = index
                if profile.tripleQuoted,
                   index + 2 < characters.count,
                   characters[index + 1] == character, characters[index + 2] == character {
                    index += 3
                    while index < characters.count {
                        if characters[index] == character,
                           index + 2 < characters.count,
                           characters[index + 1] == character, characters[index + 2] == character {
                            index += 3
                            break
                        }
                        index += 1
                    }
                } else {
                    index += 1
                    while index < characters.count {
                        if characters[index] == "\\" { index += 2; continue }
                        if characters[index] == character { index += 1; break }
                        // 닫히지 않은 문자열이 다음 줄까지 먹지 않게 한다.
                        if characters[index] == "\n" { break }
                        index += 1
                    }
                }
                // JSON 키: 문자열 바로 뒤(빈칸 건너) `:` 가 오면 키다.
                let isKey = profile.keyMarker.map { nextNonSpace(after: index) == $0 } ?? false
                spans.append(SyntaxSpan(start: start, length: index - start, kind: isKey ? profile.keyKind : .string))
                continue
            }

            // `<div`·`</div` 의 태그 이름. `<` 자체는 칠하지 않는다.
            if profile.marksTags, character == "<" {
                var nameStart = index + 1
                if nameStart < characters.count, "/?!".contains(characters[nameStart]) { nameStart += 1 }
                if nameStart < characters.count, isIdentifierHead(characters[nameStart]) {
                    var end = nameStart
                    while end < characters.count, isIdentifier(characters[end]) || ":-.".contains(characters[end]) { end += 1 }
                    spans.append(SyntaxSpan(start: nameStart, length: end - nameStart, kind: .tag))
                    index = end
                    continue
                }
            }

            if profile.attributePrefixes.contains(character) {
                let start = index
                index += 1
                while index < characters.count, isIdentifier(characters[index]) { index += 1 }
                if index > start + 1 {
                    spans.append(SyntaxSpan(start: start, length: index - start, kind: .attribute))
                    continue
                }
                continue
            }

            // 숫자는 ASCII 숫자로 시작할 때만 본다. `Character.isNumber` 는 ①·½·²·三·Ⅷ 같은 글자에도 참인데,
            // 아래 반복은 16진 숫자만 먹어서 한 글자도 못 나아가고 같은 자리에서 영원히 돌며 빈 구간을 쌓았다
            // (실측: 마크다운 줄 "응답 순서(① → ⑤)" 를 그리다 앱이 멈추고 메모리가 초당 수십 MB 씩 늘었다).
            if character.isASCII, character.isNumber, index == 0 || !isIdentifier(characters[index - 1]) {
                let start = index
                while index < characters.count,
                      characters[index].isHexDigit || characters[index] == "." || characters[index] == "_"
                        || "xXbBoOeE".contains(characters[index]) {
                    index += 1
                }
                spans.append(SyntaxSpan(start: start, length: index - start, kind: .number))
                continue
            }

            if isIdentifierHead(character) {
                let start = index
                while index < characters.count {
                    if isIdentifier(characters[index]) {
                        index += 1
                    } else if profile.hyphenatedWords, characters[index] == "-",
                              index + 1 < characters.count, isIdentifier(characters[index + 1]) {
                        index += 1
                    } else {
                        break
                    }
                }
                let word = String(characters[start..<index])
                if let kind = wordKind(word, profile: profile, next: nextNonSpace(after: index),
                                       opensCall: index < characters.count && characters[index] == "(") {
                    spans.append(SyntaxSpan(start: start, length: index - start, kind: kind))
                }
                continue
            }

            index += 1
        }
        return (spans, blockDepth > 0)
    }

    /// 이름 하나의 종류. 기본 프로파일(새 칸이 모두 기본값)이면 키워드·대문자 타입만 — 예전과 같다.
    private static func wordKind(_ word: String, profile: SyntaxProfile, next: Character?, opensCall: Bool) -> SyntaxKind? {
        if let marker = profile.keyMarker, next == marker {
            return profile.keyKind
        }
        let lookup = profile.caseInsensitive ? word.lowercased() : word
        if profile.constants.contains(lookup) {
            return .constant
        }
        if profile.keywords.contains(lookup) {
            return .keyword
        }
        if profile.types.contains(lookup) {
            return .type
        }
        if profile.capitalizedIsType, let first = word.first, first.isUppercase {
            return .type
        }
        if profile.marksFunctions, opensCall {
            return .function
        }
        return nil
    }

    /// ```diff 블록. 줄 머리로만 나눈다 — `+++`·`---` 파일 줄과 `@@` 줄은 머리 줄, `+` 는 더한 줄, `-` 는 뺀 줄.
    static func diffSpans(in source: String) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var offset = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.count
            let kind: SyntaxKind? = if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                .meta
            } else if line.hasPrefix("+") {
                .inserted
            } else if line.hasPrefix("-") {
                .deleted
            } else {
                nil
            }
            if let kind, length > 0 {
                spans.append(SyntaxSpan(start: offset, length: length, kind: kind))
            }
            offset += length + 1
        }
        return spans
    }

    static func isIdentifierHead(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
