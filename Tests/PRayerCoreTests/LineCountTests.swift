import XCTest
@testable import PRayerCore

/// 상세 탭 "변경 파일" 옆 줄 수의 꼴. 1만 줄이 넘을 때만 줄인다.
final class LineCountTests: XCTestCase {
    func testSmallCountsStayAsIs() {
        XCTAssertEqual(LineCount.compact(0), "0")
        XCTAssertEqual(LineCount.compact(305), "305")
        XCTAssertEqual(LineCount.compact(9_999), "9999", "쉼표를 넣지 않는다 — 목록 행의 증감과 같은 꼴")
    }

    func testLargeCountsAreShortened() {
        XCTAssertEqual(LineCount.compact(10_000), "10k", "딱 떨어지면 .0 을 붙이지 않는다")
        XCTAssertEqual(LineCount.compact(12_345), "12.3k")
        XCTAssertEqual(LineCount.compact(123_456), "123k", "세 자리 천 단위부터는 소수점을 뺀다")
    }
}
