import XCTest
@testable import PRayerCore

/// "응용 프로그램 폴더로 옮기기" 의 사본 만들기. 사본에 격리 딱지가 남으면 새 자리에서도 다시
/// 격리 실행되고, 프레임워크 안 심볼릭 링크가 풀리면 코드 서명이 깨진다.
final class AppBundleCopyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppBundleCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func setQuarantine(_ url: URL) {
        let value = "0081;66f8a1b2;Safari;"
        _ = value.withCString { setxattr(url.path, AppBundleCopy.quarantineAttribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    func testCopyKeepsSymlinksAndQuarantineIsRemovedFromCopyOnly() throws {
        let fm = FileManager.default
        let app = root.appendingPathComponent("Fake.app")
        let versions = app.appendingPathComponent("Contents/Frameworks/X.framework/Versions")
        try fm.createDirectory(at: versions.appendingPathComponent("A"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: versions.appendingPathComponent("A/X"))
        try fm.createSymbolicLink(atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "A")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Fake")
        try Data("exe".utf8).write(to: executable)
        setQuarantine(app)
        setQuarantine(executable)
        XCTAssertTrue(AppBundleCopy.hasQuarantine(app))

        let copy = root.appendingPathComponent("Copy.app")
        try AppBundleCopy.copy(app, to: copy)
        // ditto 는 확장 속성을 따라 옮긴다 — 그래서 따로 떼야 한다.
        XCTAssertTrue(AppBundleCopy.hasQuarantine(copy))
        try AppBundleCopy.removeQuarantine(at: copy)
        XCTAssertFalse(AppBundleCopy.hasQuarantine(copy))

        let link = copy.appendingPathComponent("Contents/Frameworks/X.framework/Versions/Current").path
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), "A")
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("Contents/MacOS/Fake")), Data("exe".utf8))
        // 원본은 건드리지 않는다.
        XCTAssertTrue(AppBundleCopy.hasQuarantine(app))
    }

    /// 딱지가 없는 번들에서 떼도 실패하지 않는다.
    func testRemovingAbsentQuarantineIsFine() throws {
        let app = root.appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        XCTAssertNoThrow(try AppBundleCopy.removeQuarantine(at: app))
        XCTAssertFalse(AppBundleCopy.hasQuarantine(app))
    }

    /// 실제 서명된 PRayer 를 딱지 붙여 복사 → 딱지 떼기 → 서명 검사가 그대로 통과해야 한다.
    /// 이 맥에 깔린 PRayer 가 없으면 건너뛴다.
    func testRealSignedAppStaysValidAfterCopy() throws {
        let candidates = ["/Applications/PRayer.app",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PRayer.app").path]
        guard let installed = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("깔린 PRayer 가 없다")
        }
        let source = root.appendingPathComponent("Source.app")
        try AppBundleCopy.copy(URL(fileURLWithPath: installed), to: source)
        setQuarantine(source)
        let copy = root.appendingPathComponent("PRayer.app")
        try AppBundleCopy.copy(source, to: copy)
        try AppBundleCopy.removeQuarantine(at: copy)
        XCTAssertFalse(AppBundleCopy.hasQuarantine(copy))

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", copy.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)
    }
}
