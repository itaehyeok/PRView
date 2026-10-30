import XCTest
@testable import PRayerCore

/// 설정 내보내기·가져오기.
///
/// 받는 파일은 남이 만든 것이고, 가져오면 내 설정이 바뀐다. 그래서 "고른 것만 바뀐다",
/// "목록은 합치기만 한다", "그 맥에서만 맞는 값은 담지 않는다" 를 테스트로 잠근다.
final class SettingsTransferTests: XCTestCase {
    private let exporterHome = "/Users/sender"
    private let importerHome = "/Users/receiver"

    private func sender() -> Settings {
        var s = Settings.default
        s.claudePath = "/Users/sender/.local/bin/claude"
        s.ghPath = "/opt/homebrew/bin/gh"
        s.onboardingCompleted = true
        s.repos = [
            RepoConfig(repo: RepoID(owner: "acme", name: "sample-ios"), prTargetBranch: "develop",
                       approvalThreshold: 3, approvalThresholdFromAPI: true),
            RepoConfig(repo: RepoID(owner: "acme", name: "sample-sdk"), prTargetBranch: "master",
                       approvalThreshold: 1, approvalThresholdFromAPI: false)
        ]
        s.deepReviewRepoPaths = ["acme/sample-ios": "/Users/sender/work/sample-ios",
                                 "acme/removed": "/Users/sender/work/removed"]
        s.hiddenLabels = ["DO NOT REVIEW", "DO NOT MERGE"]
        s.ignoredAuthors = ["someone-acme"]
        s.memberNicknames = ["riley-park-acme": "라일리"]
        s.model = "opus"
        s.effort = "high"
        s.codeFontName = "D2Coding"
        s.pollSeconds = 90
        s.notifyOnReviewDone = false
        return s
    }

    private func environment(hosts: [String] = ["github.com"], fonts: Set<String>? = nil) -> SettingsTransfer.ImportEnvironment {
        .init(home: importerHome, loggedInHosts: hosts,
              fontAvailable: { name in fonts.map { $0.contains(name) } ?? true })
    }

    /// 내보내기 화면에서 기본으로 고른 것만 담아 파일로 만들고 다시 읽는다.
    private func roundTrip(_ settings: Settings, selected: Set<String>? = nil) throws -> SettingsTransfer.ReadResult {
        let sections = SettingsTransfer.exportSections(settings, home: exporterHome)
        let file = SettingsTransfer.makeFile(settings, selected: selected ?? sections.defaultSelection,
                                             home: exporterHome, exportedBy: "sender-acme", appVersion: "0.4.7",
                                             now: Date(timeIntervalSince1970: 1_790_000_000))
        return try SettingsTransfer.read(SettingsTransfer.encode(file))
    }

    private func leaf(_ sections: [TransferSection], _ id: String) -> TransferItem? {
        sections.flatMap(\.leaves).first { $0.id == id }
    }

    // MARK: 내보내기

    /// 그 맥에서만 맞는 값(실행 파일 경로·온보딩 상태)은 파일에 아예 없다.
    func testExportLeavesOutMachineValues() throws {
        let s = sender()
        let sections = SettingsTransfer.exportSections(s, home: exporterHome)
        let file = SettingsTransfer.makeFile(s, selected: sections.selectableIDs, home: exporterHome,
                                             exportedBy: nil, appVersion: nil, now: Date())
        let text = String(decoding: try SettingsTransfer.encode(file), as: UTF8.self)
        XCTAssertFalse(text.contains("claudePath"))
        XCTAssertFalse(text.contains(".local/bin/claude"))
        XCTAssertFalse(text.contains("/opt/homebrew/bin/gh"))
        XCTAssertFalse(text.contains("onboardingCompleted"))
        // 보낸 사람의 사용자 이름이 든 경로가 남지 않는다. 로컬 클론 경로는 아예 담지 않는다.
        XCTAssertFalse(text.contains(exporterHome))
        XCTAssertFalse(text.contains("work/sample-ios"))
    }

    /// 로컬 클론 경로는 내보내지 않는다 — 전체 리뷰 클론은 받는 쪽 앱이 PR 스냅샷으로 받는다(ReviewClone).
    /// 연결해 둔 클론이 있는 사람이 내보내도 마찬가지다.
    func testExportLeavesOutClonePaths() throws {
        let s = sender()
        XCTAssertFalse(s.deepReviewRepoPaths.isEmpty)
        let read = try roundTrip(s, selected: SettingsTransfer.exportSections(s, home: exporterHome).selectableIDs)
        XCTAssertNil(read.file.settings.clonePaths)
    }

