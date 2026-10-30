import Foundation
import PRayerCore
import UserNotifications

/// 캡처용 데모 모드(DemoData)가 켜져 있는가. 배포판에서는 늘 false 다.
/// GitHub·Claude 에 묻는 길 몇 곳이 첫 줄에서 이것을 보고 멈춘다 — 가짜 화면에 진짜 조회 결과가 섞이지 않게.
enum DemoMode {
    static var isOn: Bool {
        #if DEBUG
        DemoData.isOn
        #else
        false
        #endif
    }
}

#if DEBUG
/// 공개 저장소 README 의 화면을 찍을 때 쓰는 가짜 데이터. **DEBUG 빌드에만** 있다.
///
/// `PRAYER_DEMO=1` 로 켜면 앱이 GitHub·Claude 에 묻지 않고 가짜 레포(acme/sample-ios·acme/sample-sdk),
/// 가짜 PR, 가짜 사람(Alex·Jamie·Sam·Riley)으로 화면을 채운다. 공개로 나가는 그림에 회사 레포·PR·팀원이
/// 들어가지 않게 하려는 것이다(사용자 요청, 2026-10-06). 데이터 폴더는 따로 쓴다(`PRAYER_DATA_DIR` 또는
/// 시험용 사본의 `PRayerDataDirectory`). 찍는 법은 CLAUDE.md "README 캡처"(`Scripts/readme-shots/shoot.sh`).
enum DemoData {
    static var isOn: Bool { ProcessInfo.processInfo.environment["PRAYER_DEMO"] == "1" }

    static let iOS = RepoID(owner: "acme", name: "sample-ios")
    static let sdk = RepoID(owner: "acme", name: "sample-sdk")
    static let viewer = "you-acme"
    /// 로그인은 회사 계정처럼 `-acme` 를 붙이고, 화면에는 이 이름으로 보인다.
    static let nicknames = ["alex-acme": "Alex", "jamie-acme": "Jamie", "sam-acme": "Sam", "riley-acme": "Riley"]

    @MainActor
    static func load(into model: AppModel) {
        var settings = Settings.default
        settings.onboardingCompleted = true
        settings.repos = repos
        settings.model = "opus"
        settings.effort = "high"
        settings.memberNicknames = nicknames
        settings.excludedPathPatterns = ["*.pbxproj", "*.xcassets/*"]
        // 빠뜨린 조회가 있어도 GitHub·Claude 에 닿지 않게 없는 경로를 둔다.
        settings.ghPath = "/nonexistent/gh"
        settings.claudePath = "/nonexistent/claude"
        model.settings = settings
        model.githubAccount = GitHubAccount(login: viewer, scopes: ["repo", "read:org"])
        model.claudeStatus = EngineStatus(path: settings.claudePath, version: AppInfo.verifiedClaudeVersion,
                                          loggedIn: true, accountLabel: "demo@example.com")
        model.repoOptions = repoOptions
        model.organizations = ["acme"]
        model.prs = prs(now: Date())
        model.exclusionCatalog = exclusionCatalog
        model.exclusionCatalogState = .loaded(at: Date(), repos: 2, failed: 0)
        model.lastRefreshedAt = Date()
        model.rateRemaining = 4_980
        model.notificationStatus = .authorized
        for pr in model.prs {
            let record: ReviewRecord
            switch (pr.repo, pr.number) {
            case (iOS, 128): record = loginReview(for: pr)
            case (iOS, 133): record = bannerReview(for: pr)
            default: continue
            }
            model.records[pr.id] = record
            model.recordHistory[pr.id] = [record]
        }
        Log.info("데모 데이터로 켬 — GitHub·Claude 에 묻지 않는다", "app")
    }

    // MARK: - 레포

    static let repos: [RepoConfig] = [
        RepoConfig(repo: iOS, prTargetBranch: "develop", approvalThreshold: 2, approvalThresholdFromAPI: true,
                   approvalGroups: [ApprovalGroup(count: 2, branches: ["develop", "release/*"]),
                                    ApprovalGroup(count: 1, branches: ["main", "hotfix/*"])]),
        RepoConfig(repo: sdk, prTargetBranch: "main", approvalThreshold: 1, approvalThresholdFromAPI: true,
                   approvalGroups: [ApprovalGroup(count: 1, branches: ["main"])]),
    ]

    static let repoOptions: [RepoOption] = [
        RepoOption(repo: iOS, isPrivate: true, isArchived: false, isFork: false, defaultBranch: "develop", permission: "WRITE"),
        RepoOption(repo: sdk, isPrivate: true, isArchived: false, isFork: false, defaultBranch: "main", permission: "WRITE"),
        RepoOption(repo: RepoID(owner: "acme", name: "design-system"), isPrivate: true, isArchived: false, isFork: false,
                   defaultBranch: "main", permission: "READ"),
        RepoOption(repo: RepoID(owner: "acme", name: "web-console"), isPrivate: true, isArchived: false, isFork: false,
                   defaultBranch: "main", permission: "WRITE"),
    ]

    // MARK: - PR

