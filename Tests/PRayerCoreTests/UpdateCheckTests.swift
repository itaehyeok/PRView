import XCTest
@testable import PRayerCore

/// 버전 비교와 릴리스 응답 해석.
///
/// 문자열로 견주면 "0.10.0" < "0.9.0" 이 된다. 그러면 업데이트가 나왔는데도
/// 앱이 조용히 있고, 아무도 그 사실을 모른다.
final class UpdateCheckTests: XCTestCase {
    func testNumericComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
    }

    /// 자릿수가 늘어나는 순간이 문자열 비교가 틀리는 지점이다.
    func testTwoDigitSegments() {
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
    }

    /// 자릿수가 다른 버전도 견줄 수 있어야 한다("1.0" vs "1.0.1").
    func testDifferentSegmentCounts() {
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.0"))
    }

    func testParsesTagWithAndWithoutPrefix() throws {
        let withV = try XCTUnwrap(UpdateCheck.parse(Data(#"{"tag_name":"v0.3.1"}"#.utf8)))
        XCTAssertEqual(withV.version, "0.3.1")
        let plain = try XCTUnwrap(UpdateCheck.parse(Data(#"{"tag_name":"0.3.1"}"#.utf8)))
        XCTAssertEqual(plain.version, "0.3.1")
    }

    /// 초안·프리릴리스는 아직 남에게 줄 것이 아니다.
    func testDraftAndPrereleaseAreIgnored() {
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v9.9.9","draft":true}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v9.9.9","prerelease":true}"#.utf8)))
    }

    func testGarbageIsIgnored() {
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.parse(Data("{}".utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":""}"#.utf8)))
    }

    func testParsesOnlyExpectedGitHubAsset() throws {
        let json = #"{"tag_name":"v0.3.0","assets":[{"name":"PRView-0.3.0.zip","browser_download_url":"https://github.com/itaehyeok/PRView/releases/download/v0.3.0/PRView-0.3.0.zip"}]}"#
        let release = try XCTUnwrap(UpdateCheck.parse(Data(json.utf8)))
        XCTAssertEqual(release.assetURL?.lastPathComponent, "PRView-0.3.0.zip")
        let wrongHost = json.replacingOccurrences(of: "github.com", with: "example.com")
        XCTAssertNil(UpdateCheck.parse(Data(wrongHost.utf8))?.assetURL)
        let wrongName = json.replacingOccurrences(of: "PRView-0.3.0.zip", with: "other.zip")
        XCTAssertNil(UpdateCheck.parse(Data(wrongName.utf8))?.assetURL)
        // 다리 저장소(terry-yes/PRView)의 zip 은 이름이 같아도 받지 않는다 — 이 저장소만 본다.
        let bridge = json.replacingOccurrences(of: "itaehyeok/PRView", with: "terry-yes/PRView")
        XCTAssertNil(UpdateCheck.parse(Data(bridge.utf8))?.assetURL)
    }

    /// 베타 판정 — 공개 저장소에 이 버전의 정식 릴리스가 있어야 정식이다.
    func testPublishStateFromHTTP() {
        XCTAssertEqual(UpdateCheck.publishState(
            httpStatus: 200, body: Data(#"{"tag_name":"v0.4.4","prerelease":false,"draft":false}"#.utf8)), .published)
        XCTAssertEqual(UpdateCheck.publishState(
            httpStatus: 200, body: Data(#"{"tag_name":"v0.4.4","prerelease":true}"#.utf8)), .unpublished)
        XCTAssertEqual(UpdateCheck.publishState(httpStatus: 404, body: Data()), .unpublished)
        // 한도 초과(403)·서버 오류는 모르는 것이다. 베타로 단정하면 정식을 쓰는 사람에게 "베타" 가 뜬다.
        XCTAssertEqual(UpdateCheck.publishState(httpStatus: 403, body: Data()), .unknown)
        XCTAssertEqual(UpdateCheck.publishState(httpStatus: 500, body: Data()), .unknown)
        XCTAssertEqual(UpdateCheck.publishState(httpStatus: 200, body: Data("garbage".utf8)), .unknown)
    }

    /// 베타 번호는 release.sh --beta 가 빌드 변수로 넘긴다. 베타가 아닌 빌드에서는 그 변수가 정의되지 않아
    /// 빈 값으로 들어오고, 예전 빌드에는 키가 아예 없다 — 둘 다 "번호 없음" 이어야 "베타 0" 같은 표시가 안 생긴다.
    func testBetaNumberFromInfoPlist() {
        XCTAssertEqual(UpdateCheck.betaNumber(info: ["PRayerBetaNumber": "3"]), 3)
        XCTAssertEqual(UpdateCheck.betaNumber(info: ["PRayerBetaNumber": "12"]), 12)
        XCTAssertNil(UpdateCheck.betaNumber(info: ["PRayerBetaNumber": ""]))
        XCTAssertNil(UpdateCheck.betaNumber(info: ["PRayerBetaNumber": "0"]))
        XCTAssertNil(UpdateCheck.betaNumber(info: ["PRayerBetaNumber": "$(PRAYER_BETA_NUMBER)"]))
        XCTAssertNil(UpdateCheck.betaNumber(info: ["CFBundleShortVersionString": "0.4.31"]))
        XCTAssertNil(UpdateCheck.betaNumber(info: nil))
    }

    /// 베타 태그(v0.5.0-beta.3)는 업데이트로 치지 않는다. 공개 저장소에 잘못 올라가도 팀원 앱이 베타를 받지 않게.
    func testBetaTagIsNotAnUpdate() {
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v0.5.0-beta.3"}"#.utf8)))
    }

    /// gh 는 없는 태그에 "HTTP 404" 를 stderr 로 낸다. 로그인이 끊긴 것 같은 다른 실패와 가려야 한다.
    func testPublishStateFromGH() {
        XCTAssertEqual(UpdateCheck.publishState(
            ghSucceeded: true, stdout: #"{"prerelease":false}"#, stderr: ""), .published)
        XCTAssertEqual(UpdateCheck.publishState(
            ghSucceeded: false, stdout: #"{"message":"Not Found"}"#, stderr: "gh: Not Found (HTTP 404)"), .unpublished)
        XCTAssertEqual(UpdateCheck.publishState(
            ghSucceeded: false, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login"), .unknown)
    }
}
