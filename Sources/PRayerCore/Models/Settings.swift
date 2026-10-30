import Foundation

public struct RepoConfig: Codable, Sendable, Equatable, Identifiable {
    public var repo: RepoID
    /// Approve 수를 읽어 올 브랜치. 화면에는 브랜치가 아니라 Approve 수로 보인다 — 설정의 Approve 수 메뉴에서
    /// 고르면 그 수가 걸린 대표 브랜치가 여기 들어가고, 다시 읽을 때 이 브랜치가 든 묶음의 수를 쓴다.
    /// (예전에는 사람이 직접 치는 칸이었고, 이름은 "PR 대상 브랜치" 였지만 PR 을 거르는 데 쓰이지는 않았다.)
    public var prTargetBranch: String
    /// 머지에 필요한 Approve 수. GitHub 규칙에서 읽고, 못 읽으면 이 값(기본 3)을 쓴다.
    public var approvalThreshold: Int
    public var approvalThresholdFromAPI: Bool
    /// 브랜치별 Approve 규칙을 수로 묶은 것. 묶음이 둘 이상이면 설정에서 수를 고른다. 비어 있으면 아직 못 읽었다.
    public var approvalGroups: [ApprovalGroup]
    public var enabled: Bool

    public var id: String { repo.full }

    public init(repo: RepoID, prTargetBranch: String = "develop", approvalThreshold: Int = 3,
                approvalThresholdFromAPI: Bool = false, enabled: Bool = true,
                approvalGroups: [ApprovalGroup] = []) {
        self.repo = repo
        self.prTargetBranch = prTargetBranch
        self.approvalThreshold = approvalThreshold
        self.approvalThresholdFromAPI = approvalThresholdFromAPI
        self.approvalGroups = approvalGroups
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case repo, prTargetBranch, approvalThreshold, approvalThresholdFromAPI, approvalGroups, enabled
    }

    /// repo 만 있으면 복원한다. 항목 하나가 깨져 레포 목록 전체가 사라지는 것을 막는다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(RepoID.self, forKey: .repo)
        prTargetBranch = (try? c.decodeIfPresent(String.self, forKey: .prTargetBranch)) ?? "develop"
        approvalThreshold = (try? c.decodeIfPresent(Int.self, forKey: .approvalThreshold)) ?? 3
        approvalThresholdFromAPI = (try? c.decodeIfPresent(Bool.self, forKey: .approvalThresholdFromAPI)) ?? false
        approvalGroups = (try? c.decodeIfPresent([ApprovalGroup].self, forKey: .approvalGroups)) ?? []
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }
}


public struct Settings: Codable, Sendable, Equatable {
    public var onboardingCompleted: Bool
    public var claudePath: String
    /// Codex CLI 경로. 못 찾으면 앱이 셸에 묻는다(`CodexRunner.discoverPath`). 옛 대체 엔진 시절의 같은 키도 그대로 읽는다.
    public var codexPath: String
    public var ghPath: String
    /// 물어볼 GitHub 호스트. 회사 계정이면 `github.mycorp.com` 처럼 바뀐다.
    /// `gh` 는 호스트별로 따로 로그인하므로 어느 쪽인지 앱이 정해 줘야 한다.
    public var githubHost: String
    public var repos: [RepoConfig]

