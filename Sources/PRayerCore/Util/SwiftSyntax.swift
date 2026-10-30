import Foundation

/// 코드 블록 색칠용 최소 토크나이저. 컴파일러 수준의 정확도가 목적이 아니라
/// "읽기 편한 정도" 가 목적이다. 스캐너 한 번으로 끝내 큰 diff 에서도 부담이 없다.
public enum SyntaxKind: String, Sendable, Hashable {
    case keyword
    case type
    case string
    case number
    case comment
    case attribute
    /// 아래는 마크다운 코드 블록 프로파일(CodeSyntax+Languages)만 낸다. diff 화면 프로파일은 내지 않는다.
    /// `name(` 의 이름.
    case function
    /// true·nil·None 같은 값.
    case constant
    /// JSON·CSS 의 키, HTML 의 속성 이름.
    case property
    /// HTML 태그 이름, YAML 키.
    case tag
    /// ```diff 의 `+` 줄 · `-` 줄 · `@@` 줄.
    case inserted
    case deleted
    case meta
    case plain
}

public struct SyntaxSpan: Sendable, Hashable {
    /// 문자(Character) 기준 오프셋.
    public var start: Int
    public var length: Int
    public var kind: SyntaxKind

    public init(start: Int, length: Int, kind: SyntaxKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }
}

public enum SwiftSyntax {
    public static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
        "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
        "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
        "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
        "as", "await", "any", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
        "async", "some", "consuming", "borrowing", "each", "macro", "actor", "nonisolated", "isolated",
        "lazy", "weak", "unowned", "mutating", "nonmutating", "final", "override", "required",
        "convenience", "indirect", "optional", "dynamic", "get", "set", "willSet", "didSet",
    ]

    /// 언어 태그가 Swift 인가. 마크다운 펜스의 ```swift 를 그대로 받는다.
    public static func isSwift(_ language: String?) -> Bool {
        guard let language else { return false }
        let normalized = language.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "swift"
    }

    /// 색칠할 구간만 돌려준다. 나머지는 기본색으로 그리면 된다.
    public static func spans(in source: String) -> [SyntaxSpan] {
        CodeSyntax.spans(in: source, profile: CodeSyntax.swift)
    }
}
