import Foundation

public enum AppInfo {
    /// 폴더·번들·파일 이름에 쓰는 이름. 경로에 들어가므로 이모지를 넣지 않는다.
    ///
    /// **화면 이름이 PRView 로 바뀌어도(2026-10-20) 이 값은 PRayer 로 둔다.** 이미 깔린 앱의 업데이트가
    /// `PRayer-<버전>.zip` 안의 `PRayer.app`·번들 ID `dev.itaehyeok.PRayer` 를 찾고, 데이터 폴더도 이 이름이다.
    /// 바꾸면 깔린 앱이 새 버전을 못 받고 설정·초안이 사라진 것처럼 보인다.
    public static let name = "PRayer"
    /// 화면에 보이는 이름. 창 제목·온보딩·안내 문구는 전부 이걸 쓴다(앱 메뉴·Dock 이름은 InfoPlist.strings 쪽).
    public static let displayName = "PRView"
    /// 이름 옆에 붙는 한 줄 설명. 정보 창·온보딩·상태 팝오버에 이름과 같이 보인다.
    /// 앱 메뉴·Dock·Finder 이름에는 넣지 않는다 — 길어서 잘리고, Finder 이름은 파일 이름과 같아야 한다.
    public static let subtitle = "PR Review Manager"
    /// 게시 코멘트에 붙는 숨은 마커 접두어. `<!-- prdeck:v1:<sha256-12> -->`
    ///
    /// **앱 이름을 바꿔도 이 값은 바꾸지 않는다.** 이미 GitHub 에 올라간 리뷰 코멘트에 이 문자열이
    /// 그대로 박혀 있고, "이 코멘트는 내가 올린 것" 을 이걸로 알아본다(RecheckDelta).
    /// 바꾸면 예전에 올린 내 리뷰들이 남이 쓴 새 코멘트로 잡힌다.
    public static let markerPrefix = "prdeck"
    public static let markerVersion = "v1"
    /// 플래그 세트를 실측한 Claude Code 버전. 이 버전 범위를 벗어나면 경고 배너를 띄운다.
    public static let verifiedClaudeVersion = "2.1.284"
}