    // Claude 실행
    /// 리뷰 모델 — diff 리뷰와 전체 리뷰가 **같이** 쓴다(사용자 결정: 둘로 나눌 이유가 없다).
    /// 계열 별칭(`opus`)이면 그 계열의 최신을, 모델 이름(`claude-opus-5`)이면 그 버전을 쓴다.
    /// `codex:` 로 시작하면 Codex 모델이다(`CodexModels` — 엔진도 이 값이 정한다, `ReviewEngineKind(model:)`).
    /// PR 하나만 다르게 돌리려면 `prReviewModels`.
    public var model: String
    /// 리뷰의 `claude --effort` 값(`EffortLevel`). 빈 문자열이면 넘기지 않아 모델·CLI 기본값으로 돈다.
    /// 리뷰에만 쓴다 — 코멘트 설명·"이미 언급됨" 대조처럼 짧은 호출까지 올리면 토큰만 더 든다.
    public var effort: String
    /// PR 키(`owner/name#번호`) → 그 PR 에만 쓸 리뷰 모델·생각 깊이(리뷰 시작 자리의 모델 칩에서 "이 PR 만").
    public var prReviewModels: [String: PRReviewModel]
    // 리뷰 가이드를 바꾸는 칸(팀 규칙 덧붙이기 `teamRulesPath`, 통째 교체 `reviewGuidePath`)은 없앴다. 예전 설정 파일에
    // 남은 두 키는 읽지 않고 버린다.
    /// 사용자가 직접 쓴 리뷰 규칙(설정 › 리뷰 › 내 리뷰 규칙). 리뷰 글에 대해서는 앱 기본 규칙보다 우선하고, 앱 형식 규칙보다는
    /// 아래다(`ReviewGuideText`). 빈 문자열이면 기본 규칙만으로 돈다.
    public var reviewRules: String
    /// 리뷰 1건 제한 시간(초). 0 이면 제한 없음.
    public var concurrency: Int

    // 대상·크기
    public var excludedPathPatterns: [String]
    public var autoSizeCapLines: Int
    public var manualSizeWarnLines: Int
    /// 이 라벨이 붙은 PR 은 리뷰 대기에서 숨기고, 리뷰할 필요가 없다고 표시한다(화면에서는 "특정 라벨 숨기기").
    ///
    /// 라벨 이름은 팀마다 다르다. 예전에는 `DO NOT REVIEW` 계열로 박혀 있었는데, 다른 팀과 나눠 쓰려면
    /// 각 팀이 자기 라벨(`WIP`, `hold`, 다른 파트 라벨 등)을 넣을 수 있어야 한다. 대소문자는 가리지 않는다.
    public var hiddenLabels: [String]
    /// 리뷰하지 않아도 되는 작성자(GitHub 로그인). 봇·다른 팀·이미 합의된 사람 등.
    ///
    /// 라벨은 **올린 사람이** 붙이는 것이라 내가 정할 수 없다.
    /// "이 사람 PR 은 내가 볼 일이 없다" 는 **내 쪽 사정**이라 따로 둔다(화면에서는 "특정 사람의 PR 숨기기").
    public var ignoredAuthors: [String]

    // 전체 리뷰 (워크트리 + 읽기 도구)
    //
    // 예전에는 전체 리뷰를 통째로 켜고 끄는 스위치(deepReviewEnabled)가 따로 있었다. 전체 리뷰가 diff 리뷰 버튼의
    // ▾ 메뉴 안 별도 모드이고 모델도 따로 정하던 때의 것이다. 이제 두 버튼이 늘 나란히 있어 PR 마다 고르고 모델도
    // 하나라, 스위치가 하는 일이 "클론 경로를 정했어도 막기" 뿐이었다 — 사용자 결정으로 없앴다. 옛 설정 파일에 남은
    // 키는 읽지 않는다(꺼 뒀던 사람도 클론 경로를 정한 레포에서는 전체 리뷰가 된다).
    /// 레포 full name → 로컬 클론 경로. 워크트리를 여기서 만든다.
    public var deepReviewRepoPaths: [String: String]
    // 깊은 리뷰의 모델·effort(`deepReviewModel`·`deepReviewEffort`)는 없앴다 — 리뷰 모델 하나(`model`·`effort`)를 같이 쓴다.
    // 옛 설정 파일에 남은 그 키는 읽지 않는다(diff 리뷰 모델이 둘 다의 모델이 된다).

    /// 게시 항목을 고르는 방식. A/B/C 를 비교해 보고 하나로 정한다.
    /// A: 각 섹션에서만 켠다(미리보기는 읽기 전용)
    /// B: 미리보기에서만 켠다(섹션에는 상태 배지만)
    /// C: 양쪽에서 켠다 + 컨트롤 모양을 역할별로 구분

