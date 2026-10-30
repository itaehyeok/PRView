import XCTest
@testable import PRayerCore

final class PullRequestURLTests: XCTestCase {
    /// 앵커 값은 공개 PR 의 변경 파일 탭 HTML 에서 `README` 파일 자리의 id 를 그대로 옮긴 것이다.
    func testFilesURLPointsAtFileAnchor() {
        let url = Fixtures.pr(number: 12).filesURL(host: "github.com", path: "README")
        XCTAssertEqual(url?.absoluteString,
                       "https://github.com/acme/sample-ios/pull/12/files#diff-2b7814d3fca2e99e56c51b6ff2aa313ea6e9da6424804240aa8ad891fdfe0900")
    }

    func testFilesURLUsesEnterpriseHost() {
        let url = Fixtures.pr(number: 12).filesURL(host: "github.mycorp.com", path: "Sources/App.swift")
        XCTAssertEqual(url?.host, "github.mycorp.com")
        XCTAssertEqual(url?.path, "/acme/sample-ios/pull/12/files")
        XCTAssertEqual(url?.fragment?.count, "diff-".count + 64)
    }
}