    /// 숨길 사람은 개인 사정이라 기본으로 담지 않는다. 고르지 않은 항목은 파일에 없다.
    func testExportDefaultSkipsIgnoredAuthors() throws {
        let read = try roundTrip(sender())
        XCTAssertNil(read.file.settings.ignoredAuthors)
        XCTAssertEqual(read.file.settings.hiddenLabels, ["DO NOT REVIEW", "DO NOT MERGE"])
        XCTAssertEqual(read.file.exportedBy, "sender-acme")
        XCTAssertEqual(read.file.appVersion, "0.4.7")
        XCTAssertTrue(read.skipped.isEmpty)
    }

    /// 꺼 둔 레포는 내보내지 않는다 — 받는 쪽에서는 켜진 채로 들어간다. 그 레포의 클론 경로도 담지 않는다.
    func testExportLeavesOutDisabledRepos() throws {
        var s = sender()
        s.repos[0].enabled = false  // acme/sample-ios — 클론 경로가 있는 레포
        let read = try roundTrip(s)
        XCTAssertEqual(read.file.settings.repos?.map(\.repo), ["acme/sample-sdk"])
        XCTAssertNil(read.file.settings.clonePaths)
    }

    func testExportSelectedReposOnly() throws {
        let read = try roundTrip(sender(), selected: [SettingsTransfer.ID.repo("acme/sample-sdk")])
        XCTAssertEqual(read.file.settings.repos?.map(\.repo), ["acme/sample-sdk"])
        XCTAssertNil(read.file.settings.hiddenLabels)
        XCTAssertNil(read.file.settings.reviewModel)
    }

    func testSuggestedFileName() {
        let name = SettingsTransfer.suggestedFileName(exportedBy: "riley-park-acme",
                                                      now: Date(timeIntervalSince1970: 1_790_000_000),
                                                      timeZone: TimeZone(identifier: "UTC") ?? .current)
        XCTAssertEqual(name, "PRView-설정-riley-park-acme-2026-09-21.json")
        XCTAssertEqual(SettingsTransfer.suggestedFileName(exportedBy: nil, now: Date(timeIntervalSince1970: 1_790_000_000),
                                                          timeZone: TimeZone(identifier: "UTC") ?? .current),
                       "PRView-설정-2026-09-21.json")
    }

    // MARK: 경로

    func testHomeAbbreviationAndExpansion() {
        XCTAssertEqual(SettingsTransfer.abbreviate("/Users/a/work/x", home: "/Users/a"), "~/work/x")
        XCTAssertEqual(SettingsTransfer.abbreviate("/Users/a", home: "/Users/a/"), "~")
        // 이름이 겹치는 다른 사용자 폴더를 홈으로 착각하지 않는다.
        XCTAssertEqual(SettingsTransfer.abbreviate("/Users/ab/work", home: "/Users/a"), "/Users/ab/work")
        XCTAssertEqual(SettingsTransfer.abbreviate("/Volumes/ssd/x", home: "/Users/a"), "/Volumes/ssd/x")
        XCTAssertEqual(SettingsTransfer.expand("~/work/x", home: "/Users/b"), "/Users/b/work/x")
        XCTAssertEqual(SettingsTransfer.expand("~", home: "/Users/b"), "/Users/b")
        XCTAssertEqual(SettingsTransfer.expand("/abs/path", home: "/Users/b"), "/abs/path")
    }

    // MARK: 가져오기 목록