    // 폰트 (빈 이름 = 시스템 폰트)
    public var codeFontName: String
    public var codeFontSize: Double
    /// 코드 글꼴을 사람이 고른 것인가(설정의 글꼴 탭·설정 가져오기). 고른 글꼴은 옛 기본값이어도 옮기지 않는다(init(from:)).
    public var codeFontChosen: Bool
    public var uiFontName: String
    public var uiFontSize: Double
    public var commentFontName: String
    public var commentFontSize: Double

    // 팀원 이름 표시
    public var abbreviateMemberNames: Bool
    /// 로그인 → 보여줄 이름. 비워두면 기본 규칙(첫 하이픈 앞)을 쓴다.
    public var memberNicknames: [String: String]

    // 코멘트 스타일
    // 코멘트 수·길이 상한(`maxDraftComments`·`maxCommentBodyChars`)은 없앴다 — 응답 스키마가 6개·400자로 이미
    // 묶어 둬서 올려도 그대로였고, 낮추면 모델은 모른 채 다 쓰고 뒤에서 잘렸다. 상한은 `ReviewLimits` 에 있다.
    public var minCommentBodyChars: Int
    public var maxSummaryChars: Int
    // 게시하는 글 끝 표기(`aiAttribution`·`attributionStyle` — 없음 · 👥 · by Claude)는 없앴다 — 보이는 표기는 늘
    // 붙이지 않는다(2026-10-20 사용자 결정). 숨은 마커는 그대로 붙는다(`PostBuilder.decorate`). 옛 설정 파일의 그 칸은 읽지 않는다.

    // 게시 기본값(`defaultReviewEvent`·`approveWhenFullyOK`)은 없앴다 — 게시 버튼은 이 값을 읽지 않고 리뷰 결과로
    // 먼저 골라 둔다(`PostActionPlan.recommended`). "전송 내용 자세히" 창의 첫 선택에만 쓰여 두 곳이 엇갈렸다.
    // 옛 설정 파일에 남은 네 키는 읽지 않는다.

    // 스케줄
    public var pollSeconds: Int
    public var fiveHourTokenCap: Int

    // 알림
    public var notifyOnReviewDone: Bool
    public var notifyOnFailure: Bool
    /// PR 변화 알림(새 PR·리뷰 요청·CI 실패 등).
    public var prChangeNotifications: PRChangeNotificationPrefs

    /// 레포마다 나눠 준 색(키: `RepoColors.key` → 팔레트 자리). 앱이 레포 목록이 바뀔 때 채운다 — 사람이 고르는 값이 아니다.
    /// 남겨 두는 이유: 이름에서 그때그때 셈하면 레포를 넣고 뺄 때 다른 레포의 색이 바뀐다(RepoColors 주석 참고).
    /// 설정 내보내기에는 담지 않는다. 받는 맥에서 그 맥의 레포 목록에 맞춰 다시 나눈다.
    public var repoColors: [String: Int]

    /// 슬랙 리뷰 요청(내 PR 우클릭). 토큰은 없다 — claude.ai Slack 커넥터로 보낸다(`SlackConnector`).
    public var slack: SlackSettings

    /// 처음 쓰는 사람의 제외 경로는 비운다(사용자 결정). 예전 기본값은 iOS 파일(*.pbxproj·*.xcassets 등)이라 다른 분야에는
    /// 맞지 않았다. 잠금 파일은 이 목록과 상관없이 늘 빠진다(`LockFiles`). 이미 쓰던 사람의 목록은 그대로 둔다.
    public static let defaultExcludedPatterns: [String] = []

