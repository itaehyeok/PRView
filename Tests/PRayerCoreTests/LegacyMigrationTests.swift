import XCTest
@testable import PRayerCore

/// 옛 이름의 데이터 폴더·로그·UserDefaults 를 새 이름으로 옮기는 경로. 실제 폴더 대신 임시 폴더로 잰다.
final class LegacyMigrationTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("prayer-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - 이름

    /// 꼬리를 맞춘다. 맞추지 않으면 작업본이 먼저 켜졌을 때 실제 데이터 폴더를 가져간다.
    func testLegacyNamesKeepSuffix() {
        XCTAssertEqual(LegacyMigration.legacyDirectoryNames(for: "PRayer"), ["PRMap", "PRDeck"])
        XCTAssertEqual(LegacyMigration.legacyDirectoryNames(for: "PRayer-work"), ["PRMap-work", "PRDeck-work"])
        XCTAssertEqual(LegacyMigration.legacyDirectoryNames(for: "custom-dir"), [], "앱 이름으로 시작하지 않으면 옮기지 않는다")
    }

    func testLegacyBundleIDs() {
        XCTAssertEqual(LegacyMigration.legacyBundleIDs(for: "dev.itaehyeok.PRayer"), ["dev.itaehyeok.PRMapApp"])
        XCTAssertEqual(LegacyMigration.legacyBundleIDs(for: "dev.itaehyeok.PRayer.work"), ["dev.itaehyeok.PRMapApp.work"])
        XCTAssertEqual(LegacyMigration.legacyBundleIDs(for: "dev.itaehyeok.PRayerCoreTests"), [])
        XCTAssertEqual(LegacyMigration.legacyBundleIDs(for: "com.apple.dt.xctest.tool"), [])
    }

    // MARK: - 데이터 폴더

    func testMovesWholeFolderWhenNewOneIsMissing() throws {
        let old = try makeFolder("PRMap", files: ["settings.json": "{}", "drafts/o/r/1.json": "draft", "prmap.log": "old\n"])

        XCTAssertNotNil(LegacyMigration.migrateDataFolder(base: base, current: "PRayer"))

        let new = base.appendingPathComponent("PRayer")
        XCTAssertEqual(try read(new, "settings.json"), "{}")
        XCTAssertEqual(try read(new, "drafts/o/r/1.json"), "draft")
        XCTAssertEqual(try read(new, "prayer.log"), "old\n", "로그 이름도 바꾼다")
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("prmap.log").path))
        XCTAssertFalse(fm.fileExists(atPath: old.path), "옛 폴더는 남지 않는다")
    }

    /// 로그·테스트가 새 폴더를 먼저 만들어 둔 경우. 건너뛰면 데이터가 통째로 사라진 것처럼 보인다.
    func testMergesIntoEmptySkeleton() throws {
        let old = try makeFolder("PRMap", files: ["settings.json": "{\"model\":\"opus\"}",
                                                   "drafts/o/r/1.json": "draft", "prmap.log": "old\n",
                                                   "token-ledger.json": "real ledger"])
        _ = try makeFolder("PRayer", files: ["prayer.log": "new\n", "drafts/o/r/2.json": "test draft",
                                             "token-ledger.json": "test ledger"])

        XCTAssertNotNil(LegacyMigration.migrateDataFolder(base: base, current: "PRayer"))

        let new = base.appendingPathComponent("PRayer")
        XCTAssertEqual(try read(new, "settings.json"), "{\"model\":\"opus\"}")
        XCTAssertEqual(try read(new, "drafts/o/r/1.json"), "draft", "같은 이름 폴더는 안으로 들어가 합친다")
        XCTAssertEqual(try read(new, "drafts/o/r/2.json"), "test draft", "새 쪽에만 있던 것은 그대로 둔다")
        XCTAssertEqual(try read(new, "token-ledger.json"), "real ledger", "겹치면 진짜 데이터(옛 쪽)를 남긴다")
        XCTAssertEqual(try read(new, "prayer.log"), "old\nnew\n", "옛 로그 뒤에 새 로그를 잇는다")
        XCTAssertFalse(fm.fileExists(atPath: old.path))
    }

    /// 새 폴더에 설정이 이미 있으면 옮긴 뒤이거나 새로 시작한 것이다. 덮어쓰지 않는다.
    func testLeavesAloneWhenNewFolderHasSettings() throws {
        let old = try makeFolder("PRMap", files: ["settings.json": "old"])
        _ = try makeFolder("PRayer", files: ["settings.json": "new"])

        XCTAssertNil(LegacyMigration.migrateDataFolder(base: base, current: "PRayer"))

        XCTAssertEqual(try read(base.appendingPathComponent("PRayer"), "settings.json"), "new")
        XCTAssertTrue(fm.fileExists(atPath: old.path))
    }

    func testWorkCopyDoesNotTakeRealData() throws {
        let real = try makeFolder("PRMap", files: ["settings.json": "real"])

        XCTAssertNil(LegacyMigration.migrateDataFolder(base: base, current: "PRayer-work"))

        XCTAssertEqual(try read(real, "settings.json"), "real")
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("PRayer-work").path))
    }

    func testOlderNameIsUsedWhenNewerIsAbsent() throws {
        _ = try makeFolder("PRDeck", files: ["settings.json": "deck"])

        XCTAssertNotNil(LegacyMigration.migrateDataFolder(base: base, current: "PRayer"))

        XCTAssertEqual(try read(base.appendingPathComponent("PRayer"), "settings.json"), "deck")
    }

    // MARK: - UserDefaults

    func testDefaultsMoveOnlyIntoEmptyDomain() {
        let old = "test.prayer.legacy.\(UUID().uuidString)"
        let new = "test.prayer.current.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        defaults.setPersistentDomain(["showPRList": false, "prListScope": "open"], forName: old)

        XCTAssertNotNil(LegacyMigration.migrateDefaults(to: new, from: [old], defaults: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: new)?["prListScope"] as? String, "open")
        XCTAssertNotNil(defaults.persistentDomain(forName: old), "옛 쪽은 지우지 않는다")

        defaults.setPersistentDomain(["showPRList": true], forName: new)
        XCTAssertNil(LegacyMigration.migrateDefaults(to: new, from: [old], defaults: defaults), "새 쪽에 값이 있으면 덮어쓰지 않는다")
        XCTAssertEqual(defaults.persistentDomain(forName: new)?["showPRList"] as? Bool, true)
    }

    // MARK: - 도우미

    @discardableResult
    private func makeFolder(_ name: String, files: [String: String]) throws -> URL {
        let folder = base.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    private func read(_ folder: URL, _ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }
}