    func testImportStatusesAgainstCurrentSettings() throws {
        let read = try roundTrip(sender())
        var mine = Settings.default
        mine.repos = [
            // 같은 레포, 같은 브랜치 — GitHub 에서 읽는 승인 수는 견주지 않는다.
            RepoConfig(repo: RepoID(owner: "ACME", name: "Sample-iOS"), prTargetBranch: "develop",
                       approvalThreshold: 2, approvalThresholdFromAPI: true)
        ]
        let sections = SettingsTransfer.importSections(read.file.settings, current: mine, environment: environment())
        XCTAssertEqual(leaf(sections, SettingsTransfer.ID.repo("acme/sample-ios"))?.status, .same)
        XCTAssertEqual(leaf(sections, SettingsTransfer.ID.repo("acme/sample-sdk"))?.status, .added)
        XCTAssertEqual(leaf(sections, SettingsTransfer.ID.hiddenLabels)?.status, .added)
        XCTAssertEqual(leaf(sections, SettingsTransfer.ID.reviewModel)?.status, .changed)

        // 같은 것은 고를 수 없고, 처음 선택에도 없다.
        XCTAssertFalse(sections.selectableIDs.contains(SettingsTransfer.ID.repo("acme/sample-ios")))
        XCTAssertFalse(sections.defaultSelection.contains(SettingsTransfer.ID.repo("acme/sample-ios")))
        XCTAssertTrue(sections.defaultSelection.contains(SettingsTransfer.ID.repo("acme/sample-sdk")))
    }