    public static let `default` = Settings(
        onboardingCompleted: false,
        claudePath: "\(NSHomeDirectory())/.local/bin/claude",
        codexPath: "/opt/homebrew/bin/codex",
        ghPath: "/opt/homebrew/bin/gh",
        githubHost: GitHubHost.dotCom,
        repos: [],
        model: "sonnet",
        concurrency: 1,
        excludedPathPatterns: Settings.defaultExcludedPatterns,
        autoSizeCapLines: 600,
        manualSizeWarnLines: 1000,
        // 처음 쓰는 팀의 기본값. 널리 쓰는 관례 하나만 둔다 — "DO NOT MERGE" 는 팀에 따라
        // "리뷰는 해 달라, 머지만 말라" 는 뜻이라 기본으로 숨기면 볼 PR 이 사라진다.
        hiddenLabels: Settings.defaultHiddenLabels,
        ignoredAuthors: [],
        deepReviewRepoPaths: [:],
        codeFontName: "IBM Plex Mono",
        codeFontSize: 12,
        uiFontName: "",
        uiFontSize: 13,
        commentFontName: "",
        commentFontSize: 13,
        abbreviateMemberNames: true,
        memberNicknames: [:],
        minCommentBodyChars: 20,
        maxSummaryChars: 300,
        pollSeconds: 120,
        fiveHourTokenCap: 300_000,
        notifyOnReviewDone: true,
        notifyOnFailure: true,
        prChangeNotifications: .default
    )

    public var enabledRepos: [RepoConfig] { repos.filter(\.enabled) }

    public func config(for repo: RepoID) -> RepoConfig? {
        repos.first { $0.repo == repo }
    }

    /// 켜 두고 보는 레포인가. 끈 레포는 설정은 있어도 조회·알림을 하지 않는다.
    public func isWatching(_ repo: RepoID) -> Bool {
        config(for: repo)?.enabled ?? false
    }

    /// 레포 체크 하나 — 레포 관리 팝오버·설정 창·온보딩이 같은 뜻으로 쓴다.
    ///
    /// 끄면 **지우지 않고** `enabled` 만 내린다. 예전에는 팝오버 체크는 끄기, 설정 창 체크는 지우기라
    /// 같은 체크가 곳마다 뜻이 달랐고, 팝오버에서 끈 레포가 설정 창에는 켜진 것처럼 보였다.
    /// 다시 켜면 대상 브랜치·승인 수가 그대로 돌아온다. 아예 빼는 것은 `removeRepo`.
    ///
    /// - Returns: 처음 켜서 새로 만든 레포면 true — 승인 수를 GitHub 에서 읽어야 한다.
    @discardableResult
    public mutating func setRepo(_ repo: RepoID, watched: Bool, defaultBranch: String?) -> Bool {
        if let index = repos.firstIndex(where: { $0.repo == repo }) {
            repos[index].enabled = watched
            return false
        }
        guard watched else { return false }
        var config = RepoConfig(repo: repo)
        // 처음에는 기본 브랜치의 규칙을 레포 기준으로 둔다. PR 하나하나는 그 PR 이 향하는 브랜치의 규칙으로 센다
        // (`approvalThreshold(for: PullRequestInfo)`). 예전에는 한 팀의 브랜치 규칙(기본 브랜치 대신 개발 브랜치)을 박아 두었는데,
        // 한 팀의 브랜치 전략이라 다른 팀에는 맞지 않았다.
        if let defaultBranch {
            config.prTargetBranch = defaultBranch
        }
        repos.append(config)
        return true
    }

    /// 레포를 목록에서 아예 뺀다. 로컬 클론 경로는 따로 두므로(`deepReviewRepoPaths`) 남는다.
    public mutating func removeRepo(_ repo: RepoID) {
        repos.removeAll { $0.repo == repo }
    }

    /// 레포 탭 순서 바꾸기 — 끌고 있는 레포(`repo`)를 `target` 자리로 옮긴다. 오른쪽으로 끌면 target 뒤,
    /// 왼쪽으로 끌면 target 앞에 놓인다(끄는 동안 지나가는 탭마다 한 칸씩 자리를 바꾸는 꼴).
    /// 순서는 `repos` 전체에서 바꾼다 — 꺼 둔 레포(탭에 없는)는 제자리에 남는다.
    public mutating func moveRepo(_ repo: RepoID, to target: RepoID) {
        guard repo != target,
              let from = repos.firstIndex(where: { $0.repo == repo }),
              let to = repos.firstIndex(where: { $0.repo == target }) else { return }
        let item = repos.remove(at: from)
        // 빼고 나면 target 이 한 칸 당겨졌을 수 있다. 다시 찾는다.
        guard let landing = repos.firstIndex(where: { $0.repo == target }) else { return }
        repos.insert(item, at: from < to ? landing + 1 : landing)
    }

