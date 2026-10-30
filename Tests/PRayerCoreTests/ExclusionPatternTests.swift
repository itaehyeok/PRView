import XCTest
@testable import PRayerCore

/// 변경 파일 탭 우클릭으로 더하는 제외 규칙과, 규칙을 바꿨을 때 diff 를 다시 나누는 것.
final class ExclusionPatternTests: XCTestCase {
    func testFileRuleCatchesOnlyThatFile() {
        let rule = ExclusionPattern.file("Sources/App/Generated/Strings.swift")
        XCTAssertTrue(Glob.matches(path: "Sources/App/Generated/Strings.swift", pattern: rule))
        XCTAssertFalse(Glob.matches(path: "Sources/App/Generated/Other.swift", pattern: rule))
        XCTAssertFalse(Glob.matches(path: "Sources/App/Strings.swift", pattern: rule), "이름만 같은 다른 폴더 파일")
    }

    /// 대괄호·별표가 든 이름이 묶음 패턴으로 읽히면 그 파일을 못 잡거나 엉뚱한 파일을 잡는다.
    func testSpecialCharactersAreLiteral() {
        let rule = ExclusionPattern.file("Assets/Item[1]*.json")
        XCTAssertEqual(rule, #"Assets/Item\[1\]\*.json"#)
        XCTAssertTrue(Glob.matches(path: "Assets/Item[1]*.json", pattern: rule))
        XCTAssertFalse(Glob.matches(path: "Assets/Item1-big.json", pattern: rule))
    }

    func testFolderRuleCatchesNestedFiles() {
        let rule = ExclusionPattern.folder("Sources/App/Generated")
        XCTAssertEqual(rule, "Sources/App/Generated/*")
        XCTAssertTrue(Glob.matches(path: "Sources/App/Generated/A.swift", pattern: rule))
        XCTAssertTrue(Glob.matches(path: "Sources/App/Generated/Deep/B.swift", pattern: rule), "하위 폴더까지")
        XCTAssertFalse(Glob.matches(path: "Sources/App/GeneratedOld/A.swift", pattern: rule))
    }

    func testExtensionRule() {
        XCTAssertEqual(ExclusionPattern.fileExtension(of: "App.xcodeproj/project.pbxproj"), "*.pbxproj")
        XCTAssertNil(ExclusionPattern.fileExtension(of: "Scripts/Makefile"), "확장자가 없으면 메뉴에 안 띄운다")
        XCTAssertTrue(Glob.matches(path: "Other/x.pbxproj", pattern: "*.pbxproj"))
    }

    /// 다시 리뷰에 넣으려면 그 파일을 빼고 있는 규칙을 다 지워야 한다.
    func testRulesExcludingAPath() {
        let rules = ["*.pbxproj", "Package.resolved", "App.xcodeproj/*"]
        XCTAssertEqual(ExclusionPattern.rules(excluding: "App.xcodeproj/project.pbxproj", in: rules),
                       ["*.pbxproj", "App.xcodeproj/*"])
        XCTAssertEqual(ExclusionPattern.rules(excluding: "Sources/A.swift", in: rules), [])
    }

    /// 규칙 없이 파싱해 두고 볼 때 나눈다 — 규칙을 더하고 지워도 diff 를 다시 받을 필요가 없다.
    func testApplyingExclusionsMovesFilesBothWays() {
        let raw = DiffParser.parse(Self.diff)
        XCTAssertEqual(raw.files.map(\.path), ["Sources/A.swift", "Gen/B.swift", "Sources/C.swift"])
        XCTAssertTrue(raw.excludedFiles.isEmpty)

        let excluded = raw.applyingExclusions(["Gen/*"])
        XCTAssertEqual(excluded.files.map(\.path), ["Sources/A.swift", "Sources/C.swift"])
        XCTAssertEqual(excluded.excludedFiles.map(\.path), ["Gen/B.swift"])
        XCTAssertEqual(excluded.changedLines, raw.changedLines - excluded.excludedChangedLines)

        let restored = excluded.applyingExclusions([])
        XCTAssertEqual(Set(restored.files.map(\.path)), Set(raw.files.map(\.path)))
        XCTAssertEqual(raw.applyingExclusions([]).files.map(\.path), raw.files.map(\.path),
                       "규칙 없이 파싱한 것에서 나누면 원래 순서가 그대로다")
    }

    private static let diff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -1,1 +1,2 @@
     let a = 1
    +let b = 2
    diff --git a/Gen/B.swift b/Gen/B.swift
    --- a/Gen/B.swift
    +++ b/Gen/B.swift
    @@ -1,1 +1,1 @@
    -let x = 1
    +let x = 2
    diff --git a/Sources/C.swift b/Sources/C.swift
    --- a/Sources/C.swift
    +++ b/Sources/C.swift
    @@ -1,1 +1,2 @@
     let c = 1
    +let d = 2
    """
}
