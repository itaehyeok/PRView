import XCTest
@testable import PRayerCore

/// 터미널 로그인 창이 끝나면서 남기는 결과. 이걸 못 남기면 앱은 시간이 다 될 때까지
/// "로그인하는 중" 을 띄워 둔다. 로그인 명령은 가짜로 바꿔 실제로 로그인하지 않는다.
final class LoginScriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // 실제 데이터 폴더(`Application Support`)처럼 띄어쓰기를, 따옴표 처리까지 보려고 작은따옴표도 넣는다.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginScriptTests \(UUID().uuidString)/it's here")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private var resultFile: URL { root.appendingPathComponent("claude-login.result") }

    /// 스크립트를 돌리고 남긴 결과를 읽는다. 결과 파일이 없으면 nil.
    private func run(command: String) throws -> (status: Int32, outcome: LoginScript.Outcome?) {
        let script = root.appendingPathComponent("claude-login.command")
        try LoginScript.text(appName: "PRayer", title: "Claude Code 로그인", command: command, resultPath: resultFile.path)
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let outcome = (try? Data(contentsOf: resultFile)).map { LoginScript.outcome(fromResult: String(decoding: $0, as: UTF8.self)) }
        return (process.terminationStatus, outcome)
    }

    func testSuccessfulLoginLeavesZero() throws {
        let result = try run(command: "true")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultFile.path + ".tmp"))
    }

    func testFailedLoginLeavesExitCode() throws {
        XCTAssertEqual(try run(command: "sh -c 'exit 3'").outcome, .failed("3"))
    }

    /// 로그인하다 창을 닫으면 터미널이 HUP 을 보낸다. 그래도 결과를 남겨야 앱이 안내를 되돌린다.
    func testClosingWindowLeavesHup() throws {
        let result = try run(command: "kill -HUP $$")
        XCTAssertEqual(result.outcome, .failed("hup"))
        XCTAssertEqual(result.status, 129)
    }

    func testCtrlCLeavesInt() throws {
        XCTAssertEqual(try run(command: "kill -INT $$").outcome, .failed("int"))
    }

    /// 기다리는 쪽이 없는 창(GitHub 로그인)은 결과를 남기지 않는다 — 읽는 사람 없는 파일이 쌓인다.
    func testWindowWithoutWatcherLeavesNothing() {
        let text = LoginScript.text(appName: "PRayer", title: "GitHub 로그인", command: "gh auth login", resultPath: nil)
        XCTAssertFalse(text.contains("RESULT"))
        XCTAssertTrue(text.contains("gh auth login"))
    }

    func testWaitReadsResultAndRemovesIt() async throws {
        let file = resultFile
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            try? Data("0\n".utf8).write(to: file)
        }
        let outcome = await LoginScript.waitForResult(at: file, timeout: .seconds(5), interval: .milliseconds(50))
        XCTAssertEqual(outcome, .succeeded)
        // 다음 창이 옛 결과를 읽지 않게 지운다.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWaitGivesUpAfterTimeout() async {
        let outcome = await LoginScript.waitForResult(at: resultFile, timeout: .milliseconds(200), interval: .milliseconds(50))
        XCTAssertEqual(outcome, .timedOut)
    }
}
