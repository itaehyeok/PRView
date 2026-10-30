import XCTest
@testable import PRayerCore

/// 코멘트 마크다운을 블록으로 나누는 규칙. GitHub 에서 보이는 모양과 어긋나지 않게 잠근다.
final class MarkdownBlocksTests: XCTestCase {
    /// 블록 종류와 글을 한 줄씩 적어 비교하기 쉽게 만든다.
    private func describe(_ text: String) -> [String] {
        MarkdownParser.blocks(from: text).map { block in
            switch block.kind {
            case .paragraph: return "p: \(block.text)"
            case .heading(let level): return "h\(level): \(block.text)"
            case .bullet(let indent): return "bullet\(indent): \(block.text)"
            case .task(let indent, let done): return "task\(indent)\(done ? "x" : " "): \(block.text)"
            case .ordered(let number, let indent): return "ol\(indent) \(number): \(block.text)"
            case .quote: return "quote: \(block.text)"
            case .code(let language): return "code(\(language ?? "")): \(block.text)"
            case .rule: return "rule"
            case .table(let table):
                let rows = table.rows.map { $0.joined(separator: " | ") }
                return (["table: " + table.header.joined(separator: " | ")] + rows).joined(separator: " / ")
            case .images(let images):
                return "images: " + images.map { image in
                    [image.alt, image.url.absoluteString, image.width.map { "w\(Int($0))" }, image.link.map { "→\($0.absoluteString)" }]
                        .compactMap { $0 }.joined(separator: " ")
                }.joined(separator: " + ")
            }
        }
    }

    func testSplitsHeadingsListsQuotesAndCode() {
        let body = """
        ### 제목
        첫 문단
        이어지는 줄

        - 하나
          - 둘
        1. 첫째
        > 인용
        ```swift
        let a = 1
        ```
        ---
        """
        XCTAssertEqual(describe(body), [
            "h3: 제목",
            "p: 첫 문단\n이어지는 줄",
            "bullet0: 하나",
            "bullet1: 둘",
            "ol0 1: 첫째",
            "quote: 인용",
            "code(swift): let a = 1",
            "rule",
        ])
    }

    func testSkipsHiddenComments() {
        XCTAssertEqual(describe("<!-- 마커\n여러 줄 -->\n보이는 글"), ["p: 보이는 글"])
    }

    // MARK: - 표

    /// 코멘트 속 측정 표 예시. 칸 안의 `336~696` 같은 범위가 줄을 넘어 짝지어지지 않게
    /// 칸으로 먼저 잘라야 한다 — 문단으로 두면 물결표 둘 사이가 취소선이 됐다.
    func testParsesTableAfterParagraph() {
        let body = """
        대상은 설정 화면입니다.

        | 기기 | 방향 | 버튼 영역 |
        |---|---|---|
        | 태블릿 11" | 세로 | 200×40, x 336~696 |
        | 태블릿 11" | 가로 | 200×40, x 508~868 |

        - 다크에서 버튼 옆 배경은 `#121212` 입니다.
        """
        XCTAssertEqual(describe(body), [
            "p: 대상은 설정 화면입니다.",
            "table: 기기 | 방향 | 버튼 영역 / 태블릿 11\" | 세로 | 200×40, x 336~696"
                + " / 태블릿 11\" | 가로 | 200×40, x 508~868",
            "bullet0: 다크에서 버튼 옆 배경은 `#121212` 입니다.",
        ])
    }

    /// 빈 줄 없이 문단 바로 뒤에 와도 표다 — 문단의 마지막 줄이 머리가 된다.
    func testTableHeaderTakenFromParagraphEnd() {
        XCTAssertEqual(describe("설명 줄\na | b\n--- | ---\n1 | 2\n끝 줄"), [
            "p: 설명 줄",
            "table: a | b / 1 | 2",
            "p: 끝 줄",
        ])
    }