    static func prs(now: Date) -> [PullRequestInfo] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func pr(_ repo: RepoID, _ number: Int, _ title: String, author: String, body: String = "",
                base: String, head: String, added: Int, deleted: Int, files: Int, updated: Double, created: Double,
                approvals: [String] = [], labels: [String] = [], requested: Bool = true,
                myReview: String? = nil, mine: Bool = false, threads: [PRReviewThread] = [],
                events: [PRReviewEvent] = [], comments: [PRIssueComment] = [], commits: [PRCommit] = []) -> PullRequestInfo {
            let headSha = sha(number)
            var info = PullRequestInfo(repo: repo, number: number, nodeID: "PR_demo_\(number)", title: title, bodyText: body,
                                   author: author, isDraft: false, state: "OPEN", createdAt: ago(created),
                                   updatedAt: ago(updated), headRefOid: headSha, headRefName: head, baseRefName: base,
                                   additions: added, deletions: deleted, changedFiles: files, mergeable: .mergeable,
                                   mergeStateStatus: "CLEAN", reviewDecision: approvals.isEmpty ? "REVIEW_REQUIRED" : nil,
                                   approvals: approvals.map { ApprovalInfo(login: $0, commitOid: headSha) },
                                   labels: labels, viewerDidAuthor: mine, viewerHasReviewRequest: requested,
                                   viewerLatestReviewState: myReview,
                                   // 승인은 지금 커밋에 한 것으로, 코멘트는 옛 커밋에 남긴 것으로 둔다(다시 요청됨 모양).
                                   viewerLatestReviewCommit: myReview == nil ? nil : (myReview == "APPROVED" ? headSha : sha(number + 1_000)),
                                   checkState: "SUCCESS", checks: [PRCheck(name: "build", outcome: "SUCCESS")],
                                   threads: threads, commits: commits, reviewEvents: events, issueComments: comments)
            // 머리 줄의 받는 쪽 칩이 ▾ 를 달고 눌리게 — 실제로도 쓰기 권한이 있는 팀 레포에서는 남의 PR 도 바꿀 수 있다.
            info.viewerCanUpdate = true
            return info
        }

        func iso(_ minutes: Double) -> String { ISO8601DateFormatter().string(from: ago(minutes)) }
        let loginThread = PRReviewThread(
            id: "T_demo_1", path: "App/Sources/Login/LoginView.swift", line: 42, isResolved: false, isOutdated: false,
            comments: [
                ReviewThreadComment(author: "alex-acme", body: "키보드가 올라오면 버튼이 가려지지 않나요?", createdAt: iso(250)),
                ReviewThreadComment(author: "jamie-acme", body: "`safeAreaInset` 으로 옮겨서 따라 올라가게 했어요.", createdAt: iso(65)),
                ReviewThreadComment(author: "alex-acme", body: "확인했습니다 👍", createdAt: iso(45)),
            ])
        func commit(_ seed: Int, _ headline: String, _ minutes: Double) -> PRCommit {
            PRCommit(oid: sha(seed), abbreviatedOid: String(sha(seed).prefix(7)), messageHeadline: headline,
                     committedDate: ago(minutes), author: "jamie-acme")
        }
        let paymentThread = PRReviewThread(
            id: "T_demo_2", path: "App/Sources/Payment/PaymentSummaryView.swift", line: 31, isResolved: true, isOutdated: false,
            comments: [
                ReviewThreadComment(author: "alex-acme", body: "금액은 \"원\" 까지 붙여 읽히게 하면 어떨까요?", createdAt: iso(3_000)),
                ReviewThreadComment(author: "jamie-acme", body: "accessibilityValue 로 \"12,000원\" 처럼 읽히게 바꿨어요.", createdAt: iso(2_600)),
            ])
        let paymentCommits = [
            PRCommit(oid: sha(1_241), abbreviatedOid: String(sha(1_241).prefix(7)), messageHeadline: "결제 버튼 접근성 라벨",
                     committedDate: ago(4_100), author: "jamie-acme"),
            PRCommit(oid: sha(124), abbreviatedOid: String(sha(124).prefix(7)), messageHeadline: "금액을 원 단위로 읽기",
                     committedDate: ago(2_550), author: "jamie-acme"),
        ]
        let loginCommits = [commit(1_281, "로그인 화면 레이아웃 정리", 300),
                            commit(1_282, "버튼 상태를 하나로 모음", 240),
                            commit(128, "키보드 올라올 때 버튼 위치", 70)]

