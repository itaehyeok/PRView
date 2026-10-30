import SwiftUI
import PRayerCore

/// 버튼을 누를 수 없는 확인(접근성 권한 없이 화면만 찍는 실측)에서 켜자마자 보일 자리를 고른다.
/// **DEBUG 빌드에서만** 환경 변수를 읽는다 — 배포판에서는 늘 nil 이다.
///
/// - `PRAYER_DEBUG_SELECT_PR=owner/name#번호` — 그 PR 을 고르고 AI 리뷰 탭을 연다.
///   `PRAYER_DEBUG_DETAIL_TAB=diff`(overview·review·diff)를 같이 주면 그 탭을 연다.
/// - `PRAYER_DEBUG_SETTINGS_TAB=리뷰` — 설정 창을 그 탭(SettingsView 의 tag)으로 연다.
/// - `PRAYER_DEBUG_ADD_EXCLUSION=규칙` — 화면이 뜬 뒤 제외 규칙을 하나 더한다(변경 파일 탭 우클릭과 같은 길).
/// - `PRAYER_DEBUG_SNAPSHOT_CONFIRM=1` — 고른 PR 로 "현재 PR의 스냅샷을 클론합니다" 창을 띄운다(클론은 하지 않는다).
///   `1` 대신 경로를 주면 "전에 연결한 클론 폴더를 찾을 수 없어서" 줄이 붙은 모양이 된다.
/// - `PRAYER_DEBUG_CLONE_PROGRESS=clone|files|unpack|again|running` — 고른 PR 에 진행 중인 가짜 잡을 걸어 둔다(running 은 Claude 단계)
///   (리뷰 카드·목록 배지 모양 확인용. 아무것도 받거나 돌리지 않는다).
///
/// - `PRAYER_DEBUG_EXCLUSION_QUERY=*.pl` — 설정 › 대상 제외의 규칙 칸에 그 글자를 미리 넣는다(자동완성 모양 확인).
///   `PRAYER_DEBUG_SETTINGS_TAB=제외` 와 같이 준다.
/// - `PRAYER_DEBUG_SHOW_APPROVAL_RULES=1` — 설정 레포 줄의 브랜치별 Approve 수 말풍선을 띄워 둔다(마우스를 올린 것처럼).
///   `PRAYER_DEBUG_SETTINGS_TAB=레포` 와 같이 준다.
///
/// - `PRAYER_DEBUG_FOLLOW=번호` — 고른 PR 에서 리뷰 항목 따라가기의 그 번째(0부터) 항목으로 변경 파일 탭을 연다
///   (AI 리뷰 탭에서 코드 링크를 누른 것과 같다). 따라갈 항목이 없는 새 형식 리뷰면 그 번째 코드 코멘트의 줄로 간다
///   ("코드에서 보기" 와 같다). `PRAYER_DEBUG_FOLLOW_STEPS=move,next,return` 을 주면 4초 간격으로
///   이어서 한다 — move: 이 줄에 코멘트로 달기, next: 다음 항목, return: 탭 줄의 "AI 리뷰로 돌아가기" 버튼, diff: 다시 변경 파일 탭.
///   **move 는 기록을 고친다.** 실제 초안을 건드리지 않게 `PRAYER_DATA_DIR` 로 다른 데이터 폴더를 줘서 띄운다.
/// - `PRAYER_DEBUG_SCROLL_SWEEP=pt` — 고른 PR 을 띄우고 6초 뒤 변경 파일 탭의 diff 를 그 pt 씩 위아래로 훑는다.
///   메인 스레드가 멈추면 그 스크롤 위치를 로그에 남긴다(`DebugScrollSweep`). `PRAYER_DEBUG_FOLLOW` 와 같이 준다.
///   `PRAYER_DEBUG_SWEEP_TOGGLE_KEY=횟수` 를 더 주면 한 칸마다 그 횟수만큼 키 창을 넘겼다 돌려받는다(다른 앱에 갔다 오는 것).
/// - `PRAYER_DEBUG_DIFF_FILE=경로 끝` — 변경 파일 탭이 처음 열 파일을 그 경로로 끝나는 파일로 고른다
///   (`PRAYER_DEBUG_DETAIL_TAB=diff` 와 같이 준다). 큰 파일을 그리는 시간을 스윕으로 잴 때 쓴다.
///
/// - `PRAYER_DEBUG_EDIT_TEXT=summary|strengths|<항목 키>` — AI 리뷰 탭 본문에서 그 글의 편집기를 열어 둔다
///   ("수정" 을 누른 것과 같다). 항목 키는 `ReviewItemKey`(`concern:…`·`question:…`). 저장은 하지 않는다.
///
/// - `PRAYER_DEBUG_ABOUT=1` — 정보 창(About)을 띄운다.
/// - `PRAYER_DEBUG_ONBOARDING_STEP=engine` — 온보딩을 그 단계(`OnboardingStep` 이름)에서 연다. 새 데이터 폴더로 띄우면 온보딩이 뜬다.
/// - `PRAYER_DEBUG_REVIEW_CHOICES=1` — AI 리뷰 탭 "다시 리뷰" 의 `▾` 목록(전체·diff 설명)을 펼쳐 둔다(켜고 3초 뒤).
/// - `PRAYER_DEBUG_SLACK_REQUEST=개수` — 내가 올린 PR 앞에서 그 개수만큼 골라 "슬랙 리뷰 요청 글 만들기" 창을 띄운다(보내지 않는다).
///   `PRAYER_DEBUG_SLACK_STAGE=connect|destination|compose|edit` — connect 는 저장된 연결이 있어도 다시 확인하는 모양,
///   destination 은 받는 곳 드롭다운을 펼친 모양, edit 은 미리보기를 눌러 고치는 모양. `PRAYER_DEBUG_SLACK_FAIL=missing|expired|login|timeout`
///   — 그 실패 화면으로 연다(설정에 있던 "연동 실패 화면 시험" 메뉴는 2026-10-23 뺐다).
///   `PRAYER_DEBUG_SLACK_MULTI=개수` — 내가 올린 PR 앞에서 그 개수만큼 같이 고른 모양을 만든다(⌘ 클릭한 것과 같다).
///   `PRAYER_DEBUG_SLACK_QUERY=글자` — 받는 곳 목록의 거르기 칸에 그 글자를 넣는다(받아 둔 내 채널을 거르기만 한다).
///   연동 확인과 내 채널 받기(처음 한 번)는 **진짜로 Claude 가 Slack 에 묻는다**(읽기만 한다). 보내기는 늘 사람이 누른다.
/// - `PRAYER_DEBUG_LIST_MULTI=개수` — 리뷰 목록 앞에서 그 개수만큼 같이 고른 모양을 만든다(⌘ 클릭한 것과 같다).
///   `PRAYER_DEBUG_BATCH_REVIEW=diff|deep` 을 더 주면 고른 것으로 묶음 확인 창(BatchReviewSheet)을 띄운다 —
///   우클릭 "리뷰 N개" 를 누른 것과 같은 길이고, **창만 띄운다**(시작을 누르기 전에는 아무것도 돌지 않는다).
///   개수가 1 이면 창을 띄우지 않는다 — 하나는 바로 리뷰가 도는 길(reviewNow)이라서.
/// - `PRAYER_DEBUG_REVIEW_PANEL=comments` — 좁은 창의 AI 리뷰 탭에서 코드 코멘트 탭을 연다(누른 것과 같다).
/// - `PRAYER_DEBUG_WINDOW_SIZE=1720x1050` — 본창 틀(제목 막대 포함, 곧 창째 캡처의 pt 크기)을 맞추고
///   가장 선명한(Retina) 화면 위쪽에 놓는다. README 캡처를 늘 같은 크기·같은 2배 픽셀로 찍으려고.
/// - `PRAYER_DEBUG_APPEARANCE=light|dark` — 시스템 설정과 상관없이 그 모양으로 그린다.
/// - `PRAYER_DEBUG_KEEP_LAYER=1` — 창을 다른 앱 창 뒤에 깔지 않는다(`BackgroundCopy`). 창이 보이는 채로 재는 성능 실측용.
///
/// - `PRAYER_DEBUG_MERGE=ready|confirm|merged|conflict|need1` — 머지 줄을 그 상태로 그린다(내 PR 이 막혀 있어도 모양을 보게).
///   confirm 은 ready 에 확인 대화상자를 띄운 것(켜고 2초 뒤). ready·confirm 은 Approve 기준을 지금 받은 수로 맞춰 "2/2" 처럼 그린다. **이 값이 있으면 "머지하기" 는 GitHub 을 부르지 않고**
///   1초 뒤 머지됨 줄로 바꾸기만 한다 — 확인하다 실제 PR 이 머지되지 않게.
///
/// - `PRAYER_DEBUG_BASE_PICKER=open|confirm:브랜치` — 머리 줄 받는 쪽 칩의 base 고르기 칸을 띄워 둔다(켜고 2초 뒤).
///   confirm 은 1.5초 뒤 그 브랜치 줄을 누른 것처럼 칸을 닫고 확인 시트를 띄운다. **"base 바꾸기" 는 누르지 않는다** —
///   데모 모드가 아니면 누르는 순간 GitHub 에 간다. 뒤에 깐 사본은 타이머가 App Nap 에 멈추니
///   `defaults write <사본 번들ID> NSAppSleepDisabled -bool YES` 를 같이 준다.
/// - `PRAYER_DEBUG_POST=posting|failed` — 고른 PR 의 리뷰 게시와 "리뷰 없이 Approve" 를 올리는 중·실패한 모양으로 그린다.
///   **아무것도 올리지 않는다** — 화면 상태(`AppModel.postingKeys`·`postFailures`)만 바꾼다. 게시한 뒤의 모양은 실제로
///   게시한 기록이 있는 PR 을 고르면 된다(`PRAYER_DATA_DIR` 로 복사한 데이터 폴더에서).
/// - `PRAYER_DEBUG_DIFF_BY_COMMIT=1` — 변경 파일 탭의 "커밋별로 보기" 를 켠 채로 연다(누른 것과 같다).
/// - `PRAYER_DEBUG_COMMITS_REVIEWED=행` — 커밋 표에서 그 행(0 = head)의 커밋을 리뷰한 커밋으로 친다("AI 리뷰한 지점" 줄 모양 보기).
///   리뷰 기록은 건드리지 않는다.
/// - `PRAYER_DEBUG_COMMITS_SELECT=행` 또는 `시작-끝` — 커밋별로 보기를 켤 때 첫 커밋 대신 그 행(범위)을 고른다(⇧클릭과 같다).
/// - `PRAYER_DEBUG_TEAM_STATS=week|month` — 상세 칸에 팀 통계를 그 기간으로 연다(툴바 "통계" 를 누른 것과 같다).
///   `PRAYER_DEBUG_TEAM_STATS_BACK=2` 를 같이 주면 두 기간 앞을 연다.
/// - `PRAYER_DEBUG_EXPAND_ALL=1` — 개요 탭의 본문·대화를 다 펼친 채로 연다("전체 펼치기" 를 누른 것과 같다).
/// - `PRAYER_DEBUG_HOVER_CODE=글자` — 코멘트 속 그 글자의 코드 링크에 마우스를 올린 것처럼 미리보기를 띄워 둔다.
///   스레드 파일 줄은 경로 전체를 준다.
///
/// - `PRAYER_DEBUG_SEARCH=검색어` — 목록 검색칸에 그 말을 넣는다(전체 PR 검색 아래 구역 확인용).
///   `PRAYER_DEBUG_SCOPE=open:0|myApprovals:168|recentAll:720` 를 같이 주면 그 탭에서 친다(`PRListScope.storageValue` 꼴).
///
/// `open --env PRAYER_DEBUG_SELECT_PR=o/r#1 <앱>`. 툴바 팝오버는 `PRAYER_DEBUG_OPEN_POPOVER`(ToolbarPopover).
enum DebugLaunch {
    static var selectPR: String? { value("PRAYER_DEBUG_SELECT_PR") }
    static var search: String? { value("PRAYER_DEBUG_SEARCH") }
    static var scope: PRListScope? { value("PRAYER_DEBUG_SCOPE").flatMap(PRListScope.init(storageValue:)) }
    static var expandAll: Bool { value("PRAYER_DEBUG_EXPAND_ALL") == "1" }
    static var hoverCode: String? { value("PRAYER_DEBUG_HOVER_CODE") }
    static var settingsTab: String? { value("PRAYER_DEBUG_SETTINGS_TAB") }
    static var onboardingStep: OnboardingStep? {
        value("PRAYER_DEBUG_ONBOARDING_STEP").flatMap { name in OnboardingStep.allCases.first { "\($0)" == name } }
    }
    static var teamStats: TeamStatPeriodKind? { value("PRAYER_DEBUG_TEAM_STATS").flatMap(TeamStatPeriodKind.init(rawValue:)) }
    static var teamStatsBack: Int { value("PRAYER_DEBUG_TEAM_STATS_BACK").flatMap(Int.init) ?? 0 }
    static var detailTab: DetailTab? { value("PRAYER_DEBUG_DETAIL_TAB").flatMap(DetailTab.init(rawValue:)) }
    static var diffByCommit: Bool { value("PRAYER_DEBUG_DIFF_BY_COMMIT") == "1" }
    static var commitsReviewedRow: Int? { value("PRAYER_DEBUG_COMMITS_REVIEWED").flatMap(Int.init) }
    static var commitsSelect: ClosedRange<Int>? {
        guard let raw = value("PRAYER_DEBUG_COMMITS_SELECT") else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first else { return nil }
        let last = parts.count > 1 ? parts[1] : first
        return min(first, last)...max(first, last)
    }
    static var addExclusion: String? { value("PRAYER_DEBUG_ADD_EXCLUSION") }
    /// `PRAYER_DEBUG_SKIP_SHEET=줄수` — 고른 PR 에서 그 줄 수 넘게 바뀐 파일로 리뷰 전 확인 창(SkipFilesSheet)을 띄운다.
    /// 묶음 확인 창(`PRAYER_DEBUG_BATCH_REVIEW`)에서는 "큰 파일" 기준을 그 줄 수로 낮춘다.
    static var skipSheetMinLines: Int? { value("PRAYER_DEBUG_SKIP_SHEET").flatMap(Int.init) }
    static var snapshotConfirm: String? { value("PRAYER_DEBUG_SNAPSHOT_CONFIRM") }
    static var exclusionQuery: String? { value("PRAYER_DEBUG_EXCLUSION_QUERY") }
    static var cloneProgress: String? { value("PRAYER_DEBUG_CLONE_PROGRESS") }
    static var showApprovalRules: Bool { value("PRAYER_DEBUG_SHOW_APPROVAL_RULES") != nil }
    static var showAbout: Bool { value("PRAYER_DEBUG_ABOUT") != nil }
    static var showReviewChoices: Bool { value("PRAYER_DEBUG_REVIEW_CHOICES") != nil }
    static var windowSize: CGSize? {
        guard let raw = value("PRAYER_DEBUG_WINDOW_SIZE") else { return nil }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    static var appearance: NSAppearance? {
        switch value("PRAYER_DEBUG_APPEARANCE") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
    static var slackRequestCount: Int? { value("PRAYER_DEBUG_SLACK_REQUEST").flatMap(Int.init) }
    static var slackStage: String? { value("PRAYER_DEBUG_SLACK_STAGE") }
    static var slackMultiCount: Int? { value("PRAYER_DEBUG_SLACK_MULTI").flatMap(Int.init) }
    /// 연동 실패 화면 시험(`SlackRequestDraft.simulatedFailure`).
    static var slackFailure: SlackConnectorError? {
        switch value("PRAYER_DEBUG_SLACK_FAIL") {
        case "missing": return .connectorMissing
        case "expired": return .needsAuth
        case "login": return .loginRequired
        case "timeout": return .timedOut
        default: return nil
        }
    }
    static var slackQuery: String? { value("PRAYER_DEBUG_SLACK_QUERY") }
    static var listMultiCount: Int? { value("PRAYER_DEBUG_LIST_MULTI").flatMap(Int.init) }
    static var batchReview: String? { value("PRAYER_DEBUG_BATCH_REVIEW") }
    static var followIndex: Int? { value("PRAYER_DEBUG_FOLLOW").flatMap(Int.init) }
    static var scrollSweep: CGFloat? { value("PRAYER_DEBUG_SCROLL_SWEEP").flatMap(Double.init).map { CGFloat($0) } }
    static var sweepKeyToggles: Int { value("PRAYER_DEBUG_SWEEP_TOGGLE_KEY").flatMap(Int.init) ?? 0 }
    static var diffFile: String? { value("PRAYER_DEBUG_DIFF_FILE") }
    static var editText: String? { value("PRAYER_DEBUG_EDIT_TEXT") }
    static var opensCommentPanel: Bool { value("PRAYER_DEBUG_REVIEW_PANEL") == "comments" }

    static var mergePreview: String? { value("PRAYER_DEBUG_MERGE") }
    static var basePicker: String? { value("PRAYER_DEBUG_BASE_PICKER") }
    static var postPreview: String? { value("PRAYER_DEBUG_POST") }
    /// `PRAYER_DEBUG_KEYS=click@224x559,down,shift+down,cmd+f` — 자리를 연 3초 뒤부터 1초 간격으로 본창에 키·클릭을
    /// 보낸다(`DebugKeyPress`). click@x×y 는 창 왼쪽 위(제목 막대 포함)에서 잰 pt 자리를 누른다.
    static var keyPresses: [String]? { value("PRAYER_DEBUG_KEYS")?.split(separator: ",").map(String.init) }
    /// `PRAYER_DEBUG_REVIEW_SCROLL=4` — AI 리뷰 탭을 그 번째(0부터) 코드 코멘트까지 내려 둔다(왼쪽 칸이 따라오는지 보기).
    static var reviewScrollIndex: Int? { value("PRAYER_DEBUG_REVIEW_SCROLL").flatMap(Int.init) }
    /// `PRAYER_DEBUG_FLIGHT_SECONDS=3` — "리뷰에 담기" 고스트가 날아가는 시간(기본 0.5초). 창 캡처로 날아가는 도중을 찍으려고.
    static var flightSeconds: Double? { value("PRAYER_DEBUG_FLIGHT_SECONDS").flatMap(Double.init) }
    /// `PRAYER_DEBUG_APPROVE_MORPH=배율` — 고른 PR 의 AI 리뷰 탭에서 3초 뒤 "리뷰 없이 Approve" 연출(`ApproveCheckMorph`)만
    /// 그 시간 배율로 돌린다(1 = 실제 속도, 5 = 다섯 배 느리게). **아무것도 올리지 않는다** — 끝나면 버튼이 그대로 돌아온다.
    static var approveMorphPace: Double? { value("PRAYER_DEBUG_APPROVE_MORPH").flatMap(Double.init) }
    /// `PRAYER_DEBUG_APPROVE_FLIGHT=배율` — 고른 PR 을 3초 뒤 Approve 한 것처럼 리뷰 대기 목록에서 Approved 탭으로 날린다
    /// (`ApprovalFlight`, 1 = 실제 속도). **아무것도 올리지 않는다** — 화면에서만 빠지고 앱을 다시 켜면 돌아온다.
    static var approveFlightPace: Double? { value("PRAYER_DEBUG_APPROVE_FLIGHT").flatMap(Double.init) }
    /// `PRAYER_DEBUG_REFRESH_FLIGHT=배율` — `PRAYER_DEMO=1` 과 함께. 3초 뒤 리뷰 대기 목록을 새로 받은 것처럼 갱신 연출을
    /// 그 시간 배율로 돌린다: 하나는 머지돼 All PRs 로, 하나는 웹에서 Approve 해 Approved 로 날아가고, 둘이 새로 들어온다
    /// (`AppModel.debugSimulateRefresh`). 아무것도 받지 않는다.
    static var refreshFlightPace: Double? { value("PRAYER_DEBUG_REFRESH_FLIGHT").flatMap(Double.init) }
    /// `PRAYER_DEBUG_REFRESH_LARGE=1` — 위 연출을 한꺼번에 많이 바뀌는 모양(빠짐 4·새로 5)으로.
    static var refreshLarge: Bool { value("PRAYER_DEBUG_REFRESH_LARGE") == "1" }
    /// `PRAYER_DEBUG_REFRESH_EMPTY=1` — 위 연출을 빈 목록을 처음 채우는 모양으로: 빈 행 자리를 보이다가 데모 목록이
    /// 위에서부터 차례로 펼쳐진다.
    static var refreshFromEmpty: Bool { value("PRAYER_DEBUG_REFRESH_EMPTY") == "1" }
    /// `PRAYER_DEBUG_REFRESH_SAME=1` — 위 연출에서 받은 목록이 지난 목록과 같다(행은 그대로, 머리 줄이 "최신 · 오후 2:40" 이 된다).
    static var refreshUnchanged: Bool { value("PRAYER_DEBUG_REFRESH_SAME") == "1" }
    /// `PRAYER_DEBUG_REFRESH_THEN=myApprovals:24` — 위 연출이 끝나고 4초(배율만큼) 뒤 그 탭으로 옮긴다. 데모는 받지 않으므로
    /// 다른 탭에 미리 채운 지난 목록(`ListCacheSeeding`)이 그대로 보인다.
    static var refreshThenScope: PRListScope? { value("PRAYER_DEBUG_REFRESH_THEN").flatMap(PRListScope.init(storageValue:)) }

    /// `PRAYER_DEBUG_MERGE` 가 고른 머지 줄 상태.
    static var mergeReadiness: MergeReadiness? {
        switch mergePreview {
        case "ready", "confirm": return .ready
        case "merged": return .merged
        case "conflict": return .blocked(.conflict)
        case "need1": return .blocked(.needsApprovals(1))
        default: return nil
        }
    }

    static var followSteps: [String] {
        value("PRAYER_DEBUG_FOLLOW_STEPS")?.split(separator: ",").map(String.init) ?? []
    }

    /// 클론 진행 화면을 찍으려고 거는 가짜 잡. 상태는 실측 숫자를 흉내 낸다(큰 레포).
    @MainActor
    static func fakeCloneJob(for pr: PullRequestInfo, stage: String) -> ReviewJob? {
        var job = ReviewJob(id: pr.id, repo: pr.repo, number: pr.number, title: pr.title, pr: pr,
                            trigger: .manual, deep: true)
        job.state = .running
        job.startedAt = Date().addingTimeInterval(-14)
        job.clonedSnapshot = true
        switch stage {
        case "clone":
            job.phase = .cloningSnapshot
            job.progress = GitProgress(stage: .receiving, percent: 45, done: 218_133, total: 484_739,
                                       transferred: "29.00 MiB", speed: "8.10 MiB/s")
        case "files":
            job.phase = .fetchingFiles
            job.progress = GitProgress(stage: .receiving, percent: 60, done: 7_558, total: 12_597,
                                       transferred: "38.00 MiB", speed: "7.40 MiB/s")
        case "unpack":
            job.phase = .preparingWorktree
            job.progress = GitProgress(stage: .updating, percent: 60, done: 8_284, total: 13_807)
        case "again":
            job.clonedSnapshot = false
            job.phase = .fetchingFiles
            job.progress = GitProgress(stage: .receiving, percent: 60, done: 46, total: 77,
                                       transferred: "190.00 KiB", speed: "500.00 KiB/s")
        case "running":
            // 진행 카드의 단계 목록 — 준비 단계는 끝났고 Claude 가 1분 넘게 읽는 중, 예상 범위가 붙은 모양.
            job.clonedSnapshot = false
            job.phase = .running
            job.claudeRange = 47...325
        default:
            return nil
        }
        fakePhaseLog(&job, currentFor: job.phase == .running ? 68 : 5)
        return job
    }

    /// 지금 단계 앞의 단계들을 실측 비슷한 시간으로 지나온 것처럼 찍는다 — 단계 목록에 걸린 시간이 보이게.
    @MainActor
    private static func fakePhaseLog(_ job: inout ReviewJob, currentFor seconds: TimeInterval) {
        let typical: [ReviewPhase: TimeInterval] = [.checkingPR: 1, .loadingDiff: 2, .cloningSnapshot: 12,
                                                     .fetchingCommit: 3, .fetchingFiles: 6, .preparingWorktree: 4]
        let steps = PhaseTrack.steps(deep: job.deep, clonedSnapshot: job.clonedSnapshot)
        let passed = steps.prefix { $0 != job.phase }
        var at = Date().addingTimeInterval(-seconds - passed.reduce(0) { $0 + (typical[$1] ?? 1) })
        job.startedAt = at
        job.phaseLog = []
        for step in passed {
            job.phaseLog.append((step, at))
            at = at.addingTimeInterval(typical[step] ?? 1)
        }
        job.phaseLog.append((job.phase, at))
        job.phaseAt = at
    }

    private static func value(_ key: String) -> String? {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }
}

/// 메인 창에 붙여 `DebugLaunch` 가 고른 자리를 연다. 창·목록이 자리를 잡은 뒤에 연다.
struct DebugLaunchModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            guard DebugLaunch.selectPR != nil || DebugLaunch.settingsTab != nil || DebugLaunch.showAbout
                || DebugLaunch.windowSize != nil || DebugLaunch.appearance != nil
                || DebugLaunch.slackRequestCount != nil || DebugLaunch.slackMultiCount != nil
                || DebugLaunch.listMultiCount != nil || DebugLaunch.teamStats != nil
                || DebugLaunch.refreshFlightPace != nil || DebugLaunch.search != nil else { return }
            if let appearance = DebugLaunch.appearance {
                NSApp.appearance = appearance
            }
            if let size = DebugLaunch.windowSize {
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }),
                   let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                    // 크기를 바꿀 수 있는 창은 macOS 가 높이를 화면(메뉴 막대 아래·Dock 위)에 맞춰 줄여서, Dock 크기에 따라
                    // 캡처 높이가 달라졌다(1720x1060 을 줬는데 1011·1050). 놓는 동안만 크기 조절을 꺼 그대로 놓게 한다.
                    // 외장 1배 화면에 뜨면 그림이 절반 픽셀이라 가장 선명한 화면 위쪽으로 옮긴다.
                    let visible = screen.visibleFrame
                    let origin = NSPoint(x: visible.minX + max(0, (visible.width - size.width) / 2),
                                         y: visible.maxY - size.height)
                    let resizable = window.styleMask.contains(.resizable)
                    window.styleMask.remove(.resizable)
                    window.setFrame(NSRect(origin: origin, size: size), display: true)
                    if resizable { window.styleMask.insert(.resizable) }
                }
            }
            try? await Task.sleep(for: .seconds(4))
            if let search = DebugLaunch.search {
                if let scope = DebugLaunch.scope { model.listScope = scope }
                model.filter.search = search
            }
            if DebugLaunch.showAbout {
                AboutPanel.show()
            }
            if let kind = DebugLaunch.teamStats {
                model.teamStats.kind = kind
                model.teamStats.offset = -DebugLaunch.teamStatsBack
                model.openTeamStats()
            }
            if let key = DebugLaunch.selectPR {
                model.select(prKey: key)
                model.detailTab = DebugLaunch.detailTab ?? .review
                // 확인 창만 띄운다. reviewNow 를 부르면 클론이 있는 레포는 진짜 리뷰가 돈다(토큰을 쓴다).
                if let confirm = DebugLaunch.snapshotConfirm, let pr = model.selectedPR {
                    model.pendingSnapshotClone = PendingSnapshotClone(pr: pr, missingLinkedPath: confirm == "1" ? nil : confirm)
                }
                // 리뷰 전 확인 창만 띄운다(위와 같은 이유로 reviewNow 는 부르지 않는다). 값은 물을 줄 수 기준 —
                // 지금 PR 에 해당 파일이 없어도 창 모양을 볼 수 있게 낮춰서 고른다.
                // 목록에 없는 PR 이면 받아 오는 동안 selectedPR 이 비어 있다. 잠깐 기다린다.
                for _ in 0..<100 where DebugLaunch.skipSheetMinLines != nil && model.selectedPR == nil {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let minLines = DebugLaunch.skipSheetMinLines, let pr = model.selectedPR {
                    if let diff = await model.waitForDiff(for: pr) {
                        let files = diff.files.filter { !$0.isBinary && !$0.isDeleted && $0.changedLines >= minLines }
                        if !files.isEmpty {
                            model.pendingSkipFiles = PendingSkipFiles(pr: pr, deep: false, files: files,
                                                                      totalLines: diff.changedLines)
                        }
                    }
                }
                if let stage = DebugLaunch.cloneProgress, let pr = model.selectedPR,
                   let job = DebugLaunch.fakeCloneJob(for: pr, stage: stage) {
                    model.jobs.append(job)
                }
                if let pace = DebugLaunch.approveFlightPace, let pr = model.selectedPR {
                    try? await Task.sleep(for: .seconds(3))
                    model.flyToApprovedTab(pr.id, reviewedAt: Date(), pace: pace)
                }
                if let post = DebugLaunch.postPreview, let pr = model.selectedPR {
                    let keys = [PostingKey.review(pr), PostingKey.approve(pr)]
                    switch post {
                    case "posting":
                        model.postingKeys.formUnion(keys)
                    case "failed":
                        for key in keys {
                            model.postFailures[key] = "GitHub 에 연결하지 못했습니다(디버그 미리보기). 초안은 그대로 있어요."
                        }
                    default:
                        break
                    }
                }
            }
            if DebugLaunch.settingsTab != nil {
                openSettings()
            }
            #if DEBUG
            if let pace = DebugLaunch.refreshFlightPace, DemoMode.isOn {
                try? await Task.sleep(for: .seconds(3))
                await model.debugSimulateRefresh(large: DebugLaunch.refreshLarge, fromEmpty: DebugLaunch.refreshFromEmpty,
                                                 unchanged: DebugLaunch.refreshUnchanged, pace: pace)
                if let next = DebugLaunch.refreshThenScope {
                    try? await Task.sleep(for: .seconds(4 * pace))
                    model.listScope = next
                }
            }
            #endif
            // 내 PR 은 목록을 받은 뒤에 생긴다 — 지난 목록(캐시)에는 일부만 있을 수 있어 고를 개수만큼 찰 때까지 기다린다.
            let wanted = max(DebugLaunch.slackRequestCount ?? 0, DebugLaunch.slackMultiCount ?? 0)
            for _ in 0..<150 where wanted > 0 && model.myOpenPRs.count < wanted {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let count = DebugLaunch.slackMultiCount {
                let chosen = Array(model.myOpenPRs.prefix(count))
                model.myPRSelection = RowSelection(ids: Set(chosen.map(\.id)), anchor: chosen.first?.id)
                model.selectedPRID = chosen.first?.id
            }
            if let count = DebugLaunch.listMultiCount {
                for _ in 0..<150 where model.visiblePRs.count < count {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let chosen = Array(model.visiblePRs.prefix(count))
                model.listSelection = RowSelection(ids: Set(chosen.map(\.id)), anchor: chosen.first?.id)
                model.selectedPRID = chosen.first?.id
                if let kind = DebugLaunch.batchReview, chosen.count > 1, let first = chosen.first {
                    // 메뉴를 누른 것과 같은 길 — 여럿이면 reviewNow 를 거치지 않아 창만 뜬다.
                    model.reviewFromList(first, deep: kind == "deep")
                }
            }
            if let count = DebugLaunch.slackRequestCount, !model.myOpenPRs.isEmpty {
                model.slackRequest = SlackRequestDraft(prs: Array(model.myOpenPRs.prefix(max(count, 1))),
                                                       simulatedFailure: DebugLaunch.slackFailure)
            }
            if let rule = DebugLaunch.addExclusion {
                // 바뀌기 전 화면을 먼저 찍을 수 있게 조금 뒤에 더한다.
                try? await Task.sleep(for: .seconds(6))
                model.addExclusion(rule, announce: true)
            }
            if let keys = DebugLaunch.keyPresses {
                try? await Task.sleep(for: .seconds(3))
                for key in keys {
                    DebugKeyPress.send(key)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}

/// 뒤에 띄운(`open -g`) 확인용 사본에 키·클릭을 보낸다 — 방향키·단축키 길을 접근성 권한 없이 보려고.
/// 앱을 앞으로 가져오지 않는다(치던 글자를 가로채지 않게). 앱이 뒤에 있으면 창이 key 가 못 돼 첫 클릭이 삼켜지므로
/// 맞은 뷰 클래스의 `acceptsFirstMouse` 를 true 로 바꾼다 — 뷰의 mouseDown 을 직접 부르면 SwiftUI 제스처가 안 받는다.
@MainActor
enum DebugKeyPress {
    static func send(_ step: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) })
        else { return }
        window.makeKey()
        if step.hasPrefix("click@") {
            click(step.dropFirst("click@".count), in: window)
            return
        }
        var parts = step.split(separator: "+").map(String.init)
        let name = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("cmd") { flags.insert(.command) }
        if parts.contains("shift") { flags.insert(.shift) }
        let code: UInt16
        let characters: String
        switch name {
        case "up": (code, characters) = (126, String(Character(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)))
        case "down": (code, characters) = (125, String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)))
        case "esc": (code, characters) = (53, "\u{1b}")
        case "f": (code, characters) = (3, "f")
        default: (code, characters) = (0, name)
        }
        if name == "up" || name == "down" { flags.formUnion([.function, .numericPad]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func click(_ spec: Substring, in window: NSWindow) {
        let numbers = spec.split(separator: "x").compactMap { Double($0) }
        guard numbers.count == 2 else { return }
        let point = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
        if let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point) {
            let yes: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
            class_replaceMethod(type(of: hit), #selector(NSView.acceptsFirstMouse(for:)),
                                imp_implementationWithBlock(yes), "c@:@")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
    }
}
