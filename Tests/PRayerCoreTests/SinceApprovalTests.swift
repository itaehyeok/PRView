import XCTest
@testable import PRayerCore

/// 승인한 커밋부터 head 까지 무엇이 바뀌었는지 가르는 규칙(`SinceApproval.classify`).
final class SinceApprovalTests: XCTestCase {
    private func file(_ name: String, _ add: Int = 1, _ del: Int = 0) -> SinceApproval.FileChange {
        SinceApproval.FileChange(filename: name, additions: add, deletions: del)
    }

    private func compare(_ status: String = "ahead", commits: [Int] = [1], files: [SinceApproval.FileChange])
        -> SinceApproval.Comparison {
        SinceApproval.Comparison(status: status,
                                 commits: commits.enumerated().map { .init(sha: "c\($0.offset)", parents: $0.element) },
                                 files: files)
    }

    func testCommentedFileWins() {
        let since = SinceApproval.classify(compare(files: [file("Docs/README.md"), file("Sources/Player.swift", 120, 38)]),
                                           commentedPaths: ["Sources/Player.swift"])
        XCTAssertEqual(since.kind, .commentedFile)
        XCTAssertEqual(since.commentedFiles, ["Sources/Player.swift"])
        XCTAssertEqual(since.additions, 121)
        XCTAssertEqual(since.deletions, 38)
    }

    func testCodeAndDocs() {
        XCTAssertEqual(SinceApproval.classify(compare(files: [file("Sources/A.swift")]), commentedPaths: []).kind, .code)
        XCTAssertEqual(SinceApproval.classify(compare(files: [file("docs/spec.md"), file("README.md")]),
                                              commentedPaths: []).kind, .docsOnly)
    }

    /// 확장자가 .md 여도 에이전트 지시 파일은 동작을 바꾼다 — 문서로 치면 지시가 바뀐 것을 놓친다.
    func testAgentInstructionFilesAreNotDocs() {
        XCTAssertTrue(SinceApproval.isDocument(".claude/notes/design.md"))
        XCTAssertTrue(SinceApproval.isDocument("docs/guide.md"))
        XCTAssertFalse(SinceApproval.isDocument(".claude/skills/review/SKILL.md"))
        XCTAssertFalse(SinceApproval.isDocument("CLAUDE.md"))
        XCTAssertFalse(SinceApproval.isDocument(".claude/agents/helper.md"))
        XCTAssertFalse(SinceApproval.isDocument(".claude/rules/swift.md"))
        XCTAssertFalse(SinceApproval.isDocument("Sources/App.swift"))
        XCTAssertEqual(SinceApproval.classify(compare(files: [file(".claude/skills/review/SKILL.md")]),
                                              commentedPaths: []).kind, .code)
    }

    /// 승인한 커밋이 head 의 조상이 아니면(강제 푸시) 셀 수 없다. 커밋이 아예 지워진 것은 nil 로 온다.
    func testForcePushed() {
        XCTAssertEqual(SinceApproval.classify(compare("diverged", files: [file("A.swift")]), commentedPaths: []).kind,
                       .forcePushed)
        let gone = SinceApproval.classify(nil, commentedPaths: [])
        XCTAssertEqual(gone.kind, .forcePushed)
        XCTAssertNil(gone.numbersLine)
    }

    /// base 를 받아온 머지뿐이면 compare 의 파일 목록이 base 변경으로 차 있어도 작성자가 바꾼 것은 없다.
    func testBaseMergeOnly() {
        let since = SinceApproval.classify(compare(commits: [2], files: [file("Other/Feature.swift", 500)]),
                                           commentedPaths: ["Other/Feature.swift"])
        XCTAssertEqual(since.kind, .baseMergeOnly)
        XCTAssertEqual(since.numbersLine, "1 commit since approval")
    }

    /// 머지와 작성자 커밋이 섞이면 작성자 커밋의 파일로 가른다 — base 에서 온 변경으로 "코드" 가 되면 안 된다.
    func testMixedUsesAuthorFiles() {
        let comparison = compare(commits: [1, 2], files: [file("docs/a.md"), file("Base/Merged.swift", 300)])
        XCTAssertTrue(comparison.needsAuthorFiles)
        let since = SinceApproval.classify(comparison, authorFiles: [file("docs/a.md")], commentedPaths: [])
        XCTAssertEqual(since.kind, .docsOnly)
        XCTAssertEqual(since.commits, 2)
        XCTAssertEqual(since.numbersLine, "2 commits · 1 file · +1 −0 since approval")
    }
}
