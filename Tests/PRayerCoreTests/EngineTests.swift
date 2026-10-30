import XCTest
@testable import PRayerCore

final class DiffPairingTests: XCTestCase {
    /// 나란히 보기: 연속된 삭제/추가 블록을 같은 행에 짝지어야 한다.
    func testPairsDeletionsWithAdditions() {
        let text = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,4 +1,5 @@
         keep
        -old one
        -old two
        +new one
        +new two
        +new three
         tail
        """
        let file = DiffParser.parse(text).files[0]
        let rows = DiffPairing.rows(for: file)
        let changes = rows.filter { $0.kind == .change }
        XCTAssertEqual(changes.count, 3, "삭제 2 + 추가 3 → 3행")
        XCTAssertEqual(changes[0].left?.text, "old one")
        XCTAssertEqual(changes[0].right?.text, "new one")
        XCTAssertEqual(changes[1].left?.text, "old two")
        XCTAssertEqual(changes[1].right?.text, "new two")
        XCTAssertNil(changes[2].left, "짝이 없는 추가는 왼쪽이 비어야 한다")
        XCTAssertEqual(changes[2].right?.text, "new three")

        let contexts = rows.filter { $0.kind == .context }
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[0].left?.text, contexts[0].right?.text)
        XCTAssertEqual(rows.filter { $0.kind == .hunk }.count, 1)
    }

    /// 코멘트가 붙는 위치를 보여줄 코드 조각.
    func testSnippetAroundLine() {
        let file = DiffParser.parse(DiffParserTests.sample, excluding: ["*.pbxproj"]).files[0]
        let snippet = file.snippet(around: 11, side: .right, context: 1)
        XCTAssertEqual(snippet.count, 3)
        XCTAssertTrue(snippet.contains { $0.newLine == 11 })
        XCTAssertTrue(file.isTarget(snippet.first { $0.newLine == 11 }!, targetLine: 11, side: .right))
        XCTAssertTrue(file.snippet(around: 9999, side: .right).isEmpty)
    }
}

final class EngineSettingsTests: XCTestCase {
    func testDefaultsAreClaude() {
        let settings = Settings.default
        XCTAssertTrue(settings.claudePath.hasSuffix("claude"))
        XCTAssertEqual(settings.model, "sonnet")
    }

    /// 걷어낸 기능들(자동 리뷰 타임박스·자동 요약·Codex 대체 엔진)의 키가 기존 설정 파일에는
    /// 그대로 남아 있다. 디코딩이 모르는 키를 만나 실패하면 사용자의 설정이 통째로
    /// 기본값으로 돌아간다 — 실제로 한 번 겪은 사고라 픽스처로 못 박는다.
    func testSettingsFileWithRemovedKeysStillDecodes() throws {
        let json = """
        {
          "onboardingCompleted": true,
          "claudePath": "/x/claude",
          "model": "opus",
          "pollSeconds": 300,
          "fiveHourTokenCap": 500000,
          "timeBoxPerTickLimit": 5,
          "preventSleepDuringTimeBox": false,
          "notifyOnBatchDone": true,
          "autoSummaryEnabled": false,
          "summaryTokenShareRatio": 0.25,
          "primaryEngine": "codex",
          "fallbackEngine": "claude",
          "useFallbackOnLimit": true,
          "codexPath": "/opt/homebrew/bin/codex",
          "codexModel": "gpt-5"
        }
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        // 살아 있는 값은 파일에서 그대로 읽고, 없어진 키는 조용히 무시한다.
        XCTAssertEqual(settings.pollSeconds, 300)
        XCTAssertEqual(settings.fiveHourTokenCap, 500_000)
        XCTAssertEqual(settings.model, "opus")
        XCTAssertTrue(settings.onboardingCompleted)
    }

    func testLimitDetector() {
        XCTAssertTrue(LimitDetector.matches("You have reached your usage limit"))
        XCTAssertTrue(LimitDetector.matches("HTTP 429 Too Many Requests"))
        XCTAssertFalse(LimitDetector.matches("파일을 찾을 수 없습니다"))
    }
}

final class DuplicateCommentTests: XCTestCase {
    /// 기존 스레드와 겹치는 코멘트는 표시가 남아야 UI 에서 구분할 수 있다.
    func testDuplicateFlagRoundTrips() throws {
        let json = """
        { "issue_key": "k1", "path": "A.swift", "line": 3, "side": "RIGHT",
          "body": "이미 nova 님이 언급한 사항인데 함께 확인 부탁드려요.", "severity": "minor",
          "anchor_text": "let x = 1", "duplicates_existing": true,
          "existing_note": "nova-one: 같은 강제 언랩 지적" }
        """
        let comment = try JSONDecoder().decode(DraftComment.self, from: Data(json.utf8))
        XCTAssertTrue(comment.isDuplicate)
        XCTAssertEqual(comment.existingNote, "nova-one: 같은 강제 언랩 지적")

        // 필드가 없으면 중복이 아니다(옛 출력 호환).
        let plain = try JSONDecoder().decode(DraftComment.self, from: Data("""
        { "issue_key": "k2", "path": "A.swift", "line": 3, "side": "RIGHT",
          "body": "본문", "severity": "minor", "anchor_text": "let x = 1" }
        """.utf8))
        XCTAssertFalse(plain.isDuplicate)
    }
}
