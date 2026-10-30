import Foundation

/// 마크다운 코드 블록(```언어)용 언어별 프로파일.
///
/// 예전에는 Kotlin·TS·Go·Rust 가 C 계열 키워드 한 벌로 뭉쳐 있었고, diff·CSS·SQL 은 칠하지 않았다(사용자 요청으로 늘림,
/// 2026-10-28). 색은 화면(SyntaxColors 의 GitHub 팔레트)이 정한다. 변경 파일 탭의 diff 화면은 여기를 쓰지 않는다 —
/// 파일 확장자로 고르는 `profile(forPath:)` 는 그대로다.
extension CodeSyntax {
    /// 펜스 언어 이름(소문자) → 프로파일. 모르는 이름은 nil(그러면 예전 규칙으로 고른다).
    static func fenceProfile(forLanguage language: String) -> SyntaxProfile? {
        switch language {
        case "swift": return Fence.swift
        case "objc", "objective-c", "objectivec", "obj-c", "objective-c++": return Fence.objc
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh": return Fence.cpp
        case "java", "groovy", "gradle", "dart", "cs", "csharp", "c#", "scala": return Fence.java
        case "kotlin", "kt", "kts": return Fence.kotlin
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return Fence.javascript
        case "ts", "typescript", "tsx", "mts", "cts": return Fence.typescript
        case "go", "golang": return Fence.go
        case "rust", "rs": return Fence.rust
        case "python", "py", "python3": return Fence.python
        case "ruby", "rb", "podfile", "gemfile", "fastfile": return Fence.ruby
        case "sh", "bash", "zsh", "shell", "console", "shellsession", "terminal", "dockerfile": return Fence.shell
        case "yaml", "yml": return Fence.yaml
        case "json", "jsonc", "json5", "geojson": return Fence.json
        case "xml", "html", "htm", "xhtml", "plist", "svg", "vue": return Fence.markup
        case "css", "scss", "less", "sass": return Fence.css
        case "sql", "mysql", "postgresql", "postgres", "psql", "sqlite", "plsql", "tsql": return Fence.sql
        case "diff", "patch", "udiff": return Fence.diff
        default: return nil
        }
    }

    /// `get`·`set` 은 속성 접근자에서만 키워드라 넣지 않는다 — 넣으면 `map.get(key)` 의 get 이 키워드 색이 됐다.
    enum Fence {
        static let swift: SyntaxProfile = {
            var profile = CodeSyntax.swift
            profile.id = "fence-swift"
            profile.keywords.subtract(["true", "false", "nil"])
            profile.constants = ["true", "false", "nil"]
            profile.marksFunctions = true
            return profile
        }()

        private static let cKeywords: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
            "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
            "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
            "volatile", "while", "bool",
        ]

        static let objc = SyntaxProfile(
            id: "fence-objc", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: cKeywords.union([
                "id", "self", "super", "instancetype", "nonatomic", "atomic", "strong", "weak", "copy", "assign",
                "readonly", "readwrite", "nullable", "nonnull", "__weak", "__strong", "__block", "in", "typeof",
            ]),
            capitalizedIsType: true, attributePrefixes: ["@", "#"],
            constants: ["YES", "NO", "nil", "Nil", "NULL", "true", "false"],
            marksFunctions: true)

        static let cpp = SyntaxProfile(
            id: "fence-cpp", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: cKeywords.union([
                "class", "namespace", "template", "typename", "using", "public", "private", "protected", "virtual",
                "override", "final", "new", "delete", "this", "throw", "try", "catch", "operator", "friend",
                "explicit", "mutable", "constexpr", "noexcept", "static_cast", "dynamic_cast", "reinterpret_cast",
                "const_cast", "decltype",
            ]),
            capitalizedIsType: true, attributePrefixes: ["#"],
            constants: ["true", "false", "NULL", "nullptr"],
            types: ["size_t", "string", "vector", "map", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                    "int8_t", "int16_t", "int32_t", "int64_t"],
            marksFunctions: true)

