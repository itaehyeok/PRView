import XCTest
@testable import PRayerCore

/// 앱을 바꿔 끼우는 스크립트. 앱이 꺼진 뒤에 돌아서 실패해도 화면에 띄울 곳이 없다 —
/// 그래서 실패하면 원래 앱을 되살리고, 무슨 일이 있었는지 로그에 남겨야 한다.
/// 여는 명령은 가짜(⑤번 인자)로 바꿔 실제로 앱을 띄우지 않는다.
final class UpdateHelperScriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateHelperScriptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var logFile: URL { root.appendingPathComponent("update.log") }
    private var openedFile: URL { root.appendingPathComponent("opened.txt") }

    private func makeApp(_ name: String, marker: String) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker"))
        return app
    }

    private func marker(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 연 경로를 적어 두는 가짜 `open`.
    private func opener(succeeds: Bool) throws -> String {
        let script = root.appendingPathComponent("opener-\(succeeds).sh")
        try "#!/bin/bash\necho \"$1\" >> \"\(openedFile.path)\"\nexit \(succeeds ? 0 : 1)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    /// 이미 끝난 프로세스의 PID(앱이 꺼진 상태).
    private func exitedPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @discardableResult
    private func runHelper(stage: URL?, target: URL, opener: String, pid: Int32? = nil, waitSeconds: Int = 2) throws -> Int32 {
        let script = root.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try UpdateHelperScript.text(waitSeconds: waitSeconds).write(to: script, atomically: true, encoding: .utf8)
        let processID = try pid ?? exitedPID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, stage?.path ?? "", target.path, String(processID), logFile.path, opener]
        try process.run()
        process.waitUntilExit()
        // 스크립트는 끝나면 스스로 지운다(임시 폴더에 쌓이지 않게).
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        return process.terminationStatus
    }

    private var log: String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }
    private var opened: [String] {
        ((try? String(contentsOf: openedFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func backups(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains(".previous-") }
    }

    /// 응용 프로그램 폴더로 옮겨 깔 때는 그 자리에 앱이 아직 없다. 예전 스크립트는 여기서 멈췄다
    /// (없는 앱을 비키려다 실패).
    func testFreshTargetGetsPlacedAndOpened() throws {
        let stage = try makeApp(".PRayer-update-1.app", marker: "new")
        let target = root.appendingPathComponent("Applications/PRayer.app")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        XCTAssertEqual(try runHelper(stage: stage, target: target, opener: opener(succeeds: true)), 0)
        XCTAssertEqual(marker(target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(opened, [target.path])
        XCTAssertTrue(log.contains("교체 완료"))
    }

    func testReplacesExistingAndRemovesBackup() throws {
        let target = try makeApp("PRayer.app", marker: "old")
        let stage = try makeApp(".PRayer-update-2.app", marker: "new")

        XCTAssertEqual(try runHelper(stage: stage, target: target, opener: opener(succeeds: true)), 0)
        XCTAssertEqual(marker(target), "new")
        XCTAssertEqual(backups(in: root), [])
    }

    /// 새 앱이 안 열리면 있던 앱으로 되돌리고 그걸 다시 연다.
    func testRestoresPreviousAppWhenNewOneFailsToOpen() throws {
        let target = try makeApp("PRayer.app", marker: "old")
        let stage = try makeApp(".PRayer-update-3.app", marker: "new")

        XCTAssertEqual(try runHelper(stage: stage, target: target, opener: opener(succeeds: false)), 1)
        XCTAssertEqual(marker(target), "old")
        XCTAssertEqual(backups(in: root), [])
        XCTAssertEqual(opened, [target.path, target.path])
        XCTAssertTrue(log.contains("새 앱을 열지 못함"))
        XCTAssertTrue(log.contains("있던 앱으로 되돌림"))
    }

    /// 놓을 앱 없이 열기만(옮길 자리에 같거나 더 새 버전이 이미 있을 때).
    func testOpenOnlyWhenNothingToPlace() throws {
        let target = try makeApp("PRayer.app", marker: "installed")

        XCTAssertEqual(try runHelper(stage: nil, target: target, opener: opener(succeeds: true)), 0)
        XCTAssertEqual(marker(target), "installed")
        XCTAssertEqual(opened, [target.path])
    }

    /// 앱이 끝내 안 꺼지면(종료 안내에서 취소 등) 바꿔 끼우지 않고, 준비해 둔 사본도 치운다 —
    /// 예전 스크립트는 응용 프로그램 폴더에 `.PRayer-update-….app` 을 남겼다.
    func testGivesUpAndDropsStageWhenAppKeepsRunning() throws {
        let target = try makeApp("PRayer.app", marker: "old")
        let stage = try makeApp(".PRayer-update-4.app", marker: "new")

        let status = try runHelper(stage: stage, target: target, opener: opener(succeeds: true),
                                   pid: ProcessInfo.processInfo.processIdentifier, waitSeconds: 1)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(marker(target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(opened, [])
        XCTAssertTrue(log.contains("꺼지지 않아"))
    }
}
