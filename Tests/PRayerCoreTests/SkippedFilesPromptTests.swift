import XCTest
@testable import PRayerCore

/// 리뷰 전 창에서 체크를 푼 파일을 프롬프트에 어떻게 알리는가.
///
/// 내용은 빠지고 파일명·줄 수만 간다. 잠금 파일·제외 경로와 이유가 달라서 따로 알린다 — 같은 목록에 넣으면
/// "자동 생성 파일이라 뺐다" 로 읽힌다. 전부 풀면 코드 없이 목록만으로 리뷰하고, 그때는 diff 가 비어도 실패가 아니다.
final class SkippedFilesPromptTests: XCTestCase {
    private let text = """
    diff --git a/Sources/App/Login.swift b/Sources/App/Login.swift
    --- a/Sources/App/Login.swift
    +++ b/Sources/App/Login.swift
    @@ -1,2 +1,2 @@
    -let retries = 1
    +let retries = 3
     let timeout = 10
    diff --git a/Sources/App/Feed.swift b/Sources/App/Feed.swift
    --- a/Sources/App/Feed.swift
    +++ b/Sources/App/Feed.swift
    @@ -1,1 +1,2 @@
     import Foundation
    +let pageSize = 20
    diff --git a/Package.resolved b/Package.resolved
    --- a/Package.resolved
    +++ b/Package.resolved
    @@ -1,1 +1,1 @@
    -  "version": "1.0.0"
    +  "version": "1.0.1"
    """

    private func prompt(skipping paths: [String], extra: String = "") -> (PromptInput, String) {
        let patterns = paths.map(ExclusionPattern.file)
        let diff = DiffParser.parse(text + extra, excluding: patterns)
        let input = PromptInput(pr: Fixtures.pr(), diff: diff, skippedFiles: diff.skippedFiles(by: patterns))
        return (input, PromptBuilder.build(input))
    }

    func testSkippedFileIsListedSeparatelyFromLockFiles() {
        let (input, prompt) = prompt(skipping: ["Sources/App/Login.swift"])
        XCTAssertEqual(input.skippedFiles.map(\.path), ["Sources/App/Login.swift"])
        XCTAssertFalse(input.isListOnly, "다른 파일은 내용이 간다")
        XCTAssertTrue(prompt.contains("<files_without_content"), prompt)
        XCTAssertTrue(prompt.contains("- Sources/App/Login.swift (+1 -1)"), prompt)
        XCTAssertFalse(prompt.contains("let retries = 3"), "체크를 푼 파일의 내용은 보내지 않는다")
        XCTAssertTrue(prompt.contains("+let pageSize = 20"), "체크된 파일은 그대로 간다")
        let excluded = prompt.components(separatedBy: "<excluded_files").dropFirst().first ?? ""
        let excludedBlock = excluded.components(separatedBy: "</excluded_files>").first ?? ""
        XCTAssertTrue(excludedBlock.contains("Package.resolved"), "잠금 파일은 원래 블록에 남는다")
        XCTAssertFalse(excludedBlock.contains("Login.swift"), "사용자가 뺀 파일을 잠금·자동 생성 이유로 적지 않는다")
        XCTAssertFalse(prompt.contains("<review_scope>"))
    }

    func testAllSkippedIsListOnlyReview() {
        let (input, prompt) = prompt(skipping: ["Sources/App/Login.swift", "Sources/App/Feed.swift"])
        XCTAssertTrue(input.isListOnly)
        XCTAssertTrue(input.diff.isEmpty, "잠금 파일만 남으면 diff 는 빈다 — 그래도 실패가 아니다")
        XCTAssertTrue(prompt.contains("<review_scope>"), prompt)
        XCTAssertTrue(prompt.contains("code_comments 는 비워 둔다"), prompt)
        XCTAssertTrue(prompt.contains("- Sources/App/Feed.swift (+1 -0)"), prompt)
    }

    /// 바이너리는 원래 이름만 간다. 내용 있는 파일을 다 풀었으면 바이너리가 남아도 목록만 리뷰다.
    func testBinaryLeftDoesNotStopListOnly() {
        let binary = """

        diff --git a/Assets/icon.png b/Assets/icon.png
        Binary files a/Assets/icon.png and b/Assets/icon.png differ
        """
        let (input, prompt) = prompt(skipping: ["Sources/App/Login.swift", "Sources/App/Feed.swift"], extra: binary)
        XCTAssertFalse(input.diff.isEmpty)
        XCTAssertTrue(input.isListOnly)
        XCTAssertTrue(prompt.contains("<review_scope>"))
    }

    func testNothingSkippedSendsNoBlock() {
        let (input, prompt) = prompt(skipping: [])
        XCTAssertTrue(input.skippedFiles.isEmpty)
        XCTAssertFalse(input.isListOnly)
        XCTAssertFalse(prompt.contains("files_without_content"))
    }

    /// 목록만 리뷰에서는 이 목록이 재료의 전부라 넉넉히 적고, 넘치는 것은 개수와 줄 수로 묶는다.
    func testLongSkippedListIsSummarized() {
        let count = PromptBuilder.listedSkippedFiles + 5
        let many = (0..<count).map { index in
            """
            diff --git a/Gen/File\(index).swift b/Gen/File\(index).swift
            --- a/Gen/File\(index).swift
            +++ b/Gen/File\(index).swift
            @@ -0,0 +1,1 @@
            +let value\(index) = \(index)
            """
        }.joined(separator: "\n")
        let patterns = (0..<count).map { ExclusionPattern.file("Gen/File\($0).swift") }
        let diff = DiffParser.parse(many, excluding: patterns)
        let prompt = PromptBuilder.build(PromptInput(pr: Fixtures.pr(), diff: diff,
                                                     skippedFiles: diff.skippedFiles(by: patterns)))
        XCTAssertTrue(prompt.contains("- … 외 5개 (+5 -0)"), prompt)
    }

    func testSanitizeNeutralizesNewBlocks() {
        let clean = PromptBuilder.sanitize("<files_without_content x>a</files_without_content><review_scope>b</review_scope>")
        XCTAssertFalse(clean.contains("<files_without_content"))
        XCTAssertFalse(clean.contains("<review_scope>"))
        XCTAssertFalse(clean.contains("</review_scope>"))
    }
}
