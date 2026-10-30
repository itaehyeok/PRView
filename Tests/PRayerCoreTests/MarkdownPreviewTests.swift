import XCTest
@testable import PRayerCore

/// 접힌 줄의 미리보기 글. 꾸밈이 앞을 차지해 내용이 안 보이는 일이 없게 잠근다.
final class MarkdownPreviewTests: XCTestCase {
    func testStripsHeadingsListsAndJoinsLines() {
        let body = """
        ## 배경
        - 요구사항: 빌드 결과를 **표**로 남기고 싶음
        - [ ] 체크 항목
        1. 첫 단계
        > 인용한 말
        """
        XCTAssertEqual(MarkdownPreview.text(body),
                       "배경 · 요구사항: 빌드 결과를 표로 남기고 싶음 · 체크 항목 · 첫 단계 · 인용한 말")
    }

    /// 앱 마커·템플릿 안내 같은 숨은 주석과 코드 블록(mermaid 포함)은 미리보기에 안 나온다.
    func testSkipsHiddenCommentsAndCodeBlocks() {
        let body = """
        <!-- prdeck:v1:abc123 -->
        <!--
        템플릿 안내: 아래를 채워 주세요
        -->
        ```mermaid
        flowchart TD
          A --> B
        ```
        실제 내용입니다.
        """
        XCTAssertEqual(MarkdownPreview.text(body), "실제 내용입니다.")
    }

    func testKeepsLinkTextAndDropsImagesAndCodeTicks() {
        let body = "[지라: TICKET-1](https://example.com/browse/TICKET-1) 참고 ![화면](https://example.com/a.png) `summary.py` 추가"
        XCTAssertEqual(MarkdownPreview.text(body), "지라: TICKET-1 참고 summary.py 추가")
    }

    /// 흔한 HTML 태그만 걷는다. 코드 이름의 꺾쇠는 남긴다.
    func testRemovesCommonHTMLButKeepsGenerics() {
        XCTAssertEqual(MarkdownPreview.text("<details><summary>로그</summary>펼친 내용<br/>둘째 줄</details>"),
                       "로그 펼친 내용 둘째 줄")
        XCTAssertEqual(MarkdownPreview.text("Array<String> 을 넘긴다"), "Array<String> 을 넘긴다")
    }

    func testDropsRulesAndTableSeparators() {
        let body = """
        | 항목 | 값 |
        |---|---|
        | 승인 | 3 |
        ---
        끝
        """
        XCTAssertEqual(MarkdownPreview.text(body), "항목 값 · 승인 3 · 끝")
    }

    func testTruncatesLongText() {
        let body = String(repeating: "가나다라마바사 ", count: 100)
        let preview = MarkdownPreview.text(body, maxLength: 50)
        XCTAssertEqual(preview.count, 51)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testEmptyWhenOnlyDecoration() {
        XCTAssertEqual(MarkdownPreview.text("<!-- 마커만 -->\n---\n"), "")
    }
}
