import XCTest
@testable import PRayerCore

/// 회사 계정(Enterprise)과 개인 계정(github.com)을 한 맥에서 같이 쓸 때,
/// 어느 쪽에 물어보는지가 어긋나면 "레포를 찾을 수 없습니다" 로만 보인다.
final class GitHubHostArgumentTests: XCTestCase {
    func testEnterpriseHostIsInjectedRightAfterApi() {
        let args = GitHubClient.hostArguments(["api", "graphql", "-f", "query=x"], host: "github.acme.com")
        XCTAssertEqual(args, ["api", "--hostname", "github.acme.com", "graphql", "-f", "query=x"])
    }

    /// github.com 은 gh 의 기본값이라 붙여도 같다. 붙이지 않아 로그가 짧아진다.
    func testDotComIsLeftAlone() {
        let args = ["api", "-i", "user"]
        XCTAssertEqual(GitHubClient.hostArguments(args, host: "github.com"), args)
        XCTAssertEqual(GitHubClient.hostArguments(args, host: "GitHub.com"), args)
    }

    /// `api` 로 시작하지 않는 호출(`auth status` 등)에는 --hostname 을 붙이면 안 된다.
    func testNonApiCommandsAreLeftAlone() {
        let args = ["auth", "status"]
        XCTAssertEqual(GitHubClient.hostArguments(args, host: "github.acme.com"), args)
    }

    func testBlankHostFallsBackToDotCom() {
        XCTAssertEqual(GitHubClient(ghPath: "/x/gh", host: "  ").host, "github.com")
        XCTAssertEqual(GitHubClient(ghPath: "/x/gh").host, "github.com")
        XCTAssertEqual(GitHubClient(ghPath: "/x/gh", host: "github.acme.com").webBase,
                       "https://github.acme.com")
    }

    func testWebURLsFollowTheHost() {
        let repo = RepoID(owner: "acme", name: "sample-ios")
        XCTAssertEqual(repo.url(host: "github.com")?.absoluteString, "https://github.com/acme/sample-ios")
        XCTAssertEqual(repo.url(host: "github.acme.com")?.absoluteString,
                       "https://github.acme.com/acme/sample-ios")
    }
}

/// `gh auth status` 는 JSON 을 주지 않는다. 사람이 읽는 출력을 파싱하므로 형식이 계약이다.
final class GHAuthStatusTests: XCTestCase {
    func testSingleHost() {
        let output = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          - Active account: true
          - Git operations protocol: ssh
          - Token scopes: 'read:org', 'repo'
        """
        let hosts = GHAuthStatus.parse(output)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].name, "github.com")
        XCTAssertEqual(hosts[0].login, "octocat")
        XCTAssertTrue(hosts[0].isActive)
        XCTAssertTrue(hosts[0].isDotCom)
    }

    func testEnterpriseAndDotComTogether() {
        let output = """
        github.acme.com
          ✓ Logged in to github.acme.com account nova (keyring)
          - Active account: true

        github.com
          ✓ Logged in to github.com account octocat (oauth_token)
          - Active account: false
        """
        let hosts = GHAuthStatus.parse(output)
        XCTAssertEqual(hosts.map(\.name), ["github.acme.com", "github.com"])
        XCTAssertEqual(hosts.map(\.login), ["nova", "octocat"])
        XCTAssertEqual(hosts.filter(\.isActive).map(\.name), ["github.acme.com"])
        XCTAssertFalse(hosts[0].isDotCom)
    }

    /// 옛 gh 는 `as <login>` 이라고 썼다. 문구가 바뀌어도 호스트는 읽혀야 한다.
    func testOlderWordingStillParses() {
        let hosts = GHAuthStatus.parse("github.com\n  ✓ Logged in to github.com as octocat (keyring)")
        XCTAssertEqual(hosts.map(\.name), ["github.com"])
        XCTAssertEqual(hosts[0].login, "octocat")
    }

    func testNotLoggedInGivesNothing() {
        let output = """
        You are not logged into any GitHub hosts. To log in, run: gh auth login
        """
        XCTAssertTrue(GHAuthStatus.parse(output).isEmpty)
    }

    func testLabelShowsBothHostAndAccount() {
        XCTAssertEqual(GitHubHost(name: "github.acme.com", login: "nova").label, "github.acme.com · nova")
        XCTAssertEqual(GitHubHost(name: "github.com").label, "github.com")
    }
}
