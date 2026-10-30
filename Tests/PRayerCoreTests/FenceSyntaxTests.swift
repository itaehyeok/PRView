import XCTest
@testable import PRayerCore

/// 코멘트 속 코드 블록(```언어)의 언어별 색칠. diff 화면 프로파일(profile(forPath:))은 따로 잠겨 있다(CodeSyntaxProfileTests).
final class FenceSyntaxTests: XCTestCase {
    private func kinds(_ source: String, _ language: String) throws -> [String: SyntaxKind] {
        let profile = try XCTUnwrap(CodeSyntax.profile(forLanguage: language), language)
        let characters = Array(source)
        var result: [String: SyntaxKind] = [:]
        for span in CodeSyntax.spans(in: source, profile: profile) {
            result[String(characters[span.start..<(span.start + span.length)])] = span.kind
        }
        return result
    }

    func testLanguageAliasesPickOwnProfiles() {
        let ids = ["kotlin": "fence-kotlin", "kt": "fence-kotlin", "ts": "fence-ts", "tsx": "fence-ts",
                   "go": "fence-go", "rust": "fence-rust", "css": "fence-css", "SQL": "fence-sql",
                   "diff": "fence-diff", "patch": "fence-diff", "objc": "fence-objc", "py": "fence-python",
                   "yml": "fence-yaml", "json": "fence-json", "html": "fence-markup", "bash": "fence-shell"]
        for (language, id) in ids {
            XCTAssertEqual(CodeSyntax.profile(forLanguage: language)?.id, id, language)
        }
        // 모르는 이름은 예전 규칙(확장자)으로, 그것도 모르면 칠하지 않는다.
        XCTAssertEqual(CodeSyntax.profile(forLanguage: "php")?.id, "clike")
        XCTAssertNil(CodeSyntax.profile(forLanguage: "text"))
    }

    func testFileExtensionProfilesStayTheSame() {
        // 변경 파일 탭은 예전 프로파일을 그대로 쓴다 — 함수 이름·상수를 따로 칠하지 않는다.
        let profile = CodeSyntax.profile(forPath: "a/b.kt")
        XCTAssertEqual(profile?.id, "clike")
        XCTAssertFalse(profile?.marksFunctions ?? true)
    }

    func testSwiftFunctionsAndConstants() throws {
        let result = try kinds("let capped = min(width, 400) ?? nil\nfunc layoutHeight(for w: CGFloat)", "swift")
        XCTAssertEqual(result["let"], .keyword)
        XCTAssertEqual(result["min"], .function)
        XCTAssertEqual(result["layoutHeight"], .function)
        XCTAssertEqual(result["nil"], .constant)
        XCTAssertEqual(result["CGFloat"], .type)
        XCTAssertEqual(result["400"], .number)
    }

    func testKotlinAndTypeScript() throws {
        let kotlin = try kinds("suspend fun load(id: String): Item? = null", "kotlin")
        XCTAssertEqual(kotlin["suspend"], .keyword)
        XCTAssertEqual(kotlin["fun"], .keyword)
        XCTAssertEqual(kotlin["load"], .function)
        XCTAssertEqual(kotlin["null"], .constant)
        XCTAssertEqual(try kinds("api.get(id)", "kotlin")["get"], .function)
        XCTAssertEqual(try kinds("map.get(key)", "js")["get"], .function)
        let ts = try kinds("interface A { id: string; run(): void }", "ts")
        XCTAssertEqual(ts["interface"], .keyword)
        XCTAssertEqual(ts["string"], .type)
        XCTAssertEqual(ts["run"], .function)
    }

    func testGoRustAndSQL() throws {
        let go = try kinds("func (s *Server) Start() error { return nil }", "go")
        XCTAssertEqual(go["func"], .keyword)
        XCTAssertEqual(go["Start"], .function)
        XCTAssertEqual(go["error"], .type)
        XCTAssertEqual(go["nil"], .constant)
        let rust = try kinds("fn area(&self) -> u32 { Some(1) }", "rust")
        XCTAssertEqual(rust["fn"], .keyword)
        XCTAssertEqual(rust["u32"], .type)
        XCTAssertEqual(rust["Some"], .constant)
        let sql = try kinds("SELECT id FROM users WHERE name IS NULL -- 주석", "sql")
        XCTAssertEqual(sql["SELECT"], .keyword)
        XCTAssertEqual(sql["NULL"], .constant)
        XCTAssertEqual(sql["-- 주석"], .comment)
    }

    func testKeysTagsAndProperties() throws {
        XCTAssertEqual(try kinds(#"{"name": "a", "ok": true}"#, "json")[#""name""#], .property)
        XCTAssertEqual(try kinds(#"{"name": "a"}"#, "json")[#""a""#], .string)
        let yaml = try kinds("runs-on: macos-15\nenabled: true", "yaml")
        XCTAssertEqual(yaml["runs-on"], .tag)
        XCTAssertEqual(yaml["true"], .constant)
        let css = try kinds(".a { background-color: red; }", "css")
        XCTAssertEqual(css["background-color"], .property)
        let html = try kinds(#"<div class="x"></div>"#, "html")
        XCTAssertEqual(html["div"], .tag)
        XCTAssertEqual(html["class"], .property)
        XCTAssertEqual(html[#""x""#], .string)
    }

    func testDiffLines() throws {
        let source = "@@ -10,7 +10,7 @@ final class A\n-        return width\n+        return min(width, 400)\n     }"
        let result = try kinds(source, "diff")
        XCTAssertEqual(result["@@ -10,7 +10,7 @@ final class A"], .meta)
        XCTAssertEqual(result["-        return width"], .deleted)
        XCTAssertEqual(result["+        return min(width, 400)"], .inserted)
        XCTAssertEqual(result.count, 3)
    }

    /// 스캐너가 제자리를 돌지 않는다 — 새 갈래(키·태그·하이픈 이름)에서도.
    func testNewProfilesDoNotStall() {
        let sources = ["- [ ] 응답 순서(① → 2) <a- b=\"c\"> key-: x", "<", "a-", "\"k\" :", "<!x", "@@\n+\n-"]
        for language in ["swift", "objc", "cpp", "java", "kotlin", "js", "ts", "go", "rust", "python", "ruby",
                         "sh", "yaml", "json", "html", "css", "sql", "diff"] {
            let profile = CodeSyntax.profile(forLanguage: language)!
            for source in sources {
                let spans = CodeSyntax.spans(in: source, profile: profile)
                XCTAssertFalse(spans.contains { $0.length <= 0 }, "\(language): 빈 구간")
                XCTAssertTrue(spans.allSatisfy { $0.start >= 0 && $0.start + $0.length <= source.count }, language)
            }
        }
    }
}