    /// 탭 하나만큼 옮긴다(탭 우클릭 "왼쪽으로·오른쪽으로"). 꺼 둔 레포는 건너뛰고 옆 탭과 자리를 바꾼다.
    public mutating func moveRepo(_ repo: RepoID, by step: Int) {
        let tabs = enabledRepos.map(\.repo)
        guard let index = tabs.firstIndex(of: repo), tabs.indices.contains(index + step) else { return }
        moveRepo(repo, to: tabs[index + step])
    }

    /// 이 PR 의 리뷰에 쓸 모델·생각 깊이. 이 PR 만 따로 고른 것이 있으면 그것, 없으면 기본값.
    public func reviewModelChoice(forPRKey key: String) -> ReviewModelChoice {
        if let chosen = prReviewModels[key] {
            return ReviewModelChoice(model: chosen.model, effort: chosen.effort, isPRChoice: true)
        }
        return ReviewModelChoice(model: model, effort: effort, isPRChoice: false)
    }

    /// 레포의 기준 Approve 수. 설정 화면이 보여 주고, PR 이 향하는 브랜치의 규칙을 모를 때 쓴다.
    /// GitHub 규칙을 못 읽은 레포는 직접 정한 값(처음 3)이다 — 낮게 잡으면 Approve 가 덜 찬 PR 이 대기에서 사라진다.
    public func approvalThreshold(for repo: RepoID) -> Int {
        config(for: repo)?.approvalThreshold ?? 3
    }

    /// 이 PR 을 머지하는 데 필요한 Approve 수 — **그 PR 이 향하는 브랜치(base)의 규칙**으로 센다.
    /// GitHub 도 그 브랜치의 규칙으로 막는다. 레포 하나에 수 하나를 쓰면, `main` 은 2명·`release` 는 1명인 레포에서
    /// 한쪽 PR 은 늘 틀리게 셌다. 그 브랜치가 읽어 둔 규칙 묶음에 없으면 레포 기준 수를 쓴다.
    public func approvalThreshold(for pr: PullRequestInfo) -> Int {
        guard let config = config(for: pr.repo) else { return approvalThreshold(for: pr.repo) }
        if let group = ApprovalGroups.group(containing: pr.baseRefName, in: config.approvalGroups) {
            return group.count
        }
        return config.approvalThreshold
    }

    /// 리뷰 프로세스에 거는 제한 시간 — 사실상 없다.
    ///
    /// 설정으로 두지 않는다. 시간을 재서 끊으면 이미 쓴 토큰만 버리고 결과는 못 얻는다.
    /// 멈춘 것 같으면 진행 카드의 취소 버튼으로 사람이 끊는 게 낫다. 그래도 0 을 주지
    /// 않는 이유는 프로세스가 영원히 매달려 워커를 막는 최악을 피하기 위해서다.
    public static let reviewTimeout: TimeInterval = 24 * 3600

    /// 이 레포로 전체 리뷰가 가능한가 — 로컬 클론 경로를 정해 둔 레포만 된다.
    public func deepReviewPath(for repo: RepoID) -> String? {
        guard let path = deepReviewRepoPaths[repo.full], !path.isEmpty else { return nil }
        return path
    }

