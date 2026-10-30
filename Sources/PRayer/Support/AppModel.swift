import Foundation
import Observation
import AppKit
// SwiftUI 를 통째로 들이면 앱의 `Settings` 가 SwiftUI.Settings 와 겹친다 — 목록에서 뺄 때 쓰는 둘만 들인다.
import func SwiftUI.withAnimation
import struct SwiftUI.Animation
import UserNotifications
import PRayerCore

enum JobState: String, Sendable {
    case queued, running, done, failed, cancelled

    var label: String {
        switch self {
        case .queued: return "대기"
        case .running: return "리뷰중"
        case .done: return "완료"
        case .failed: return "실패"
        case .cancelled: return "취소됨"
        }
    }
}

struct ReviewJob: Identifiable, Sendable {
    var id: String
    var repo: RepoID
    var number: Int
    var title: String
    /// enqueue 시점의 PR 스냅샷. 폴링으로 목록이 교체돼도 잡을 실행할 수 있어야 한다.
    var pr: PullRequestInfo
    var trigger: ReviewRecord.Trigger
    /// 이 잡에 쓸 모델·effort(이 PR 에 고른 것 또는 기본값). nil 이면 설정의 기본값.
    var modelOverride: String?
    var effortOverride: String?
    /// 이 잡을 돌릴 엔진 — 넣을 때의 모델 값으로 정한다(`ReviewEngineKind(model:)`). 진행 카드가 "Codex 가 읽고 판단" 처럼 쓴다.
    var engine: ReviewEngineKind = .claude
    /// 워크트리를 붙여 diff 밖까지 보게 할 것인가.
    var deep = false
    /// 이번 리뷰에서만 뺄 파일(리뷰 전 확인 창에서 "빼고 리뷰"). 제외 경로 규칙 꼴(`ExclusionPattern.file`)이다.
    var skipPaths: [String] = []
    var state: JobState = .queued
    /// 지금 어느 단계인가. 화면에 그대로 보여 준다.
    var phase: ReviewPhase = .queued
    var phaseAt: Date = Date()
    /// 지나온 단계와 들어간 시각, 들어간 순서대로. 진행 카드가 단계마다 걸린 시간을 여기서 센다.
    var phaseLog: [(phase: ReviewPhase, at: Date)] = []
    /// 이번 "Claude 가 읽고 판단" 이 걸릴 90% 범위(초). 잡을 시작할 때 지난 리뷰로 한 번 잡는다(`ClaudeStepEstimate`).
    var claudeRange: ClosedRange<Double>?
    /// 받기·풀기 단계의 진행(git 이 찍는 퍼센트). 단계가 바뀌면 비운다.
    var progress: GitProgress?
    /// 이 잡이 PR 스냅샷을 처음 받았는가 — 그러면 진행 문구가 "클론 중 1/2·2/2" 로 이어진다.
    var clonedSnapshot = false
    var queuedAt: Date = Date()
    var startedAt: Date?
    var message: String?

    var isActive: Bool { state == .queued || state == .running }

    /// 다음 단계로 넘어간다. 같은 단계를 다시 알리면 시각을 새로 찍지 않는다.
    mutating func enter(_ next: ReviewPhase, at date: Date = Date()) {
        guard phase != next || phaseLog.isEmpty else { return }
        phase = next
        phaseAt = date
        phaseLog.append((next, date))
    }

    /// 끝난 단계에 걸린 시간 — 그 단계에 들어간 때부터 다음 단계에 들어간 때까지. 거치지 않았으면 nil.
    func duration(of step: ReviewPhase) -> TimeInterval? {
        guard let index = phaseLog.lastIndex(where: { $0.phase == step }), index + 1 < phaseLog.count else { return nil }
        return phaseLog[index + 1].at.timeIntervalSince(phaseLog[index].at)
    }
}

/// `AppModel.postingKeys`·`postFailures` 의 키. 리뷰 게시와 "리뷰 없이 Approve" 는 따로 돈다.
enum PostingKey {
    static func review(_ pr: PullRequestInfo) -> String { "review|\(pr.id)" }
    static func approve(_ pr: PullRequestInfo) -> String { "approve|\(pr.id)" }
}

struct Banner: Identifiable {
    /// `success` 는 게시처럼 되돌릴 수 없는 일이 끝났다는 알림이다. 파란 정보 표시로는 "끝났다" 가 덜 읽혔다.
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var message: String
    var actionTitle: String?
    /// 버튼이 GitHub 으로 가는가. 그러면 버튼 앞에 GitHub 로고를 단다(GitHubLink 참고).
    var opensGitHub = false
    /// 로그인이 끊겨 띄운 안내인가. 다시 로그인한 것이 확인되면 앱이 스스로 거둔다 —
    /// 로그인하고 돌아왔는데 빨간 안내가 그대로면, 된 건지 안 된 건지 또 헤맨다.
    var clearsOnEngineLogin = false
    /// 무언가 끝나기를 기다리는 안내. 아이콘 대신 빙글이를 돌리고, 저절로 닫지 않는다.
    var inProgress = false
    var action: (@MainActor () -> Void)?
}

/// 목록 헤더의 필터. 기본값은 **처음 켠 사람이 바로 쓸 수 있는 상태**다 —
/// 열린 PR 중 내가 처리할 몫만 남기고, 남이 보지 말라고 표시한 것은 빼 둔다.
/// 한 번 바꾸면 그 선택이 저장돼 다음 실행에도 유지된다(검색어만 매번 비운다).
struct PRFilter: Codable, Equatable {
    /// 골라 둔 사람(설정의 ignoredAuthors)이 올린 PR 숨기기. 목록이 비면 아무 일도 안 한다.
    var hideIgnoredAuthors = true
    /// 골라 둔 라벨(설정의 hiddenLabels, 기본 `DO NOT REVIEW`)이 붙은 PR 숨기기. 목록이 비면 아무 일도 안 한다.
    var hideLabels = true
    /// 목록에서 뺀 레포(`RepoID.full`). 보일 레포가 아니라 **뺄 레포**를 적는다 — 보일 레포를 적으면
    /// 나중에 설정에서 새로 넣은 레포가 처음부터 숨어서 "넣었는데 안 나온다" 가 된다.
    var hiddenRepos: [String] = []
    /// 검색어는 저장하지 않는다. 다시 켰을 때 목록이 비어 있으면 원인을 찾기 어렵다.
    var search = ""

    private static let storageKey = "prFilter"

    enum CodingKeys: String, CodingKey {
        case hideLabels, hideIgnoredAuthors, hiddenRepos
    }

    /// 읽기만 하는 옛 키. `hideLabels` 의 0.3.0 까지 이름이다 — 지우면 그때 꺼 둔 필터가 다시 켜진다.
    private enum LegacyKeys: String, CodingKey {
        case hideDoNotReview
    }

    init() {}