    func testTableAlignmentsAndCellCounts() throws {
        let blocks = MarkdownParser.blocks(from: "| 왼 | 가운데 | 오른 |\n|:--|:-:|--:|\n| 1 |\n| a | b | c | 넘침 |")
        guard case .table(let table) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("표가 아니다")
        }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows, [["1", "", ""], ["a", "b", "c"]])
    }

    /// `\|` 는 칸을 나누지 않는다. 다른 이스케이프(`\*`)는 줄 안 서식이 읽도록 남긴다.
    func testEscapedPipeStaysInCell() {
        XCTAssertEqual(MarkdownTable.cells(#"| `a \| b` | \*별\* |"#), ["`a | b`", #"\*별\*"#])
    }

    /// 구분 줄이 없거나 칸 수가 다르면 표가 아니다. `|` 없는 `---` 는 가로줄 그대로.
    func testNotATable() {
        XCTAssertEqual(describe("a | b\n그냥 글"), ["p: a | b\n그냥 글"])
        XCTAssertEqual(describe("a | b | c\n|---|---|"), ["p: a | b | c\n|---|---|"])
        XCTAssertEqual(describe("글\n\n---"), ["p: 글", "rule"])
    }

    // MARK: - 체크박스

    func testTaskListItems() {
        XCTAssertEqual(describe("- [x] 라이트 확인\n- [ ] 다크 확인\n  * [X] 가로 모드\n- [x]붙여 쓴 글\n- 그냥 항목"), [
            "task0x: 라이트 확인",
            "task0 : 다크 확인",
            "task1x: 가로 모드",
            "bullet0: [x]붙여 쓴 글",
            "bullet0: 그냥 항목",
        ])
    }

    // MARK: - 번호 목록

    /// 번호 아래 들여쓴 번호·글머리 항목은 한 단계 안으로 들어간다. `1)` 도 번호다.
    func testNestedOrderedLists() {
        XCTAssertEqual(describe("1. 첫째\n   1. 안쪽 첫째\n   - 안쪽 글머리\n2) 둘째\n\t3. 탭 들여쓰기"), [
            "ol0 1: 첫째",
            "ol1 1: 안쪽 첫째",
            "bullet1: 안쪽 글머리",
            "ol0 2: 둘째",
            "ol2 3: 탭 들여쓰기",
        ])
    }

    /// `1.` 만 되풀이해도 1·2·3 이다. 안쪽 목록을 지나도 바깥 번호는 이어지고, 목록이 끝나면 다시 시작한다.
    func testOrderedListsRenumberLikeGitHub() {
        XCTAssertEqual(describe("1. 가\n1. 나\n   1. 안\n   1. 안2\n1. 다\n\n끝\n\n3. 셋부터\n3. 넷"), [
            "ol0 1: 가",
            "ol0 2: 나",
            "ol1 1: 안",
            "ol1 2: 안2",
            "ol0 3: 다",
            "p: 끝",
            "ol0 3: 셋부터",
            "ol0 4: 넷",
        ])
    }

    // MARK: - 그림

    /// 실제 코멘트의 끌어다 붙인 그림 줄. 제목 아래 설명 글처럼 보이던 것이 그림이 된다.
    func testImageOnlyLines() {
        let body = """
        #### iPad 가로

        ![iPad 가로 화면](https://github.com/user-attachments/assets/11111111-2222-4333-8444-555555555555)
        <img src="https://example.com/a.png" width="300" alt="전"> <img src='https://example.com/b.png' width=300 alt="후">
        <p align="center"><a href="https://example.com/big"><img src="https://example.com/s.png"></a></p>
        [![배지](https://example.com/badge.svg)](https://example.com/ci)
        """
        XCTAssertEqual(describe(body), [
            "h4: iPad 가로",
            "images: iPad 가로 화면 https://github.com/user-attachments/assets/11111111-2222-4333-8444-555555555555",
            "images: 전 https://example.com/a.png w300 + 후 https://example.com/b.png w300",
            "images:  https://example.com/s.png →https://example.com/big",
            "images: 배지 https://example.com/badge.svg →https://example.com/ci",
        ])
    }

    /// 글과 섞인 그림은 문단 그대로(줄 안 서식이 설명 글로 보인다).
    func testImageMixedWithTextStaysParagraph() {
        XCTAssertEqual(describe("전후 비교 ![a](https://example.com/a.png)"), ["p: 전후 비교 ![a](https://example.com/a.png)"])
        XCTAssertEqual(describe("<img src=\"https://example.com/a.png\"> 설명"), ["p: <img src=\"https://example.com/a.png\"> 설명"])
    }

    // MARK: - 첨부 그림 주소

    func testAttachmentAssetID() {
        XCTAssertEqual(GitHubAttachment.assetID(of: URL(string: "https://github.com/user-attachments/assets/11111111-2222-4333-8444-AAAAAAAAAAAA")!),
                       "11111111-2222-4333-8444-aaaaaaaaaaaa")
        XCTAssertEqual(GitHubAttachment.assetID(of: URL(string: "https://github.com/acme/app/assets/1234567/22222222-3333-4444-8555-666666666666")!),
                       "22222222-3333-4444-8555-666666666666")
        XCTAssertNil(GitHubAttachment.assetID(of: URL(string: "https://example.com/22222222-3333-4444-8555-666666666666.png")!))
    }

    /// 실제 bodyHTML 모양(주소는 줄임). `<a href>` 와 `<img src>` 에 같은 주소가 `&amp;` 로 실린다.
    func testSignedURLsFromBodyHTML() {
        let html = #"<p><a target="_blank" href="https://private-user-images.githubusercontent.com/1234567/100000001-11111111-2222-4333-8444-555555555555.png?jwt=eyJ0.eyJp.sig&amp;x=1"><img src="https://private-user-images.githubusercontent.com/1234567/100000001-11111111-2222-4333-8444-555555555555.png?jwt=eyJ0.eyJp.sig&amp;x=1" alt="iPad"></a> <img src="https://example.com/plain.png"></p>"#
        let found = GitHubAttachment.signedURLs(inHTML: html)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found["11111111-2222-4333-8444-555555555555"]?.absoluteString,
                       "https://private-user-images.githubusercontent.com/1234567/100000001-11111111-2222-4333-8444-555555555555.png?jwt=eyJ0.eyJp.sig&x=1")
    }
}
