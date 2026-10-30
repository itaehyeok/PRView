import XCTest
@testable import PRayerCore

/// 자원이 통째로 박힌 줄을 가리는 규칙.
final class DiffElisionTests: XCTestCase {
    private func long(_ count: Int, _ filler: Character = "a") -> String {
        String(repeating: String(filler), count: count)
    }

    func testShortLineIsKept() {
        XCTAssertNil(DiffElision.elision(for: "let value = compute()"))
        XCTAssertNil(DiffElision.elision(for: ""))
    }

    /// 경계에서 뒤집히는지 본다. 상한 "이하" 는 그대로 보여 준다.
    func testBoundary() {
        XCTAssertNil(DiffElision.elision(for: long(DiffElision.characterLimit)))
        XCTAssertNotNil(DiffElision.elision(for: long(DiffElision.characterLimit + 1)))
    }

    func testLongPlainLineReportsLength() throws {
        let elided = try XCTUnwrap(DiffElision.elision(for: long(5_000)))
        XCTAssertEqual(elided.characterCount, 5_000)
        XCTAssertNil(elided.embeddedType)
        XCTAssertTrue(elided.label.contains("긴 줄"), elided.label)
        XCTAssertTrue(elided.label.contains("생략"), elided.label)
    }

    /// 실제로 겪은 모양: SVG 안에 그림이 base64 로 들어온다. 종류를 라벨에 띄운다.
    func testEmbeddedBase64ImageIsNamed() throws {
        let line = #"    <image width="1024" xlink:href="data:image/png;base64,"# + long(60_000, "A") + #""/>"#
        let elided = try XCTUnwrap(DiffElision.elision(for: line))
        XCTAssertEqual(elided.embeddedType, "image/png")
        XCTAssertTrue(elided.label.contains("image/png"), elided.label)
    }

    /// 자원 URI 는 줄 앞쪽에 오므로 앞부분만 훑는다. 뒤에 있으면 종류는 못 찾아도
    /// 길이로는 여전히 가려야 한다 — 못 찾았다고 내용을 그대로 쏟으면 안 된다.
    func testTypeNotFoundStillElides() throws {
        let line = long(10_000) + "data:image/png;base64,AAAA"
        let elided = try XCTUnwrap(DiffElision.elision(for: line))
        XCTAssertNil(elided.embeddedType)
        XCTAssertTrue(elided.label.contains("긴 줄"), elided.label)
    }

    func testSummarizedReplacesOnlyLongLines() {
        let source = ["<svg>", "  <image href=\"data:image/png;base64," + long(9_000, "A") + "\"/>", "</svg>"]
            .joined(separator: "\n")
        let summary = DiffElision.summarized(source)
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "<svg>")
        XCTAssertEqual(lines[2], "</svg>")
        XCTAssertTrue(lines[1].contains("image/png"), String(lines[1]))
        XCTAssertFalse(summary.contains("AAAA"), "base64 본문이 남아 있으면 안 된다")
    }

    /// 가릴 줄이 없으면 원문 그대로여야 한다. 긴 파일을 괜히 다시 만들지 않는다.
    func testSummarizedKeepsTextWithoutLongLines() {
        let source = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertGreaterThan(source.count, DiffElision.characterLimit)
        XCTAssertEqual(DiffElision.summarized(source), source)
    }
}