    /// 저장된 값에 **없는 항목은 기본값으로** 둔다.
    ///
    /// 기본 합성 디코더는 키가 하나라도 없으면 통째로 실패한다. 그러면 `load()` 의
    /// `try?` 가 nil 을 받아 **사용자가 맞춰 둔 필터가 전부 초기화된다.**
    /// 필터를 하나 더할 때마다 그 일이 벌어지므로 직접 푼다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PRFilter()
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        hideLabels = try c.decodeIfPresent(Bool.self, forKey: .hideLabels)
            ?? (try? legacy?.decodeIfPresent(Bool.self, forKey: .hideDoNotReview)) ?? fallback.hideLabels
        hideIgnoredAuthors = try c.decodeIfPresent(Bool.self, forKey: .hideIgnoredAuthors) ?? fallback.hideIgnoredAuthors
        hiddenRepos = (try? c.decodeIfPresent([String].self, forKey: .hiddenRepos)) ?? fallback.hiddenRepos
    }

    static func save(_ filter: PRFilter) {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func load() -> PRFilter {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let restored = try? JSONDecoder().decode(PRFilter.self, from: data) else { return PRFilter() }
        return restored
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: 상태
    var settings: Settings = .default {
        // 레포 목록이 바뀌면 색을 다시 나눠 준다(syncRepoColors). 레포를 넣고 빼는 길이 여럿이라
        // (설정 화면·레포 관리 팝오버·가져오기·온보딩) 길마다 부르지 않고 여기서 한 번에 지킨다.
        didSet { syncRepoColors() }
    }
    var claudeStatus: EngineStatus?
    /// 로그아웃으로 확인됐던 엔진이 마지막으로 다시 로그인된 시각(`AuthFailure.loginRecovered`).
    /// 그 전에 로그인이 끊겨 실패한 잡은 이제 다시 리뷰하면 된다.
    var engineLoginRecoveredAt: Date?
    /// `auth status` 가 마지막으로 **실제로 답한** 로그인 여부. 명령이 돌지 못한 확인은 반영하지 않는다 —
    /// 그걸 로그아웃으로 치면 로그인하지 않았는데도 다음 확인에서 "다시 로그인했다" 고 판정한다.
    @ObservationIgnored private var lastKnownLogin: Bool?
    /// 터미널 로그인 창이 끝나기를 기다리는 중인가(`LoginScript`). 그동안 로그인 안내는 "로그인하는 중" 이다.
    var engineLoginInProgress = false
    @ObservationIgnored var engineLoginWatch: Task<Void, Never>?
    @ObservationIgnored var codexLoginWatch: Task<Void, Never>?
    /// 별칭 → 지금 CLI 가 부르는 모델. 없으면 기본 목록(`ClaudeModels.all`)을 보여 준다.
    var modelCatalog: ModelCatalog?
    /// '과거 버전 고르기' 에 쌓은 이름 — 계열이 새 버전으로 넘어간 앞 모델과 직접 입력한 이름.
    var rememberedModels: [String] = []
    /// 이번 실행에서 이미 물어본 CLI(경로|버전). 실패해도 앱 전환마다 다시 띄우지 않게 한다.
    @ObservationIgnored private var modelProbeAttempt: String?
    /// Codex CLI 상태. 깔지 않은 사람도 많다 — nil 이면 아직 안 봤다(`checkCodex`).
    var codexStatus: EngineStatus?
    /// Codex 가 알려 준 모델 목록(`CodexCatalog`). 계열 → 실제 모델, 모델마다 effort 단계.
    var codexCatalog: CodexCatalog?
    /// 이번 실행에서 이미 물어본 목록(경로|버전|시간 칸). 실패해도 앱 전환마다 다시 묻지 않게.
    @ObservationIgnored var codexProbeAttempt: String?
    /// 이번 실행에서 Codex 를 셸에 찾아봤는가. 안 깐 사람의 맥에서 앱으로 돌아올 때마다 셸을 띄우지 않게 한 번만 본다
    /// (설정·온보딩의 "다시 확인" 은 다시 찾는다).
    @ObservationIgnored var codexDiscoveryTried = false
    var githubAccount: GitHubAccount?
    var githubError: String?
    /// 연속 갱신 실패 횟수. 한 번 흔들린 것으로 빨간 토스트를 띄우지 않는다.
    var consecutiveRefreshFailures = 0
    var prs: [PullRequestInfo] = []
    /// 목록을 아직 이어 받는 중인가. 첫 페이지를 그린 뒤에도 뒤가 더 남아 있을 수 있다.
    /// 이때의 "필터로 N건 숨김" 은 최종 숫자가 아니므로 화면이 단정하지 않게 한다.
    var isLoadingMore = false
    /// PR 키 → **지금 보고 있는** 리뷰 기록. 기본은 가장 최근 것이고, 히스토리에서 고르면 바뀐다.
    var records: [String: ReviewRecord] = [:]
    /// PR 키 → 남겨 둔 리뷰 기록 전부, 최신순. 같은 PR 을 여러 번 리뷰한 내역을 여기서 고른다.
    var recordHistory: [String: [ReviewRecord]] = [:]
    var jobs: [ReviewJob] = []
    var ledger = TokenLedger()
    /// 남의 코멘트를 쉬운 말로 푼 것. key → 설명.
    var explanations: [String: CommentExplanation] = [:]
    /// "이미 언급됨" 대조 결과. 키 → 결과.
    var relevances: [String: DiscussionRelevance] = [:]
    /// 지금 대조 중인 키(중복 실행 방지 + 진행 표시).
    var relevanceKeys: Set<String> = []
    /// 항목별 "다시 확인" 결과와 지금 돌고 있는 것들.
    var rechecks: [String: ItemRecheck] = [:]
    var recheckKeys: Set<String> = []
    var explainingKeys: Set<String> = []
    /// 최근 3건이 아니라 전체 내역을 펼쳐 둔 PR. 목록이 갱신돼도 유지되도록 모델이 들고 있는다.
    var fullActivityPRs: Set<String> = []
    var repoOptions: [RepoOption] = []
    var organizations: [String] = []
    /// `gh` 에 로그인돼 있는 호스트들. 설정에서 고르게 한다.
    var githubHosts: [GitHubHost] = []
    /// 나와 있는 새 버전. 없으면 nil.
    var availableUpdate: UpdateCheck.Release?
    var isUpdating = false
    /// 마지막 업데이트 실패 이유. 누른 자리(위 안내 줄·상태 팝오버)에 적는다 — 창 아래 토스트로만
    /// 띄웠더니 팀원에게는 "눌러도 아무 반응이 없다" 로 보였다.
    var updateFailure: String?
    /// 창 위 안내 줄에서 X 로 닫은 버전. **이번 실행 동안만** 기억한다 — 다음에 켜면 다시 알린다.
    /// 그보다 새 버전이 나오면 버전이 달라져 다시 뜬다.
    var dismissedUpdateVersion: String?
    /// 지금 버전이 공개 저장소에 올라가 있는가(베타 판정). 새 버전을 물을 때 같이 묻는다.
    var publishState: UpdateCheck.PublishState = .unknown {
        didSet { applyChannelIcon() }
    }
    /// 마지막으로 새 버전을 물어본 때. 앱으로 돌아올 때마다 gh 를 띄우지 않게 간격을 둔다.
    @ObservationIgnored private var lastUpdateCheck: Date?
    @ObservationIgnored private var isCheckingUpdate = false
    /// 설정 창을 열면서 곧장 보여 줄 자리. 보여 주고 나면 설정 쪽이 nil 로 되돌린다.
    var settingsFocus: SettingsFocus?
    /// 서버에 마지막으로 보낸 검색어. 같은 말을 다시 보내지 않으려고 들고 있다.
    var lastRepoSearch: String?
    /// 필터는 앱을 다시 켜도 유지한다(검색어만 매번 비운다).
    /// 목록 탭. 닫힘·머지를 보려면 기간이 걸린 탭을 쓴다(무제한으로 긁으면 GitHub 이 502 를 낸다).
    var listScope: PRListScope = .open {
        didSet {
            guard listScope != oldValue, !isRestoringScope else { return }
            // 탭마다 마지막에 고른 기간을 기억한다. 탭을 옮겨 다녀도 각 탭이 자기 기간으로 돌아온다.
            if let window = listScope.window {
                rememberedWindows[listScope.kind] = window
                saveRememberedWindows()
            }
            UserDefaults.standard.set(listScope.storageValue, forKey: "prListScope")
            // 앞 탭에서 돌던 갱신 연출은 끝 상태로 넘긴다 — 붙잡아 둔 행·숨겨 둔 새 행이 이 탭으로 따라오지 않게.
            settleRefreshChoreography()
            // 그 탭의 지난 결과를 먼저 보여 주고, 새로 받는 동안 목록 위에 "가져오는 중" 을 띄운다.
            // 앞 탭 목록을 그대로 두면 이 탭의 조건으로 걸러진 엉뚱한 일부가 보인다(사용자 피드백).
            listCache[oldValue.storageValue] = prs
            var next = listCache[listScope.storageValue] ?? []
            // 보고 있던 PR 은 남겨 둔다 — 빠지면 받는 동안 오른쪽이 비어 버린다.
            if let selected = prs.first(where: { $0.id == selectedPRID }), !next.contains(where: { $0.id == selected.id }) {
                next.append(selected)
            }
            prs = next
            // 받은 지 얼마 안 된 탭이면(방금 보다가 다른 탭에 갔다 온 것) 그 결과를 그대로 믿고 조용히 다시 받는다 —
            // 비어 있어도 빈 행 자리 대신 "없습니다" 를 보이고, 바뀐 행만 날아가거나 들어온다
            // (ListRefreshChange.quietRefetchWindow).
            isShowingCachedList = !isListFresh(listScope)
            Task { await refresh() }
            // 아래 구역(전체 PR 검색)은 탭마다 범위가 다르다 — All PRs 는 그 기간보다 오래된 것만 찾는다.
            scheduleExtraSearch()
        }
    }

    /// 그 탭의 목록을 받은 지 얼마 안 됐나 — 탭을 옮겨 오거나 앱을 켤 때 "가져오는 중" 을 띄울지 가른다.
    private func isListFresh(_ scope: PRListScope) -> Bool {
        ListRefreshChange.isFresh(fetchedAt: lastFetched(scope), now: Date(), pollSeconds: settings.pollSeconds)
    }

    /// 그 탭을 마지막으로 다 받은 때. 목록 맨 아래가 "14:32 갱신" 으로 보인다.
    func lastFetched(_ scope: PRListScope) -> Date? {
        listFetchedAt[scope.storageValue]
    }

    /// 탭 종류별로 마지막에 고른 기간.
    private var rememberedWindows: [PRListScopeKind: PRListWindow] = [:]

    /// 기동 중 저장된 탭을 되돌리는 동안에는 didSet 의 자동 갱신을 막는다.
    /// 이 시점엔 아직 GitHub 로그인 정보가 없어서, 승인 탭이면 `reviewed-by:` 가 빠진
    /// 엉뚱한(그리고 비싼) 검색이 한 번 나간다. 기동 끝의 refresh() 한 번이면 된다.
    private var isRestoringScope = false

    /// 그 탭을 지금 누르면 어떤 범위가 되는가 — 기억해 둔 기간으로 돌아간다.
    func scope(for kind: PRListScopeKind) -> PRListScope {
        PRListScope(kind: kind, window: kind.usesWindow ? window(for: kind) : nil)
    }

    func window(for kind: PRListScopeKind) -> PRListWindow {
        rememberedWindows[kind] ?? PRListScope.defaultWindow
    }

    private func saveRememberedWindows() {
        let raw = rememberedWindows.reduce(into: [String: Int]()) { $0[$1.key.rawValue] = $1.value.hours }
        UserDefaults.standard.set(raw, forKey: "prListScopeWindows")
    }

    private func loadRememberedWindows() {
        guard let raw = UserDefaults.standard.dictionary(forKey: "prListScopeWindows") as? [String: Int] else { return }
        for (key, hours) in raw {
            guard let kind = PRListScopeKind(rawValue: key), let window = PRListWindow(rawValue: hours) else { continue }
            rememberedWindows[kind] = window
        }
    }

    var filter = PRFilter() {
        didSet {
            guard filter != oldValue else { return }
            PRFilter.save(filter)
            // 검색어·레포 고르기가 바뀌면 아래 구역을 다시 찾는다. 같은 열쇠면 안에서 그냥 돌아간다.
            scheduleExtraSearch()
        }
    }
    var selectedPRID: String? {
        // 같이 고른 것 밖으로 옮겨 가면(다른 목록의 행 클릭·알림으로 열기) 같이 고른 것을 푼다 —
        // 안 풀면 보이지 않는 곳에 고른 것이 남아 다음 우클릭이 엉뚱한 PR 까지 보내거나 리뷰한다.
        didSet {
            guard let selectedPRID else { return }
            // 통계를 보다가 PR 을 고르면(행 클릭·방향키·알림) 상세 칸이 그 PR 로 돌아간다(AppModel+TeamStats).
            if showingTeamStats {
                showingTeamStats = false
                prBeforeTeamStats = nil
            }
            if !myPRSelection.ids.isEmpty, !myPRSelection.ids.contains(selectedPRID) { myPRSelection = RowSelection() }
            if !listSelection.ids.isEmpty, !listSelection.ids.contains(selectedPRID) { listSelection = RowSelection() }
        }
    }
    /// 상세 칸에 팀 통계를 보이는가(툴바 "통계").
    var showingTeamStats = false
    /// 통계를 열 때 고르고 있던 PR. 통계 버튼으로 닫으면 이 PR 로 돌아간다.
    @ObservationIgnored var prBeforeTeamStats: String?
    /// 통계 화면의 기간·받은 재료. 화면이 아니라 여기 둔다 — PR 을 보다 돌아올 때마다 다시 받지 않게.
    @ObservationIgnored lazy var teamStats = TeamStatsStore()
    /// "내가 올린 PR" 에서 ⌘·⇧ 클릭으로 같이 고른 PR. 우클릭 "슬랙 리뷰 요청 글 만들기" 가 한 글에 묶는다(AppModel+Slack).
    var myPRSelection = RowSelection()
    /// "내가 올린 PR" 을 "더 보기" 로 다 펼쳤는가. 목록의 방향키 이동도 보이는 행만 따라야 해서 뷰가 아니라 여기 둔다.
    var myPRShowsAll = false
    /// 리뷰 목록에서 ⌘·⇧ 클릭으로 같이 고른 PR. 우클릭 "리뷰 N개" 가 한꺼번에 건다(AppModel+BatchReview).
    var listSelection = RowSelection()
    /// 여러 PR 에 한꺼번에 거는 리뷰. 값이 있으면 묶음 확인 창이 뜬다.
    var pendingBatchReview: PendingBatchReview?
    /// 슬랙 리뷰 요청 창. 값이 있으면 창이 뜬다(MainWindow).
    var slackRequest: SlackRequestDraft?
    /// PR id → 마지막으로 슬랙에 리뷰를 요청한 기록. 같은 PR 을 또 요청할 때 언제·어디에 보냈는지 보여 준다.
    var slackRequests: [String: SlackRequestEntry] = [:]
    /// 내 채널을 받는 중인가(`loadMySlackChannels`). 판을 닫았다 열어도 이어서 보이게 모델에 둔다 — 처음 한 번 1분 넘게 걸린다.
    var slackChannelsLoading: SlackChannelsLoading?
    var slackChannelsError: SlackConnectorError?
    /// 변경이 많아 확인을 기다리는 리뷰. 값이 있으면 확인 창이 뜬다.
    var pendingLargeReview: PendingLargeReview?
    /// 한 파일이 1,000줄 넘게 바뀌어 "빼고 리뷰할까요?" 를 기다리는 리뷰(SkippableFiles). 값이 있으면 창이 뜬다.
    var pendingSkipFiles: PendingSkipFiles?
    /// 제외 규칙 자동완성의 재료(레포 파일·최근 PR 의 바뀐 파일). 설정 › 대상 제외를 열 때 받는다(AppModel+Exclusions).
    var exclusionCatalog: ExclusionCatalog?
    var exclusionCatalogState: ExclusionCatalogState = .idle
    /// PR 스냅샷을 처음 받기 전에 묻는 전체 리뷰. 값이 있으면 "현재 PR의 스냅샷을 클론합니다" 창이 뜬다.
    var pendingSnapshotClone: PendingSnapshotClone?
    /// 스냅샷이 없는 레포에서 처음 받을 코드 크기(키: `owner/name@head`). 리뷰 전 화면·메뉴가 보인다(loadSnapshotCodeSize).
    var snapshotCodeSizes: [String: CodeSize] = [:]
    /// 받아 둔 스냅샷이 이 맥에서 차지하는 크기(키: `owner/name`). 설정의 크기와 같은 셈이다(loadSnapshotDiskSize).
    var snapshotDiskSizes: [String: Int64] = [:]
    /// 레포 관리 팝오버에서 누른 "지우기"·"연결 끊기". 확인 창은 본창이 띄운다 — 팝오버 안에서 띄우면
    /// 창이 뜨는 순간 팝오버가 닫히며 확인 창도 같이 사라질 수 있다.
    var pendingCloneAction: PendingCloneAction?
    /// 상세 화면에서 보고 있는 탭.
    ///
    /// 뷰가 아니라 여기에 둔다. 상세 화면은 `.id(pr.id)` 로 PR 마다 새로 만들어지는데,
    /// 탭이 뷰 안의 @State 면 PR 을 바꿀 때마다 개요로 되돌아간다 — 여러 PR 의 리뷰 결과를
    /// 연달아 훑을 때 매번 탭을 다시 눌러야 했다.
    /// 저장하지는 않는다. 앱을 다시 켜면 개요부터 시작한다.
    var detailTab: DetailTab = .overview
    var banner: Banner?
    /// 초안 없는 코드 코멘트(우려사항만·질문)에서 고친 달 글. 키는 `IssueCard.bodyKey`("PR id|지적 키").
    /// AI 리뷰 탭과 변경 파일 탭이 같은 카드를 그려서, 한쪽에서 고친 글이 다른 쪽에도 보여야 한다.
    var issueBodies: [String: String] = [:]
    /// 지금 바로 달고 있는 코드 코멘트(같은 키). 두 탭의 카드가 같이 "다는 중" 을 보인다.
    var postingIssueKeys: Set<String> = []
    /// 지금 GitHub 에 올리고 있는 리뷰 게시·Approve(`PostingKey`). 화면 상태로 두면 게시 도중 다른 PR 로 갔다 오는
    /// 사이 화면이 새로 만들어져 버튼이 다시 "게시" 로 돌아왔다 — 같은 리뷰를 한 번 더 누를 수 있었다.
    var postingKeys: Set<String> = []
    /// 마지막 게시가 실패한 이유(`PostingKey` → 사람이 읽는 글). 그 자리 버튼이 "다시 시도" 로 바뀌고 이유를 아래에 적는다.
    var postFailures: [String: String] = [:]
    var isRefreshing = false
    /// 사람이 누른 새로고침이 도는 중(`refreshByUser`). 목록 머리 줄의 ↻ 가 본다.
    private(set) var isUserRefreshing = false
    var isLoadingRepos = false
    var lastRefreshedAt: Date?
    var rateRemaining: Int?
    var showOnboarding = false
    var isSleeping = false
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// PR@head → 받은 diff 를 **제외 규칙 없이** 파싱한 것. 화면은 `parsedDiff(for:)` 로 지금 규칙에 맞춰 나눠 본다.
    var diffCache: [String: ParsedDiff] = [:]
    var diffCacheOrder: [String] = []
    /// `parsedDiff(for:)` 가 나눈 결과. 같은 규칙이면 다시 나누지 않는다(화면이 한 번 그릴 때 여러 번 묻는다).
    @ObservationIgnored var exclusionMemo: [String: (patterns: [String], diff: ParsedDiff)] = [:]
    var loadingDiffKeys: Set<String> = []
    /// 변경 파일 탭 "커밋별로 보기"(AppModel+Commits). PR@head → 그 브랜치의 커밋 그래프.
    var branchGraphs: [String: BranchGraphState] = [:]
    var loadingBranchKeys: Set<String> = []
    /// 커밋을 고른 뒤의 diff. "레포|범위" → 제외 규칙 없이 파싱한 것. 커밋 oid 로 정해져 바뀌지 않는다.
    var commitDiffCache: [String: ParsedDiff] = [:]
    var commitDiffOrder: [String] = []
    @ObservationIgnored var commitExclusionMemo: [String: (patterns: [String], diff: ParsedDiff)] = [:]
    var loadingCommitDiffKeys: Set<String> = []
    var commitDiffErrors: [String: String] = [:]
    var listTruncated = false
    var repoListTruncated = false
    var pendingRefresh = false
    var didBootstrap = false
    var pendingRecords: [String: ReviewRecord] = [:]
    var prSnapshots: [String: PRSnapshot] = [:]
    /// 첫 조회는 기준선이라 알리지 않는다(앱을 처음 켰을 때 모든 PR 이 "새 PR" 로 쏟아지는 것 방지).
    var hasSnapshotBaseline = false
    /// 지금 화면에 있는 목록이 아직 이번 조회 결과가 아닌가 — 지난번 캐시이거나, 처음이라 비어 있다
    /// (조회가 끝나면 false). 목록 머리 줄의 "가져오는 중" 과 빈 목록의 빈 행 자리가 본다.
    /// 처음 값이 true 인 것은 앱을 처음 켜 캐시가 없을 때도 첫 결과 전에는 "없습니다" 대신
    /// "가져오는 중" 을 띄우려는 것이다. 폴링으로 다시 받을 때는 false 라 빈 화면이 깜빡이지 않는다.
    private(set) var isShowingCachedList = true
    /// 탭마다 마지막으로 받은 목록(키: 탭의 storageValue). 탭을 옮기면 새로 받는 동안 그 탭의 지난 결과를
    /// 먼저 보여 준다 — 예전에는 앞 탭의 목록이 그대로 남아, 승인 탭에서 방금 승인한 PR 이 없는 것처럼 보였다.
    @ObservationIgnored var listCache: [String: [PullRequestInfo]] = [:]
    /// 탭마다 마지막으로 다 받은 때(키: 탭의 storageValue). 앱을 켤 때는 디스크에 남긴 때로 채운다.
    @ObservationIgnored private var listFetchedAt: [String: Date] = [:]
    /// 검색칸 아래 구역 — 지금 탭 밖의 PR 을 서버에서 찾은 것(AppModel+Search).
    var extraSearch = ExtraSearchState()
    @ObservationIgnored var extraSearchTask: Task<Void, Never>?
    /// 같은 검색어·범위를 다시 묻지 않으려고 둔다. 탭을 오가도 받은 결과가 바로 뜬다.
    @ObservationIgnored var extraSearchCache: [String: (state: ExtraSearchState, at: Date)] = [:]
    /// 아래 구역에서 고른 PR. 탭 목록(`prs`)에 없어서 상세 칸이 여기서 읽는다(selectedPR).
    var searchPickedPR: PullRequestInfo?
    /// 이 앱에서 승인한 PR(키: pr.id). 승인 탭 검색(GitHub 검색 색인)은 승인을 늦게 반영해, 방금 승인한
    /// PR 이 한동안 검색에 안 온다. 그동안은 따로 받아 합치고, 검색에 오면 지운다.
    @ObservationIgnored var recentApprovals: [String: (repo: RepoID, number: Int, at: Date)] = [:]
    var saveTasks: [String: Task<Void, Never>] = [:]
    var sleepObservers: [NSObjectProtocol] = []

    /// 1초마다 갱신되는 시계. 진행 중인 리뷰의 경과 시간(mm:ss)을 화면에 흘려보내는 용도다.
    /// 자동 리뷰를 걷어낸 뒤에도 이건 남는다 — 리뷰가 도는 동안 초 단위로 다시 그려야 하기 때문.
    var clockTick = Date()

    /// 상대 시각("now", "1h", "2d")을 그리는 뷰들이 **시간이 흘렀다는 사실을 알기 위해** 읽는 값.
    ///
    /// 상대 시각은 "지금" 이 언제냐에 따라 달라지는데, 뷰의 입력은 날짜 하나뿐이라
    /// SwiftUI 는 시간이 흐른 것을 모른다. 그래서 한 번 그린 "now" 가 한 시간 뒤에도
    /// "now" 로 남아 있었다(실측: 1시간 21분 전 승인이 목록에서 계속 "now" 였다).
    ///
    /// 1초짜리 `clockTick` 을 쓰지 않는 이유: 목록 전체가 초당 한 번 다시 그려진다.
    /// 30초면 "now → 1m" 전환이 늦어 보이지 않고, 그 위 단위(h·d)에서는 차이가 아예 없다.
    var relativeTimeTick = Date()
    static let relativeTimeInterval: TimeInterval = 30

    let store = Store()
    let claude = ClaudeRunner()
    let codex = CodexRunner()
    var pollTask: Task<Void, Never>?
    var workerTask: Task<Void, Never>?
    var runningTask: Task<Void, Never>?
    var clockTask: Task<Void, Never>?

    var github: GitHubClient { GitHubClient(ghPath: settings.ghPath, host: settings.githubHost) }

    // MARK: - 파생 상태

    var selectedPR: PullRequestInfo? {
        guard let selectedPRID else { return nil }
        if let pr = prs.first(where: { $0.id == selectedPRID }) { return pr }
        // 검색 아래 구역에서 고른 PR — 탭 목록 밖이다. 검색어를 지워도 보던 PR 이 오른쪽에 남는다.
        return searchPickedPR?.id == selectedPRID ? searchPickedPR : nil
    }

    /// 이 PR 을 내가 스코프 기간 안에 승인했는가.
    func viewerApprovedRecently(_ pr: PullRequestInfo, hours: Int) -> Bool {
        guard let at = viewerApprovedAt(pr) else { return false }
        return at >= Date().addingTimeInterval(-Double(hours) * 3600)
    }

    /// 내가 이 PR 을 **승인한 시각**(여러 번이면 가장 최근).
    ///
    /// "최근 승인" 탭은 이 시각으로 거르는데 행은 PR 올린 시각(Created)을 보여 줬다.
    /// 그래서 방금 승인해도 "24h 탭인데 1d ago" 처럼 보였다(실측: PR 은 18시간 전에
    /// 올라왔고 승인은 40분 전이었다). 거르는 기준과 보여 주는 값은 같아야 한다.
    func viewerApprovedAt(_ pr: PullRequestInfo) -> Date? {
        guard let login = githubAccount?.login else { return nil }
        // 다른 탭의 지난 목록을 미리 채울 때(ListCacheSeeding)도 같은 잣대를 쓴다.
        return pr.viewerApprovedAt(login: login)
    }

    /// 필터 값만 뽑아 Core 판정에 넘긴다. 빈 화면 진단과 **같은 규칙**을 쓰게 해서
    /// "필터를 풀면 보인다" 는 안내가 실제 목록과 어긋나지 않게 한다.
    var filterState: PRFilterState {
        PRFilterState(hideIgnoredAuthors: filter.hideIgnoredAuthors,
                      hideLabels: filter.hideLabels,
                      search: filter.search,
                      hasIgnoredAuthors: !settings.ignoredAuthors.isEmpty,
                      hasHiddenLabels: !settings.hiddenLabels.isEmpty,
                      hiddenRepos: hiddenRepoKeys)
    }

    /// 레포 탭에서 뺀 레포 중 **지금 켜져 있는 것만**(`PRFilterState.repoKey`).
    /// 설정에서 지웠거나 툴바에서 꺼 둔 레포가 기록에 남아 있어도 "필터 켜짐" 으로 세지 않는다 —
    /// 세면 아무것도 안 거르는데 필터 숫자만 떠 있게 된다.
    var hiddenRepoKeys: Set<String> {
        guard !filter.hiddenRepos.isEmpty else { return [] }
        let hidden = Set(filter.hiddenRepos.map { $0.lowercased() })
        return Set(settings.enabledRepos.map { PRFilterState.repoKey($0.repo) }).intersection(hidden)
    }

    func isRepoShown(_ repo: RepoID) -> Bool {
        !filter.hiddenRepos.contains { $0.caseInsensitiveCompare(repo.full) == .orderedSame }
    }

    /// 레포 하나를 목록에 보이거나 뺀다(레포 탭의 ⌘-클릭, 레포 관리 팝오버의 눈 아이콘).
    /// 목록에서만 빼고 조회·알림은 그대로 둔다 — 그건 레포 관리(⚙︎)의 켜기·끄기다.
    func setRepoShown(_ repo: RepoID, _ shown: Bool) {
        filter.hiddenRepos.removeAll { $0.caseInsensitiveCompare(repo.full) == .orderedSame }
        if !shown { filter.hiddenRepos.append(repo.full) }
        filter.hiddenRepos.sort()
    }

    /// 이 레포만 남기고 켜진 다른 레포를 모두 뺀다. 레포 하나를 들여다볼 때가 가장 흔한 쓰임이라 한 번에 한다.
    func showOnly(_ repo: RepoID) {
        let key = PRFilterState.repoKey(repo)
        filter.hiddenRepos = settings.enabledRepos.map(\.repo)
            .filter { PRFilterState.repoKey($0) != key }
            .map(\.full)
            .sorted()
    }

    /// 레포 탭의 ⌘-클릭: 지금 고른 레포들에 더하거나 뺀다. 전부 보이는 중이면 그 레포 하나부터 고르기 시작한다.
    /// 마지막 하나는 빼지 않는다 — 빼면 목록이 통째로 빈다.
    func toggleRepoInSelection(_ repo: RepoID) {
        guard !hiddenRepoKeys.isEmpty else {
            showOnly(repo)
            return
        }
        let shown = isRepoShown(repo)
        let shownCount = settings.enabledRepos.filter { isRepoShown($0.repo) }.count
        guard !(shown && shownCount == 1) else { return }
        setRepoShown(repo, !shown)
    }

    /// 레포 탭을 끌어 순서를 바꾼다(끄는 동안 지나가는 탭마다 불린다). 순서는 설정의 레포 목록 순서라
    /// 설정 창의 레포 목록·필터의 레포 목록도 같은 순서가 된다.
    func moveRepo(_ repo: RepoID, to target: RepoID) {
        settings.moveRepo(repo, to: target)
        Task { await save() }
    }

    /// 탭 우클릭 "왼쪽으로·오른쪽으로 옮기기". 탭이 넘쳐 끌어서 닿지 않는 자리로도 옮길 수 있게 둔다.
    func moveRepo(_ repo: RepoID, by step: Int) {
        settings.moveRepo(repo, by: step)
        Task { await save() }
    }

    var visiblePRs: [PullRequestInfo] {
        let state = filterState
        let listed = prs.filter { isListed($0, state: state) }
        // 머지·닫힘으로 받은 목록에서 없어진 행은 칩이 떠날 때까지 제자리에 남긴다(applyFetched).
        guard !departingRows.isEmpty else { return listed }
        return (listed + departingRows).sorted { $0.createdAt > $1.createdAt }
    }

    private func isListed(_ pr: PullRequestInfo, state: PRFilterState) -> Bool {
        // 새로 온 PR 은 빠지는 칩이 탭에 닿은 뒤 차례대로 들어온다(applyFetched). 그때까지 숨긴다.
        if heldBackArrivals.contains(pr.id) { return false }
        // 방금 내가 처리한 PR 은 조건에서 빠져도 잠깐 남겨 둔다(아래 markLeaving 참고).
        if leavingPRs[pr.id] != nil || heldForFlight.contains(pr.id) { return true }
        // 유예가 끝난 PR 은 GitHub 이 뭐라고 하든 뺀다(아래 dismissedPRs 참고).
        if PRVisibility.isDismissed(pr: pr, dismissals: dismissedPRs) { return false }
        // 내가 올린 것은 맨 위 별도 그룹이 맡는다. 여기 두면 같은 PR 이 두 번 나온다.
        if isMineInOpenTab(pr) { return false }
        return passesScopeAndFilters(pr, state: state)
    }

    /// 레포 탭에 붙는 건수 — 그 레포를(nil 이면 전부) 보이게 하면 목록에 나올 PR 수다.
    /// 받아 둔 수를 쓰면 라벨·사람 필터에 걸려 안 나올 PR 까지 세서, 눌렀더니 건수보다 적게 나온다.
    func visibleCount(showing repo: RepoID?) -> Int {
        var state = filterState
        state.hiddenRepos = []
        let key = repo.map(PRFilterState.repoKey)
        return prs.filter { pr in
            if let key, PRFilterState.repoKey(pr.repo) != key { return false }
            return isListed(pr, state: state)
        }.count
    }

    private func isMineInOpenTab(_ pr: PullRequestInfo) -> Bool {
        listScope.kind == .open && pr.viewerDidAuthor && pr.isOpen
    }

    /// 리뷰 대기 탭 맨 위에 따로 묶는 **내가 올린 PR**.
    ///
    /// 필터를 받지 않는다. "내 차례만"·"특정 라벨 숨기기" 는 **남의 PR 을 리뷰하려고**
    /// 있는 조건이라 내 PR 에는 뜻이 없고, 그 필터가 켜져 있을 때가 바로 이 그룹이 필요한 때다.
    ///
    /// 검색어만은 받는다 — 검색은 "찾기" 라, 찾는 것이 내 PR 일 때 그룹이 안 걸러지면
    /// 검색 결과 위에 엉뚱한 줄이 계속 남는다. 레포 고르기도 같은 이유로 받는다 — 레포 하나만
    /// 보려는데 다른 레포의 내 PR 이 맨 위에 남으면 좁힌 보람이 없다.
    var myOpenPRs: [PullRequestInfo] {
        guard listScope.kind == .open else { return [] }
        let needle = filter.search.trimmingCharacters(in: .whitespaces).lowercased()
        let hiddenRepos = hiddenRepoKeys
        return prs
            .filter { pr in
                guard isMineInOpenTab(pr) else { return false }
                if hiddenRepos.contains(PRFilterState.repoKey(pr.repo)) { return false }
                if PRVisibility.isDismissed(pr: pr, dismissals: dismissedPRs) { return false }
                guard !needle.isEmpty else { return true }
                return "\(pr.number) \(pr.title) \(pr.headRefName)".lowercased().contains(needle)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 숨김을 빼고 탭·필터만으로 보일 PR 인가.
    func passesScopeAndFilters(_ pr: PullRequestInfo, state: PRFilterState) -> Bool {
        guard PRVisibility.scopeIncludes(pr: pr, scope: listScope,
                                         approvedInWindow: approvedInWindow(pr)) else { return false }
        return PRVisibility.hidingFilters(pr: pr,
                                          state: state,
                                          scope: listScope,
                                          hasHiddenLabel: settings.hasHiddenLabel(pr.labels),
                                          isIgnoredAuthor: settings.isIgnoredAuthor(pr.author))
            .isEmpty
    }

    /// 이 레포의 PR 이 목록에 안 보이는 **실제** 이유.
    ///
    /// 예전에는 "모두 필터에 걸렸습니다" 한 문장이었는데, 필터가 아닌 이유로 빠지는 길이
    /// 셋이나 된다(탭 조건·내가 처리해서 뺌·내가 올린 PR 그룹으로 옮김). 그때 "필터를 푼다"
    /// 를 권하면 눌러도 아무 일이 없다. 무엇이 걸렀는지를 세어서 그대로 말한다.
    struct RepoHiddenReason {
        var scopeExcluded = 0
        var dismissed = 0
        var movedToMyPRs = 0
        /// 필터 종류 → 그 필터에 걸린 건수. 한 PR 이 둘에 걸리면 양쪽에 센다.
        var byFilter: [PRFilterKind: Int] = [:]
        /// 숨길 사람·숨길 라벨 필터에 실제로 걸린 이름. "특정 사람의 PR 숨기기 2건" 만으로는
        /// 누구 때문인지 몰라 설정을 뒤져야 했다 — 이유를 말할 때 이름까지 적는다.
        var authors: Set<String> = []
        var labels: Set<String> = []

        /// 필터를 풀면 뭐라도 나오는가. 아니면 [끄기] 를 권하면 안 된다.
        var filtersCanHelp: Bool { !byFilter.isEmpty }
    }

    func hiddenReason(for repo: RepoID) -> RepoHiddenReason {
        let state = filterState
        var reason = RepoHiddenReason()
        for pr in prs where pr.repo == repo {
            if leavingPRs[pr.id] != nil || heldForFlight.contains(pr.id) { continue }
            if PRVisibility.isDismissed(pr: pr, dismissals: dismissedPRs) {
                reason.dismissed += 1
                continue
            }
            if isMineInOpenTab(pr) {
                reason.movedToMyPRs += 1
                continue
            }
            guard PRVisibility.scopeIncludes(pr: pr, scope: listScope,
                                             approvedInWindow: approvedInWindow(pr)) else {
                reason.scopeExcluded += 1
                continue
            }
            let kinds = PRVisibility.hidingFilters(pr: pr,
                                                   state: state,
                                                   scope: listScope,
                                                   hasHiddenLabel: settings.hasHiddenLabel(pr.labels),
                                                   isIgnoredAuthor: settings.isIgnoredAuthor(pr.author))
            for kind in kinds { reason.byFilter[kind, default: 0] += 1 }
            if kinds.contains(.hideIgnoredAuthors) { reason.authors.insert(pr.author) }
            if kinds.contains(.hideLabels), let label = settings.hiddenLabel(in: pr.labels) { reason.labels.insert(label) }
        }
        return reason
    }

    /// 목록에서 빠질 PR 을 이만큼 남겨 둔다.
    static let removalGrace: TimeInterval = 5

    /// 곧 목록에서 빠질 PR → 빠지는 시각.
    ///
    /// 게시·승인 직후에 행이 툭 사라지면 무엇이 없어졌는지, 내가 무엇을 한 건지 확인할 틈이 없다.
    /// 몇 초 남겨 두고 줄어드는 표시를 보여 준 다음 조용히 뺀다.
    private(set) var leavingPRs: [String: Date] = [:]

    func leavingDeadline(for pr: PullRequestInfo) -> Date? { leavingPRs[pr.id] }

    /// Approve 해서 Approved 탭으로 날아갈 PR — 칩이 뜰 때까지, 그리고 뜬 뒤 행을 접을 때까지 목록에 붙잡아 둔다.
    /// `leavingPRs` 와 달리 흐려지지 않는다(`ApprovalFlight`). 새로 받은 목록에서 빠지는 PR 도 여기 붙잡는다.
    private(set) var heldForFlight: Set<String> = []
    /// 지금 탭으로 날아가는 칩.
    private(set) var approvalFlights: [ApprovalFlight] = []
    /// 칩이 탭에 닿을 때마다 그 탭의 값이 바뀐다. 탭이 이 값을 보고 한 번 반짝인다.
    private(set) var tabLandings: [PRListScopeKind: TabLanding] = [:]

    // MARK: 새로 받은 목록 차례대로 보이기

    /// 받은 목록에서 아예 없어진(머지·닫힘) PR 중 아직 화면에 남겨 둔 행. `prs` 는 늘 받은 그대로 두고 화면에만
    /// 잠깐 남긴다 — `prs` 에 섞으면 알림·캐시·저장이 이미 없어진 PR 을 본다.
    private(set) var departingRows: [PullRequestInfo] = []
    /// 새로 온 PR 중 아직 차례가 안 온 것. 빠지는 칩이 탭에 닿은 뒤 하나씩 펼쳐진다.
    private(set) var heldBackArrivals: Set<String> = []
    /// 방금 들어온 행. 옅은 바탕이 잠깐 남았다가 사라진다 — 움직임은 짧게 끝나도, 잠깐 딴 데를 봤다 와서
    /// 어디가 새것인지 보이게.
    private(set) var freshPRs: Set<String> = []
    /// 지난 목록을 보이며 다시 받아 끝낸 때. 목록 머리 줄이 "가져오는 중 · 오후 2:02 목록" 에서 "최신 · 오후 2:40" 으로
    /// 바뀌어 잠깐 남았다가 평소의 "오후 2:40 갱신" 으로 돌아간다(PRListView 의 ListHeader). nil 이면 걷는다.
    private(set) var staleRefreshCheckedAt: Date?
    @ObservationIgnored private var refreshChoreography: Task<Void, Never>?
    /// 이번 갱신이 `heldForFlight` 에 붙잡은 것. Approve 칩이 붙잡은 것과 가른다.
    @ObservationIgnored private var refreshHeld: Set<String> = []

    /// 이 행의 배지 자리를 칩의 출발 자리로 적어야 하나.
    func isFlightSource(_ pr: PullRequestInfo) -> Bool { heldForFlight.contains(pr.id) }
    /// 칩이 이 행에서 떠났나 — 떠난 행은 바로 감춘다(칩이 그 자리에서 나온 것처럼).
    func hasLaunchedFlight(_ pr: PullRequestInfo) -> Bool { approvalFlights.contains { $0.prKey == pr.id } }

    /// 내가 처리해서 목록에서 뺀 PR → 뺄 때의 head 커밋과 리뷰 시각.
    ///
    /// 유예가 끝났을 때 "필터가 다시 판단하게" 두면 행이 사라지지 않는다. 게시 직후에는
    /// GitHub 이 아직 예전 상태를 돌려주는 창이 있어서(읽기-쓰기 지연), 그동안은 필터가
    /// 그 PR 을 여전히 "내 차례" 로 본다. 그래서 5초를 세고 흐려진 행이 도로 또렷해진 채
    /// 다음 폴링(기본 120초)까지 남아 있었다 — 카운트다운이 헛돈 셈이다.
    ///
    /// 승인·게시는 **내가 한 일**이라 GitHub 에 물어볼 필요가 없다. 유예가 끝나면 바로 뺀다.
    /// 화면에서만 쓰는 상태라 저장하지 않는다 — 앱을 다시 켜면 GitHub 이 말하는 대로 돌아온다.
    /// 새 커밋이나 재요청이 오면 다시 보인다(PRVisibility.isDismissed).
    private(set) var dismissedPRs: [String: PRDismissal] = [:]

    /// PR 하나만 다시 조회해 목록의 그 항목을 갈아 끼운다.
    ///
    /// 게시 직후처럼 "그 PR 의 상태만" 바뀐 것이 확실할 때 쓴다. 전체 갱신은 닫힘 포함 탭에서
    /// 수십 초가 걸리고 rate limit 도 먹는다.
    func refreshOne(repo: RepoID, number: Int) async {
        // try? 가 이중 옵셔널을 한 겹으로 눌러 주므로 바인딩은 한 번이면 된다.
        guard let fresh = try? await github.pullRequest(repo, number: number) else { return }
        replace(with: fresh)
    }

    /// 방금 받은 PR 하나를 목록에 끼운다. 목록에 없는 PR(필터 밖)은 건드리지 않는다.
    /// 다른 탭의 지난 목록에도 반영한다(seedOtherCaches) — 게시 뒤 다시 받은 PR 이 Approved·All PRs 에 먼저 보이게.
    func replace(with fresh: PullRequestInfo) {
        seedOtherCaches(with: [fresh], from: listScope)
        // 검색 아래 구역에서 고른 PR 도 게시·Approve 뒤 새 모습으로 바꾼다 — 탭 목록에 없어 아래 guard 에서 끝난다.
        replaceInExtraSearch(fresh)
        guard let index = prs.firstIndex(where: { $0.id == fresh.id }) else { return }
        forgetDiffsIfBaseChanged(from: [prs[index]], to: [fresh])
        prs[index] = fresh
        dismissedPRs = PRVisibility.prunedDismissals(dismissedPRs, prs: prs)
    }

    /// `reviewedAt` 은 방금 낸 리뷰의 게시 시각 — 뺀 뒤 다시 리뷰 요청이 왔는지 가르는 기준이다.
    /// `approved` 면 리뷰 대기에서 Approved 탭으로 옮겨 가는 것이라, 흐려지며 사라지는 대신 그 탭으로 날아간다.
    func markLeaving(_ prKey: String, reviewedAt: Date, approved: Bool = false) {
        if approved, ApprovalFlight.applies(to: listScope.kind) {
            flyToApprovedTab(prKey, reviewedAt: reviewedAt)
            return
        }
        leavingPRs[prKey] = Date().addingTimeInterval(Self.removalGrace)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.removalGrace))
            guard let self, let deadline = self.leavingPRs[prKey] else { return }
            // 그동안 다시 눌러 시간이 밀렸으면 그때까지 기다린다.
            guard deadline <= Date().addingTimeInterval(0.25) else { return }
            self.finishLeaving(prKey, reviewedAt: reviewedAt)
        }
    }

    /// Approve 한 PR 의 배지 자리에서 칩을 띄워 Approved 탭으로 보낸다(`ApprovalFlight`).
    ///
    /// 5초 유예(`removalGrace`)는 두지 않는다. 유예는 무엇이 없어졌는지 볼 틈이었는데, 칩이 어디로 갔는지를 그대로
    /// 보여 준다. 배지가 Approved 로 바뀐 것을 볼 틈(`beat`)만 두고 칩을 띄운 뒤, 곧 행을 빼 아래 행들이 올라오게 한다.
    /// `pace` 는 확인 캡처 때 시간을 늘리는 배율이다(`PRAYER_DEBUG_APPROVE_FLIGHT`).
    func flyToApprovedTab(_ prKey: String, reviewedAt: Date, pace: Double = 1) {
        guard let number = prs.first(where: { $0.id == prKey })?.number else {
            // 갱신하는 사이 목록에서 이미 빠졌다. 날릴 행이 없으니 탭만 반짝여 어디로 갔는지 알린다.
            landTab(.myApprovals, count: 1)
            return
        }
        heldForFlight.insert(prKey)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ApprovalFlight.beat * pace))
            guard let self else { return }
            self.approvalFlights.append(ApprovalFlight(prKey: prKey, number: number, pace: pace))
            try? await Task.sleep(for: .seconds(ApprovalFlight.rowDelay * pace))
            self.finishLeaving(prKey, reviewedAt: reviewedAt)
        }
    }

    /// 칩이 탭에 닿았다(출발 자리가 화면 밖이라 날지 못한 것도 여기로 온다).
    func landApprovalFlight(_ id: UUID) {
        guard let flight = approvalFlights.first(where: { $0.id == id }) else { return }
        approvalFlights.removeAll { $0.id == id }
        landTab(flight.destination, count: 1 + flight.others)
    }

    private func landTab(_ kind: PRListScopeKind, count: Int) {
        var landing = tabLandings[kind] ?? TabLanding()
        landing.serial += 1
        landing.count = count
        tabLandings[kind] = landing
    }

    /// 붙잡아 둔 PR 을 목록에서 뺀다.
    private func finishLeaving(_ prKey: String, reviewedAt: Date) {
        // 빠진 자리를 아래 행들이 툭 튀어 올라와 메우면 눈이 따라가지 못해 어디까지 봤는지 놓친다.
        // 빼는 순간을 애니메이션으로 감싸 아래 행들이 미끄러져 올라오게 한다.
        withAnimation(.smooth(duration: 0.3)) {
            // 유예를 거두기 **전에** 숨김에 넣는다. 순서가 바뀌면 그 사이 한 번 다시 그려지면서
            // 흐려졌던 행이 도로 또렷해졌다가 사라진다.
            if let pr = prs.first(where: { $0.id == prKey }) {
                dismissedPRs[prKey] = PRDismissal(head: pr.headRefOid, reviewedAt: reviewedAt)
            }
            leavingPRs.removeValue(forKey: prKey)
            heldForFlight.remove(prKey)
        }
    }

    /// 승인 탭의 기간 조건. 탭의 정의이지 필터가 아니다.
    func approvedInWindow(_ pr: PullRequestInfo) -> Bool {
        guard let hours = listScope.windowHours else { return true }
        return viewerApprovedRecently(pr, hours: hours)
    }

    /// 목록이 비었을 때 무엇이 원인인지. 화면 문구가 이걸 읽는다.
    var emptyDiagnosis: EmptyListDiagnosis {
        EmptyListDiagnosis.make(prs: prs,
                                state: filterState,
                                scope: listScope,
                                hasHiddenLabel: { [settings] pr in
                                    settings.hasHiddenLabel(pr.labels)
                                },
                                approvedInWindow: { [weak self] pr in
                                    self?.approvedInWindow(pr) ?? true
                                },
                                isIgnoredAuthor: { [settings] pr in
                                    settings.isIgnoredAuthor(pr.author)
                                })
    }

    /// 이 작성자를 안 보기 목록에 넣거나 뺀다. 행의 맥락 메뉴가 쓴다 —
    /// "이 사람 것은 안 봐도 되는데" 하는 생각이 드는 자리가 거기다.
    func toggleIgnoredAuthor(_ login: String) {
        if let index = settings.ignoredAuthors.firstIndex(where: {
            $0.caseInsensitiveCompare(login) == .orderedSame
        }) {
            settings.ignoredAuthors.remove(at: index)
        } else {
            settings.ignoredAuthors.append(login)
        }
        Task { await save() }
    }

    /// 숨길 라벨 목록에 넣거나 뺀다. 라벨 편집 화면과 행의 라벨 맥락 메뉴가 쓴다.
    func toggleHiddenLabel(_ label: String) {
        if let index = settings.hiddenLabels.firstIndex(where: {
            $0.caseInsensitiveCompare(label) == .orderedSame
        }) {
            settings.hiddenLabels.remove(at: index)
        } else {
            settings.hiddenLabels.append(label)
        }
        Task { await save() }
    }

    /// 필터 하나를 끈다. 빈 화면에서 줄별 [끄기] 버튼이 쓴다.
    func turnOff(_ kind: PRFilterKind) {
        switch kind {
        case .hideIgnoredAuthors: filter.hideIgnoredAuthors = false
        case .hideLabels: filter.hideLabels = false
        case .repos: filter.hiddenRepos = []
        case .search: filter.search = ""
        }
    }

    func turnOffAllFilters() {
        filter.hideIgnoredAuthors = false
        filter.hideLabels = false
        filter.hiddenRepos = []
        filter.search = ""
    }

    var activeJobCount: Int { jobs.filter(\.isActive).count }
    var fiveHourTokens: Int { ledger.tokens(inLast: TokenLedger.fiveHours) }

    func record(for pr: PullRequestInfo) -> ReviewRecord? {
        guard let record = records[pr.id], !record.discarded else { return nil }
        return record
    }

    /// 그 PR 의 리뷰 기록 전부(최신순). 폐기한 것은 빼고 보여 준다.
    func history(for pr: PullRequestInfo) -> [ReviewRecord] {
        (recordHistory[pr.id] ?? []).filter { !$0.discarded }
    }

    /// 히스토리에서 다른 리뷰를 골라 화면에 올린다.
    func selectRecord(_ record: ReviewRecord) {
        records[record.prKey] = record
    }

    /// 리뷰 결과 검사에서 앱이 손본 것을 문제 기록에 남긴다. 새 리뷰가 생길 때만 부른다 —
    /// 초안을 고치거나 게시할 때마다 부르면 같은 경고가 여러 번 쌓인다.
    func recordValidationProblems(_ record: ReviewRecord) {
        for issue in record.validationIssues {
            ProblemLog.shared.record(issue.kind ?? .other, detail: "#\(record.number) \(issue.message)")
        }
    }

    /// 새로 만들어진(또는 갱신된) 기록을 히스토리에 반영하고 화면에 올린다.
    ///
    /// 같은 리뷰의 편집은 `createdAt` 이 그대로라 제자리에서 갈아 끼우고, 새 리뷰는 맨 앞에 넣는다.
    /// 상한을 넘긴 것은 목록에서만 떨어뜨린다 — 파일 정리는 다음 실행의 loadRecords 가 한다.
    func remember(_ record: ReviewRecord) {
        var list = recordHistory[record.prKey] ?? []
        if let index = list.firstIndex(where: { $0.headSha == record.headSha && $0.createdAt == record.createdAt }) {
            list[index] = record
        } else {
            list.insert(record, at: 0)
            list.sort { $0.createdAt > $1.createdAt }
        }
        recordHistory[record.prKey] = Array(list.prefix(Store.historyLimit))
        records[record.prKey] = record
    }

    /// 이 PR 이 큐에 있거나 실행 중인가. 완료 전까지 리뷰 버튼을 잠근다.
    /// 불러온 PR 에 등장한 사람들. 설정에서 표시 이름을 고칠 대상 목록.
    var knownMembers: [String] {
        var seen = Set<String>()
        for pr in prs {
            seen.insert(pr.author)
            for approval in pr.approvals { seen.insert(approval.login) }
            for commit in pr.commits { seen.insert(commit.author) }
            for thread in pr.threads {
                for comment in thread.comments { seen.insert(comment.author) }
            }
        }
        seen.remove("")
        return seen.sorted { $0.lowercased() < $1.lowercased() }
    }

    func isReviewing(_ pr: PullRequestInfo) -> Bool {
        jobs.contains { $0.id == pr.id && $0.isActive }
    }

    /// 지난 실행에서 돌던 리뷰의 결과를 가져온다.
    /// `claude` 는 앱의 자식이지만 앱이 꺼져도 계속 돌 수 있어, 결과 파일이 남아 있으면 초안이 된다.
    func harvestUnfinishedReviews() async {
        guard let engine = makeEngine() else { return }
        let results = await engine.harvestSpooledJobs()
        guard !results.isEmpty else { return }
        var recovered = 0
        var running = 0
        var lost: [String] = []
        for result in results {
            switch result {
            case .recovered(let record):
                remember(record)
                recordValidationProblems(record)
                recovered += 1
            case .stillRunning(let job):
                running += 1
                Log.info("앱 밖에서 계속 돌고 있는 리뷰: \(job.pr.id)", "spool")
            case .lost(let job, let reason):
                lost.append("#\(job.pr.number) \(reason)")
            }
        }
        ledger = await store.loadLedger()
        var parts: [String] = []
        if recovered > 0 { parts.append("끝나 있던 리뷰 \(recovered)건을 가져왔습니다") }
        if running > 0 { parts.append("앱 밖에서 \(running)건이 아직 돌고 있습니다(끝나면 다음 실행에 반영됩니다)") }
        if !lost.isEmpty { parts.append("결과를 잃은 리뷰 \(lost.count)건: \(lost.joined(separator: " · "))") }
        if !parts.isEmpty {
            banner = Banner(kind: lost.isEmpty ? .info : .warning, message: parts.joined(separator: " · "))
        }
    }

    /// 전체 내역까지 펼쳐 둔 PR. 기본은 최근 3건만 보여 준다.
    /// 화면에서만 쓰는 상태라 저장하지 않는다 — 앱을 다시 켜면 모두 3건으로 돌아온다.
    func isActivityFull(_ pr: PullRequestInfo) -> Bool {
        fullActivityPRs.contains(pr.id)
    }

    func toggleActivityFull(_ pr: PullRequestInfo) {
        if fullActivityPRs.contains(pr.id) {
            fullActivityPRs.remove(pr.id)
        } else {
            fullActivityPRs.insert(pr.id)
        }
    }

    func job(for pr: PullRequestInfo) -> ReviewJob? {
        jobs.last { $0.id == pr.id }
    }

    func badge(for pr: PullRequestInfo) -> BadgeResult {
        let running = job(for: pr)?.isActive ?? false
        return BadgeResolver.resolve(pr: pr,
                                     isRunning: running,
                                     record: record(for: pr),
                                     skipReason: skipReason(for: pr))
    }

    func skipReason(for pr: PullRequestInfo) -> SkipReason? {
        ReviewSkip.skipReason(pr: pr,
                              settings: settings,
                              approvalThreshold: settings.approvalThreshold(for: pr),
                              changedLinesAfterExclusion: nil,
                              hasRecordForHead: records[pr.id]?.headSha == pr.headRefOid)
    }

    // MARK: - 기동

    func bootstrap() async {
        // 창이 다시 열릴 때 다시 돌면 메모리 설정이 디스크 값으로 되돌아가고 옵저버가 중복 등록된다.
        guard !didBootstrap else { return }
        didBootstrap = true
        // 번들 폰트 등록. onAppear 에 걸었더니 실행되지 않아(실측) 확실히 도는 자리로 옮겼다.
        BundledFonts.registerAll()
        #if DEBUG
        // README 캡처용 데모 모드 — 디스크의 설정·초안을 읽지 않고, 묻지도 않는다(DemoData).
        if DemoData.isOn {
            DemoData.load(into: self)
            return
        }
        #endif
        settings = await store.loadSettings()
        // 머지·닫힌 PR 에 골라 둔 리뷰 모델이 쌓이지 않게 오래된 것은 버린다(PRReviewModel.lifetime).
        settings.prReviewModels = PRReviewModel.pruned(settings.prReviewModels, now: Date())
        if let snapshots = await store.loadSnapshots() {
            prSnapshots = snapshots
            hasSnapshotBaseline = true
        }
        filter = PRFilter.load()
        // 모델 목록을 수확보다 먼저 읽는다 — 수확이 Codex 계열(`codex:sol`)을 실제 모델로 풀 때 쓴다. 늦게 읽으면
        // 초안에 계열 이름이 그대로 남는다(실측 2026-10-29: 머리 줄에 "codex:codex:sol").
        modelCatalog = await store.loadModelCatalog()
        codexCatalog = await store.loadCodexCatalog()
        rememberedModels = await store.loadRememberedModels()
        await harvestUnfinishedReviews()
        loadRememberedWindows()
        if let raw = UserDefaults.standard.string(forKey: "prListScope"),
           let restored = PRListScope(storageValue: raw) {
            isRestoringScope = true
            listScope = restored
            isRestoringScope = false
        }
        // 조회가 끝나기 전에 지난번 목록을 먼저 그려 둔다. 창이 빈 채로 떴다가 통째로
        // 다시 그려지는 대신, 이미 알던 목록이 나와 있고 조회가 끝나면 달라진 행만 바뀐다
        // (ForEach 가 pr.id 로 묶여 있어 같은 PR 은 그 행을 그대로 재사용한다).
        // 탭이 다른 목록은 쓰지 않는다 — 엉뚱한 목록을 보여 주는 것보다 비어 있는 게 낫다.
        // 다른 탭의 지난 목록도 들고 있다가 그 탭으로 옮길 때 먼저 보인다(listScope didSet).
        for cached in await store.loadLists() {
            listCache[cached.scope] = cached.prs
            listFetchedAt[cached.scope] = cached.savedAt
        }
        if let cached = listCache[listScope.storageValue] {
            prs = cached
            // 베타를 깔아 다시 켠 것처럼 방금까지 보던 목록이면 띠 없이 조용히 다시 받는다.
            isShowingCachedList = !isListFresh(listScope)
            Log.info("지난 목록 \(cached.count)건을 먼저 그린다(\(listScope.storageValue)) — 지난 목록이 있는 탭 \(listCache.count)개", "app")
        }
        // 앱이 리뷰 도중 죽었으면 락이 남는다. 워크트리 자체는 재사용하므로 지우지 않는다.
        // PR 스냅샷 옆 워크트리도 같은 락을 쓴다.
        let snapshotPaths = settings.repos.map(\.repo).filter { ReviewClone.exists($0) }.map { ReviewClone.path(for: $0).path }
        let repoPaths = settings.deepReviewRepoPaths.values.filter { !$0.isEmpty } + snapshotPaths
        if !repoPaths.isEmpty {
            Task.detached { await WorktreeManager().clearStaleLocks(repoPaths: repoPaths) }
        }
        recordHistory = await store.loadRecords()
        records = recordHistory.compactMapValues { $0.first }
        explanations = await store.loadExplanations()
        relevances = await store.loadRelevances()
        rechecks = await store.loadRechecks()
        slackRequests = await store.loadSlackRequests()
        ledger = await store.loadLedger()
        showOnboarding = !settings.onboardingCompleted
        NotificationRouter.shared.onSelect = { [weak self] prKey in
            self?.select(prKey: prKey)
        }
        // 알림 권한은 **사용자가 직접 켤 때만** 요청한다.
        // 앱이 알아서 요청하면 사용자가 대화상자에 답하기 전에 앱이 종료되는 등으로
        // 거부 상태가 번들 ID 단위로 캐시돼 이후 요청이 계속 거부된다(실측).
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        await refreshNotificationStatus()
        observeSleepWake()
        observeActivation()
        startClock()
        await checkEngines()
        await checkGitHub()
        if settings.onboardingCompleted {
            await refresh(reloadThresholds: true)
            startPolling()
        }
        await store.pruneDiffCache()
        await checkForUpdateIfDue()
    }

    func finishOnboarding() async {
        await adoptReadyEngineIfNeeded()
        settings.onboardingCompleted = true
        await save()
        showOnboarding = false
        await refresh()
        startPolling()
    }

    func save() async {
        await store.save(settings: settings)
    }

    /// 레포 색을 지금 레포 목록에 맞춰 나눠 준다(RepoColors). 행·탭의 점은 RepoDot.assignments 를 읽는다.
    /// 결과가 달라졌을 때만 설정을 고치고 저장한다 — 고친 설정이 이 함수를 다시 부르지만 그때는 결과가 같아 멈춘다.
    private func syncRepoColors() {
        let assigned = RepoColors.assign(repos: settings.repos.map(\.repo.name), existing: settings.repoColors)
        RepoDot.assignments = assigned
        guard assigned != settings.repoColors else { return }
        settings.repoColors = assigned
        Task { await save() }
    }

    // MARK: - 상태 점검 (매 실행 무음 점검)

    /// 두 엔진을 다 본다. 하나만 쓰는 사람도 나중에 다른 쪽을 붙일 수 있게 늘 같이 본다 — 안 깐 쪽은 금방 끝난다.
    func checkEngines() async {
        guard !DemoMode.isOn else { return }
        await checkClaude()
        await checkCodex()
    }

    /// - Returns: 이번 확인으로 다시 로그인한 것을 알아챘는가(`noteEngineLoginRecovered` 를 불렀는가).
    @discardableResult
    func checkClaude() async -> Bool {
        var path = settings.claudePath
        if !FileManager.default.isExecutableFile(atPath: path) {
            if let discovered = await claude.discoverPath() {
                path = discovered
                settings.claudePath = discovered
                await save()
            }
        }
        let status = await claude.status(path: path)
        // 이전 값은 기다린 뒤에 읽는다. 앱 전환과 실패 직후 확인이 겹쳐 돌 수 있다.
        let recovered = AuthFailure.loginRecovered(lastKnown: lastKnownLogin, current: status)
        if status.loginKnown {
            lastKnownLogin = status.loggedIn
        }
        claudeStatus = status
        Log.info("claude 상태: 설치=\(status.isInstalled) 로그인=\(status.loginKnown ? String(status.loggedIn) : "모름") 계정=\(status.accountLabel ?? "-") 버전=\(status.version ?? "-")", "app")
        refreshModelCatalogIfNeeded(path: path, status: status)
        if recovered {
            noteEngineLoginRecovered()
        }
        return recovered
    }

    /// 다시 로그인한 것을 확인했다. 로그인하라던 안내를 거두고, 된 것을 짧게 알린다.
    func noteEngineLoginRecovered() {
        engineLoginRecoveredAt = Date()
        Log.info("claude 다시 로그인 확인", "app")
        guard banner?.clearsOnEngineLogin == true else { return }
        banner = Banner(kind: .info, message: "Claude Code 에 다시 로그인했습니다. 이어서 리뷰할 수 있습니다.")
    }

    /// 그 시각 뒤로 다시 로그인한 것이 확인됐는가.
    func engineLoginRecovered(after date: Date) -> Bool {
        guard let engineLoginRecoveredAt else { return false }
        return engineLoginRecoveredAt > date
    }

    /// Claude 가 준비돼 있지 않으면 리뷰를 시작할 수 없다.
    var claudeReady: Bool { claudeStatus?.isReady ?? false }

    // MARK: - 모델 목록

    /// CLI 가 알려 준 이름을 입힌 계열 목록. 화면은 `ClaudeModels.all` 대신 이걸 쓴다.
    var modelOptions: [ReviewModelOption] { ClaudeModels.options(catalog: modelCatalog) }

    /// '과거 버전 고르기' 목록 — 계열마다 최신을 뺀 지난 버전과 직접 입력한 이름. Codex 이름(`codex:`)은 뺀다.
    var pastModelOptions: [ReviewModelOption] {
        ClaudeModels.pastOptions(catalog: modelCatalog,
                                 remembered: rememberedModels.filter { ReviewEngineKind(model: $0) == .claude })
    }

    /// Effort 칸의 단계 — CLI 가 `--help` 에 적은 것. 못 읽었으면 기본 단계.
    var effortLevels: [String] { EffortLevel.levels(catalog: modelCatalog) }

    func modelOption(id: String) -> ReviewModelOption? {
        switch ReviewEngineKind(model: id) {
        case .claude: return ClaudeModels.option(id: id, catalog: modelCatalog)
        case .codex: return CodexModels.option(id: id, catalog: codexCatalog)
        }
    }

    /// '모델 이름 직접 입력' 에 쓴 이름을 CLI 에 물은 결과.
    enum CustomModelCheck: Equatable {
        /// CLI 가 아는 모델. 이름은 CLI 가 보여 준 것.
        case known(displayName: String)
        /// CLI 가 모르는 이름 — 받아는 주지만 리뷰가 실패할 수 있다.
        case unknown
        /// 묻지 못했다(Claude Code 가 없거나 응답이 없음).
        case unchecked
    }

    /// 직접 입력한 이름을 CLI 에 묻는다. 토큰을 쓰지 않는다(`ModelProbe`).
    func checkCustomModel(_ name: String) async -> CustomModelCheck {
        guard let status = claudeStatus, status.isInstalled,
              let outcome = await claude.probeModel(alias: name, path: status.path),
              let resolved = outcome.model else { return .unchecked }
        return outcome.recognized ? .known(displayName: resolved.displayName) : .unknown
    }

    /// 이름을 '과거 버전 고르기' 에 남긴다. 씨앗 목록에 있거나 이미 있으면 그대로다.
    func rememberModels(_ ids: [String]) async {
        let next = ClaudeModels.remembering(ids, into: rememberedModels)
        guard next != rememberedModels else { return }
        rememberedModels = next
        await store.save(rememberedModels: next)
    }

    /// CLI 가 바뀌었으면 별칭이 가리키는 모델을 다시 묻는다.
    ///
    /// 새 모델(Opus 5 → 5.5 같은)은 앱 코드가 아니라 **CLI 업데이트로** 들어온다. 앱으로 돌아올
    /// 때마다 여기까지 오므로, 터미널에서 `claude update` 하고 돌아오면 목록이 바로 바뀐다.
    /// 같은 CLI 면 묻지 않는다. 기다리지 않는다 — 켜는 순서(목록 갱신 등)를 붙잡지 않게.
    private func refreshModelCatalogIfNeeded(path: String, status: EngineStatus) {
        guard status.isReady, let version = status.version,
              modelCatalog?.matches(path: path, version: version) != true else { return }
        let attempt = "\(path)|\(version)"
        guard modelProbeAttempt != attempt else { return }
        modelProbeAttempt = attempt
        Task { [weak self] in await self?.probeModels(path: path, version: version) }
    }

    /// 계열 넷 → CLI 가 알려 준 새 계열 → `--help` 의 effort 단계 순으로 묻는다.
    private func probeModels(path: String, version: String) async {
        var models: [String: ResolvedModel] = [:]
        var spentTokens = false
        var available: [String] = []
        // 하나씩 묻는다. 급하지 않고(별칭당 1초 안팎), `claude` 여러 개가 한꺼번에 뜨지 않게 한다.
        for family in ClaudeModels.all {
            guard let outcome = await claude.probeModel(alias: family.id, path: path) else { continue }
            spentTokens = spentTokens || outcome.spentTokens
            if let model = outcome.model { models[family.id] = model }
            if available.isEmpty { available = outcome.availableAliases }
        }
        // 앱이 모르는 계열 — `/model` 이 알려 준 별칭 중 풀어 보니 같은 이름의 계열 모델인 것만 더한다.
        // (`best`·`default`·`opusplan` 처럼 다른 계열을 빌려 쓰는 별칭은 여기서 걸러진다.)
        var extraFamilies: [String] = []
        for alias in available where ClaudeModels.option(id: alias) == nil && !spentTokens {
            guard let outcome = await claude.probeModel(alias: alias, path: path) else { continue }
            spentTokens = spentTokens || outcome.spentTokens
            guard let model = outcome.model, ModelProbe.isFamily(alias: alias, resolvedTo: model) else { continue }
            models[alias] = model
            extraFamilies.append(alias)
        }
        let help = await claude.helpText(path: path)
        let effortLevels = help.map(ModelProbe.effortLevels(inHelp:))
        let summary = (ClaudeModels.all.map(\.id) + extraFamilies)
            .map { "\($0)=\(models[$0]?.modelID ?? "?")" }
            .joined(separator: " ")
        Log.info("모델 확인(claude \(version)): \(summary) · effort=\(effortLevels?.joined(separator: ",") ?? "?")", "app")
        if spentTokens {
            Log.error("모델 확인이 API 를 불렀다(claude \(version)). 이 버전에서는 다시 묻지 않는다", "app")
        }
        let catalog = ModelCatalog(claudePath: path, claudeVersion: version, models: models, checkedAt: Date(),
                                   effortLevels: effortLevels ?? [], extraFamilies: extraFamilies)
        // CLI 업데이트로 계열이 새 버전으로 넘어갔으면 앞 버전을 '과거 버전 고르기' 에 남긴다.
        if let previous = modelCatalog {
            await rememberModels(previous.replacedModels(by: catalog))
        }
        if !models.isEmpty { modelCatalog = catalog }
        // 다 알아냈을 때만 남긴다 — 빠진 게 있으면 다음 실행에 다시 묻는다.
        // 토큰을 썼으면 빠진 게 있어도 남긴다. 같은 버전에서 켤 때마다 또 쓰지 않게.
        let complete = ClaudeModels.all.allSatisfy { models[$0.id] != nil } && effortLevels != nil
        if complete || spentTokens {
            await store.save(modelCatalog: catalog)
        }
    }

    func checkGitHub() async {
        guard !DemoMode.isOn else { return }
        // 설정에 경로 칸이 없으므로 앱이 찾는다. Homebrew 자리가 맥마다 다르다.
        if !FileManager.default.isExecutableFile(atPath: settings.ghPath),
           let discovered = await GitHubClient.discoverPath() {
            settings.ghPath = discovered
            await save()
        }
        githubHosts = await GitHubClient.loggedInHosts(ghPath: settings.ghPath)
        // 설정에 적힌 호스트에 로그인이 없고 다른 호스트 하나만 로그인돼 있으면 그쪽으로 옮긴다.
        // 처음 쓰는 사람이 엔터프라이즈 하나만 붙여 놓고 "왜 아무것도 안 보이지" 하는 걸 막는다.
        if !githubHosts.isEmpty, !githubHosts.contains(where: { $0.name == settings.githubHost }) {
            let pick = githubHosts.first { $0.isActive } ?? githubHosts[0]
            Log.info("gh 호스트 \(settings.githubHost) 에 로그인이 없어 \(pick.name) 로 바꾼다", "app")
            settings.githubHost = pick.name
            await save()
        }
        do {
            githubAccount = try await github.account()
            githubError = nil
            if let account = githubAccount {
                Log.info("gh 계정: \(account.login)@\(settings.githubHost) scopes=\(account.scopes.joined(separator: ","))", "app")
            }
        } catch {
            githubAccount = nil
            githubError = error.localizedDescription
            Log.error("gh 확인 실패: \(error.localizedDescription)", "app")
        }
    }

    // MARK: - 글자 크기 (⌘+ / ⌘- / ⌘0)

    /// 세 가지 크기(코드·UI·코멘트)를 **같이** 움직인다.
    ///
    /// 크기를 배율로 따로 두지 않고 저장값 자체를 바꾸는 이유: 화면 곳곳이
    /// `settings.codeFontSize - 1` 처럼 저장값에서 직접 계산한다. 배율을 FontTheme 안에만
    /// 두면 그 자리들이 배율을 안 타서 글자 크기가 화면마다 어긋난다.
    func changeFontSize(by delta: Double) {
        settings.codeFontSize = (settings.codeFontSize + delta).clamped(to: 9...20)
        settings.uiFontSize = (settings.uiFontSize + delta).clamped(to: 11...22)
        settings.commentFontSize = (settings.commentFontSize + delta).clamped(to: 11...22)
        Task { await save() }
    }

    func resetFontSize() {
        settings.codeFontSize = Settings.default.codeFontSize
        settings.uiFontSize = Settings.default.uiFontSize
        settings.commentFontSize = Settings.default.commentFontSize
        Task { await save() }
    }

    /// 지금이 기본 크기인가. 메뉴의 "기본 크기" 를 흐리게 할지 정하는 데만 쓴다.
    var isDefaultFontSize: Bool {
        settings.codeFontSize == Settings.default.codeFontSize
            && settings.uiFontSize == Settings.default.uiFontSize
            && settings.commentFontSize == Settings.default.commentFontSize
    }

    // MARK: - 업데이트

    /// 켤 때와 **앱으로 돌아올 때** 본다. 켜 둔 채로 쓰는 앱이라, 켤 때만 보면 새 버전이 나와도
    /// 껐다 켜기 전까지 모른다. 돌아올 때마다 gh 를 띄우지 않게 5분 간격을 둔다.
    /// 실패하면 조용히 넘어간다 — 거드는 기능이라 빨간 배너를 띄우면 정작 할 일을 가린다.
    func checkForUpdateIfDue() async {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < Self.updateCheckInterval { return }
        await checkForUpdate()
    }

    static let updateCheckInterval: TimeInterval = 5 * 60

    func checkForUpdate() async {
        guard !DemoMode.isOn else { return }
        guard !isCheckingUpdate, !isUpdating else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        lastUpdateCheck = Date()
        // 지금 버전이 베타인지도 같이 묻는다. 한 번 공개된 버전은 내려가지 않으니 그 뒤로는 묻지 않는다.
        if publishState != .published {
            publishState = await UpdateCheck.publishState(of: UpdateCheck.currentVersion(), ghPath: settings.ghPath)
        }
        guard let release = await UpdateCheck.latest(ghPath: settings.ghPath) else { return }
        guard UpdateCheck.isNewer(release.version, than: UpdateCheck.currentVersion()) else { return }
        if availableUpdate?.version != release.version {
            Log.info("새 버전 v\(release.version) (지금 v\(UpdateCheck.currentVersion()))", "app")
        }
        availableUpdate = release
    }

    /// 창 위에 새 버전 안내 줄을 띄울지. X 로 닫은 버전이면 이번 실행 동안은 숨긴다.
    var showsUpdatePrompt: Bool {
        guard let update = availableUpdate else { return false }
        return update.version != dismissedUpdateVersion
    }

    /// 지금 보는 앱이 어떤 것인가 — 목록 아래 버전 줄(VersionFooter)과 상태 팝오버가 쓴다.
    enum BuildKind { case development, beta, release, unknown }

    /// 베타면 실행 중 Dock·⌘Tab 아이콘을 BETA 띠 그림으로 바꾼다(make-icon.swift 의 AppIconBeta).
    /// 베타와 정식은 같은 파일이라(승격은 zip 을 그대로 옮긴다) 앱 파일 아이콘은 정식 것이다 — 그래서 켜져 있을
    /// 때만 바꿀 수 있다. 개발 빌드는 파일 아이콘 자체가 DEV 띠라(project.yml Debug) 여기서 건드리지 않는다.
    private func applyChannelIcon() {
        guard buildKind == .beta, let image = NSImage(named: "AppIconBeta") else { return }
        NSApp.applicationIconImage = image
    }

    var buildKind: BuildKind {
        #if DEBUG
        // 소스로 빌드한 것(build.sh·install.sh). 버전 번호는 같아도 배포본이 아니다.
        // 데모 모드는 README 캡처용이라 정식판처럼 버전만 보인다.
        return DemoMode.isOn ? .release : .development
        #else
        switch publishState {
        case .published: return .release
        case .unpublished: return .beta
        case .unknown: return .unknown
        }
        #endif
    }

    /// 문제 보고 글(ProblemReport). 종류·횟수·버전만 담는다 — 파일·PR·레포 이름은 넣지 않는다.
    func problemReportText(days: Int = 30) -> String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let channel: String?
        switch buildKind {
        case .development: channel = "개발 빌드"
        case .beta: channel = UpdateCheck.betaNumber().map { "베타 \($0)" } ?? "베타"
        case .release: channel = "정식"
        case .unknown: channel = nil
        }
        let context = ProblemReport.Context(appVersion: UpdateCheck.currentVersion(),
                                            build: build,
                                            channel: channel,
                                            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                            claudeVersion: claudeStatus?.version,
                                            reviewModel: modelOption(id: settings.model)?.label)
        return ProblemReport.text(entries: ProblemLog.shared.entries(), context: context, days: days)
    }

    /// 보고 글을 클립보드에 담는다. 사람이 누를 때만 한다 — 앱이 알아서 어디로 보내지 않는다.
    func copyProblemReport(days: Int = 30) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(problemReportText(days: days), forType: .string)
        banner = Banner(kind: .info, message: "문제 보고를 복사했습니다. 슬랙이나 메신저에 붙여 넣어 보내 주세요.")
    }

    /// 화면에 보일 버전. 베타면 버전 **뒤에** "베타 N" 을 붙여 태그(v0.5.0-beta.3)와 같은 순서로 읽히게 한다
    /// (사용자 결정). 베타끼리는 버전이 같아서 번호가 있어야 어느 베타인지 안다. 번호 없는 예전 베타(0.4.x)는 "베타" 만.
    var versionLabel: String {
        let version = "v\(UpdateCheck.currentVersion())"
        switch buildKind {
        case .beta: return UpdateCheck.betaNumber().map { "\(version) 베타 \($0)" } ?? "\(version) 베타"
        case .development: return "\(version) 개발"
        case .release, .unknown: return version
        }
    }

    /// "v0.5.0 베타 3 (build 312) · 아직 공개 전" 처럼 한 줄로.
    var versionSummary: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let version = "v\(UpdateCheck.currentVersion())"
        switch buildKind {
        case .development: return "\(version) (build \(build)) · 개발 빌드"
        case .beta: return "\(versionLabel) (build \(build)) · 아직 공개 전, 이 맥에서만 보입니다"
        case .release: return "\(version) (build \(build)) · 정식"
        case .unknown: return "\(version) (build \(build))"
        }
    }

    func runUpdate() {
        guard let release = availableUpdate, !isUpdating else { return }
        isUpdating = true
        updateFailure = nil
        Task {
            defer { isUpdating = false }
            do {
                let prepared = try await AppUpdater.prepare(release, ghPath: settings.ghPath)
                try AppUpdater.install(prepared)
                NSApp.terminate(nil)
            } catch {
                Log.error("앱 업데이트 실패 v\(release.version): \(error.localizedDescription)", "app", problem: .updateFailed)
                updateFailure = error.localizedDescription
                banner = Banner(kind: .error, message: error.localizedDescription)
            }
        }
    }

    func openLogFile() {
        NSWorkspace.shared.open(AppPaths.logFile)
    }

    // MARK: - 레포

    func loadRepoOptions() async {
        guard !DemoMode.isOn else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            let result = try await github.viewerRepositories()
            repoOptions = result.repos.filter { !$0.isArchived }
            organizations = result.organizations
            repoListTruncated = result.truncated
            // 볼 레포는 사용자가 고른다. 미리 골라 두지 않는다(쓰는 팀마다 다르다).
        } catch is CancellationError {
            // 취소는 실패가 아니다. `.task` 로 건 조회는 설정 창을 닫거나 탭을 옮기는 순간
            // 뷰와 함께 취소되는데, 그걸 빨간 배너로 띄우면 아무 잘못이 없는데 에러가 뜬다(실측).
        } catch {
            banner = Banner(kind: .error, message: "레포 목록을 불러오지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 레포 검색(서버). 접근 가능한 레포가 수천 개라 전량 열거는 하지 않는다.
    ///
    /// 찾은 것은 `repoOptions` 에 **보태기만** 한다. 지우면 타자를 치는 동안 이미 고른 레포가
    /// 목록에서 사라졌다 나타난다. 화면에 뭘 보여 줄지는 `RepoQuery.matches` 가 정한다.
    func searchRepos(_ query: RepoQuery) async {
        guard !DemoMode.isOn else { return }
        guard let terms = query.searchTerms(knownOwners: organizations) else { return }
        // 타자마다 도는 경로라 같은 말로는 두 번 보내지 않는다(지웠다 다시 쳐도 호출이 쌓인다).
        guard lastRepoSearch != query.raw else { return }
        lastRepoSearch = query.raw
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            var found = try await github.searchRepositories(terms: terms)
            // `org:` 는 개인 계정 레포를 못 잡는다. 정확한 이름을 쳤으면 그 레포만 직접 확인한다.
            if let exact = query.exactRepo,
               !found.contains(where: { $0.repo == exact }),
               let option = try await github.repository(exact) {
                found.insert(option, at: 0)
            }
            var merged = repoOptions
            for option in found where !merged.contains(where: { $0.repo == option.repo }) {
                merged.insert(option, at: 0)
            }
            repoOptions = merged
            // 결과가 없다고 배너를 띄우지 않는다 — 치는 도중에는 안 나오는 게 정상이다.
        } catch is CancellationError {
            // 새 검색어가 들어오면 앞 검색이 취소된다. 에러가 아니다.
            lastRepoSearch = nil
        } catch {
            lastRepoSearch = nil
            banner = Banner(kind: .error, message: "레포 검색 실패: \(error.localizedDescription)")
        }
    }

    /// 목록에 없는 레포를 이름으로 확인해 추가한다.
    func addRepoByName(_ repo: RepoID) async {
        if settings.isWatching(repo) {
            banner = Banner(kind: .info, message: "\(repo.full) 는 이미 선택돼 있습니다.")
            return
        }
        // 꺼 둔 레포면 다시 켠다. 새로 만들면 같은 레포가 두 줄이 된다.
        if settings.config(for: repo) != nil {
            await setRepoWatched(repo, true)
            return
        }
        do {
            guard let option = try await github.repository(repo) else {
                banner = Banner(kind: .warning, message: "\(repo.full) 에 접근할 수 없습니다. 이름과 권한을 확인하세요.")
                return
            }
            if !repoOptions.contains(where: { $0.repo == option.repo }) {
                repoOptions.insert(option, at: 0)
            }
            settings.repos.append(RepoConfig(repo: option.repo,
                                             prTargetBranch: option.defaultBranch ?? "develop"))
            await refreshApprovalThreshold(for: option.repo)
            await save()
        } catch is CancellationError {
            // 창이 닫히면 취소된다. 에러가 아니다.
        } catch {
            banner = Banner(kind: .error, message: "레포 확인 실패: \(error.localizedDescription)")
        }
    }

    /// 레포 체크 — 레포 관리 팝오버·설정 창·온보딩이 함께 쓴다. 끄면 설정은 남기고 조회·알림만 멈춘다
    /// (`Settings.setRepo` 주석). 켜거나 끄는 즉시 목록을 다시 받는다.
    func setRepoWatched(_ repo: RepoID, _ watched: Bool) async {
        let defaultBranch = repoOptions.first { $0.repo == repo }?.defaultBranch
        settings.setRepo(repo, watched: watched, defaultBranch: defaultBranch)
        if !watched { dropUnwatchedPRs() }
        await save()
        // 다시 켠 레포도 승인 수를 새로 읽는다 — 꺼 둔 사이에 브랜치 보호가 바뀌었을 수 있다. 그 레포 하나만 묻는다.
        if watched { await refreshApprovalThreshold(for: repo) }
        await refresh()
    }

    /// 레포를 목록에서 아예 뺀다(체크를 끄는 것과 달리 대상 브랜치·승인 수도 지운다).
    func removeRepo(_ repo: RepoID) async {
        settings.removeRepo(repo)
        dropUnwatchedPRs()
        await save()
        await refresh()
    }

    /// 끈 레포의 PR 을 지금 목록과 탭별 지난 결과에서 바로 뺀다. 다음 조회를 기다리면 끈 레포가 한동안
    /// 그대로 보이고, 전부 끄면 조회 자체를 하지 않아(refresh 의 guard) 영영 남는다.
    private func dropUnwatchedPRs() {
        let watched = Set(settings.enabledRepos.map(\.repo))
        prs.removeAll { !watched.contains($0.repo) }
        for key in listCache.keys {
            listCache[key]?.removeAll { !watched.contains($0.repo) }
        }
    }

    /// 켜 둔 레포만 묻는다. 꺼 둔 레포는 다시 켤 때 그 레포 하나만 읽는다(setRepoWatched).
    func refreshApprovalThresholds() async {
        guard !DemoMode.isOn else { return }
        for config in settings.enabledRepos {
            await refreshApprovalThreshold(for: config.repo)
        }
    }

    /// 이 레포의 브랜치별 Approve 규칙을 읽어 묶고, 지금 쓸 Approve 수를 정한다.
    ///
    /// 쓸 수는 `prTargetBranch` 가 든 묶음의 수다. 설정 메뉴에서 수를 고르면 그 묶음의 대표 브랜치가 거기 들어가므로,
    /// 앱을 켤 때·⌘R·레포를 다시 켤 때 이 함수가 다시 돌아도 고른 수가 되돌아가지 않는다.
    func refreshApprovalThreshold(for repo: RepoID) async {
        guard !DemoMode.isOn else { return }
        guard let config = settings.config(for: repo) else { return }
        // 새 규칙(ruleset)은 브랜치 이름을 알아야 물을 수 있다. 이 레포의 PR 들이 실제로 향하는 브랜치도 같이 묻는다.
        let bases = Set(prs.filter { $0.repo == repo }.map(\.baseRefName)).sorted()
        let read = await github.approvalRules(repo, candidates: [config.prTargetBranch] + bases)
        if let read, !read.rules.isEmpty {
            // 기다리는 동안 레포 목록이 바뀌었을 수 있다. 자리를 다시 찾는다.
            guard let index = settings.repos.firstIndex(where: { $0.repo == repo }) else { return }
            let groups = ApprovalGroups.group(read.rules, defaultBranch: read.defaultBranch)
            let current = settings.repos[index].prTargetBranch
            // 고른(또는 예전에 친) 브랜치가 규칙에 없으면 기본 브랜치의 수로 시작한다 — 오타로 3명에 머물던 것도 여기서 풀린다.
            let chosen = ApprovalGroups.group(containing: current, in: groups)
                ?? read.defaultBranch.flatMap { ApprovalGroups.group(containing: $0, in: groups) }
                ?? groups[0]
            if ApprovalGroups.group(containing: current, in: groups) == nil {
                settings.repos[index].prTargetBranch = ApprovalGroups.representative(of: chosen)
            }
            settings.repos[index].approvalGroups = groups
            settings.repos[index].approvalThreshold = chosen.count
            settings.repos[index].approvalThresholdFromAPI = true
        } else {
            // 규칙이 없거나 못 읽었다. 예전 방식으로 그 브랜치 하나만 한 번 더 물어보고, 그래도 없으면 직접 정한 값(기본 3)을 쓴다.
            // 규칙이 없다고 0명으로 두지 않는다 — 0이면 모든 PR 이 "Approve 가 다 찼다" 로 보여 리뷰 대상에서 빠진다.
            let count = try? await github.requiredApprovals(repo, branch: config.prTargetBranch)
            guard let index = settings.repos.firstIndex(where: { $0.repo == repo }) else { return }
            settings.repos[index].approvalGroups = []
            if let count {
                settings.repos[index].approvalThreshold = count
                settings.repos[index].approvalThresholdFromAPI = true
            } else {
                settings.repos[index].approvalThresholdFromAPI = false
            }
        }
        await save()
    }

    /// GitHub 규칙을 못 읽은 레포의 Approve 수를 사람이 정한다(설정의 레포 줄 "직접 정함").
    /// 예전에는 브랜치마다 수가 다를 때 하나를 골라 모든 PR 에 쓰는 메뉴가 있었는데, 이제 PR 마다 그 PR 이 향하는
    /// 브랜치의 수를 쓰므로(`Settings.approvalThreshold(for: PullRequestInfo)`) 고를 일은 규칙을 못 읽었을 때만 남았다.
    func setManualApprovalThreshold(_ count: Int, for repo: RepoID) {
        guard let index = settings.repos.firstIndex(where: { $0.repo == repo }) else { return }
        settings.repos[index].approvalThreshold = count
        settings.repos[index].approvalThresholdFromAPI = false
        Task { await save() }
    }

    // MARK: - 새로고침

    /// 사람이 누른 새로고침(툴바·⌘R·목록 머리 줄 ↻·빈 화면의 "지금 새로고침"). 받는 동안 목록 머리 줄의 ↻ 가 돈다 —
    /// 2분마다 도는 폴링·탭 이동은 조용히 받는다.
    func refreshByUser() async {
        guard !isUserRefreshing else { return }
        isUserRefreshing = true
        defer { isUserRefreshing = false }
        // 폴링이 받는 중이면 끝나기를 기다렸다가 받는다 — refresh 는 받는 중이면 예약만 걸고 바로 돌아와서, 그대로 부르면
        // ↻ 가 한 번 깜빡이고 멈춘다(예약한 받기는 폴링 쪽이 이어서 돌린다).
        while isRefreshing {
            try? await Task.sleep(for: .milliseconds(150))
        }
        await refresh(reloadThresholds: true)
    }

    /// - Parameter reloadThresholds: 레포의 승인 임계값을 GitHub 에 다시 물어볼지.
    ///   앱을 켤 때와 사람이 새로고침을 누를 때만 참이다. 2분마다 도는 폴링까지 물어보면
    ///   레포 수만큼의 호출이 하루 종일 반복되는데, 브랜치 보호 규칙은 그렇게 자주 바뀌지 않는다.
    func refresh(reloadThresholds: Bool = false) async {
        guard !DemoMode.isOn else { return }
        guard !settings.enabledRepos.isEmpty else {
            // 받을 레포가 없다. 끄기 전에 받아 둔 목록을 남기면 끈 레포의 PR 이 계속 보인다.
            dropUnwatchedPRs()
            return
        }
        if reloadThresholds { await refreshApprovalThresholds() }
        // 필터 변경으로 다시 조회가 필요한 경우가 있으므로 진행 중이면 예약해 둔다.
        if isRefreshing {
            pendingRefresh = true
            return
        }
        await performRefresh()
        // 받는 동안 들어온 요청(탭 이동·필터 변경)은 isRefreshing 을 **내린 뒤에** 돌린다. 예전에는 이 확인이
        // 받는 함수 안(defer 보다 먼저)에 있어서, 다시 부른 refresh 가 "받는 중" 을 보고 또 미뤘다 —
        // 결국 다음 폴링(최대 2분)까지 아무도 돌리지 않아, 탭을 옮겨도 앞 탭 목록이 그대로였다.
        if pendingRefresh {
            pendingRefresh = false
            await refresh()
        }
    }

    /// 받아 온 목록으로 바꾼다.
    ///
    /// 화면에서 바뀌는 행이 있으면 한꺼번에 갈아 끼우지 않고 차례대로 보인다(사용자 선택 2026-10-28, 시안 A "순서대로").
    /// 빠지는 행은 칩이 되어 그 PR 이 이제 있는 탭으로 날아가고(`ApprovalFlight` — 웹에서 Approve 한 것은 Approved,
    /// 머지·닫힘은 All PRs), 마지막 칩이 탭에 닿은 뒤 새 행이 하나씩 위에서부터 펼쳐진다(`View.listRowTransition`).
    /// 예전에는 새 행이 있을 때만 한꺼번에 펼쳤고, 빠지기만 하면 툭 사라져 무엇이 어디로 갔는지 안 보였다.
    ///
    /// `prs` 는 받은 그대로 바로 바꾸고 **화면만** 붙잡아 둔다(`heldForFlight`·`departingRows`·`heldBackArrivals`) —
    /// 알림·캐시·저장은 `prs` 를 보므로 연출 도중에도 받은 목록 그대로다.
    ///
    /// 빠지는 행이 없을 때도(처음 채울 때·뒤 페이지를 받는 중) 새로 보일 행은 위에서부터 차례로 펼친다. 그려 둔 적이
    /// 없는 탭(`baseline` nil)은 처음 채우는 것이라 옅은 바탕은 없다.
    ///
    /// - Parameter isFinal: 다 받았나. 여러 페이지 탭은 뒤 페이지를 받는 동안 지난 목록의 나머지를 남긴다 — 앞 페이지에
    ///   없다고 빠진 것이 아니다(뒤 페이지에 있을 수 있다). 예전에는 첫 페이지가 오는 순간 목록 뒤쪽이 사라졌다가
    ///   다음 페이지에서 돌아왔다. 빠진 것은 다 받은 뒤에야 알고, 차례대로 보이는 것도 그때 한다.
    /// - Parameter pace: 연출 시간 배율. 확인 캡처 때 늘린다(`PRAYER_DEBUG_REFRESH_FLIGHT`).
    private func applyFetched(_ fetched: [PullRequestInfo], baseline: Set<String>?, isFinal: Bool, pace: Double = 1) {
        settleRefreshChoreography()
        var next = fetched
        if !isFinal, baseline != nil {
            let have = Set(next.map(\.id))
            next += prs.filter { !have.contains($0.id) }
            next.sort { $0.createdAt > $1.createdAt }
        }
        let state = filterState
        let shown = visiblePRs
        let listed = next.filter { isListed($0, state: state) }.map(\.id)
        let change = baseline == nil
            ? ListRefreshChange(before: [], after: [])
            : ListRefreshChange(before: shown.map(\.id), after: listed)
        forgetDiffsIfBaseChanged(from: prs, to: next)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // 지난 목록을 보이며 받던 것을 다 받았다 — 목록 머리 줄이 "최신" 을 잠깐 보인다. 빈 목록을 채운 것·그려 둔 적 없는
        // 탭은 "가져오는 중" 이 없었거나 견줄 것이 없다. 여러 페이지 탭은 첫 페이지에서 걷혀(isShowingCachedList) 여기
        // 오지 않는다.
        let endsStaleRefresh = isShowingCachedList && isFinal && baseline != nil && !shown.isEmpty

        guard !change.isEmpty, isFinal, !reduceMotion else {
            // 빠지는 행을 날리지 않는다 — 바뀐 것이 없거나, 처음 채우거나, 아직 뒤 페이지를 받는 중(지난 목록을 남긴다)
            // 이거나, 동작 줄이기가 켜져 있다. 새로 보일 행은 그래도 위에서부터 차례로 펼친다 — 빈 목록을 처음 채울 때·
            // 첫 페이지를 받을 때 한꺼번에 툭 생겨 보였다(사용자 지적 2026-10-29). 첫 행은 바로 펼쳐 빈 행 자리가 그
            // 자리에서 걷힌다.
            let shownIDs = Set(shown.map(\.id))
            let entering = reduceMotion ? [] : listed.filter { !shownIDs.contains($0) }
            let waiting = Array(entering.dropFirst())
            let moves = !change.isEmpty || !entering.isEmpty || (shown.isEmpty && !next.isEmpty)
            withAnimation(moves ? .smooth(duration: 0.3) : nil) {
                prs = next
                // 새 커밋이 올라온 PR 은 다시 볼 일이 생긴 것이라 숨김을 거둔다.
                dismissedPRs = PRVisibility.prunedDismissals(dismissedPRs, prs: next)
                isShowingCachedList = false
                heldBackArrivals = Set(waiting)
                freshPRs.formUnion(change.arrivals.filter { !heldBackArrivals.contains($0) })
                if endsStaleRefresh {
                    staleRefreshCheckedAt = Date()
                }
            }
            if !waiting.isEmpty {
                let glow = !change.arrivals.isEmpty
                refreshChoreography = Task { [weak self] in
                    guard await self?.revealArrivals(waiting, glow: glow, pace: pace) == true else { return }
                    self?.refreshChoreography = nil
                }
            }
            fadeFresh(change.arrivals, pace: pace)
            return
        }

        let flies = ApprovalFlight.applies(to: listScope.kind)
        let fetchedByID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shownByID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let leaving: [DepartingRow] = change.departures.compactMap { id in
            guard let pr = shownByID[id] else { return nil }
            return DepartingRow(pr: pr, to: flies ? ListRefreshChange.destination(of: fetchedByID[id], leaving: listScope) : nil)
        }
        // 받은 목록으로 바꾸되 보이는 행은 그대로 둔다 — 빠질 행은 붙잡고 새 행은 숨긴다. 이 애니메이션으로는 머리 줄이
        // "최신" 으로 바뀌는 것만 움직인다.
        // 빠지는 행이 없으면 첫 새 행은 바로 펼친다 — 다 숨기면 빈 목록이 한 순간 "없습니다" 로 보일 수 있다.
        let waiting = leaving.isEmpty ? Array(change.arrivals.dropFirst()) : change.arrivals
        withAnimation(.easeOut(duration: 0.28 * pace)) {
            prs = next
            dismissedPRs = PRVisibility.prunedDismissals(dismissedPRs, prs: next)
            departingRows = leaving.map(\.pr).filter { fetchedByID[$0.id] == nil }
            refreshHeld = Set(change.departures)
            heldForFlight.formUnion(change.departures)
            heldBackArrivals = Set(waiting)
            freshPRs.formUnion(change.arrivals.filter { !heldBackArrivals.contains($0) })
            isShowingCachedList = false
            if endsStaleRefresh {
                staleRefreshCheckedAt = Date()
            }
        }
        refreshChoreography = Task { [weak self] in
            await self?.playRefreshChoreography(leaving: leaving, arrivals: waiting, glowing: change.arrivals,
                                                large: change.isLarge, pace: pace)
        }
    }

    /// 화면에서 빠지는 행과 그 PR 이 날아갈 탭(nil 이면 제자리에서 접히기만).
    private struct DepartingRow {
        let pr: PullRequestInfo
        let to: PRListScopeKind?
    }

    /// 빠지는 행을 탭으로 날려 보내고, 마지막 칩이 탭에 닿은 뒤 새 행을 하나씩 펼친다(applyFetched).
    ///
    /// 빠지는 행마다 칩을 띄우고 0.14초 뒤(`ApprovalFlight.rowDelay` — 같이 접으면 칩이 어디서 나왔는지 놓친다) 행을
    /// 접는다. 다음 칩은 그 직후에 뜬다. 한꺼번에 많이 바뀌면(`ListRefreshChange.isLarge`) 갈 탭마다 칩 하나로 묶고
    /// 새 행은 간격을 줄여 펼친다(`ListRefreshChange.arrivalCadence`) — 하나씩 하면 1초를 넘겨 오히려 기다림이 길어진다.
    ///
    /// - Parameters:
    ///   - arrivals: 아직 숨겨 둔 새 행(위에서부터).
    ///   - glowing: 옅은 바탕을 잠깐 칠했다 걷을 새 행 전부 — 빠지는 행이 없어 바로 펼친 첫 행도 든다.
    private func playRefreshChoreography(leaving: [DepartingRow], arrivals: [String], glowing: [String], large: Bool,
                                         pace: Double) async {
        /// 기다린다. 그사이 연출이 끝 상태로 넘어갔으면(탭 이동·다음 결과) false.
        func pause(_ seconds: Double) async -> Bool {
            try? await Task.sleep(for: .seconds(seconds * pace))
            return !Task.isCancelled
        }

        var flew = false
        if large {
            for kind in PRListScopeKind.allCases {
                let group = leaving.filter { $0.to == kind }
                guard let first = group.first else { continue }
                approvalFlights.append(ApprovalFlight(prKey: first.pr.id, number: first.pr.number, destination: kind,
                                                      others: group.count - 1, pace: pace))
                flew = true
            }
            if flew {
                guard await pause(ApprovalFlight.rowDelay) else { return }
            }
            releaseDeparting(leaving.map(\.pr.id), pace: pace)
        } else {
            for row in leaving {
                if let kind = row.to {
                    approvalFlights.append(ApprovalFlight(prKey: row.pr.id, number: row.pr.number, destination: kind, pace: pace))
                    flew = true
                }
                guard await pause(ApprovalFlight.rowDelay) else { return }
                releaseDeparting([row.pr.id], pace: pace)
            }
        }

        // 마지막 칩이 탭에 닿은 뒤 새 행을 들인다. 날린 칩이 없으면 접힌 자리가 닫힐 만큼만 기다린다.
        if !leaving.isEmpty, !arrivals.isEmpty {
            guard await pause(flew ? ApprovalFlight.duration - ApprovalFlight.rowDelay + 0.1 : 0.3) else { return }
        }
        guard await revealArrivals(arrivals, glow: true, pace: pace) else { return }

        // 옅은 바탕과 머리 줄의 "최신" 은 잠깐 남겼다가 걷는다.
        guard await pause(1.4) else { return }
        withAnimation(.easeOut(duration: 1.2 * pace)) {
            freshPRs.subtract(glowing)
        }
        withAnimation(.easeInOut(duration: 0.26 * pace)) {
            staleRefreshCheckedAt = nil
        }
        refreshChoreography = nil
    }

    /// 숨겨 둔 새 행을 위에서부터 하나씩 펼친다(`ListRefreshChange.arrivalCadence` — 많으면 간격을 줄이고 화면에 들
    /// 만큼만 차례로, 나머지는 마지막 차례에 같이). 그사이 연출이 끝 상태로 넘어가면(탭 이동·다음 결과) false.
    private func revealArrivals(_ ids: [String], glow: Bool, pace: Double) async -> Bool {
        let cadence = ListRefreshChange.arrivalCadence(count: ids.count)
        for step in 0..<cadence.steps {
            if step > 0 {
                try? await Task.sleep(for: .seconds(cadence.interval * pace))
                guard !Task.isCancelled else { return false }
            }
            let batch = step == cadence.steps - 1 ? Array(ids[step...]) : [ids[step]]
            withAnimation(.smooth(duration: 0.3 * pace)) {
                heldBackArrivals.subtract(batch)
                if glow { freshPRs.formUnion(batch) }
            }
        }
        return true
    }

    /// 붙잡아 둔 빠지는 행을 접는다 — 아래 행들이 미끄러져 올라온다.
    private func releaseDeparting(_ ids: [String], pace: Double) {
        withAnimation(.smooth(duration: 0.3 * pace)) {
            heldForFlight.subtract(ids)
            refreshHeld.subtract(ids)
            departingRows.removeAll { ids.contains($0.id) }
        }
    }

    /// 한꺼번에 들인 새 행의 옅은 바탕과 머리 줄의 "최신" 을 잠깐 뒤 걷는다.
    private func fadeFresh(_ ids: [String], pace: Double) {
        guard !ids.isEmpty || staleRefreshCheckedAt != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6 * pace))
            withAnimation(.easeOut(duration: 1.2 * pace)) {
                self?.freshPRs.subtract(ids)
            }
            withAnimation(.easeInOut(duration: 0.26 * pace)) {
                self?.staleRefreshCheckedAt = nil
            }
        }
    }

    /// 하던 갱신 연출을 끝 상태로 바로 넘긴다 — 탭을 옮기거나 다음 결과가 먼저 오면. 이미 떠난 칩은 마저 날아간다.
    private func settleRefreshChoreography() {
        refreshChoreography?.cancel()
        refreshChoreography = nil
        // 값을 넣기만 해도 화면이 다시 그려지므로, 정리할 것이 없으면 건드리지 않는다.
        guard !refreshHeld.isEmpty || !departingRows.isEmpty || !heldBackArrivals.isEmpty
                || !freshPRs.isEmpty || staleRefreshCheckedAt != nil else { return }
        heldForFlight.subtract(refreshHeld)
        refreshHeld = []
        departingRows = []
        heldBackArrivals = []
        freshPRs = []
        staleRefreshCheckedAt = nil
    }

    #if DEBUG
    /// `PRAYER_DEBUG_REFRESH_FLIGHT` — 데모 목록을 새로 받은 것처럼 바꿔 갱신 연출을 돌린다(아무것도 받지 않는다).
    /// 40분 전에 받은 지난 목록인 것처럼 목록 머리 줄 "가져오는 중 · 오후 2:02 목록" 을 2.5초
    /// 보인 뒤 `DemoData.refreshed` 로 바꾼다. 시간은 `pace` 배.
    /// 실제로 받을 때처럼 다른 탭의 지난 목록도 미리 채운다 — 끝난 뒤 Approved 를 누르면 방금 Approve 한 #131 이 있다.
    ///
    /// `fromEmpty` 면 지난 목록 없이 빈 목록에서 시작해 데모 목록을 처음 받은 것처럼 채운다. `unchanged` 면 받은 것이
    /// 지난 목록과 같다 — 행은 그대로이고 머리 줄이 "최신 · 오후 2:40" 이 된다.
    func debugSimulateRefresh(large: Bool, fromEmpty: Bool, unchanged: Bool, pace: Double) async {
        // 실제 목록은 늘 올린 시각순이다. 데모 목록은 아니라서 먼저 맞춰 둔다 — 안 맞추면 연출 중에 순서가 바뀐다.
        let sorted = prs.sorted { $0.createdAt > $1.createdAt }
        if fromEmpty {
            selectedPRID = nil
            prs = []
            listCache[listScope.storageValue] = nil
            isShowingCachedList = true
            isRefreshing = true
            try? await Task.sleep(for: .seconds(2.5 * pace))
            applyFetched(sorted, baseline: nil, isFinal: true, pace: pace)
            isRefreshing = false
            return
        }
        prs = sorted
        listCache[listScope.storageValue] = sorted
        listFetchedAt[listScope.storageValue] = Date().addingTimeInterval(-40 * 60)
        isShowingCachedList = true
        isRefreshing = true
        try? await Task.sleep(for: .seconds(2.5 * pace))
        let fetched = unchanged ? sorted : DemoData.refreshed(sorted, large: large)
        applyFetched(fetched, baseline: Set(sorted.map(\.id)), isFinal: true, pace: pace)
        listFetchedAt[listScope.storageValue] = Date()
        isRefreshing = false
        seedOtherCaches(with: fetched, from: listScope)
        // 지난번에 2분 전 받은 것으로 친다 — 머지돼 빠진 #126 이 All PRs 에 들어간다.
        seedDeparted(from: sorted, fetched: fetched, since: Date().addingTimeInterval(-120), source: listScope)
    }

    /// 개발 빌드의 "현재 목록 비우기"·"모든 목록 비우기" — 받는 중 화면(빈 행 자리)을 다시 보려고. 지난 목록을
    /// 메모리와 디스크에서 지우고 처음 받는 것처럼 다시 받는다(사용자 요청 2026-10-28).
    func debugClearLists(all: Bool) {
        settleRefreshChoreography()
        let keys = all ? Array(Set(listCache.keys).union(listFetchedAt.keys).union([listScope.storageValue]))
                       : [listScope.storageValue]
        for key in keys {
            listCache[key] = nil
            listFetchedAt[key] = nil
        }
        Task { [store] in await store.removeLists(scopes: all ? nil : keys) }
        prs = []
        isShowingCachedList = true
        Log.info("개발: \(all ? "모든" : "현재") 목록을 비우고 다시 받는다", "app")
        Task { await refresh() }
    }
    #endif

    private func performRefresh() async {
        isRefreshing = true
        // isLoadingMore 도 여기서 함께 내린다. 받는 도중에 탭을 옮기면 아래 guard 가 중간에 끝내는데,
        // 그때 이 깃발이 남아 목록이 영영 "더 받는 중" 을 달고 있었다.
        defer {
            isRefreshing = false
            isLoadingMore = false
        }
        do {
            let repos = settings.enabledRepos.map(\.repo)
            // 한 페이지씩 받아 **오는 대로 그린다.** 30일 탭은 전부 받는 데 40초가 넘게 걸려서
            // (실측) 다 받고 나서 그리면 그동안 빈 화면을 본다.
            //
            // 뒷 페이지가 앞 페이지 위로 끼어들지 않는 것은 서버 정렬(sort:created-desc)과
            // 아래 정렬 기준이 같기 때문이다. 둘 중 하나만 바꾸면 읽는 도중에 목록이 재배열된다.
            let scopeAtStart = listScope
            let limit = listScope.maxResults
            // 받기 전에 이 탭에 그려 둔 목록(지난 목록·앞 조회). 여기 없던 PR 만 "새로 온 것" 으로 보고 펼쳐 넣는다
            // (applyFetched). 그려 둔 적이 없는 탭이면 nil — 처음 채우는 것은 펼치지 않는다.
            let baseline = listCache[scopeAtStart.storageValue] == nil ? nil : Set(prs.map(\.id))
            var collected: [PullRequestInfo] = []
            var cursor: String?
            var pageSize: Int?
            var total: Int?
            var truncated = false
            var pages = 0
            while pages < GitHubClient.searchPageCeiling {
                let slice = try await github.pullRequestSlice(repos: repos,
                                                              scope: scopeAtStart,
                                                              viewerLogin: githubAccount?.login,
                                                              cursor: cursor,
                                                              pageSize: pageSize)
                pages += 1
                // 받는 도중에 탭을 옮겼다면 이 결과는 남의 것이다. 붙이면 목록이 섞인다.
                // 그냥 return 하면 탭을 옮기며 예약한 갱신이 뒤에서 확인되지 않을 수 있어, 예약을 확실히 걸고 끝낸다.
                guard listScope == scopeAtStart else {
                    pendingRefresh = true
                    throw CancellationError()
                }
                collected.append(contentsOf: slice.prs)
                total = slice.totalCount ?? total
                rateRemaining = slice.rateRemaining ?? rateRemaining
                pageSize = slice.nextPageSize

                // 아직 받는 중이라는 것을 목록이 알아야 "필터로 N건 숨김" 을 단정하지 않는다.
                isLoadingMore = slice.hasNextPage && collected.count < limit
                // 뒤가 남았으면 받은 데까지 먼저 그린다. 다 받은 것은 아래에서 한 번에 바꾼다 — 빠진 것은 그때야 안다.
                // 올린 시각(최신 PR 이 위) 기준. 마지막 활동 시각은 행에 함께 보여준다.
                if isLoadingMore {
                    applyFetched(GitHubClient.deduped(collected).sorted { $0.createdAt > $1.createdAt },
                                 baseline: baseline, isFinal: false)
                }
                if pages == 1 {
                    // 이 줄과 아래 "PR 조회" 줄의 시각 차이가 곧 "먼저 그리고 이어 받은" 시간이다.
                    Log.info("첫 페이지 \(collected.count)건 받음\(isLoadingMore ? " — 뒤는 이어 받는 중" : "")", "app")
                }

                guard slice.hasNextPage, let end = slice.endCursor else { break }
                cursor = end
                if collected.count >= limit {
                    truncated = true
                    break
                }
            }
            isLoadingMore = false
            // 승인 탭: GitHub 검색 색인이 승인을 늦게 반영해, 방금 승인한 PR 이 한동안 검색에 안 온다
            // (사용자 피드백 — 방금 승인했는데 승인 탭에 없었다). 이 앱에서 승인한 것이면 따로 받아 합친다.
            if scopeAtStart.requiresMyApproval {
                let extra = await recentlyApprovedMissing(from: collected, windowHours: scopeAtStart.windowHours)
                guard listScope == scopeAtStart else {
                    pendingRefresh = true
                    throw CancellationError()
                }
                if !extra.isEmpty {
                    collected.append(contentsOf: extra)
                    Log.info("승인 탭: 검색에 아직 없는 방금 승인한 PR \(extra.count)건을 따로 받아 합쳤다", "app")
                }
            }
            // 다 받았다 — 빠진 것과 새로 온 것을 차례대로 보인다(applyFetched).
            let fetched = GitHubClient.deduped(collected).sorted { $0.createdAt > $1.createdAt }
            let before = prs
            let fetchedBefore = listFetchedAt[scopeAtStart.storageValue]
            applyFetched(fetched, baseline: baseline, isFinal: true)
            listCache[scopeAtStart.storageValue] = prs
            listFetchedAt[scopeAtStart.storageValue] = Date()
            seedOtherCaches(with: fetched, from: scopeAtStart)
            seedDeparted(from: before, fetched: fetched, since: fetchedBefore, source: scopeAtStart)
            if let total, collected.count < total { truncated = true }
            listTruncated = truncated
            lastRefreshedAt = Date()
            githubError = nil
            pruneDiffCache()
            detectChangesAndNotify()
            // 다음 실행에서 먼저 그릴 목록. 잘린 목록은 저장하지 않는다 —
            // 다음에 켜면 "일부만" 이라는 사실 없이 반쪽 목록이 먼저 보인다.
            if !truncated {
                let cached = Store.CachedList(scope: listScope.storageValue, savedAt: Date(), prs: prs)
                Task { [store] in await store.save(list: cached) }
            }
            consecutiveRefreshFailures = 0
            Log.info("PR 조회 \(prs.count)건 / \(pages)페이지 (전체 \(total.map(String.init) ?? "?"), rate 잔여 \(rateRemaining.map(String.init) ?? "?"))", "app")
            // 처음 고를 때는 **필터된 목록**에서 고른다.
            // 전체 목록(prs)의 첫 번째를 고르면 필터에 걸려 왼쪽에 없는 PR 이 오른쪽에 떠서,
            // 목록에서 찾을 수 없는 것을 보고 있게 된다(실측: 재시작할 때마다 전체 최신 PR 이
            // 떴는데 "내 차례만" 에 걸려 목록에는 없었다). 보이는 것이 없으면 고르지 않는다.
            //
            // 조회(selectedPR)까지 필터를 걸지는 않는다. 보고 있던 PR 을 승인해 목록에서
            // 빠지는 순간 오른쪽이 비어 버린다 — 5초 유예(markLeaving)와도 어긋난다.
            // 통계를 보는 중이면 고르지 않는다 — 고르는 순간 통계가 닫힌다(selectedPRID didSet).
            if selectedPRID == nil, !showingTeamStats { selectedPRID = visiblePRs.first?.id }
        } catch is CancellationError {
            Log.info("PR 조회 취소됨", "app")
        } catch {
            // GitHub 검색은 잠깐 흔들리고 다음 폴링에서 회복되는 일이 많다(실측: 13초간 502).
            // 한 번 실패로 빨간 토스트를 띄우면 소음이라, 연속 2회부터 알린다.
            // 이미 받아 둔 목록은 그대로 두므로 화면이 비지 않는다.
            consecutiveRefreshFailures += 1
            githubError = error.localizedDescription
            Log.error("PR 조회 실패(\(consecutiveRefreshFailures)회 연속): \(error.localizedDescription)", "app",
                      // 한 번 흔들리는 것은 다음 폴링에서 회복된다. 배너를 띄우는 것과 같은 기준(2회 연속)에서만 센다.
                      problem: consecutiveRefreshFailures == 2 ? .refreshFailed : nil)
            if consecutiveRefreshFailures >= 2 {
                banner = Banner(kind: .error,
                                message: "PR 목록을 갱신하지 못했습니다(\(consecutiveRefreshFailures)회 연속): \(error.localizedDescription)")
            }
        }
    }

    /// 이 앱에서 승인했다고 적어 둔다 — 승인 탭 검색이 늦게 따라오는 동안 따로 받아 합치려고.
    ///
    /// Approved·All PRs 탭의 지난 목록에도 방금 Approve 한 모습으로 먼저 넣는다 — 그 탭으로 옮기면 받기 전에도
    /// 보이게(사용자 요청 2026-10-28). 그 탭을 받으면 GitHub 이 준 것으로 바뀐다.
    func noteApproval(repo: RepoID, number: Int) {
        let now = Date()
        recentApprovals["\(repo.full)#\(number)"] = (repo, number, now)
        if let login = githubAccount?.login, let pr = prs.first(where: { $0.repo == repo && $0.number == number }) {
            seedOtherCaches(with: [ListCacheSeeding.approved(pr, by: login, at: now)], from: listScope)
        }
    }

    /// 받은 PR 을 다른 탭의 지난 목록에도 반영한다(`ListCacheSeeding`) — 같은 PR 은 새 정보로 갈아 끼우고, 그 탭의
    /// 검색에 걸릴 PR 은 더한다. 그 탭으로 옮기면 받기 전에도 이미 아는 PR 이 보이고, 받은 뒤에는 새로 온 것만
    /// 펼쳐진다(사용자 요청 2026-10-28).
    ///
    /// 지금 탭은 건드리지 않는다 — 화면의 목록이고 제 조회가 맞춘다. 대상은 지난 목록이 있는 탭과, 종류마다 누르면 열릴
    /// 기간의 탭이다(한 번도 안 본 탭도 미리 채운다). 디스크에는 쓰지 않는다 — 그 탭을 받은 적이 없는데 남기면 다시 켤 때
    /// 받은 지 얼마 안 된 목록으로 잘못 읽히고(isListFresh), 지금 탭을 2분마다 받을 때마다 다른 탭 파일까지 다시 쓴다.
    private func seedOtherCaches(with fetched: [PullRequestInfo], from source: PRListScope) {
        guard !fetched.isEmpty else { return }
        var keys = Set(listCache.keys)
        for kind in PRListScopeKind.allCases {
            keys.insert(scope(for: kind).storageValue)
        }
        keys.remove(listScope.storageValue)
        keys.remove(source.storageValue)
        let now = Date()
        for key in keys {
            guard let target = PRListScope(storageValue: key),
                  let merged = ListCacheSeeding.merge(fetched, into: listCache[key] ?? [], scope: target,
                                                      viewerLogin: githubAccount?.login, now: now) else { continue }
            listCache[key] = merged
        }
    }

    /// 리뷰 대기 탭에서 받은 목록에 없어진 PR(머지·닫힘)을 다른 탭의 지난 목록에 넣는다(`ListCacheSeeding.departed`) —
    /// 칩이 All PRs 로 날아갔는데 그 탭에 없으면 어긋난다. 지난번에 받은 적이 없으면 언제 빠졌는지 몰라 넣지 않는다.
    private func seedDeparted(from before: [PullRequestInfo], fetched: [PullRequestInfo], since: Date?,
                              source: PRListScope) {
        guard source.kind == .open, let since else { return }
        let found = Set(fetched.map(\.id))
        seedOtherCaches(with: ListCacheSeeding.departed(before.filter { !found.contains($0.id) }, since: since),
                        from: source)
    }

    /// 승인 탭 검색에 아직 안 온, 이 앱에서 최근 승인한 PR 을 따로 받는다. 검색에 온 것은 더 들고 있지 않는다.
    func recentlyApprovedMissing(from collected: [PullRequestInfo], windowHours: Int?) async -> [PullRequestInfo] {
        let now = Date()
        let found = Set(collected.map(\.id))
        recentApprovals = recentApprovals.filter { key, value in
            !found.contains(key) && now.timeIntervalSince(value.at) < 30 * 86_400
        }
        let window = Double(windowHours ?? 24) * 3600
        var fetched: [PullRequestInfo] = []
        for item in recentApprovals.values where now.timeIntervalSince(item.at) < window {
            if let pr = try? await github.pullRequest(item.repo, number: item.number) {
                fetched.append(pr)
            }
        }
        return fetched
    }

    /// 알림 클릭 등으로 지정된 PR 을 선택한다. 목록에 없으면 단건 조회해 합친다.
    func select(prKey: String) {
        if prs.contains(where: { $0.id == prKey }) {
            selectedPRID = prKey
            return
        }
        let parts = prKey.split(separator: "#")
        guard parts.count == 2, let repo = RepoID(full: String(parts[0])), let number = Int(parts[1]) else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let fetched = try? await self.github.pullRequest(repo, number: number) {
                if !self.prs.contains(where: { $0.id == fetched.id }) {
                    self.prs.insert(fetched, at: 0)
                }
                self.selectedPRID = fetched.id
            } else {
                self.banner = Banner(kind: .warning,
                                     message: "\(prKey) 를 목록에서 찾지 못했습니다. 필터나 닫힘 상태를 확인하세요.")
            }
        }
    }

    /// 이전 폴링과 비교해 알릴 만한 변화를 찾아 알림을 보낸다.
    func detectChangesAndNotify() {
        let previous = prSnapshots
        let prefs = settings.prChangeNotifications
        let changeSets = PRChangeDetector.changes(previous: previous,
                                                  current: prs,
                                                  approvalThreshold: { [settings] pr in
                                                      settings.approvalThreshold(for: pr)
                                                  },
                                                  lastSeenAt: PRChangeDetector.lastSeen(previous))
        // 교체가 아니라 누적이다. 탭마다 목록이 달라서 교체하면 기억을 잃는다(merged 주석 참고).
        prSnapshots = PRChangeDetector.merged(previous: previous, current: prs)
        Task { [prSnapshots, store] in await store.save(snapshots: prSnapshots) }

        guard hasSnapshotBaseline else {
            // 기준선을 처음 만드는 중이면 알리지 않는다.
            hasSnapshotBaseline = true
            return
        }

        var notifiable: [(PullRequestInfo, PRChange)] = []
        for set in changeSets {
            for change in set.changes where prefs.allows(change) {
                notifiable.append((set.pr, change))
            }
        }
        guard !notifiable.isEmpty else { return }
        Log.info("PR 변화 알림 \(notifiable.count)건", "notify")

        if notifiable.count <= 3 {
            for (pr, change) in notifiable {
                Notifier.prChange(pr: pr, change: change)
            }
        } else {
            // 한꺼번에 많이 바뀌면 알림 폭주 대신 요약 1건.
            Notifier.prChangeSummary(count: notifiable.count)
        }
    }

    /// 메모리 diff 캐시를 현재 head 기준으로 정리한다(무한 증가 방지).
    func pruneDiffCache() {
        let valid = Set(prs.map(diffKey(for:)))
        for key in diffCache.keys where !valid.contains(key) {
            diffCache.removeValue(forKey: key)
            diffCacheOrder.removeAll { $0 == key }
        }
        while diffCacheOrder.count > 8, let oldest = diffCacheOrder.first {
            diffCacheOrder.removeFirst()
            diffCache.removeValue(forKey: oldest)
        }
        exclusionMemo = exclusionMemo.filter { diffCache[$0.key] != nil }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = self?.settings.pollSeconds else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                guard let self else { return }
                if self.isSleeping { continue }
                await self.refresh()
            }
        }
    }

    /// 진행 중인 리뷰의 경과 시간을 초 단위로 다시 그리게 하는 1Hz 시계.
    /// 같은 태스크에서 30초짜리 굵은 시계도 함께 굴린다(타이머를 둘 둘 이유가 없다).
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = Date()
                self.clockTick = now
                // 값을 **바꿀 때만** 구독한 뷰가 다시 그려진다. 매초 바꾸면 목록 전체가
                // 초당 한 번 다시 그려져 스크롤이 무거워진다.
                if now.timeIntervalSince(self.relativeTimeTick) >= Self.relativeTimeInterval {
                    self.relativeTimeTick = now
                }
            }
        }
    }

    /// 앱으로 돌아올 때마다 엔진 로그인 상태와 새 버전을 다시 본다.
    ///
    /// 터미널에서 로그인하고 돌아왔는데 표시등이 그대로 빨갛게 남아 있으면, 로그인이 된 건지
    /// 아닌지 또 헤맨다. 사용자가 "다시 확인" 을 눌러 줄 것을 기대하지 않는다.
    /// `claude auth status` 한 번이라 비용도 거의 없다. 새 버전은 5분 간격으로만 묻는다.
    private func observeActivation() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.checkEngines()
                    await self.checkForUpdateIfDue()
                }
            }
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
        sleepObservers.removeAll()
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSleeping = true
                Log.info("잠자기 진입 — 새 리뷰 투입 중지", "queue")
            }
        })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = false
                Log.info("잠자기 해제", "queue")
                // 잠자기 때문에 워커가 멈췄을 수 있다. 큐에 남은 잡을 반드시 다시 돌린다.
                self.startWorkerIfNeeded()
                Task {
                    await self.refresh()
                    self.startWorkerIfNeeded()
                }
            }
        })
    }

    func refreshNotificationStatus() async {
        notificationStatus = await Notifier.authorizationState()
    }

    /// 사용자가 "알림 켜기" 를 눌렀을 때만 호출한다.
    func enableNotifications() async {
        let granted = await Notifier.requestAuthorizationNow()
        await refreshNotificationStatus()
        if !granted, notificationStatus != .authorized {
            banner = Banner(kind: .warning,
                            message: "알림이 켜지지 않았습니다. 시스템 설정 › 알림 › \(AppInfo.displayName) 에서 허용하세요.",
                            actionTitle: "시스템 설정 열기",
                            action: {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            })
        }
    }

    var notificationsEnabled: Bool {
        notificationStatus == .authorized || notificationStatus == .provisional
    }

    /// 앱 종료 시: 진행 중 자식 프로세스를 내리고 대기 중 초안을 즉시 저장한다.
    func teardown() {
        pollTask?.cancel()
        clockTask?.cancel()
        runningTask?.cancel()
        workerTask?.cancel()
        for task in saveTasks.values { task.cancel() }
        saveTasks.removeAll()
        for record in pendingRecords.values {
            Store.writeSynchronously(record: record)
        }
        pendingRecords.removeAll()
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        Log.info("종료 — 진행 중 리뷰 취소, 초안 저장 완료", "app")
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// 확인 창이 뜬 동안 들고 있을 리뷰 요청.
///
/// PR 을 통째로 들고 있는 이유: 창이 떠 있는 사이에 목록이 갱신돼 `prs` 에서 이 PR 이
/// 빠질 수 있다. 그때 id 만 들고 있으면 "그대로 진행" 이 조용히 아무 일도 하지 않는다.
/// 자동완성 재료를 받는 상태. 실패해도 규칙은 그대로 적을 수 있다 — 자동완성만 빠진다.
enum ExclusionCatalogState: Equatable {
    case idle
    case loading
    /// 받은 때·레포 수·못 받은 레포 수.
    case loaded(at: Date, repos: Int, failed: Int)
    case failed(String)
}

/// PR 스냅샷을 처음 받기 전의 확인. 크기는 창이 열린 뒤 GitHub 에 물어 채운다.
struct PendingSnapshotClone: Identifiable {
    let pr: PullRequestInfo
    /// 예전에 연결해 둔 클론 폴더가 사라졌으면 그 경로 — 창에 한 줄 더 알린다.
    let missingLinkedPath: String?

    var id: String { pr.id }
}

/// 클론 정리 동작 — PR 스냅샷 지우기, 예전에 연결한 내 클론 끊기. 확인 창 문구를 같이 들고 다닌다
/// (설정 창과 레포 관리 팝오버가 같은 말을 쓰게).
struct PendingCloneAction: Identifiable {
    enum Kind { case deleteSnapshot, unlink(path: String) }
    let repo: RepoID
    let kind: Kind
    /// 지울 크기(알고 있으면). 확인 창 문구에 쓴다.
    var size: Int64?

    var id: String { repo.full }

    var title: String {
        switch kind {
        case .deleteSnapshot: return "\(repo.name)의 PR 스냅샷을 지울까요?"
        case .unlink: return "\(repo.name) 클론 폴더 연결을 끊을까요?"
        }
    }

    var message: String {
        switch kind {
        case .deleteSnapshot:
            let amount = size.map { " \(ByteSizeText.short($0))" } ?? ""
            return "받아 둔 코드\(amount)를 지웁니다. 다음에 이 레포를 전체 리뷰하면 다시 클론합니다."
        case .unlink(let path):
            let shown = (path as NSString).abbreviatingWithTildeInPath
            return "폴더(\(shown))는 지우지 않습니다. \(AppInfo.displayName)가 그 옆에 만든 리뷰 폴더만 정리하고, 앞으로 이 레포의 전체 리뷰는 PR 스냅샷으로 합니다."
        }
    }

    var confirmTitle: String {
        if case .unlink = kind { return "연결 끊기" }
        return "지우기"
    }
}

struct PendingLargeReview: Identifiable {
    let pr: PullRequestInfo
    let lines: Int
    let modelOverride: String?
    let effortOverride: String?
    let deep: Bool
    /// 앞 창(빼고 리뷰할까요?)에서 이번만 빼기로 한 파일.
    var skipPaths: [String] = []
    /// 모델을 따로 고르지 않았을 때 실제로 쓸 모델(설정의 기본값).
    let fallbackModel: String

    var id: String { pr.id }
    var number: Int { pr.number }
    var title: String { pr.title }
    var modelID: String { modelOverride ?? fallbackModel }
}

/// 리뷰 버튼을 눌렀는데 한 파일이 1,000줄 넘게 바뀌어 묻는 중인 리뷰(SkipFilesSheet).
struct PendingSkipFiles: Identifiable {
    let pr: PullRequestInfo
    let deep: Bool
    /// 물을 파일들(`SkippableFiles.find`).
    let files: [DiffFile]
    /// 지금 규칙(잠금 파일·제외 경로)을 뺀 뒤의 변경 줄 수.
    let totalLines: Int

    var id: String { pr.id }
    var skippedLines: Int { files.reduce(0) { $0 + $1.changedLines } }
}