        return [
            pr(iOS, 128, "로그인 화면 정리", author: "jamie-acme",
               body: "로그인 화면의 레이아웃을 정리하고, 흩어져 있던 버튼 상태를 하나로 모았습니다.\n\n리뷰 포인트\n- 키보드가 올라올 때 버튼 위치\n- 다크 모드에서 버튼 색",
               base: "develop", head: "feature/login-cleanup", added: 98, deleted: 18, files: 3, updated: 35, created: 320,
               approvals: ["alex-acme"], labels: ["feature"], threads: [loginThread],
               events: [PRReviewEvent(author: "alex-acme", state: "APPROVED", submittedAt: ago(40), body: "")],
               comments: [PRIssueComment(author: "sam-acme", body: "`LoginButtonLabel` 의 로딩 상태 스크린샷도 붙여 주시면 좋겠어요.", createdAt: ago(200))],
               commits: loginCommits),
            pr(iOS, 131, "설정 화면 다크 모드 색 맞추기", author: "alex-acme",
               body: "다크 모드에서 설정 화면의 셀 배경과 글자 색이 시스템 색과 달라 보이던 것을 색 토큰으로 맞췄습니다.",
               base: "develop", head: "fix/settings-dark", added: 48, deleted: 21, files: 4, updated: 15, created: 1_500,
               labels: ["bug"], myReview: "COMMENTED",
               events: [PRReviewEvent(author: viewer, state: "COMMENTED", submittedAt: ago(1_420),
                                      body: "구분선 색도 다크 모드에서 한 번 봐 주세요. 지금은 흰 줄처럼 보여요.")],
               comments: [PRIssueComment(author: "alex-acme", body: "구분선 색까지 맞췄습니다. 다시 봐 주세요 🙏", createdAt: ago(20))],
               commits: [
                   PRCommit(oid: sha(1_311), abbreviatedOid: String(sha(1_311).prefix(7)), messageHeadline: "다크 모드 색 토큰 정리",
                            committedDate: ago(1_480), author: "alex-acme"),
                   PRCommit(oid: sha(1_131), abbreviatedOid: String(sha(1_131).prefix(7)), messageHeadline: "설정 셀 배경색 맞추기",
                            committedDate: ago(1_450), author: "alex-acme"),
                   PRCommit(oid: sha(131), abbreviatedOid: String(sha(131).prefix(7)), messageHeadline: "구분선 색 다크 모드 대응",
                            committedDate: ago(25), author: "alex-acme"),
               ]),
            pr(iOS, 126, "네트워크 재시도 정책 정리", author: "sam-acme",
               base: "develop", head: "refactor/retry", added: 212, deleted: 160, files: 9, updated: 180, created: 2_900),
            pr(iOS, 129, "알림 권한 안내 문구 수정", author: viewer,
               base: "develop", head: "fix/notification-copy", added: 12, deleted: 8, files: 2, updated: 90, created: 400,
               approvals: ["riley-acme"], requested: false, mine: true),
            pr(sdk, 42, "이미지 캐시 크기 제한", author: "riley-acme",
               base: "main", head: "feature/cache-limit", added: 87, deleted: 12, files: 5, updated: 60, created: 700),
            pr(iOS, 133, "홈 배너 자동 넘김 간격 조정", author: "riley-acme",
               body: "배너가 3초마다 넘어가 긴 문구를 다 못 읽는다는 의견이 있어 5초로 늘렸습니다. 손으로 넘기는 중에는 자동으로 넘기지 않고, 동작 줄이기 설정도 따릅니다.",
               base: "develop", head: "feature/banner-interval", added: 24, deleted: 4, files: 2, updated: 20, created: 110,
               labels: ["feature"]),
            pr(iOS, 124, "결제 화면 접근성 라벨 추가", author: "jamie-acme",
               body: "결제 화면의 버튼과 금액에 VoiceOver 라벨을 붙였습니다.\n\n확인한 것\n- 결제 수단 고르기\n- 쿠폰 적용 후 금액 읽기",
               base: "develop", head: "a11y/payment-labels", added: 41, deleted: 6, files: 4, updated: 300, created: 4_200,
               approvals: ["alex-acme", "sam-acme"], labels: ["accessibility"], requested: false, myReview: "APPROVED",
               threads: [paymentThread],
               events: [PRReviewEvent(author: "alex-acme", state: "APPROVED", submittedAt: ago(2_400), body: ""),
                        PRReviewEvent(author: viewer, state: "APPROVED", submittedAt: ago(1_900), body: "VoiceOver 로 결제까지 따라가 봤어요. 좋습니다 👍"),
                        PRReviewEvent(author: "sam-acme", state: "APPROVED", submittedAt: ago(320), body: "")],
               comments: [PRIssueComment(author: "riley-acme", body: "쿠폰 금액도 읽히는 것 확인했습니다.", createdAt: ago(1_200))],
               commits: paymentCommits),
            pr(sdk, 44, "Swift 6 동시성 경고 정리", author: "sam-acme",
               base: "main", head: "chore/swift6-warnings", added: 156, deleted: 131, files: 12, updated: 95, created: 1_300,
               labels: ["refactor"]),
            pr(sdk, 40, "README 예제 갱신", author: "alex-acme",
               base: "main", head: "docs/readme", added: 30, deleted: 9, files: 1, updated: 240, created: 3_000,
               labels: ["docs"]),
        ]
    }

    /// `PRAYER_DEBUG_REFRESH_FLIGHT` 가 쓰는 "새로 받은" 목록. 리뷰 대기 탭에서 #126 은 머지돼 빠지고(All PRs 로),
    /// #131 은 웹에서 Approve 해 빠지고(Approved 로), 둘이 새로 온다. `large` 면 빠짐 4·새로 5 로 한꺼번에 바뀌는 모양.
    static func refreshed(_ prs: [PullRequestInfo], large: Bool) -> [PullRequestInfo] {
        let now = Date()
        let merged: Set<Int> = large ? [126, 40] : [126]
        var next = prs.filter { !merged.contains($0.number) }
        for number in large ? [131, 44] : [131] {
            guard let index = next.firstIndex(where: { $0.number == number }) else { continue }
            // 리뷰 기록까지 Approve 한 모습으로 — Approved 탭이 그 시각으로 거른다(AppModel.approvedInWindow).
            next[index] = ListCacheSeeding.approved(next[index], by: viewer, at: now)
        }
        guard let template = prs.first(where: { $0.repo == iOS && $0.number == 126 }) else { return next }
        func arrival(_ repo: RepoID, _ number: Int, _ title: String, author: String, created minutes: Double) -> PullRequestInfo {
            var pr = template
            pr.repo = repo
            pr.number = number
            pr.nodeID = "PR_demo_\(number)"
            pr.title = title
            pr.author = author
            pr.createdAt = now.addingTimeInterval(-minutes * 60)
            pr.updatedAt = pr.createdAt
            pr.headRefOid = sha(number)
            pr.headRefName = "feature/demo-\(number)"
            return pr
        }
        next.append(arrival(iOS, 135, "검색 결과가 없을 때 안내 문구", author: "sam-acme", created: 3))
        next.append(arrival(sdk, 43, "로그 레벨 설정 추가", author: "alex-acme", created: 900))
        if large {
            next.append(arrival(iOS, 136, "다운로드 진행률 표시", author: "riley-acme", created: 1))
            next.append(arrival(sdk, 45, "캐시 만료 시간 설정", author: "jamie-acme", created: 30))
            next.append(arrival(iOS, 134, "온보딩 건너뛰기 버튼", author: "jamie-acme", created: 60))
        }
        return next.sorted { $0.createdAt > $1.createdAt }
    }

    /// 커밋 해시처럼 보이는 40자. 같은 수를 주면 늘 같다(캡처를 다시 찍어도 같은 화면).
    static func sha(_ seed: Int) -> String {
        var x = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        var out = ""
        while out.count < 40 {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out += String(format: "%016llx", x)
        }
        return String(out.prefix(40))
    }

    // MARK: - 새 커밋 확인 창

    static var newCommitsPrompt: HeadDriftPrompt {
        let drift = HeadDrift(baseSha: sha(128), headSha: sha(1_283),
                              commits: [HeadDrift.Commit(oid: sha(1_284), headline: "로그인 버튼 색 수정"),
                                        HeadDrift.Commit(oid: sha(1_283), headline: "오타 고침")],
                              totalCount: 2)
        return HeadDriftPrompt.make(drift: drift, subject: .review(event: .comment, label: "코멘트 게시", inlineCount: 2))
    }

    // MARK: - 전체 리뷰 확인 창의 크기

    static let snapshotSize = (code: CodeSize(files: 1_284, bytes: 44_040_192, truncated: false),
                               repoBytes: Int64(1_288_490_189))

    // MARK: - 제외 자동완성

    /// `*.pl` 을 치면 `*.plist`(레포 파일 24개 · 최근 PR 3건)와 `*.pl`(2개)이 뜨게 짠 가짜 레포.
    static var exclusionCatalog: ExclusionCatalog {
        var paths: [String] = []
        let features = ["Login", "Settings", "Home", "Profile", "Player", "Search", "Library", "Onboarding"]
        for feature in features {
            for kind in ["View", "ViewModel", "Coordinator", "Service", "Model"] {
                paths.append("App/Sources/\(feature)/\(feature)\(kind).swift")
            }
            paths.append("App/Resources/\(feature).xcassets/Contents.json")
            paths.append("App/Resources/\(feature).xcassets/icon.imageset/icon.png")
        }
        for i in 1...12 { paths.append("App/Supporting/Config\(i).plist") }
        for target in ["App", "Widget", "NotificationService", "Share", "Intents", "Watch"] {
            paths.append("\(target)/Info.plist")
            paths.append("\(target)/\(target).entitlements")
        }
        for name in ["Root", "Advanced", "About", "Debug", "Licenses", "Privacy"] {
            paths.append("App/Settings.bundle/\(name).plist")
        }
        paths += ["Scripts/release.pl", "Scripts/strings.pl", "Scripts/bootstrap.sh",
                  "App.xcodeproj/project.pbxproj", "Package.resolved", "README.md"]
        typealias File = ExclusionCatalog.PRFile
        var prs: [[File]] = []
        prs.append([File(path: "App/Info.plist", additions: 2, deletions: 1),
                    File(path: "App/Sources/Login/LoginView.swift", additions: 80, deletions: 3)])
        prs.append([File(path: "Widget/Info.plist", additions: 4, deletions: 0),
                    File(path: "App/Settings.bundle/Root.plist", additions: 12, deletions: 2)])
        prs.append([File(path: "App/Supporting/Config3.plist", additions: 6, deletions: 6),
                    File(path: "App.xcodeproj/project.pbxproj", additions: 40, deletions: 12)])
        for (i, feature) in features.enumerated() {
            prs.append([File(path: "App/Sources/\(feature)/\(feature)View.swift", additions: 20 + i * 7, deletions: 4 + i),
                        File(path: "App/Sources/\(feature)/\(feature)ViewModel.swift", additions: 12 + i * 3, deletions: 2)])
        }
        return ExclusionCatalog(paths: paths, pullRequests: prs)
    }

    // MARK: - AI 리뷰 (acme/sample-ios#128)

    /// 로그인 화면 PR 에 돌린 것처럼 보이는 리뷰 한 건. 줄 번호·anchor 는 `loginDiff` 의 새 파일 기준이다.
    static func loginReview(for pr: PullRequestInfo) -> ReviewRecord {
        let vm = "App/Sources/Login/LoginViewModel.swift"
        let view = "App/Sources/Login/LoginView.swift"
        let state = "App/Sources/Login/LoginButtonState.swift"
        let comments = [
            DraftComment(issueKey: "double-tap-login", path: vm, line: 24, side: .right,
                         body: "`state = .loading` 을 Task 안에서 바꾸고 있어서, 버튼을 빠르게 두 번 누르면 두 번째 탭 때도 아직 `.enabled` 입니다. 로그인 요청이 두 번 나갑니다.\n\nTask 를 만들기 전에 `guard state != .loading else { return }` 로 막고 `state = .loading` 을 먼저 바꿔 주세요.",
                         severity: .blocker, anchorText: "Task {",
                         rationaleKo: "login() 은 @MainActor 지만 Task 안의 첫 줄은 다음 틱에 돈다. 그 사이 두 번째 탭이 들어오면 guard 가 없다.",
                         evidence: [CodeEvidence(path: view, line: 34, note: "버튼이 viewModel.login() 을 바로 부른다"),
                                    CodeEvidence(path: vm, line: 25, note: "state 를 Task 안에서 .loading 으로 바꾼다")]),
            DraftComment(issueKey: "raw-error-message", path: view, line: 24, side: .right,
                         body: "(비블로커) 서버 오류의 `localizedDescription` 이 그대로 보입니다. 네트워크 오류면 영어 시스템 문구가 섞일 수 있어서, 사용자에게 보일 문구로 한 번 바꿔 주면 좋겠습니다.",
                         severity: .minor, anchorText: "if let message = viewModel.state.errorMessage {",
                         evidence: [CodeEvidence(path: vm, line: 30, note: "error.localizedDescription 을 그대로 담는다")]),
            DraftComment(issueKey: "focus-on-every-appear", path: view, line: 43, side: .right,
                         body: "(비블로커) 화면이 나타날 때마다 이메일 칸에 포커스를 줍니다. 비밀번호를 치다가 다른 화면에 다녀오면 커서가 이메일로 돌아가요. 이메일이 비어 있을 때만 주는 건 어떨까요?",
                         severity: .minor, anchorText: ".onAppear {"),
            DraftComment(issueKey: "state-tests", path: state, line: 4, side: .right,
                         body: "(비블로커) `failed` 에서도 다시 누를 수 있게 한 건 의도대로 보여요. 이 전환(failed → loading → enabled)을 테스트로 하나 남겨 두면 좋겠습니다.",
                         severity: .nit, anchorText: "enum LoginButtonState: Equatable {"),
            DraftComment(issueKey: "after-login-navigation", path: vm, line: 28, side: .right,
                         body: "[질문] 로그인에 성공한 뒤 화면 전환은 어디서 하나요? 지금은 state 를 .enabled 로 돌리기만 해서, 넘어가기 전 잠깐 버튼이 다시 눌리는 상태로 보일 수 있어요.",
                         severity: .nit, anchorText: "state = .enabled"),
        ]
        // 새 출력 형식(2026-10-20~)처럼 작성자에게 남길 말은 코드 코멘트 한 목록뿐이다 — 우려사항·질문 목록은 비운다.
        let output = ReviewOutput(
            verdict: .requestChanges,
            summaryKo: "로그인 화면의 레이아웃을 정리하고 흩어져 있던 버튼 상태를 LoginButtonState 하나로 모아, 화면이 그 값만 보고 그리도록 바꾸셨습니다. 다만 버튼을 빠르게 두 번 누르면 로그인 요청이 두 번 나갈 수 있어 그 부분 확인이 필요합니다.",
            concerns: [],
            strengths: ["키보드가 올라올 때 safeAreaInset 으로 버튼이 따라 올라가 가려지지 않습니다.",
                        "실패한 뒤에도 버튼을 다시 누를 수 있어 오류가 나도 화면을 다시 열지 않아도 됩니다."],
            draftComments: comments)
        var record = ReviewRecord(repo: pr.repo, number: pr.number, headSha: pr.headRefOid, baseRefName: pr.baseRefName,
                            promptVersion: "demo", model: "claude-opus-5-5", createdAt: Date().addingTimeInterval(-18 * 60),
                            trigger: .manual, deep: true, output: output,
                            comments: comments.map { DraftCommentState(comment: $0) }, includeStrengths: false,
                            bodyDraft: output.summaryKo,
                            usage: EngineUsage(model: "claude-opus-5-5", inputTokens: 12, cacheCreationTokens: 9_812,
                                               cacheReadTokens: 148_220, outputTokens: 2_416, costUSD: 0.21, durationMs: 74_000))
        // 이어서 대화하기 칸이 "이어 갈 수 없음" 대신 평소 모양으로 보이게(실제로 이어 가지는 않는다).
        record.sessionID = "00000000-0000-4000-8000-000000000128"
        return record
    }

    // MARK: - AI 리뷰 (acme/sample-ios#133) — 머지를 막는 이슈가 없는 리뷰

    static func bannerReview(for pr: PullRequestInfo) -> ReviewRecord {
        let banner = "App/Sources/Home/HomeBannerView.swift"
        let home = "App/Sources/Home/HomeView.swift"
        let comments = [
            DraftComment(issueKey: "drag-stops-autoplay", path: banner, line: 31, side: .right,
                         body: "(비블로커) 끌고 있을 때 넘김을 건너뛰면 그 index 의 task 가 그대로 끝나서, 손을 뗀 뒤에 다른 장으로 넘기지 않으면 자동 넘김이 멈춥니다. 손을 뗀 뒤 다시 세도록 `isDragging` 도 `task(id:)` 의 id 에 넣어 주면 좋겠어요.",
                         severity: .minor, anchorText: "guard !isDragging else {",
                         evidence: [CodeEvidence(path: banner, line: 24, note: "onEnded 에서 isDragging 만 바꾸고 다시 세지 않는다")]),
            DraftComment(issueKey: "interval-injection", path: banner, line: 10, side: .right,
                         body: "(비블로커) 간격을 나중에 서버 설정으로 받을 계획이 있다면, 여기를 init 으로 받게 열어 두면 바꾸기 쉬울 것 같아요.",
                         severity: .nit, anchorText: "static let interval: TimeInterval = 5"),
            DraftComment(issueKey: "banner-layout-shift", path: home, line: 8, side: .right,
                         body: "[질문] 배너를 받아 오는 동안에는 자리가 비었다가 나중에 180pt 가 생기는데, 아래 목록이 밀려 내려가는 게 의도인가요?",
                         severity: .nit, anchorText: "if !viewModel.banners.isEmpty {",
                         evidence: [CodeEvidence(path: home, line: 8, note: "배너가 비면 HomeBannerView 를 그리지 않는다")]),
        ]
        // 권장(minor)이 있어 판정은 comment — 필수가 없으니 화면은 "머지를 막는 이슈 없음" 이다.
        let output = ReviewOutput(
            verdict: .comment,
            summaryKo: "배너 자동 넘김 간격을 5초로 늘리고 Timer 대신 task(id:) 로 바꿔, 손으로 넘긴 뒤에는 간격을 처음부터 다시 세도록 하셨습니다. 동작 줄이기 설정까지 따르게 해 긴 문구를 끝까지 읽을 수 있게 잘 맞춰 주셔서, 머지를 막을 만한 부분은 없습니다.",
            concerns: [],
            strengths: ["Timer 를 들고 있지 않아 화면이 사라질 때 따로 멈추지 않아도 됩니다."],
            draftComments: comments)
        var record = ReviewRecord(repo: pr.repo, number: pr.number, headSha: pr.headRefOid, baseRefName: pr.baseRefName,
                                  promptVersion: "demo", model: "claude-opus-5-5", createdAt: Date().addingTimeInterval(-6 * 60),
                                  trigger: .manual, deep: true, output: output,
                                  comments: comments.map { DraftCommentState(comment: $0) }, includeStrengths: false,
                                  bodyDraft: output.summaryKo,
                                  usage: EngineUsage(model: "claude-opus-5-5", inputTokens: 10, cacheCreationTokens: 7_204,
                                                     cacheReadTokens: 96_310, outputTokens: 1_388, costUSD: 0.12, durationMs: 41_000))
        record.sessionID = "00000000-0000-4000-8000-000000000133"
        return record
    }

    // MARK: - diff

    /// 변경 파일 탭에 보일 가짜 diff. #128·#133 만 읽을 내용이 있다.
    ///
    /// README 캡처에 안 나오는 PR 몇 개는 목록의 +/− 수만큼 뜻 없는 줄로 채운다 — 여러 개 골라 리뷰하는 확인 창
    /// (BatchReviewSheet)이 PR 마다 줄 수·예상 토큰을 보여야 해서. 나머지는 비어 있다.
    static func diff(for pr: PullRequestInfo) -> String {
        switch (pr.repo, pr.number) {
        case (iOS, 128): return loginDiff
        case (iOS, 133): return bannerDiff
        case (iOS, 126), (sdk, 42), (sdk, 44): return fillerDiff(for: pr)
        default: return ""
        }
    }

    /// 파일 수·추가·삭제 줄 수가 목록과 같은 diff. 같은 PR 이면 늘 같다.
    static func fillerDiff(for pr: PullRequestInfo) -> String {
        let count = max(pr.changedFiles, 1)
        let folder = pr.headRefName.split(separator: "/").last.map(String.init) ?? "change"
        return (0..<count).map { index in
            let added = pr.additions / count + (index < pr.additions % count ? 1 : 0)
            let deleted = pr.deletions / count + (index < pr.deletions % count ? 1 : 0)
            let path = "Sources/\(folder)/Part\(index + 1).swift"
            var lines = ["diff --git a/\(path) b/\(path)",
                         "index 1a2b3c4..5d6e7f8 100644",
                         "--- a/\(path)",
                         "+++ b/\(path)",
                         "@@ -1,\(deleted) +1,\(added) @@"]
            lines += (0..<deleted).map { "-    let before\($0) = \($0)" }
            lines += (0..<added).map { "+    let after\($0) = \($0)" }
            return lines.joined(separator: "\n") + "\n"
        }.joined()
    }

    static let bannerDiff = #"""
