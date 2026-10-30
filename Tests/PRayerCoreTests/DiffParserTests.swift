import XCTest
@testable import PRayerCore

final class DiffParserTests: XCTestCase {
    static let sample = """
    diff --git a/Sources/Foo.swift b/Sources/Foo.swift
    index 1111111..2222222 100644
    --- a/Sources/Foo.swift
    +++ b/Sources/Foo.swift
    @@ -10,4 +10,5 @@ final class Foo {
         func bar() {
    -        let x = try! compute()
    +        guard let x = try? compute() else { return }
    +        print(x)
         }
     }
    diff --git a/App.xcodeproj/project.pbxproj b/App.xcodeproj/project.pbxproj
    --- a/App.xcodeproj/project.pbxproj
    +++ b/App.xcodeproj/project.pbxproj
    @@ -1,2 +1,3 @@
     unchanged
    +added
    """

    func testParsesFilesAndLineNumbers() {
        let diff = DiffParser.parse(Self.sample)
        XCTAssertEqual(diff.files.count, 2)

        guard let foo = diff.files.first(where: { $0.path == "Sources/Foo.swift" }) else {
            return XCTFail("Foo.swift 를 찾지 못했습니다.")
        }
        XCTAssertEqual(foo.additions, 2)
        XCTAssertEqual(foo.deletions, 1)

        let deletion = foo.lines.first { $0.kind == .deletion }
        XCTAssertEqual(deletion?.oldLine, 11)
        XCTAssertNil(deletion?.newLine)
        XCTAssertEqual(deletion?.text, "        let x = try! compute()")

        let additions = foo.lines.filter { $0.kind == .addition }
        XCTAssertEqual(additions.map(\.newLine), [11, 12])

        let firstContext = foo.lines.first { $0.kind == .context }
        XCTAssertEqual(firstContext?.oldLine, 10)
        XCTAssertEqual(firstContext?.newLine, 10)

        // 삭제 1줄 + 추가 2줄 뒤의 컨텍스트는 old 12 / new 13 이어야 한다.
        let contexts = foo.lines.filter { $0.kind == .context }
        XCTAssertEqual(contexts.dropFirst().first?.oldLine, 12)
        XCTAssertEqual(contexts.dropFirst().first?.newLine, 13)
    }

    func testExclusionMovesGeneratedFilesOut() {
        let diff = DiffParser.parse(Self.sample, excluding: ["*.pbxproj"])
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files[0].path, "Sources/Foo.swift")
        XCTAssertEqual(diff.excludedFiles.count, 1)
        XCTAssertEqual(diff.excludedFiles[0].path, "App.xcodeproj/project.pbxproj")
        XCTAssertEqual(diff.excludedFiles[0].changedLines, 1)
        XCTAssertEqual(diff.changedLines, 3)
    }

    func testHunkHeaderParsing() {
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -12,7 +14,9 @@ func foo()")?.oldStart, 12)
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -12,7 +14,9 @@ func foo()")?.newStart, 14)
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -0,0 +1 @@")?.newStart, 1)
        XCTAssertNil(DiffParser.parseHunkHeader("not a hunk"))
    }

    func testNewFileDetection() {
        let text = """
        diff --git a/New.swift b/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,2 @@
        +import Foundation
        +// hello
        """
        let diff = DiffParser.parse(text)
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertTrue(diff.files[0].isNew)
        XCTAssertEqual(diff.files[0].lines.filter { $0.kind == .addition }.map(\.newLine), [1, 2])
    }

    func testNumberedDiffUsesSidePrefixes() {
        let diff = DiffParser.parse(Self.sample, excluding: ["*.pbxproj"])
        let numbered = PromptBuilder.numberedDiff(diff)
        XCTAssertTrue(numbered.contains("--- FILE: Sources/Foo.swift ---"))
        XCTAssertTrue(numbered.contains("L011 |-        let x = try! compute()"))
        XCTAssertTrue(numbered.contains("R011 |+        guard let x = try? compute() else { return }"))
        XCTAssertTrue(numbered.contains("R012 |+        print(x)"))
        XCTAssertFalse(numbered.contains("pbxproj"))
    }
}