        static let java = SyntaxProfile(
            id: "fence-java", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["\"", "'"], tripleQuoted: true,
            keywords: [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "continue",
                "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if",
                "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package",
                "private", "protected", "public", "return", "short", "static", "super", "switch", "synchronized",
                "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record",
                "sealed", "permits", "yield", "def", "async", "await", "late", "required", "namespace", "using",
                "override", "readonly",
            ],
            capitalizedIsType: true, attributePrefixes: ["@"],
            constants: ["true", "false", "null"],
            marksFunctions: true)

        static let kotlin = SyntaxProfile(
            id: "fence-kotlin", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: true),
            stringDelimiters: ["\"", "'"], tripleQuoted: true,
            keywords: [
                "as", "break", "class", "continue", "do", "else", "for", "fun", "if", "in", "interface", "is",
                "object", "package", "return", "super", "this", "throw", "try", "typealias", "val", "var", "when",
                "while", "by", "catch", "constructor", "finally", "import", "init", "where",
                "abstract", "annotation", "companion", "const", "crossinline", "data", "enum", "external", "final",
                "infix", "inline", "inner", "internal", "lateinit", "noinline", "open", "operator", "out",
                "override", "private", "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg",
                "value",
            ],
            capitalizedIsType: true, attributePrefixes: ["@"],
            constants: ["true", "false", "null"],
            marksFunctions: true)

        private static let jsKeywords: Set<String> = [
            "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
            "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let",
            "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with",
            "yield", "async", "await", "of", "static", "from", "as",
        ]

        static let javascript = SyntaxProfile(
            id: "fence-js", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["\"", "'", "`"], tripleQuoted: false,
            keywords: jsKeywords,
            capitalizedIsType: true, attributePrefixes: ["@"],
            constants: ["true", "false", "null", "undefined", "NaN", "Infinity"],
            marksFunctions: true)

        static let typescript: SyntaxProfile = {
            var profile = javascript
            profile.id = "fence-ts"
            profile.keywords.formUnion([
                "interface", "type", "enum", "implements", "namespace", "declare", "readonly", "abstract",
                "private", "protected", "public", "keyof", "infer", "is", "asserts", "satisfies", "override",
                "module",
            ])
            profile.types = ["string", "number", "boolean", "any", "unknown", "never", "void", "object",
                             "bigint", "symbol"]
            return profile
        }()

        static let go = SyntaxProfile(
            id: "fence-go", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["\"", "'", "`"], tripleQuoted: false,
            keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
                "struct", "switch", "type", "var",
            ],
            // Go 는 대문자가 "밖으로 보이는 이름" 이라 타입으로 칠하지 않는다.
            capitalizedIsType: false, attributePrefixes: [],
            constants: ["true", "false", "nil", "iota"],
            types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8",
                    "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64",
                    "uintptr", "any"],
            marksFunctions: true)

        static let rust = SyntaxProfile(
            id: "fence-rust", lineComments: ["//"], blockComment: .init(open: "/*", close: "*/", nests: true),
            // `'a` 수명 표기가 문자 리터럴처럼 줄 끝까지 먹지 않게 작은따옴표는 문자열로 보지 않는다.
            stringDelimiters: ["\""], tripleQuoted: false,
            keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
                "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where",
                "while",
            ],
            capitalizedIsType: true, attributePrefixes: [],
            constants: ["true", "false", "None", "Some", "Ok", "Err"],
            types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
                    "f64", "bool", "char", "str"],
            marksFunctions: true)

        static let python = SyntaxProfile(
            id: "fence-python", lineComments: ["#"], blockComment: nil,
            stringDelimiters: ["\"", "'"], tripleQuoted: true,
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match",
                "case", "self",
            ],
            capitalizedIsType: true, attributePrefixes: ["@"],
            constants: ["True", "False", "None"],
            types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"],
            marksFunctions: true)

        static let ruby = SyntaxProfile(
            id: "fence-ruby", lineComments: ["#"], blockComment: nil,
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: [
                "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure",
                "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self",
                "super", "then", "undef", "unless", "until", "when", "while", "yield", "require",
                "require_relative", "attr_accessor", "attr_reader", "attr_writer", "private", "protected",
                "public", "lambda", "proc",
            ],
            // `:name` 심볼.
            capitalizedIsType: true, attributePrefixes: [":"],
            constants: ["true", "false", "nil"],
            marksFunctions: true)

        static let shell = SyntaxProfile(
            id: "fence-shell", lineComments: ["#"], blockComment: nil,
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                "function", "return", "local", "export", "readonly", "declare", "set", "unset", "shift", "source",
                "exit", "break", "continue", "trap", "eval", "exec", "echo", "printf", "cd", "test", "read",
                "sudo", "FROM", "RUN", "COPY", "ADD", "ENV", "ARG", "WORKDIR", "CMD", "ENTRYPOINT", "EXPOSE",
            ],
            // `$HOME` 같은 변수.
            capitalizedIsType: false, attributePrefixes: ["$"],
            constants: ["true", "false"])

        static let yaml = SyntaxProfile(
            id: "fence-yaml", lineComments: ["#"], blockComment: nil,
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: [],
            capitalizedIsType: false, attributePrefixes: ["&", "*"],
            constants: ["true", "false", "null", "yes", "no", "on", "off", "True", "False", "Null"],
            keyMarker: ":", keyKind: .tag, hyphenatedWords: true)

        static let json = SyntaxProfile(
            id: "fence-json", lineComments: [], blockComment: nil,
            stringDelimiters: ["\""], tripleQuoted: false,
            keywords: [],
            capitalizedIsType: false, attributePrefixes: [],
            constants: ["true", "false", "null"],
            keyMarker: ":", keyKind: .property)

        static let markup = SyntaxProfile(
            id: "fence-markup", lineComments: [], blockComment: .init(open: "<!--", close: "-->", nests: false),
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: [],
            capitalizedIsType: false, attributePrefixes: [],
            keyMarker: "=", keyKind: .property, hyphenatedWords: true, marksTags: true)

        static let css = SyntaxProfile(
            id: "fence-css", lineComments: [], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["\"", "'"], tripleQuoted: false,
            keywords: ["important", "inherit", "initial", "unset", "none", "auto"],
            capitalizedIsType: false, attributePrefixes: ["@", "$"],
            keyMarker: ":", keyKind: .property, hyphenatedWords: true)

        static let sql = SyntaxProfile(
            id: "fence-sql", lineComments: ["--"], blockComment: .init(open: "/*", close: "*/", nests: false),
            stringDelimiters: ["'", "\""], tripleQuoted: false,
            keywords: [
                "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "alter", "drop", "index", "on", "join", "left", "right", "inner",
                "outer", "full", "cross", "group", "by", "order", "having", "limit", "offset", "as", "distinct",
                "union", "all", "exists", "in", "is", "like", "between", "case", "when", "then", "else", "end",
                "primary", "key", "foreign", "references", "default", "unique", "check", "constraint", "view",
                "trigger", "begin", "commit", "rollback", "transaction", "with", "returning", "asc", "desc",
                "if", "add", "column", "database", "schema", "grant", "revoke",
            ],
            capitalizedIsType: false, attributePrefixes: [],
            constants: ["null", "true", "false"],
            types: ["int", "integer", "bigint", "smallint", "varchar", "char", "text", "boolean", "date",
                    "timestamp", "datetime", "decimal", "numeric", "float", "double", "json", "jsonb", "uuid"],
            caseInsensitive: true,
            marksFunctions: true)

        static let diff = SyntaxProfile(
            id: "fence-diff", lineComments: [], blockComment: nil,
            stringDelimiters: [], tripleQuoted: false,
            keywords: [],
            capitalizedIsType: false, attributePrefixes: [],
            isDiff: true)
    }
}
