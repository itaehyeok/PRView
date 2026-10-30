import XCTest
@testable import PRayerCore

/// 리뷰 전에 "빼고 리뷰할까요?" 로 물을 파일 고르기 — 한 파일 1,000줄 넘게 바뀐 것.
final class SkippableFilesTests: XCTestCase {
    private func file(_ path: String, add: Int, del: Int = 0, binary: Bool = false, deleted: Bool = false) -> DiffFile {
        DiffFile(path: path, oldPath: path, isBinary: binary, isNew: false, isDeleted: deleted, lines: [],
                 additions: add, deletions: del)
    }

    private func pick(_ files: [DiffFile]) -> [String] {
        SkippableFiles.find(in: ParsedDiff(files: files, excludedFiles: [])).map(\.path)
    }

    /// 실측 사례: 생성된 목록을 통째로 넣은 설정 파일(각 1,043줄).
    func testHugeFilesAreAskedWhateverTheirKind() {
        XCTAssertEqual(pick([file("App/Info-Release.plist", add: 1043),
                             file("Sources/Generated/Strings.swift", add: 1820),
                             file("web/src/App.tsx", add: 600, del: 400)]),
                       ["App/Info-Release.plist", "Sources/Generated/Strings.swift", "web/src/App.tsx"])
    }

    func testBelowThresholdIsNotAsked() {
        XCTAssertEqual(pick([file("App.xcodeproj/project.pbxproj", add: 54, del: 519),
                             file("docs/spec/home.md", add: 339),
                             file("Sources/Home/NewViewController.swift", add: 675),
                             file("Config/Big.json", add: 600, del: 399)]), [],
                       "999줄까지는 묻지 않는다")
    }

    /// 지운 코드도 리뷰에 넣는다(사용자 결정). 이미지는 줄이 없다.
    func testDeletedAndBinaryFilesAreNeverAsked() {
        XCTAssertEqual(pick([file("Legacy/OldViewController.m", add: 0, del: 1146, deleted: true),
                             file("Assets/icon.png", add: 0, binary: true)]), [])
    }

    /// 잠금 파일은 이미 '제외됨' 에 있어 묻지 않는다(늘 빠진다).
    func testLockFilesNeverReachTheQuestion() {
        let body = (0..<1200).map { "+line\($0)" }.joined(separator: "\n")
        let text = """
        diff --git a/package-lock.json b/package-lock.json
        --- a/package-lock.json
        +++ b/package-lock.json
        @@ -0,0 +1,1200 @@
        \(body)
        """
        let diff = DiffParser.parse(text)
        XCTAssertEqual(diff.excludedFiles.first?.changedLines, 1200)
        XCTAssertTrue(SkippableFiles.find(in: diff).isEmpty)
    }
}