diff --git a/App/Sources/Home/HomeBannerView.swift b/App/Sources/Home/HomeBannerView.swift
index fc40643..6ab1a8d 100644
--- a/App/Sources/Home/HomeBannerView.swift
+++ b/App/Sources/Home/HomeBannerView.swift
@@ -3,7 +3,11 @@ import SwiftUI
 struct HomeBannerView: View {
     let banners: [Banner]
     @State private var index = 0
-    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
+    @State private var isDragging = false
+    @Environment(\.accessibilityReduceMotion) private var reduceMotion
+
+    /// 한 장을 보여 주는 시간. 글이 긴 배너도 다 읽을 수 있게 3초에서 늘렸다.
+    static let interval: TimeInterval = 5
 
     var body: some View {
         TabView(selection: $index) {
@@ -14,8 +18,22 @@ struct HomeBannerView: View {
         }
         .tabViewStyle(.page)
         .frame(height: 180)
-        .onReceive(timer) { _ in
-            index = (index + 1) % banners.count
+        .simultaneousGesture(
+            DragGesture()
+                .onChanged { _ in isDragging = true }
+                .onEnded { _ in isDragging = false }
+        )
+        .task(id: index) {
+            guard banners.count > 1, !reduceMotion else {
+                return
+            }
+            try? await Task.sleep(for: .seconds(Self.interval))
+            guard !isDragging else {
+                return
+            }
+            withAnimation {
+                index = (index + 1) % banners.count
+            }
         }
     }
 }
diff --git a/App/Sources/Home/HomeView.swift b/App/Sources/Home/HomeView.swift
index a403079..d0aa03e 100644
--- a/App/Sources/Home/HomeView.swift
+++ b/App/Sources/Home/HomeView.swift
@@ -5,7 +5,9 @@ struct HomeView: View {
 
     var body: some View {
         ScrollView {
-            HomeBannerView(banners: viewModel.banners)
+            if !viewModel.banners.isEmpty {
+                HomeBannerView(banners: viewModel.banners)
+            }
             HomeSectionList(sections: viewModel.sections)
         }
         .task {
"""#

    static let loginDiff = #"""
diff --git a/App/Sources/Login/LoginView.swift b/App/Sources/Login/LoginView.swift
index 95c1ecc..6680199 100644
--- a/App/Sources/Login/LoginView.swift
+++ b/App/Sources/Login/LoginView.swift
@@ -2,20 +2,61 @@ import SwiftUI
 
 struct LoginView: View {
     @StateObject private var viewModel = LoginViewModel()
+    @FocusState private var focused: Field?
+
+    enum Field {
+        case email, password
+    }
 
     var body: some View {
-        VStack(spacing: 16) {
-            Text("다시 오신 걸 환영해요")
-                .font(.title2.bold())
-            TextField("이메일", text: $viewModel.email)
-                .textContentType(.emailAddress)
-            SecureField("비밀번호", text: $viewModel.password)
-            Spacer()
-            Button("로그인") {
+        ScrollView {
+            VStack(alignment: .leading, spacing: 16) {
+                Text("다시 오신 걸 환영해요")
+                    .font(.title2.bold())
+                TextField("이메일", text: $viewModel.email)
+                    .textContentType(.emailAddress)
+                    .keyboardType(.emailAddress)
+                    .focused($focused, equals: .email)
+                    .onSubmit { focused = .password }
+                SecureField("비밀번호", text: $viewModel.password)
+                    .focused($focused, equals: .password)
+                    .onSubmit { viewModel.login() }
+                if let message = viewModel.state.errorMessage {
+                    Text(message)
+                        .font(.footnote)
+                        .foregroundStyle(.red)
+                }
+            }
+            .padding(24)
+        }
+        .safeAreaInset(edge: .bottom) {
+            Button {
                 viewModel.login()
+            } label: {
+                LoginButtonLabel(state: viewModel.state)
+            }
+            .buttonStyle(.borderedProminent)
+            .disabled(!viewModel.state.isEnabled)
+            .padding(.horizontal, 24)
+            .padding(.bottom, 12)
+        }
+        .onAppear {
+            focused = .email
+        }
+    }
+}
+
+private struct LoginButtonLabel: View {
+    let state: LoginButtonState
+
+    var body: some View {
+        HStack(spacing: 8) {
+            if state == .loading {
+                ProgressView()
             }
-            .disabled(!viewModel.isValid || viewModel.isLoading)
+            Text(state == .loading ? "로그인 중…" : "로그인")
         }
-        .padding(24)
+        .frame(maxWidth: .infinity)
+        .padding(.vertical, 6)
     }
 }
diff --git a/App/Sources/Login/LoginViewModel.swift b/App/Sources/Login/LoginViewModel.swift
index 0256854..796e05a 100644
--- a/App/Sources/Login/LoginViewModel.swift
+++ b/App/Sources/Login/LoginViewModel.swift
@@ -2,26 +2,40 @@ import Foundation
 
 @MainActor
 final class LoginViewModel: ObservableObject {
-    @Published var email = ""
-    @Published var password = ""
-    @Published var isLoading = false
-    @Published var errorMessage: String?
+    @Published var email = "" {
+        didSet { refreshState() }
+    }
+    @Published var password = "" {
+        didSet { refreshState() }
+    }
+    @Published private(set) var state: LoginButtonState = .disabled
 
-    private let auth = AuthService.shared
+    private let auth: AuthServicing
+
+    init(auth: AuthServicing = AuthService.shared) {
+        self.auth = auth
+    }
 
     var isValid: Bool {
         email.contains("@") && password.count >= 8
     }
 
     func login() {
-        isLoading = true
         Task {
+            state = .loading
             do {
                 try await auth.login(email: email, password: password)
+                state = .enabled
             } catch {
-                errorMessage = error.localizedDescription
+                state = .failed(error.localizedDescription)
             }
-            isLoading = false
         }
     }
+
+    private func refreshState() {
+        guard state != .loading else {
+            return
+        }
+        state = isValid ? .enabled : .disabled
+    }
 }
diff --git a/App/Sources/Login/LoginButtonState.swift b/App/Sources/Login/LoginButtonState.swift
new file mode 100644
index 0000000..d70fb58 100644
--- /dev/null
+++ b/App/Sources/Login/LoginButtonState.swift
@@ -0,0 +1,25 @@
+import Foundation
+
+/// 로그인 버튼이 보일 모양. 화면은 이 값 하나만 보고 그린다.
+enum LoginButtonState: Equatable {
+    case disabled
+    case enabled
+    case loading
+    case failed(String)
+
+    var isEnabled: Bool {
+        switch self {
+        case .enabled, .failed:
+            return true
+        case .disabled, .loading:
+            return false
+        }
+    }
+
+    var errorMessage: String? {
+        if case .failed(let message) = self {
+            return message
+        }
+        return nil
+    }
+}
"""#

    // MARK: - 커밋별로 보기

    /// 변경 파일 탭 "커밋별로 보기" 의 가짜 브랜치. 안에서 갈라졌다 합친 가지 하나와 base 를 받아온 머지 하나를 둔다 — 그래프 두 레인과
    /// 오른쪽에서 들어오는 짧은 선이 다 보이게. 마지막 커밋이 PR 의 head 다.
    static func branchCommits(for pr: PullRequestInfo) -> BranchCommits {
        let now = Date()
        func seed(_ i: Int) -> String { sha(pr.number * 100 + i) }
        func commit(_ oid: String, _ headline: String, _ parents: [String], _ minutes: Double,
                    _ added: Int, _ deleted: Int, files: Int, author: String = "jamie-acme") -> BranchCommit {
            BranchCommit(oid: oid, abbreviatedOid: String(oid.prefix(7)), headline: headline,
                         authorName: nicknames[author] ?? author, authorLogin: author,
                         date: now.addingTimeInterval(-minutes * 60), parents: parents,
                         additions: added, deletions: deleted, changedFiles: files)
        }
        let commits = [
            commit(seed(1), "로그인 화면 레이아웃 뼈대", [seed(90)], 3_000, 34, 3, files: 1),
            commit(seed(2), "로그인 버튼에 접근성 라벨 달기", [seed(1)], 2_600, 2, 0, files: 1, author: "sam-acme"),
            commit(seed(3), "키보드가 올라오면 버튼도 따라 올라가게", [seed(1)], 2_400, 6, 4, files: 1),
            commit(seed(4), "Merge branch 'login-a11y' into \(pr.headRefName)", [seed(3), seed(2)], 2_000, 2, 0, files: 1),
            commit(seed(5), "Merge branch '\(pr.baseRefName)' into \(pr.headRefName)", [seed(4), seed(91)], 900, 21, 4, files: 2),
            commit(pr.headRefOid, "리뷰 반영: 에러 문구 다듬기", [seed(5)], 60, 3, 2, files: 1),
        ]
        return BranchCommits(baseRefName: pr.baseRefName, headRefName: pr.headRefName, commits: commits,
                             totalCount: commits.count)
    }

    /// 커밋을 고른 뒤의 diff. 커밋마다 작은 조각을, 범위는 PR 전체 diff 를 돌려준다.
    static func commitDiff(for spec: CommitDiffSpec) -> String {
        guard case .commit(let oid) = spec else { return loginDiff }
        for number in [128, 133] {
            for index in 1...5 where sha(number * 100 + index) == oid {
                return commitDiffs[index - 1]
            }
        }
        return commitDiffs[5]
    }

    static let commitDiffs: [String] = [
        #"""
diff --git a/App/Sources/Login/LoginView.swift b/App/Sources/Login/LoginView.swift
new file mode 100644
index 0000000..95c1ecc
--- /dev/null
+++ b/App/Sources/Login/LoginView.swift
@@ -0,0 +1,14 @@
+import SwiftUI
+
+struct LoginView: View {
+    @State private var email = ""
+    @State private var password = ""
+
+    var body: some View {
+        VStack(spacing: 16) {
+            TextField("이메일", text: $email)
+            SecureField("비밀번호", text: $password)
+            Button("로그인") { }
+        }
+    }
+}
"""#,
        #"""
diff --git a/App/Sources/Login/LoginView.swift b/App/Sources/Login/LoginView.swift
index 95c1ecc..a1b2c3d 100644
--- a/App/Sources/Login/LoginView.swift
+++ b/App/Sources/Login/LoginView.swift
@@ -9,6 +9,8 @@ struct LoginView: View {
             TextField("이메일", text: $email)
             SecureField("비밀번호", text: $password)
             Button("로그인") { }
+                .accessibilityLabel("로그인")
+                .accessibilityHint("이메일과 비밀번호로 로그인합니다")
         }
     }
 }
"""#,
        #"""
diff --git a/App/Sources/Login/LoginView.swift b/App/Sources/Login/LoginView.swift
index 95c1ecc..b2c3d4e 100644
--- a/App/Sources/Login/LoginView.swift
+++ b/App/Sources/Login/LoginView.swift
@@ -6,9 +6,11 @@ struct LoginView: View {
 
     var body: some View {
-        VStack(spacing: 16) {
+        ScrollView {
+            VStack(spacing: 16) {
                 TextField("이메일", text: $email)
                 SecureField("비밀번호", text: $password)
-            Button("로그인") { }
-        }
+            }
+        }
+        .safeAreaInset(edge: .bottom) { Button("로그인") { } }
     }
 }
"""#,
        #"""
diff --git a/App/Sources/Login/LoginView.swift b/App/Sources/Login/LoginView.swift
index b2c3d4e..c3d4e5f 100644
--- a/App/Sources/Login/LoginView.swift
+++ b/App/Sources/Login/LoginView.swift
@@ -13,4 +13,6 @@ struct LoginView: View {
         }
         .safeAreaInset(edge: .bottom) { Button("로그인") { } }
+            .accessibilityLabel("로그인")
+            .accessibilityHint("이메일과 비밀번호로 로그인합니다")
     }
 }
"""#,
        #"""
diff --git a/App/Sources/Home/HomeView.swift b/App/Sources/Home/HomeView.swift
index a403079..d0aa03e 100644
--- a/App/Sources/Home/HomeView.swift
+++ b/App/Sources/Home/HomeView.swift
@@ -5,7 +5,9 @@ struct HomeView: View {
 
     var body: some View {
         ScrollView {
-            HomeBannerView(banners: viewModel.banners)
+            if !viewModel.banners.isEmpty {
+                HomeBannerView(banners: viewModel.banners)
+            }
             HomeSectionList(sections: viewModel.sections)
         }
         .task {
diff --git a/App/Sources/Home/HomeBannerView.swift b/App/Sources/Home/HomeBannerView.swift
index fc40643..6ab1a8d 100644
--- a/App/Sources/Home/HomeBannerView.swift
+++ b/App/Sources/Home/HomeBannerView.swift
@@ -3,6 +3,7 @@ import SwiftUI
 struct HomeBannerView: View {
     let banners: [Banner]
     @State private var index = 0
-    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
+    /// 한 장을 보여 주는 시간. 글이 긴 배너도 다 읽을 수 있게 3초에서 늘렸다.
+    static let interval: TimeInterval = 5
 
     var body: some View {
"""#,
        #"""
diff --git a/App/Sources/Login/LoginViewModel.swift b/App/Sources/Login/LoginViewModel.swift
index 7d1e2f0..8e2f3a1 100644
--- a/App/Sources/Login/LoginViewModel.swift
+++ b/App/Sources/Login/LoginViewModel.swift
@@ -21,5 +21,6 @@ final class LoginViewModel: ObservableObject {
         case .invalidPassword:
-            errorMessage = "비밀번호가 틀렸습니다."
+            errorMessage = "비밀번호가 맞지 않아요. 다시 입력해 주세요."
         case .locked:
-            errorMessage = "계정이 잠겼습니다."
+            errorMessage = "로그인을 여러 번 실패해 잠시 잠겼어요."
+            showsResetLink = true
         }
"""#,
    ]
}
#endif
