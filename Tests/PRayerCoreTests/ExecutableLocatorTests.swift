import XCTest
@testable import PRayerCore

/// GUI 앱에서 `claude`·`gh` 를 찾는 경로. 되는 사람과 안 되는 사람이 갈린 원인이 여기였다
/// (로그인 셸만 물어서 `~/.zshrc` 의 nvm·alias 를 못 봤다).
final class ExecutableLocatorTests: XCTestCase {
    private let home = "/Users/me"

    // MARK: - `command -v` 출력 읽기

    func testPlainPath() {
        XCTAssertEqual(ExecutableLocator.parseLookup("/Users/me/.nvm/versions/node/v22.1.0/bin/claude\n",
                                                     name: "claude", home: home),
                       "/Users/me/.nvm/versions/node/v22.1.0/bin/claude")
    }

    /// 예전 "로컬 설치" 는 PATH 가 아니라 alias 로만 불린다. zsh·bash 가 찍는 꼴이 조금씩 다르다.
    func testAliasForms() {
        XCTAssertEqual(ExecutableLocator.parseLookup("alias claude=/Users/me/.claude/local/claude", name: "claude", home: home),
                       "/Users/me/.claude/local/claude")
        XCTAssertEqual(ExecutableLocator.parseLookup("alias claude='~/.claude/local/claude'", name: "claude", home: home),
                       "/Users/me/.claude/local/claude")
        XCTAssertEqual(ExecutableLocator.parseLookup(#"alias claude="$HOME/.claude/local/claude""#, name: "claude", home: home),
                       "/Users/me/.claude/local/claude")
        XCTAssertEqual(ExecutableLocator.parseLookup("alias claude='/opt/tools/claude --verbose'", name: "claude", home: home),
                       "/opt/tools/claude", "뒤에 붙인 옵션은 뗀다")
    }

    /// 대화형 셸은 설정 파일이 인사말·색 코드를 찍기도 한다. 마지막 경로 줄을 믿는다.
    func testSkipsShellNoise() {
        let output = "\u{1B}[32mWelcome back\u{1B}[0m\nUpdating plugins…\n\u{1B}]0;title\u{07}/opt/homebrew/bin/gh\n"
        XCTAssertEqual(ExecutableLocator.parseLookup(output, name: "gh", home: home), "/opt/homebrew/bin/gh")
    }

    func testNotAPathMeansNotFound() {
        XCTAssertNil(ExecutableLocator.parseLookup("", name: "claude", home: home))
        XCTAssertNil(ExecutableLocator.parseLookup("claude not found", name: "claude", home: home))
        XCTAssertNil(ExecutableLocator.parseLookup("claude", name: "claude", home: home), "함수 이름만 찍힌 경우")
        XCTAssertNil(ExecutableLocator.parseLookup("alias claude='npx @anthropic-ai/claude-code'", name: "claude", home: home),
                     "실행 파일이 아니라 다른 명령을 부르는 alias")
    }

    // MARK: - 덜 흔한 위치

    /// npm 으로 깐 CLI 는 Node 버전마다 따로 있다. 새 버전부터 본다 — 문자열 순서면 v9 가 v22 보다 앞선다.
    func testNvmNewestFirst() throws {
        let fakeHome = try temporaryDirectory()
        for version in ["v18.20.0", "v22.1.0", "v9.11.2"] {
            try FileManager.default.createDirectory(
                atPath: "\(fakeHome)/.nvm/versions/node/\(version)/bin", withIntermediateDirectories: true)
        }
        XCTAssertEqual(ExecutableLocator.nvmBinDirectories(home: fakeHome).map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent },
                       ["v22.1.0", "v18.20.0", "v9.11.2"])
        XCTAssertEqual(ExecutableLocator.nvmBinDirectories(home: "/nonexistent-home"), [])
    }

    func testFallbackAfterShellFindsNothing() async throws {
        let dir = try temporaryDirectory()
        let tool = "prayer-missing-tool-\(UUID().uuidString.prefix(8))"
        let fallback = "\(dir)/\(tool)"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: fallback))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback)

        let found = await ExecutableLocator.find(tool, preferred: ["\(dir)/nope"], fallback: [fallback])
        XCTAssertEqual(found, fallback)
    }

    /// 실제 셸을 로그인·대화형으로 띄워 묻는다. 멈추지 않고(표준 입력을 비워 준다) 경로를 읽어야 한다.
    func testAsksRealShell() async {
        let path = await ExecutableLocator.askShell("env")
        XCTAssertEqual(path.map { URL(fileURLWithPath: $0).lastPathComponent }, "env", String(describing: path))
    }

    private func temporaryDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
