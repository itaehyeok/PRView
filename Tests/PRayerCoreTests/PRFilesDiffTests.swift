import XCTest
@testable import PRayerCore

/// GitHub 이 통째로 주지 않는 큰 PR 을 파일 목록으로 받아 다시 짠 diff.
///
/// 실측: 파일 1,107개를 옮긴 PR — 바뀐 줄은 +210 −111 인데 diff·리뷰·요약이 모두 실패했다. 파일 목록으로
/// 받으면 1,078개가 이름만 바뀐 파일·이미지라, 다시 짠 diff 가 git 과 같게 읽히는지와 그런 파일이 프롬프트를
/// 부풀리지 않는지를 본다.
final class PRFilesDiffTests: XCTestCase {
    private let files: [PRFilesDiff.File] = [
        .init(filename: "Sources/A.swift", status: "modified",
              patch: "@@ -1,2 +1,2 @@\n import Foundation\n-let a = 1\n+let a = 2", changes: 2),
        .init(filename: "Sources/New.swift", status: "added", patch: "@@ -0,0 +1 @@\n+struct New {}", changes: 1),
        .init(filename: "Sources/Old.swift", status: "removed", patch: "@@ -1 +0,0 @@\n-struct Old {}", changes: 1),
        .init(filename: "Packages/Core/Moved.swift", previous_filename: "Sources/Moved.swift", status: "renamed", changes: 0),
        .init(filename: "Packages/Core/Edited.swift", previous_filename: "Sources/Edited.swift", status: "renamed",
              patch: "@@ -3 +3 @@\n-old\n+new", changes: 2),
        .init(filename: "Assets/icon.png", status: "added", changes: 0),
    ]

    func testRebuiltDiffParsesLikeGit() throws {
        let parsed = DiffParser.parse(PRFilesDiff.unifiedDiff(from: files))
        XCTAssertEqual(parsed.files.map(\.path), ["Sources/A.swift", "Sources/New.swift", "Sources/Old.swift",
                                                  "Packages/Core/Moved.swift", "Packages/Core/Edited.swift", "Assets/icon.png"])

        let modified = try XCTUnwrap(parsed.file(matching: "Sources/A.swift"))
        XCTAssertEqual(modified.additions, 1)
        XCTAssertEqual(modified.deletions, 1)
        XCTAssertTrue(try XCTUnwrap(parsed.file(matching: "Sources/New.swift")).isNew)
        XCTAssertTrue(try XCTUnwrap(parsed.file(matching: "Sources/Old.swift")).isDeleted)

        // 내용이 그대로인 이름 변경: 줄은 없고 옛 경로만 남는다.
        let moved = try XCTUnwrap(parsed.file(matching: "Packages/Core/Moved.swift"))
        XCTAssertEqual(moved.oldPath, "Sources/Moved.swift")
        XCTAssertTrue(moved.lines.isEmpty)
        XCTAssertFalse(moved.isBinary)

        // 옮기면서 고친 파일은 줄 번호까지 제대로 읽혀야 코멘트 줄 검사가 통한다.
        let edited = try XCTUnwrap(parsed.file(matching: "Packages/Core/Edited.swift"))
        XCTAssertEqual(edited.oldPath, "Sources/Edited.swift")
        XCTAssertEqual(edited.lines.first { $0.kind == .addition }?.newLine, 3)

        // patch 가 없는 파일(바이너리이거나 너무 큼)은 있다는 것만 남긴다.
        let icon = try XCTUnwrap(parsed.file(matching: "Assets/icon.png"))
        XCTAssertTrue(icon.isBinary)
        XCTAssertTrue(icon.isNew)
    }

    /// 내용 없는 파일은 20개까지만 이름을 적고 나머지는 개수로 — 머리 줄에 토큰을 쓰지 않는다.
    func testPromptBundlesContentlessFiles() {
        var many = files
        for index in 0..<50 {
            many.append(.init(filename: "Packages/Core/F\(index).swift", previous_filename: "Sources/F\(index).swift",
                              status: "renamed", changes: 0))
        }
        for index in 0..<30 {
            many.append(.init(filename: "Assets/img\(index).png", status: "added"))
        }
        let numbered = PromptBuilder.numberedDiff(DiffParser.parse(PRFilesDiff.unifiedDiff(from: many)))

        XCTAssertTrue(numbered.contains("--- FILE: Sources/A.swift ---"))
        XCTAssertTrue(numbered.contains("--- FILE: Packages/Core/Edited.swift ---"), "옮기면서 고친 파일은 내용째 넣는다")
        XCTAssertTrue(numbered.contains("내용 변경 없이 이름만 바뀐 파일 51개"))
        XCTAssertTrue(numbered.contains("- Sources/Moved.swift → Packages/Core/Moved.swift"))
        XCTAssertTrue(numbered.contains("- … 외 31개\n"))
        XCTAssertTrue(numbered.contains("내용을 볼 수 없는 파일 31개"))
        XCTAssertTrue(numbered.contains("외 11개 (png 11)"))
        XCTAssertFalse(numbered.contains("--- FILE: Packages/Core/F7.swift"), "이름만 바뀐 파일에 머리 줄을 쓰지 않는다")
        XCTAssertLessThan(numbered.count, 6_000)
    }

    func testRecognizesTooLargeErrors() {
        XCTAssertTrue(PRFilesDiff.isTooLargeError(
            "gh: Sorry, the diff exceeded the maximum number of files (300). Consider using 'List pull requests files' API or locally cloning the repository instead. (HTTP 406)"))
        XCTAssertTrue(PRFilesDiff.isTooLargeError("gh: Sorry, the diff exceeded the maximum number of lines (20000)."))
        XCTAssertFalse(PRFilesDiff.isTooLargeError("gh: Not Found (HTTP 404)"))
    }

    func testDecodesGitHubFilesPayload() throws {
        let json = #"[{"sha":"x","filename":"b/New.swift","status":"renamed","additions":0,"deletions":0,"changes":0,"previous_filename":"a/Old.swift","blob_url":"u"}]"#
        let decoded = try JSONDecoder().decode([PRFilesDiff.File].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.previous_filename, "a/Old.swift")
        XCTAssertNil(decoded.first?.patch)
    }
}
