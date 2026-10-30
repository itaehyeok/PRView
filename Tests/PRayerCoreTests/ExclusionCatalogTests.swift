import XCTest
@testable import PRayerCore

/// 제외 규칙 자동완성 — 레포 파일에서 후보를 만들고, 친 글자에 맞는 것을 최근 PR 에서 자주 바뀐 순으로 띄운다.
final class ExclusionCatalogTests: XCTestCase {
    private let paths = [
        "App/Info.plist",
        "App/Settings.plist",
        "App/Main.swift",
        "App/View.swift",
        "Modules/Core/Package.swift",
        "Modules/Core/Package.resolved",
        "App/Assets.xcassets/Icon.imageset/Contents.json",
        "App/Assets.xcassets/Icon.imageset/icon.png",
        "App/Assets.xcassets/Contents.json",
        "Pods/Alamofire/Source.swift",
        "Pods/Alamofire/Other.swift",
        "Scripts/build.pl",
    ]

    private func pr(_ files: (String, Int)...) -> [ExclusionCatalog.PRFile] {
        files.map { ExclusionCatalog.PRFile(path: $0.0, additions: $0.1, deletions: 0) }
    }

    /// `*.pl` 을 치면 `*.plist` 가 뜬다(사용자 예시). `*.` 로 시작하면 확장자만 — 파일 이름이 끼지 않는다.
    func testExtensionPrefix() {
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [])
        let found = catalog.suggestions(for: "*.pl").map(\.pattern)
        XCTAssertEqual(Set(found), ["*.plist", "*.pl"])
        XCTAssertFalse(found.contains("Package.swift"))
        let plist = catalog.suggestions(for: "*.pl").first { $0.pattern == "*.plist" }
        XCTAssertEqual(plist?.repoFiles, 2)
        XCTAssertEqual(plist?.kind, .fileExtension)
    }

    /// 최근 PR 에서 자주 바뀐 것이 위로 — 레포에 더 많아도 PR 에서 안 바뀌면 아래.
    func testRanksByRecentPRs() {
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [
            pr(("Scripts/build.pl", 5)),
            pr(("Scripts/build.pl", 7), ("App/Info.plist", 1)),
            pr(("Scripts/build.pl", 2)),
        ])
        let found = catalog.suggestions(for: "*.pl")
        XCTAssertEqual(found.first?.pattern, "*.pl")
        XCTAssertEqual(found.first?.prCount, 3)
        XCTAssertEqual(found.first?.changedLines, 14)
        XCTAssertEqual(found.last?.pattern, "*.plist")
        XCTAssertEqual(found.last?.prCount, 1)
    }

    /// 확장자 달린 폴더는 `*.xcassets/*`, 그냥 폴더는 `Pods/*`, 파일 이름은 그대로 — Glob 이 읽는 꼴.
    func testFolderAndNameCandidates() {
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [])
        let xcassets = catalog.suggestions(for: "xcass").first
        XCTAssertEqual(xcassets?.pattern, "*.xcassets/*")
        XCTAssertEqual(xcassets?.kind, .folder)
        XCTAssertEqual(xcassets?.repoFiles, 3)
        XCTAssertEqual(catalog.suggestions(for: "Pods").first?.pattern, "Pods/*")
        let names = catalog.suggestions(for: "Pack").map(\.pattern)
        XCTAssertTrue(names.contains("Package.swift"))
        XCTAssertTrue(names.contains("Package.resolved"))
        // 후보 수는 그 규칙을 Glob 으로 잰 수와 같아야 한다 — 화면 숫자가 실제로 빠지는 수다.
        for suggestion in catalog.suggestions(for: "a", limit: 50) {
            XCTAssertEqual(catalog.stats(for: suggestion.pattern).repoFiles, suggestion.repoFiles, suggestion.pattern)
        }
    }

    /// 코드를 빼는 규칙에는 경고를 단다. 폴더는 안의 절반 넘게가 코드일 때.
    func testCodeWarning() {
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [])
        XCTAssertEqual(catalog.suggestions(for: "*.sw").first?.isCode, true)
        XCTAssertEqual(catalog.suggestions(for: "Pods").first?.isCode, true)
        XCTAssertEqual(catalog.suggestions(for: "*.pli").first?.isCode, false)
        XCTAssertEqual(catalog.suggestions(for: "Package.s").first?.isCode, true)
    }

    /// 꼴 표시는 떼고 견준다. 세 글자부터는 가운데가 맞아도 띄운다(앞부분이 맞는 것이 먼저).
    func testNormalizeAndContains() {
        XCTAssertEqual(ExclusionCatalog.normalized(" *.PL "), "pl")
        XCTAssertEqual(ExclusionCatalog.normalized("Pods/*"), "pods")
        XCTAssertEqual(ExclusionCatalog.normalized("Pods/"), "pods")
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [])
        XCTAssertTrue(catalog.suggestions(for: "set").contains { $0.pattern == "*.imageset/*" || $0.pattern == "Settings.plist" })
        XCTAssertTrue(catalog.suggestions(for: "").isEmpty)
        XCTAssertTrue(catalog.suggestions(for: "zz").isEmpty)
    }

    /// 기본 브랜치에 없어도 PR 에 나온 새 파일은 후보가 된다(레포 수는 0).
    func testPRonlyFilesBecomeCandidates() {
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [pr(("Docs/guide.mdx", 40))])
        let mdx = catalog.suggestions(for: "*.mdx").first
        XCTAssertEqual(mdx?.repoFiles, 0)
        XCTAssertEqual(mdx?.prCount, 1)
    }

    /// 이미 있는 규칙(아무 꼴이든)도 Glob 으로 잰다 — 목록 옆 숫자.
    func testStatsForExistingRules() {
        let catalog = ExclusionCatalog(paths: paths, pullRequests: [pr(("App/Info.plist", 3)), pr(("App/View.swift", 1))])
        XCTAssertEqual(catalog.stats(for: "*.plist").repoFiles, 2)
        XCTAssertEqual(catalog.stats(for: "*.plist").prCount, 1)
        XCTAssertEqual(catalog.stats(for: "Package.resolved").repoFiles, 1)
        XCTAssertEqual(catalog.stats(for: "*.xcassets/*").repoFiles, 3)
        XCTAssertEqual(catalog.stats(for: "Nope/*").repoFiles, 0)
    }

    /// 이름에 fnmatch 특수 글자가 있으면 글자 그대로 읽게 막은 꼴로 띄운다(ExclusionPattern.escaped).
    func testSpecialCharactersAreEscaped() {
        let catalog = ExclusionCatalog(paths: ["Sources/Item[1].swift"], pullRequests: [])
        let found = catalog.suggestions(for: "Item").first
        XCTAssertEqual(found?.pattern, "Item\\[1\\].swift")
        XCTAssertEqual(catalog.stats(for: found?.pattern ?? "").repoFiles, 1)
    }
}