    /// 팀 규칙은 처음부터 고르고, 취향·개인 사정은 고르지 않는다.
    func testImportDefaultSelectionSkipsPersonalItems() throws {
        let read = try roundTrip(sender(), selected: SettingsTransfer.exportSections(sender(), home: exporterHome).selectableIDs)
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default, environment: environment())
        let picked = sections.defaultSelection
        XCTAssertTrue(picked.contains(SettingsTransfer.ID.hiddenLabels))
        XCTAssertTrue(picked.contains(SettingsTransfer.ID.reviewModel))
        XCTAssertTrue(picked.contains(SettingsTransfer.ID.memberNicknames))
        XCTAssertFalse(picked.contains(SettingsTransfer.ID.ignoredAuthors))
        XCTAssertFalse(picked.contains(SettingsTransfer.ID.pollSeconds))
        XCTAssertFalse(picked.contains(SettingsTransfer.ID.reviewNotifications))
        XCTAssertFalse(picked.contains(SettingsTransfer.ID.fonts))
        // 고를 수는 있다.
        XCTAssertTrue(sections.selectableIDs.contains(SettingsTransfer.ID.fonts))
    }

    /// 예전 앱이 내보낸 파일의 클론 경로는 목록에 보이지도, 들어오지도 않는다 — 들이면 고를 수도 없는 "연결" 이
    /// 생겨 PR 스냅샷 대신 그 폴더를 읽는다. 칸은 읽기만 해서 깨진 칸으로 잡히지도 않는다.
    func testOldClonePathsAreNotImported() throws {
        var old = SettingsTransferPayload()
        old.repos = [.init(repo: "acme/sample-ios", prTargetBranch: "develop", approvalThreshold: 2, approvalThresholdFromGitHub: false)]
        old.clonePaths = ["acme/sample-ios": "~/work/sample-ios"]
        let read = try SettingsTransfer.read(SettingsTransfer.encode(
            SettingsTransferFile(exportedAt: nil, exportedBy: nil, appVersion: "0.4.31", settings: old)))
        XCTAssertTrue(read.skipped.isEmpty)
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default, environment: environment())
        XCTAssertFalse(sections.flatMap(\.leaves).contains { $0.id.contains("clonePath") })
        let result = SettingsTransfer.apply(read.file.settings, selected: sections.selectableIDs.union(["clonePath:acme/sample-ios"]),
                                            to: .default, environment: environment())
        XCTAssertTrue(result.settings.deepReviewRepoPaths.isEmpty)
        XCTAssertEqual(result.settings.repos.map(\.repo.full), ["acme/sample-ios"])
    }

    /// 로그인하지 않은 호스트는 경고를 달고 고르지 않는다.
    func testHostNotLoggedInIsWarnedAndUnselected() throws {
        var s = sender()
        s.githubHost = "github.acme.example"
        let read = try roundTrip(s)
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default, environment: environment())
        let host = leaf(sections, SettingsTransfer.ID.githubHost)
        XCTAssertEqual(host?.status, .changed)
        XCTAssertNotNil(host?.note)
        XCTAssertFalse(sections.defaultSelection.contains(SettingsTransfer.ID.githubHost))
    }

    func testMissingFontIsNoted() throws {
        let read = try roundTrip(sender())
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default,
                                                       environment: environment(fonts: ["Menlo"]))
        XCTAssertTrue(leaf(sections, SettingsTransfer.ID.fonts)?.note?.contains("D2Coding") ?? false)
    }

    // MARK: 적용

    /// 목록은 합치기만 한다. 받은 파일에 없다고 내 것을 지우지 않는다.
    func testApplyMergesWithoutRemoving() throws {
        let read = try roundTrip(sender())
        var mine = Settings.default
        mine.claudePath = "/Users/receiver/.local/bin/claude"
        mine.hiddenLabels = ["wip", "do not review"]
        mine.repos = [RepoConfig(repo: RepoID(owner: "acme", name: "mine-only"), prTargetBranch: "main")]
        mine.memberNicknames = ["other-acme": "다른이"]

        let sections = SettingsTransfer.importSections(read.file.settings, current: mine, environment: environment())
        let result = SettingsTransfer.apply(read.file.settings, selected: sections.defaultSelection, to: mine,
                                            environment: environment())
        let s = result.settings
        XCTAssertEqual(s.repos.map(\.repo.full), ["acme/mine-only", "acme/sample-ios", "acme/sample-sdk"])
        XCTAssertTrue(s.repos.allSatisfy(\.enabled))
        XCTAssertEqual(result.addedRepos.map(\.full), ["acme/sample-ios", "acme/sample-sdk"])
        // 대소문자만 다른 라벨은 같은 라벨이다.
        XCTAssertEqual(s.hiddenLabels, ["wip", "do not review", "DO NOT MERGE"])
        XCTAssertEqual(s.memberNicknames, ["other-acme": "다른이", "riley-park-acme": "라일리"])
        XCTAssertEqual(s.model, "opus")
        XCTAssertEqual(s.effort, "high")
        // 고르지 않은 것과 담기지 않은 것은 그대로다.
        XCTAssertEqual(s.claudePath, "/Users/receiver/.local/bin/claude")
        XCTAssertEqual(s.pollSeconds, Settings.default.pollSeconds)
        XCTAssertEqual(s.codeFontName, Settings.default.codeFontName)
        XCTAssertTrue(s.ignoredAuthors.isEmpty)
        XCTAssertFalse(result.hostChanged)
    }

    /// 가져온 글꼴은 고른 것으로 친다 — 옛 기본값(Menlo)이어도 다음에 읽을 때 새 기본으로 바뀌지 않는다.
    func testImportedFontCountsAsChosen() throws {
        var s = sender()
        s.codeFontName = "Menlo"
        let exported = SettingsTransfer.exportSections(s, home: exporterHome).defaultSelection
            .union([SettingsTransfer.ID.fonts])
        let read = try roundTrip(s, selected: exported)
        let result = SettingsTransfer.apply(read.file.settings, selected: [SettingsTransfer.ID.fonts],
                                            to: Settings.default, environment: environment())
        XCTAssertTrue(result.settings.codeFontChosen)
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(result.settings))
        XCTAssertEqual(reloaded.codeFontName, "Menlo")
    }

    /// 이미 있는 레포는 대상 브랜치만 바꾼다. 승인 수를 GitHub 에서 읽은 파일이면 내 승인 수를 덮지 않는다.
    func testApplyUpdatesExistingRepoBranch() throws {
        let read = try roundTrip(sender())
        var mine = Settings.default
        mine.repos = [RepoConfig(repo: RepoID(owner: "acme", name: "sample-ios"), prTargetBranch: "staging",
                                 approvalThreshold: 2, approvalThresholdFromAPI: true)]
        let id = SettingsTransfer.ID.repo("acme/sample-ios")
        let result = SettingsTransfer.apply(read.file.settings, selected: [id], to: mine,
                                            environment: environment())
        XCTAssertEqual(result.settings.repos.count, 1)
        XCTAssertEqual(result.settings.repos[0].prTargetBranch, "develop")
        XCTAssertEqual(result.settings.repos[0].approvalThreshold, 2)
        XCTAssertEqual(result.updatedRepos.map(\.full), ["acme/sample-ios"])
        XCTAssertTrue(result.addedRepos.isEmpty)
    }

    /// 내가 꺼 둔 레포를 받은 파일이 담고 있으면 "같음" 이 아니다 — 같음으로 두면 잠겨서 켤 수가 없다.
    /// 골라 가져오면 켠다.
    func testImportTurnsOnMyDisabledRepo() throws {
        let read = try roundTrip(sender())
        var mine = Settings.default
        mine.repos = [RepoConfig(repo: RepoID(owner: "acme", name: "sample-ios"), prTargetBranch: "develop",
                                 approvalThreshold: 3, approvalThresholdFromAPI: true, enabled: false)]
        let id = SettingsTransfer.ID.repo("acme/sample-ios")
        let sections = SettingsTransfer.importSections(read.file.settings, current: mine, environment: environment())
        XCTAssertEqual(leaf(sections, id)?.status, .changed)
        XCTAssertTrue(leaf(sections, id)?.current?.contains("꺼 둠") ?? false)
        XCTAssertTrue(sections.selectableIDs.contains(id))

        let result = SettingsTransfer.apply(read.file.settings, selected: [id], to: mine,
                                            environment: environment())
        XCTAssertEqual(result.settings.repos.count, 1)
        XCTAssertTrue(result.settings.repos[0].enabled)
        XCTAssertEqual(result.updatedRepos.map(\.full), ["acme/sample-ios"])
    }

    /// 전체 리뷰 켜기·끄기 스위치를 없앴다 — 내보내지 않고, 옛 파일에 있어도 가져오기 목록에 안 보이고 적용하지 않는다.
    func testDeepReviewSwitchIsNeitherExportedNorImported() throws {
        let read = try roundTrip(sender())
        XCTAssertNil(read.file.settings.deepReview)

        var old = read.file.settings
        old.deepReview = .init(enabled: false, model: "opus", effort: "")
        let sections = SettingsTransfer.importSections(old, current: .default, environment: environment())
        XCTAssertFalse(sections.flatMap(\.leaves).contains { $0.id == "deepReview" })

        let result = SettingsTransfer.apply(old, selected: sections.selectableIDs.union(["deepReview"]), to: .default,
                                            environment: environment())
        XCTAssertFalse(result.applied.contains { $0.hasPrefix("전체 리뷰(워크트리)") })
    }

    /// 팀 규칙·통째로 바꾸던 리뷰 가이드는 앱에서 뺐다(2026-10-06). 그것을 담은 옛 파일도 읽히고, 그 칸은
    /// 목록에도 설정에도 들어오지 않으며 깨진 칸으로 알리지도 않는다.
    func testOldGuideAndTeamRulesAreIgnored() throws {
        let json = #"""
        {"format":"\#(SettingsTransferFile.formatName)","version":1,
         "settings":{"hiddenLabels":["WIP"],
                     "teamRules":{"fileName":"team-rules.md","text":"- 린트가 잡는 것은 지적하지 않는다"},
                     "reviewGuide":{"fileName":"review.md","text":"# 통째로 바꾼 가이드"}}}
        """#
        let read = try SettingsTransfer.read(Data(json.utf8))
        XCTAssertEqual(read.file.settings.hiddenLabels, ["WIP"])
        XCTAssertTrue(read.skipped.isEmpty)
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default, environment: environment())
        XCTAssertEqual(sections.flatMap(\.leaves).map(\.id), [SettingsTransfer.ID.hiddenLabels])
        let encoded = String(decoding: try SettingsTransfer.encode(read.file), as: UTF8.self)
        XCTAssertFalse(encoded.contains("teamRules"))
        XCTAssertFalse(encoded.contains("reviewGuide"))
    }

    /// 게시 글 끝 표기(👥)를 없앴다(2026-10-20) — 코멘트 스타일 칸은 내보내지 않고, 옛 파일에 있어도 가져오기 목록에
    /// 안 보이고 적용하지 않는다.
    func testCommentStyleIsNeitherExportedNorImported() throws {
        let read = try roundTrip(sender())
        XCTAssertNil(read.file.settings.commentStyle)

        var old = read.file.settings
        old.commentStyle = .init(maxComments: 3, maxCommentChars: 200, aiAttribution: false)
        let sections = SettingsTransfer.importSections(old, current: .default, environment: environment())
        XCTAssertFalse(sections.flatMap(\.leaves).contains { $0.id == "commentStyle" })

        let result = SettingsTransfer.apply(old, selected: sections.selectableIDs.union(["commentStyle"]), to: .default,
                                            environment: environment())
        XCTAssertFalse(result.applied.contains { $0.contains("표기") })
    }

    /// 없앤 게시 기본값(postDefaults)이 든 옛 파일도 읽히고, 그 칸은 목록에 나오지 않는다.
    func testOldPostDefaultsAreIgnored() throws {
        let json = #"""
        {"format":"\#(SettingsTransferFile.formatName)","version":1,
         "settings":{"hiddenLabels":["WIP"],"postDefaults":{"reviewEvent":"APPROVE","approveWhenFullyOK":true}}}
        """#
        let read = try SettingsTransfer.read(Data(json.utf8))
        XCTAssertEqual(read.file.settings.hiddenLabels, ["WIP"])
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default, environment: environment())
        XCTAssertFalse(sections.flatMap(\.leaves).contains { $0.id == "postDefaults" })
        XCTAssertTrue(read.skipped.isEmpty)
    }

    func testNewReposListsOnlySelectedMissingRepos() throws {
        let read = try roundTrip(sender())
        var mine = Settings.default
        mine.repos = [RepoConfig(repo: RepoID(owner: "acme", name: "sample-ios"))]
        let all: Set<String> = [SettingsTransfer.ID.repo("acme/sample-ios"), SettingsTransfer.ID.repo("acme/sample-sdk")]
        XCTAssertEqual(SettingsTransfer.newRepos(read.file.settings, selected: all, current: mine).map(\.full),
                       ["acme/sample-sdk"])
        XCTAssertTrue(SettingsTransfer.newRepos(read.file.settings, selected: [], current: mine).isEmpty)
    }

    // MARK: 받은 파일 검사

    func testRejectsFilesThatAreNotSettings() {
        XCTAssertThrowsError(try SettingsTransfer.read(Data(#"{"hello":"world"}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsTransferError, .notSettingsFile)
        }
        XCTAssertThrowsError(try SettingsTransfer.read(Data("not json".utf8))) {
            XCTAssertEqual($0 as? SettingsTransferError, .notSettingsFile)
        }
        XCTAssertThrowsError(try SettingsTransfer.read(Data(#"{"format":"prayer-settings","version":9,"settings":{}}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsTransferError, .newerVersion(9))
        }
        XCTAssertThrowsError(try SettingsTransfer.read(Data(#"{"format":"prayer-settings","version":1,"settings":{}}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsTransferError, .nothingToImport)
        }
    }

    /// 칸 하나가 깨졌다고 파일 전체를 버리지 않는다. 버리거나 고친 값은 화면에 알린다.
    func testBrokenValuesAreSkippedAndReported() throws {
        let json = #"""
        {
          "format": "prayer-settings",
          "version": 1,
          "exportedBy": "bad login with spaces",
          "settings": {
            "repos": [
              { "repo": "acme/good", "prTargetBranch": "develop" },
              { "prTargetBranch": "main" },
              { "repo": "no-slash" },
              { "repo": "acme/bad branch", "prTargetBranch": "develop" },
              { "repo": "acme/spacey", "prTargetBranch": "has space" }
            ],
            "pollSeconds": "fast",
            "fiveHourTokenCap": 10,
            "hiddenLabels": ["ok", "", "line\nbreak"],
            "githubHost": "not a host",
            "reviewModel": { "model": "opus; rm -rf", "effort": "high" }
          }
        }
        """#
        let read = try SettingsTransfer.read(Data(json.utf8))
        let p = read.file.settings
        XCTAssertEqual(p.repos?.map(\.repo), ["acme/good"])
        XCTAssertEqual(p.repos?.first?.approvalThreshold, 3)
        XCTAssertNil(p.pollSeconds)
        XCTAssertEqual(p.fiveHourTokenCap, 50_000)
        XCTAssertEqual(p.hiddenLabels, ["ok"])
        XCTAssertNil(p.githubHost)
        XCTAssertNil(p.reviewModel)
        XCTAssertNil(read.file.exportedBy)
        // 깨진 레포 줄(이름 없음) 1 + 꼴 틀린 이름 2 + 브랜치 1, 갱신 주기·토큰 상한·라벨·호스트·모델.
        XCTAssertTrue(read.skipped.contains { $0.hasPrefix("리뷰할 레포 — 읽을 수 없는 형식") })
        XCTAssertTrue(read.skipped.contains { $0.hasPrefix("갱신 주기 — 읽을 수 없는 형식") })
        XCTAssertTrue(read.skipped.contains { $0.contains("50000") })
        XCTAssertTrue(read.skipped.contains { $0.hasPrefix("숨길 라벨 — 꼴이 틀린 값 2개") })
        XCTAssertTrue(read.skipped.contains { $0.hasPrefix("GitHub 호스트") })
        // diff·전체 리뷰가 모델 하나를 같이 쓰게 되면서 항목 이름이 "diff 리뷰 모델" 에서 바뀌었다.
        XCTAssertTrue(read.skipped.contains { $0.hasPrefix("리뷰 모델") })
        XCTAssertEqual(read.skipped.filter { $0.hasPrefix("리뷰할 레포") }.count, 4)
    }

    /// 화면에서 고를 수 있는 범위 밖의 숫자는 끝으로 맞춘다. 코멘트 스타일 칸은 읽지 않으므로 맞추지 않고 버린다.
    func testOutOfRangeNumbersAreClamped() throws {
        var payload = SettingsTransferPayload()
        payload.pollSeconds = 5
        payload.commentStyle = .init(maxComments: 99, maxCommentChars: 10, aiAttribution: true)
        payload.sizeLimits = .init(largeLines: 600, warnLines: 99_999)
        let file = SettingsTransferFile(exportedAt: nil, exportedBy: nil, appVersion: nil, settings: payload)
        let read = try SettingsTransfer.read(SettingsTransfer.encode(file))
        XCTAssertEqual(read.file.settings.pollSeconds, 30)
        XCTAssertNil(read.file.settings.commentStyle)
        XCTAssertEqual(read.file.settings.sizeLimits, .init(largeLines: 600, warnLines: 10_000))
        XCTAssertEqual(read.skipped.count, 2)
    }

    /// 내보낸 것을 그대로 받으면 같은 설정이 된다(고를 수 있는 것을 전부 골랐을 때).
    func testFullRoundTripReproducesSharedValues() throws {
        let s = sender()
        let read = try roundTrip(s, selected: SettingsTransfer.exportSections(s, home: exporterHome).selectableIDs)
        let env = environment()
        let sections = SettingsTransfer.importSections(read.file.settings, current: .default, environment: env)
        let r = SettingsTransfer.apply(read.file.settings, selected: sections.selectableIDs, to: .default,
                                       environment: env).settings
        XCTAssertEqual(r.repos.map(\.repo), s.repos.map(\.repo))
        XCTAssertEqual(r.repos.map(\.prTargetBranch), s.repos.map(\.prTargetBranch))
        XCTAssertEqual(r.repos.map(\.approvalThreshold), s.repos.map(\.approvalThreshold))
        // 클론 경로는 옮기지 않는다(testExportLeavesOutClonePaths).
        XCTAssertTrue(r.deepReviewRepoPaths.isEmpty)
        XCTAssertEqual(Set(r.hiddenLabels.map { $0.lowercased() }), Set(s.hiddenLabels.map { $0.lowercased() }))
        XCTAssertEqual(r.ignoredAuthors, s.ignoredAuthors)
        XCTAssertEqual(r.memberNicknames, s.memberNicknames)
        XCTAssertEqual(r.model, s.model)
        XCTAssertEqual(r.effort, s.effort)
        XCTAssertEqual(r.pollSeconds, s.pollSeconds)
        XCTAssertEqual(r.notifyOnReviewDone, s.notifyOnReviewDone)
        XCTAssertEqual(r.codeFontName, s.codeFontName)
        XCTAssertEqual(r.excludedPathPatterns, s.excludedPathPatterns)
        // 담지 않는 값은 받는 쪽 것이 남는다.
        XCTAssertEqual(r.claudePath, Settings.default.claudePath)
        XCTAssertEqual(r.onboardingCompleted, Settings.default.onboardingCompleted)
    }

    /// 묶음마다 설명이 있고, 묶음 안의 항목(묶음 자신 제외)마다 무엇을 하는 설정인지 적혀 있다.
    func testEverySectionAndItemIsExplained() {
        var s = sender()
        s.memberNicknames = ["a-acme": "가"]
        let sections = SettingsTransfer.exportSections(s, home: exporterHome)
        XCTAssertEqual(sections.map(\.id), ["repos", "hiding", "members", "review", "scope", "notifications", "appearance"])
        for section in sections {
            XCTAssertFalse(section.summary.isEmpty, section.id)
            for item in section.items {
                XCTAssertFalse(item.detail.isEmpty, item.id)
                XCTAssertNotEqual(item.title, item.id, "제목이 없는 항목: \(item.id)")
            }
        }
    }
}