public enum AppPaths {
    /// 데이터 폴더 이름. 기본은 `PRayer`, `PRAYER_DATA_DIR` 로 갈아끼울 수 있다.
    ///
    /// 곁가지 워크트리에서 빌드한 작업본을 실제로 띄워 볼 때가 있는데, 그때 같은 폴더를 쓰면
    /// **실제 초안·설정·토큰 원장을 건드린다.** 두 앱을 동시에 켜면 같은 JSON 을 서로 덮어쓴다.
    /// 그래서 작업본은 다른 폴더를 보게 한다(Scripts/install.sh 가 넣어 준다).
    public static var dataDirectoryName: String {
        let override = ProcessInfo.processInfo.environment["PRAYER_DATA_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "PRayerDataDirectory") as? String
        guard let override, !override.trimmingCharacters(in: .whitespaces).isEmpty else {
            return AppInfo.name
        }
        return override
    }

    static var applicationSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// 경로 계산만 한다. 옛 이름 폴더를 옮기는 일은 `LegacyMigration.run()` 이 앱 시작 때 한 번 한다
    /// (여기서 하면 경로만 계산하는 테스트도 폴더를 옮긴다).
    public static var support: URL {
        applicationSupportBase.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    public static var settingsFile: URL { support.appendingPathComponent("settings.json") }
    /// 설정 가져오기 직전의 설정. 마지막 한 번만 남긴다 — 되돌리기를 놓쳤을 때 이 파일을 settings.json 자리에 두면 된다.
    public static var settingsBeforeImportFile: URL { support.appendingPathComponent("settings-before-import.json") }
    public static var snapshotsFile: URL { support.appendingPathComponent("pr-snapshots.json") }
    public static var ledgerFile: URL { support.appendingPathComponent("token-ledger.json") }
    public static var explanationsFile: URL { support.appendingPathComponent("comment-explanations.json") }
    /// 돌고 있는 리뷰 1건당 폴더 하나. 앱이 죽어도 결과가 남는다.
    public static var jobsDirectory: URL { support.appendingPathComponent("jobs", isDirectory: true) }
    public static var draftsDirectory: URL { support.appendingPathComponent("drafts", isDirectory: true) }
    public static var diffCacheDirectory: URL { support.appendingPathComponent("diff-cache", isDirectory: true) }
    public static var relevancesFile: URL { support.appendingPathComponent("discussion-relevance.json") }
    /// 탭마다 마지막으로 받은 목록(`Store.loadLists`). 탭마다 파일 하나다.
    public static var listCacheDirectory: URL { support.appendingPathComponent("list-cache", isDirectory: true) }
    /// 그 탭의 목록 파일. 탭 이름(`PRListScope.storageValue`, `open:0` 꼴)의 `:` 는 Finder 에서 `/` 로 보여
    /// 글자·숫자가 아닌 것은 `-` 로 바꾼다.
    public static func listCacheFile(scope: String) -> URL {
        let name = scope.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return listCacheDirectory.appendingPathComponent("\(name).json")
    }
    /// 예전에 지금 탭 하나만 남기던 파일. 처음 읽을 때 탭별 파일로 옮긴다.
    public static var legacyListCacheFile: URL { support.appendingPathComponent("pr-list-cache.json") }
    public static var rechecksFile: URL { support.appendingPathComponent("item-rechecks.json") }
    /// 기본 리뷰 규칙 + 사용자 리뷰 규칙 + 앱 형식 규칙을 이은 리뷰 지침(`ReviewGuideText`).
    /// `--system-prompt-file` 이 파일 경로를 받아서, 이은 글을 여기에 써 두고 넘긴다.
    public static var composedGuideFile: URL { support.appendingPathComponent("review-guide.md") }
    /// PR 마다 마지막으로 슬랙에 리뷰를 요청한 기록(`SlackRequestEntry`).
    public static var slackRequestsFile: URL { support.appendingPathComponent("slack-requests.json") }
    /// 별칭 → 모델 표. CLI 버전이 바뀔 때만 다시 쓴다.
    public static var modelCatalogFile: URL { support.appendingPathComponent("model-catalog.json") }
    public static var codexCatalogFile: URL { support.appendingPathComponent("codex-models.json") }
    /// '과거 버전 고르기' 에 쌓은 모델 이름. CLI 가 바뀌어도 이어 가도록 위 표와 따로 둔다.
    public static var rememberedModelsFile: URL { support.appendingPathComponent("remembered-models.json") }
    static let logFileName = "prayer.log"
    public static var logFile: URL { support.appendingPathComponent(logFileName) }
    /// 경고·실패를 종류별로 쌓는 문제 기록(ProblemLog). 이 맥에만 남는다.
    public static var problemsFile: URL { support.appendingPathComponent("problems.json") }
    /// Claude 를 돌릴 고정 빈 작업 디렉터리. git 저장소나 CLAUDE.md 가 있는 곳에서 돌리면
    /// 시스템 프롬프트 캐시 키(cwd·git 상태)가 매번 달라진다.
    public static var claudeWorkingDirectory: URL { support.appendingPathComponent("claude-cwd", isDirectory: true) }

    public static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [support, draftsDirectory, diffCacheDirectory, claudeWorkingDirectory, jobsDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 옛 이름 규칙(`<번호>-<커밋12자>.json`). 같은 커밋을 다시 리뷰하면 덮어써서 히스토리가
    /// 남지 않았다. 읽기와 마이그레이션에만 쓴다 — 새로 쓸 때는 `draftFile(...createdAt:)` 을 쓴다.
    public static func legacyDraftFile(repo: RepoID, number: Int, headSha: String) -> URL {
        draftsDirectory
            .appendingPathComponent(repo.slug, isDirectory: true)
            .appendingPathComponent("\(number)-\(headSha.prefix(12)).json")
    }

    /// 리뷰 1건의 초안 파일. 이름에 생성 시각까지 넣어 **같은 커밋을 여러 번 리뷰해도**
    /// 서로 다른 파일이 되게 한다. 같은 리뷰를 편집해 다시 저장할 때는 createdAt 이 그대로라
    /// 같은 파일에 덮어쓴다(편집마다 파일이 늘어나지 않는다).
    public static func draftFile(repo: RepoID, number: Int, headSha: String, createdAt: Date) -> URL {
        draftsDirectory
            .appendingPathComponent(repo.slug, isDirectory: true)
            .appendingPathComponent("\(number)-\(headSha.prefix(12))-\(stamp(createdAt)).json")
    }

    /// 파일 이름에 넣을 시각. 초 단위까지면 충분하다(리뷰가 1초 안에 두 번 끝나지 않는다).
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
