import XCTest
@testable import PRayerCore

/// 리뷰한 Claude 대화를 `claude --resume` 으로 이어 가는 경로.
final class ClaudeSessionTests: XCTestCase {
    private func invocation(persist: Bool) -> [String] {
        ClaudeInvocation(claudePath: "/bin/echo", systemPromptPath: "g", schemaJSON: "{}", model: "opus",
                         timeout: 10, workingDirectory: "/tmp", persistSession: persist).arguments
    }

    /// 본 리뷰만 대화를 남긴다. 보조 호출(설명·대조·재확인)까지 남기면 사용자의 `--resume` 목록이 덮인다.
    func testOnlyPersistedInvocationDropsNoPersistenceFlag() {
        XCTAssertFalse(invocation(persist: true).contains("--no-session-persistence"))
        XCTAssertTrue(invocation(persist: false).contains("--no-session-persistence"))
        // 기본값은 남기지 않는 쪽이다 — 새 호출 경로가 생겨도 조용히 대화를 쌓지 않게.
        let defaultArguments = ClaudeInvocation(claudePath: "/bin/echo", systemPromptPath: "g", schemaJSON: "{}",
                                                model: "opus", timeout: 10, workingDirectory: "/tmp").arguments
        XCTAssertTrue(defaultArguments.contains("--no-session-persistence"))
    }

    /// 대화를 남겨도 나머지 안전 장치는 그대로여야 한다.
    func testPersistedInvocationKeepsSafetyFlags() {
        let arguments = invocation(persist: true)
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--tools"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        let mode = arguments.firstIndex(of: "--permission-mode").map { arguments[$0 + 1] }
        XCTAssertEqual(mode, "dontAsk")
    }

    func testResumeCommandUsesLowercasedID() {
        XCTAssertEqual(ClaudeSession.resumeCommand(sessionID: "3F2A9C1E-7B4D-4E21-9A0C-5D8E2F6B1A73"),
                       "claude --resume 3f2a9c1e-7b4d-4e21-9a0c-5d8e2f6b1a73")
    }

    /// CLI 결과에서 읽은 값을 셸 명령에 넣는다 — UUID 가 아니면 명령을 만들지 않는다.
    func testResumeCommandRejectsNonUUID() {
        XCTAssertNil(ClaudeSession.resumeCommand(sessionID: ""))
        XCTAssertNil(ClaudeSession.resumeCommand(sessionID: "3f2a9c1e; rm -rf ~"))
        XCTAssertNil(ClaudeSession.resumeCommand(sessionID: "3f2a9c1e-7b4d-4e21-9a0c-5d8e2f6b1a73 && echo x"))
    }

    func testTranscriptLookupScansEveryProjectFolder() throws {
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-projects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projects) }
        let id = "3f2a9c1e-7b4d-4e21-9a0c-5d8e2f6b1a73"
        // 전체 리뷰는 워크트리마다 작업 폴더가 달라 대화가 어느 하위 폴더에 있을지 모른다.
        let folder = projects.appendingPathComponent("-Users-someone-worktrees-pr-12", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-other", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("\(id).jsonl"))

        XCTAssertTrue(ClaudeSession.transcriptExists(sessionID: id, in: projects))
        XCTAssertTrue(ClaudeSession.transcriptExists(sessionID: id.uppercased(), in: projects))
        XCTAssertFalse(ClaudeSession.transcriptExists(sessionID: UUID().uuidString, in: projects))
        XCTAssertFalse(ClaudeSession.transcriptExists(sessionID: id,
                                                      in: projects.appendingPathComponent("missing")))
    }

    /// CLI 결과 JSON 의 `session_id` 가 리뷰 기록까지 간다(앱이 죽은 뒤 수확하는 경로도 같은 파싱을 쓴다).
    func testParseReadsSessionID() {
        let stdout = #"{"type":"result","is_error":false,"session_id":"3f2a9c1e-7b4d-4e21-9a0c-5d8e2f6b1a73","result":"{}"}"#
        let run = ClaudeRunner().parse(result: ProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false),
                                       model: "opus")
        XCTAssertEqual(run.sessionID, "3f2a9c1e-7b4d-4e21-9a0c-5d8e2f6b1a73")
    }

    /// 0.5.1 전 기록에는 sessionID 가 없다. 읽혀야 하고, 값은 비어 있어야 한다.
    func testRecordWithoutSessionIDStillDecodes() throws {
        let pr = Fixtures.pr()
        var record = Fixtures.record(pr: pr, output: Fixtures.output())
        record.sessionID = "3f2a9c1e-7b4d-4e21-9a0c-5d8e2f6b1a73"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let roundTrip = try decoder.decode(ReviewRecord.self, from: encoder.encode(record))
        XCTAssertEqual(roundTrip.sessionID, record.sessionID)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        object.removeValue(forKey: "sessionID")
        let old = try decoder.decode(ReviewRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.sessionID)
    }
}