    /// 이 작성자를 안 보기로 해 뒀는가. 대소문자는 무시한다 — GitHub 로그인은 대소문자를 안 가린다.
    public func isIgnoredAuthor(_ login: String) -> Bool {
        ignoredAuthors.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    public static let defaultHiddenLabels = ["DO NOT REVIEW"]

    /// 예전 기본 코드 글꼴. 저장된 값이 이것이면 읽을 때 지금 기본으로 옮긴다(init(from:)).
    static let legacyCodeFontName = "Menlo"
    static let legacyCodeFontSize: Double = 11

    /// PR 라벨 중 숨길 라벨로 정해 둔 첫 번째. 대소문자는 무시한다(GitHub 라벨 검색도 안 가린다).
    public func hiddenLabel(in labels: [String]) -> String? {
        labels.first { label in
            hiddenLabels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
        }
    }

    public func hasHiddenLabel(_ labels: [String]) -> Bool {
        hiddenLabel(in: labels) != nil
    }

    public func isHiddenLabel(_ label: String) -> Bool {
        hiddenLabel(in: [label]) != nil
    }

    /// 화면에 보여줄 팀원 이름.
    public func displayName(_ login: String) -> String {
        MemberNames.short(login, overrides: memberNicknames, enabled: abbreviateMemberNames)
    }


    enum CodingKeys: String, CodingKey {
        case onboardingCompleted, claudePath, codexPath, ghPath, githubHost, repos
        case model, effort, prReviewModels, reviewRules, concurrency
        case excludedPathPatterns, autoSizeCapLines, manualSizeWarnLines
        case hiddenLabels
        case ignoredAuthors
        case deepReviewRepoPaths
        case codeFontName, codeFontSize, codeFontChosen, uiFontName, uiFontSize, commentFontName, commentFontSize
        case abbreviateMemberNames, memberNicknames
        case minCommentBodyChars, maxSummaryChars
        case pollSeconds, fiveHourTokenCap
        case notifyOnReviewDone, notifyOnFailure, prChangeNotifications
        case repoColors
        case slack
    }

    /// 읽기만 하는 옛 키. `CodingKeys` 에 두면 합성 인코더가 속성을 찾다가 컴파일이 깨진다.
    private enum LegacyKeys: String, CodingKey {
        /// `hiddenLabels` 의 옛 이름(0.3.0 까지). 지우면 그 전 설정의 라벨 목록이 기본값으로 돌아간다.
        case doNotReviewLabels
    }

    /// 결측 필드가 있는 옛 설정 파일도 읽히도록 모든 키에 기본값을 준다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` 는 중첩 옵셔널을 평탄화하므로 키가 없거나 타입이 달라도 fallback 으로 떨어진다.
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) {
                return decoded
            }
            return fallback
        }
        onboardingCompleted = v(.onboardingCompleted, d.onboardingCompleted)
        claudePath = v(.claudePath, d.claudePath)
        codexPath = v(.codexPath, d.codexPath)
        ghPath = v(.ghPath, d.ghPath)
        githubHost = v(.githubHost, d.githubHost)
        repos = v(.repos, d.repos)
        model = v(.model, d.model)
        effort = v(.effort, d.effort)
        prReviewModels = v(.prReviewModels, d.prReviewModels)
        reviewRules = v(.reviewRules, d.reviewRules)
        concurrency = v(.concurrency, d.concurrency)
        excludedPathPatterns = v(.excludedPathPatterns, d.excludedPathPatterns)
        autoSizeCapLines = v(.autoSizeCapLines, d.autoSizeCapLines)
        manualSizeWarnLines = v(.manualSizeWarnLines, d.manualSizeWarnLines)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        hiddenLabels = v(.hiddenLabels,
                         (try? legacy?.decodeIfPresent([String].self, forKey: .doNotReviewLabels)) ?? d.hiddenLabels)
        ignoredAuthors = v(.ignoredAuthors, d.ignoredAuthors)
        deepReviewRepoPaths = v(.deepReviewRepoPaths, d.deepReviewRepoPaths)
        codeFontName = v(.codeFontName, d.codeFontName)
        codeFontSize = v(.codeFontSize, d.codeFontSize)
        codeFontChosen = v(.codeFontChosen, d.codeFontChosen)
        // 예전 기본 코드 글꼴(Menlo 11pt)이 남아 있으면 지금 기본으로 옮긴다. 그대로 두면 저장된 옛 기본값이
        // 새 기본값을 영영 가린다. 크기는 11pt 그대로일 때만 옮긴다 — 다른 크기는 ⌘+ / ⌘- 로 맞춘 것이다.
        // 사람이 고른 Menlo 는 옛 기본값이 아니라 고른 것이라 그대로 둔다(codeFontChosen).
        if !codeFontChosen, codeFontName == Settings.legacyCodeFontName {
            codeFontName = d.codeFontName
            if codeFontSize == Settings.legacyCodeFontSize { codeFontSize = d.codeFontSize }
        }
        uiFontName = v(.uiFontName, d.uiFontName)
        uiFontSize = v(.uiFontSize, d.uiFontSize)
        commentFontName = v(.commentFontName, d.commentFontName)
        commentFontSize = v(.commentFontSize, d.commentFontSize)
        abbreviateMemberNames = v(.abbreviateMemberNames, d.abbreviateMemberNames)
        memberNicknames = v(.memberNicknames, d.memberNicknames)
        minCommentBodyChars = v(.minCommentBodyChars, d.minCommentBodyChars)
        maxSummaryChars = v(.maxSummaryChars, d.maxSummaryChars)
        pollSeconds = v(.pollSeconds, d.pollSeconds)
        fiveHourTokenCap = v(.fiveHourTokenCap, d.fiveHourTokenCap)
        notifyOnReviewDone = v(.notifyOnReviewDone, d.notifyOnReviewDone)
        notifyOnFailure = v(.notifyOnFailure, d.notifyOnFailure)
        prChangeNotifications = (try? c.decodeIfPresent(PRChangeNotificationPrefs.self,
                                                        forKey: .prChangeNotifications)) ?? d.prChangeNotifications
        repoColors = v(.repoColors, d.repoColors)
        slack = v(.slack, d.slack)
    }

    public init(onboardingCompleted: Bool, claudePath: String, codexPath: String = "/opt/homebrew/bin/codex", ghPath: String,
                githubHost: String = GitHubHost.dotCom, repos: [RepoConfig],
                model: String,
                concurrency: Int, excludedPathPatterns: [String], autoSizeCapLines: Int,
                manualSizeWarnLines: Int, hiddenLabels: [String],
                ignoredAuthors: [String] = [],
                deepReviewRepoPaths: [String: String] = [:],
                effort: String = "", prReviewModels: [String: PRReviewModel] = [:],
                reviewRules: String = "",
                codeFontName: String = "IBM Plex Mono", codeFontSize: Double = 12, codeFontChosen: Bool = false,
                uiFontName: String = "", uiFontSize: Double = 13,
                commentFontName: String = "", commentFontSize: Double = 13,
                abbreviateMemberNames: Bool = true, memberNicknames: [String: String] = [:],
                minCommentBodyChars: Int, maxSummaryChars: Int,
                pollSeconds: Int,
                fiveHourTokenCap: Int,
                notifyOnReviewDone: Bool, notifyOnFailure: Bool,
                prChangeNotifications: PRChangeNotificationPrefs = .default,
                repoColors: [String: Int] = [:],
                slack: SlackSettings = .default) {
        self.onboardingCompleted = onboardingCompleted
        self.claudePath = claudePath
        self.codexPath = codexPath
        self.ghPath = ghPath
        self.githubHost = githubHost
        self.repos = repos
        self.model = model
        self.effort = effort
        self.prReviewModels = prReviewModels
        self.reviewRules = reviewRules
        self.concurrency = concurrency
        self.excludedPathPatterns = excludedPathPatterns
        self.autoSizeCapLines = autoSizeCapLines
        self.manualSizeWarnLines = manualSizeWarnLines
        self.hiddenLabels = hiddenLabels
        self.ignoredAuthors = ignoredAuthors
        self.deepReviewRepoPaths = deepReviewRepoPaths
        self.codeFontName = codeFontName
        self.codeFontSize = codeFontSize
        self.codeFontChosen = codeFontChosen
        self.uiFontName = uiFontName
        self.uiFontSize = uiFontSize
        self.commentFontName = commentFontName
        self.commentFontSize = commentFontSize
        self.abbreviateMemberNames = abbreviateMemberNames
        self.memberNicknames = memberNicknames
        self.minCommentBodyChars = minCommentBodyChars
        self.maxSummaryChars = maxSummaryChars
        self.pollSeconds = pollSeconds
        self.fiveHourTokenCap = fiveHourTokenCap
        self.notifyOnReviewDone = notifyOnReviewDone
        self.notifyOnFailure = notifyOnFailure
        self.prChangeNotifications = prChangeNotifications
        self.repoColors = repoColors
        self.slack = slack
    }
}
