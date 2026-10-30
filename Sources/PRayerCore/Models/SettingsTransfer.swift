import Foundation

// MARK: - 파일

/// 내 설정을 팀원에게 건네는 파일 한 개(JSON).
///
/// 팀원이 같은 레포·같은 규칙으로 시작하려면 설정 화면을 하나씩 따라 쳐야 했다. 그렇다고
/// `settings.json` 을 통째로 건네면 그 맥에서만 맞는 값(claude·gh 경로, 온보딩 상태)과
/// 개인 취향(알림·글꼴)까지 덮인다. 그래서 **항목 단위**로 담고, 받는 쪽이 지금 값과 견줘 보며
/// 고른 것만 들인다(`SettingsTransfer`).
///
/// 계정·토큰은 담을 것이 없다 — 앱이 애초에 저장하지 않는다(gh·claude 로그인을 빌려 쓴다).
public struct SettingsTransferFile: Codable, Equatable, Sendable {
    public static let formatName = "prayer-settings"
    /// 항목을 **더할** 때는 올리지 않는다 — 옛 앱은 모르는 키를 건너뛴다. 같은 키의 뜻이 바뀔 때만
    /// 올린다. 옛 앱은 더 높은 판을 읽지 않는다(뜻을 짐작해 들이면 엉뚱한 값이 들어간다).
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date?
    /// 내보낸 사람의 GitHub 로그인. 받는 쪽 화면에 누구 설정인지 보여 준다.
    public var exportedBy: String?
    public var appVersion: String?
    /// 파일을 텍스트로 열어 본 사람을 위한 안내. 앱은 읽지 않는다.
    public var note: String?
    public var settings: SettingsTransferPayload

    public init(exportedAt: Date?, exportedBy: String?, appVersion: String?, settings: SettingsTransferPayload) {
        format = Self.formatName
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.exportedBy = exportedBy
        self.appVersion = appVersion
        note = "\(AppInfo.displayName) 설정 파일입니다. \(AppInfo.displayName) → 설정 → ‘설정 공유’ 탭 → ‘가져오기…’로 열면 항목을 골라 가져올 수 있습니다. 토큰·로그인 정보는 들어 있지 않습니다."
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, exportedBy, appVersion, note, settings
    }

    /// 머리 정보는 깨져 있어도 넘어간다. 형식 이름과 본문만 있으면 읽는다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        exportedAt = try? c.decodeIfPresent(Date.self, forKey: .exportedAt)
        exportedBy = try? c.decodeIfPresent(String.self, forKey: .exportedBy)
        appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        settings = try c.decode(SettingsTransferPayload.self, forKey: .settings)
    }
}

/// 파일에 담기는 설정. 모든 칸이 선택이다 — 내보낼 때 고른 것만 채운다.
///
/// `Settings` 를 그대로 쓰지 않는 이유: 앱 안의 이름·모양이 바뀌어도 이미 건넨 파일은 읽혀야 한다.
/// 사람이 열어 봐도 읽히게 레포는 `owner/name` 한 줄로 적는다.
public struct SettingsTransferPayload: Codable, Equatable, Sendable {
    public struct Repo: Codable, Equatable, Sendable {
        /// `owner/name`.
        public var repo: String
        public var prTargetBranch: String
        public var approvalThreshold: Int
        /// 승인 기준을 GitHub 브랜치 보호에서 읽었는가. 받는 쪽도 다시 읽으므로 참이면 숫자는
        /// 참고값이다(브랜치 보호를 못 읽는 사람에게만 처음 값이 된다).
        public var approvalThresholdFromGitHub: Bool

        public init(repo: String, prTargetBranch: String, approvalThreshold: Int, approvalThresholdFromGitHub: Bool) {
            self.repo = repo
            self.prTargetBranch = prTargetBranch
            self.approvalThreshold = approvalThreshold
            self.approvalThresholdFromGitHub = approvalThresholdFromGitHub
        }

        enum CodingKeys: String, CodingKey {
            case repo, prTargetBranch, approvalThreshold, approvalThresholdFromGitHub
        }

        /// 레포 이름만 있으면 읽는다. 사람이 손으로 고친 파일에서 칸 하나가 빠졌다고 레포를 버리지 않는다.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repo = try c.decode(String.self, forKey: .repo)
            prTargetBranch = (try? c.decodeIfPresent(String.self, forKey: .prTargetBranch)) ?? "develop"
            approvalThreshold = (try? c.decodeIfPresent(Int.self, forKey: .approvalThreshold)) ?? 3
            approvalThresholdFromGitHub = (try? c.decodeIfPresent(Bool.self, forKey: .approvalThresholdFromGitHub)) ?? false
        }
    }

    public struct ReviewModel: Codable, Equatable, Sendable {
        public var model: String
        /// 빈 문자열 = `--effort` 를 넘기지 않음(CLI 기본값).
        public var effort: String
        public init(model: String, effort: String) {
            self.model = model
            self.effort = effort
        }
    }

    /// 예전 파일의 "전체 리뷰(워크트리) 켜 둘지". 전체 리뷰를 켜고 끄는 스위치를 없애서(Settings 주석) 이제
    /// 내보내지 않고, 받은 파일에 있어도 가져오기 목록에 보이지 않고 적용하지 않는다 — 옛 파일을 읽다가 깨지지 않게
    /// 꼴만 남겨 둔다.
    public struct DeepReview: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var model: String
        public var effort: String
        public init(enabled: Bool, model: String, effort: String) {
            self.enabled = enabled
            self.model = model
            self.effort = effort
        }
    }

    /// 예전 파일의 "게시하는 글에 👥 를 붙일지"(`aiAttribution`)와 코멘트 수·길이 칸. 끝 표기를 없애서(Settings 주석)
    /// 이제 내보내지 않고, 받은 파일에 있어도 가져오기 목록에 보이지 않고 적용하지 않는다 — 옛 파일을 읽다가 깨지지 않게
    /// 꼴만 남겨 둔다.
    public struct CommentStyle: Codable, Equatable, Sendable {
        public var maxComments: Int
        public var maxCommentChars: Int
        public var aiAttribution: Bool
        public init(maxComments: Int, maxCommentChars: Int, aiAttribution: Bool) {
            self.maxComments = maxComments
            self.maxCommentChars = maxCommentChars
            self.aiAttribution = aiAttribution
        }
    }

    // 게시 기본값(postDefaults: 리뷰 종류·완전허용이면 Approve)은 설정에서 없앴다. 옛 파일에 있으면 읽지 않는다.
    // 팀 규칙(teamRules)·통째로 바꾸던 리뷰 가이드(reviewGuide)도 앱에서 뺐다(ResourceLoader.guide 주석). 마찬가지로 읽지 않는다.

    public struct SizeLimits: Codable, Equatable, Sendable {
        /// 이 줄 수를 넘으면 ‘큼’ 표시.
        public var largeLines: Int
        /// 이 줄 수를 넘으면 리뷰 전에 한 번 더 묻는다.
        public var warnLines: Int
        public init(largeLines: Int, warnLines: Int) {
            self.largeLines = largeLines
            self.warnLines = warnLines
        }
    }

    public struct ReviewNotifications: Codable, Equatable, Sendable {
        public var done: Bool
        public var failure: Bool
        public init(done: Bool, failure: Bool) {
            self.done = done
            self.failure = failure
        }
    }

    /// 빈 이름 = 시스템 글꼴.
    public struct Fonts: Codable, Equatable, Sendable {
        public var code: String
        public var codeSize: Double
        public var comment: String
        public var commentSize: Double
        public var ui: String
        public var uiSize: Double
        public init(code: String, codeSize: Double, comment: String, commentSize: Double, ui: String, uiSize: Double) {
            self.code = code
            self.codeSize = codeSize
            self.comment = comment
            self.commentSize = commentSize
            self.ui = ui
            self.uiSize = uiSize
        }
    }

    public var githubHost: String?
    public var repos: [Repo]?
    /// `owner/name` → 로컬 클론 경로. **읽기만 하고 들이지도, 담지도 않는다** — 전체 리뷰 클론은 이제 앱이 PRayer
    /// 폴더에 PR 스냅샷으로 받아 고를 게 없다(ReviewClone, 2026-10-06). 예전 파일을 읽을 때 깨진 칸으로
    /// 보이지 않게 칸만 남긴다.
    public var clonePaths: [String: String]?
    public var hiddenLabels: [String]?
    public var ignoredAuthors: [String]?
    public var abbreviateMemberNames: Bool?
    public var memberNicknames: [String: String]?
    public var reviewModel: ReviewModel?
    public var deepReview: DeepReview?
    public var commentStyle: CommentStyle?
    public var excludedPathPatterns: [String]?
    public var sizeLimits: SizeLimits?
    public var fiveHourTokenCap: Int?
    public var reviewNotifications: ReviewNotifications?
    public var prChangeNotifications: PRChangeNotificationPrefs?
    public var pollSeconds: Int?
    public var fonts: Fonts?

    /// 읽다가 깨져 있어 버린 칸의 키(같은 키가 여러 번 나오면 그만큼 버린 것). 파일에는 쓰지 않는다.
    public var unreadableKeys: [String] = []

    public init() {}

    public var isEmpty: Bool {
        githubHost == nil && repos == nil && hiddenLabels == nil && ignoredAuthors == nil
            && abbreviateMemberNames == nil && memberNicknames == nil && reviewModel == nil && deepReview == nil
            && commentStyle == nil && excludedPathPatterns == nil
            && sizeLimits == nil && fiveHourTokenCap == nil && reviewNotifications == nil
            && prChangeNotifications == nil && pollSeconds == nil && fonts == nil
    }

    enum CodingKeys: String, CodingKey {
        case githubHost, repos, clonePaths, hiddenLabels, ignoredAuthors
        case abbreviateMemberNames, memberNicknames
        case reviewModel, deepReview, commentStyle
        case excludedPathPatterns, sizeLimits, fiveHourTokenCap
        case reviewNotifications, prChangeNotifications, pollSeconds, fonts
    }

    /// 칸 하나가 깨졌다고 파일 전체를 버리지 않는다. 깨진 칸은 `unreadableKeys` 에 적고 넘어간다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var broken: [String] = []
        func v<T: Decodable>(_ key: CodingKeys) -> T? {
            do {
                return try c.decodeIfPresent(T.self, forKey: key)
            } catch {
                broken.append(key.stringValue)
                return nil
            }
        }
        githubHost = v(.githubHost)
        // 레포는 하나씩 살린다 — 한 줄이 깨졌다고 나머지 레포까지 버리면 고를 것이 사라진다.
        if let list: [Lossy<Repo>] = v(.repos) {
            repos = list.compactMap(\.value)
            for _ in 0..<(list.count - (repos?.count ?? 0)) { broken.append(CodingKeys.repos.stringValue) }
        }
        clonePaths = v(.clonePaths)
        hiddenLabels = v(.hiddenLabels)
        ignoredAuthors = v(.ignoredAuthors)
        abbreviateMemberNames = v(.abbreviateMemberNames)
        memberNicknames = v(.memberNicknames)
        reviewModel = v(.reviewModel)
        deepReview = v(.deepReview)
        commentStyle = v(.commentStyle)
        excludedPathPatterns = v(.excludedPathPatterns)
        sizeLimits = v(.sizeLimits)
        fiveHourTokenCap = v(.fiveHourTokenCap)
        reviewNotifications = v(.reviewNotifications)
        prChangeNotifications = v(.prChangeNotifications)
        pollSeconds = v(.pollSeconds)
        fonts = v(.fonts)
        unreadableKeys = broken
    }
}

/// 원소 하나가 깨져도 배열을 끝까지 읽게 하는 껍데기. 이 init 은 던지지 않아서 배열 해독이 멈추지 않는다.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - 화면에 그릴 목록

/// 고를 수 있는 항목 한 줄. 레포·로컬 클론처럼 여럿을 하나씩 고르는 것은 `children` 으로 묶는다.
public struct TransferItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 내보내기 — 담을 수 있다.
        case export
        /// 가져오기 — 내 설정에 없던 것을 더한다.
        case added
        /// 가져오기 — 내 값이 바뀐다.
        case changed
        /// 가져오기 — 지금 값과 같다. 고를 것이 없다.
        case same
    }

    public var id: String
    public var title: String
    /// 무엇을 하는 설정인지. 묶음 안의 줄(레포 하나)은 비워 두고 묶음이 설명한다.
    public var detail: String
    /// 담을 값(내보내기) 또는 가져올 값(가져오기)을 한 줄로.
    public var value: String
    /// 가져오기 — 지금 내 값. 새로 더하는 것이면 nil.
    public var current: String?
    public var status: Status
    /// 고르기 전에 알아야 할 것(이 맥에 없는 폴더 등).
    public var note: String?
    public var selectedByDefault: Bool
    public var children: [TransferItem]

    public var isSelectable: Bool { status != .same }
    /// 실제로 고르는 단위. 묶음이면 그 안의 줄들, 아니면 자기 자신.
    public var leaves: [TransferItem] { children.isEmpty ? [self] : children }
}

/// 설정 창의 탭과 같은 갈래로 나눈 묶음.
public struct TransferSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// 이 묶음이 무엇이고 설정 창 어디에 있는지.
    public var summary: String
    public var items: [TransferItem]

    public var leaves: [TransferItem] { items.flatMap(\.leaves) }
}

extension Array where Element == TransferSection {
    /// 처음 열었을 때 골라 둘 항목.
    public var defaultSelection: Set<String> {
        Set(flatMap(\.leaves).filter { $0.isSelectable && $0.selectedByDefault }.map(\.id))
    }

    /// 고를 수 있는 항목 전부("모두 고르기").
    public var selectableIDs: Set<String> {
        Set(flatMap(\.leaves).filter(\.isSelectable).map(\.id))
    }
}

public enum SettingsTransferError: LocalizedError, Equatable {
    case notSettingsFile
    case newerVersion(Int)
    case nothingToImport
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notSettingsFile:
            return "\(AppInfo.displayName) 설정 파일이 아닙니다. \(AppInfo.displayName) 의 ‘내보내기…’로 만든 .json 파일을 고르세요."
        case .newerVersion(let version):
            return "더 새 \(AppInfo.displayName) 에서 만든 파일입니다(형식 \(version)판). 앱을 업데이트한 뒤 다시 여세요."
        case .nothingToImport:
            return "이 파일에는 가져올 수 있는 항목이 없습니다."
        case .tooLarge:
            return "파일이 너무 큽니다. \(AppInfo.displayName) 설정 파일이 맞는지 확인하세요."
        }
    }
}

// MARK: - 내보내기·가져오기

public enum SettingsTransfer {
    /// 가져오는 맥의 사정. 받은 값이 이 맥에서 쓸 수 있는지 견주는 데 쓴다.
    public struct ImportEnvironment: Sendable {
        public var home: String
        /// gh 가 로그인돼 있는 호스트. 비어 있으면 아직 모르는 것이라 경고하지 않는다.
        public var loggedInHosts: [String]
        public var fontAvailable: @Sendable (String) -> Bool

        public init(home: String, loggedInHosts: [String],
                    fontAvailable: @escaping @Sendable (String) -> Bool) {
            self.home = home
            self.loggedInHosts = loggedInHosts
            self.fontAvailable = fontAvailable
        }
    }

    public struct ReadResult: Equatable, Sendable {
        public var file: SettingsTransferFile
        /// 형식이 맞지 않아 건너뛴 값. 화면에 그대로 보여 준다 — 말없이 버리면 "왜 그 레포가 없지" 가 된다.
        public var skipped: [String]
    }

    public struct ApplyResult: Equatable, Sendable {
        public var settings: Settings
        /// 실제로 바뀐 항목을 사람이 읽는 말로.
        public var applied: [String]
        public var addedRepos: [RepoID]
        public var updatedRepos: [RepoID]
        public var hostChanged: Bool
    }

    /// 받는 파일 크기 상한. 예전 파일에 리뷰 가이드가 담겨 있어도 수백 KB 를 넘지 않는다(읽지는 않는다).
    public static let maxFileBytes = 2_000_000

    // MARK: 항목 이름

    /// 고르는 단위의 이름. 화면의 선택 집합과 `apply` 가 이 이름으로 말한다.
    public enum ID {
        public static let repos = "repos"
        public static func repo(_ full: String) -> String { "repo:\(full)" }
        public static let githubHost = "githubHost"
        public static let hiddenLabels = "hiddenLabels"
        public static let ignoredAuthors = "ignoredAuthors"
        public static let abbreviateMemberNames = "abbreviateMemberNames"
        public static let memberNicknames = "memberNicknames"
        public static let reviewModel = "reviewModel"
        public static let excludedPathPatterns = "excludedPathPatterns"
        public static let sizeLimits = "sizeLimits"
        public static let fiveHourTokenCap = "fiveHourTokenCap"
        public static let reviewNotifications = "reviewNotifications"
        public static let prChangeNotifications = "prChangeNotifications"
        public static let pollSeconds = "pollSeconds"
        public static let fonts = "fonts"
    }

    /// 고른 레포 중 내 목록에 아직 없는 것 — 가져오기 전에 내 계정으로 보이는지 확인할 대상.
    public static func newRepos(_ p: SettingsTransferPayload, selected: Set<String>, current: Settings) -> [RepoID] {
        (p.repos ?? []).compactMap { repo in
            guard selected.contains(ID.repo(repo.repo)),
                  !current.repos.contains(where: { sameRepo($0.repo.full, repo.repo) }) else { return nil }
            return RepoID(full: repo.repo)
        }
    }

    /// 항목 제목. 화면·건너뛴 값 안내·적용 결과가 같은 말을 쓰게 한 곳에 둔다(앱은 적용 결과에서 항목을 뺄 때 쓴다).
    public static func title(forKey key: String) -> String {
        switch key {
        case ID.repos: return "리뷰할 레포"
        case ID.githubHost: return "GitHub 호스트"
        case ID.hiddenLabels: return "숨길 라벨"
        case ID.ignoredAuthors: return "숨길 사람"
        case ID.abbreviateMemberNames: return "이름 짧게 보이기"
        case ID.memberNicknames: return "직접 붙인 표시 이름"
        case ID.reviewModel: return "리뷰 모델"
        case ID.excludedPathPatterns: return "제외 경로"
        case ID.sizeLimits: return "크기 기준"
        case ID.fiveHourTokenCap: return "5시간 토큰 상한"
        case ID.reviewNotifications: return "AI 리뷰 알림"
        case ID.prChangeNotifications: return "PR 변화 알림"
        case ID.pollSeconds: return "갱신 주기"
        case ID.fonts: return "글꼴과 크기"
        default: return key
        }
    }

    // MARK: 내보내기

    /// 내보낼 수 있는 것 전부. 고르기 전의 원본이다.
    ///
    /// 담지 않는 것: claude·gh 실행 파일 경로와 온보딩 상태(그 맥에서만 맞는 값), 화면에 고치는 칸이
    /// 없는 내부 값(요약 길이 상한 등). 빈 목록은 담지 않는다 — 받는 쪽에서 할 일이 없다.
    public static func payload(from settings: Settings, home: String) -> SettingsTransferPayload {
        var p = SettingsTransferPayload()
        p.githubHost = settings.githubHost
        // 켜 둔 레포만 담는다. 끈 레포까지 담으면 받는 쪽에서는 켜진 채로 들어간다(받은 레포는 켜서 넣는다).
        if !settings.enabledRepos.isEmpty {
            p.repos = settings.enabledRepos.map {
                SettingsTransferPayload.Repo(repo: $0.repo.full,
                                             prTargetBranch: $0.prTargetBranch,
                                             approvalThreshold: $0.approvalThreshold,
                                             approvalThresholdFromGitHub: $0.approvalThresholdFromAPI)
            }
        }
        // 로컬 클론 경로는 담지 않는다 — 받는 쪽은 PR 스냅샷을 앱이 알아서 받는다(clonePaths 주석).
        if !settings.hiddenLabels.isEmpty { p.hiddenLabels = settings.hiddenLabels }
        if !settings.ignoredAuthors.isEmpty { p.ignoredAuthors = settings.ignoredAuthors }
        p.abbreviateMemberNames = settings.abbreviateMemberNames
        if !settings.memberNicknames.isEmpty { p.memberNicknames = settings.memberNicknames }
        p.reviewModel = .init(model: settings.model, effort: settings.effort)
        if !settings.excludedPathPatterns.isEmpty { p.excludedPathPatterns = settings.excludedPathPatterns }
        p.sizeLimits = .init(largeLines: settings.autoSizeCapLines, warnLines: settings.manualSizeWarnLines)
        p.fiveHourTokenCap = settings.fiveHourTokenCap
        p.reviewNotifications = .init(done: settings.notifyOnReviewDone, failure: settings.notifyOnFailure)
        p.prChangeNotifications = settings.prChangeNotifications
        p.pollSeconds = settings.pollSeconds
        p.fonts = .init(code: settings.codeFontName, codeSize: settings.codeFontSize,
                        comment: settings.commentFontName, commentSize: settings.commentFontSize,
                        ui: settings.uiFontName, uiSize: settings.uiFontSize)
        return p
    }

    /// 내보내기 화면에 그릴 목록.
    public static func exportSections(_ settings: Settings, home: String) -> [TransferSection] {
        sections(payload(from: settings, home: home), current: nil, environment: nil)
    }

    /// 고른 항목만 담은 파일.
    public static func makeFile(_ settings: Settings, selected: Set<String>, home: String,
                                exportedBy: String?, appVersion: String?, now: Date) -> SettingsTransferFile {
        let full = payload(from: settings, home: home)
        return SettingsTransferFile(exportedAt: now, exportedBy: exportedBy, appVersion: appVersion,
                                    settings: filtered(full, selected: selected))
    }

    static func filtered(_ p: SettingsTransferPayload, selected: Set<String>) -> SettingsTransferPayload {
        func pick<T>(_ id: String, _ value: T?) -> T? { selected.contains(id) ? value : nil }
        var out = SettingsTransferPayload()
        out.githubHost = pick(ID.githubHost, p.githubHost)
        let repos = (p.repos ?? []).filter { selected.contains(ID.repo($0.repo)) }
        out.repos = repos.isEmpty ? nil : repos
        out.hiddenLabels = pick(ID.hiddenLabels, p.hiddenLabels)
        out.ignoredAuthors = pick(ID.ignoredAuthors, p.ignoredAuthors)
        out.abbreviateMemberNames = pick(ID.abbreviateMemberNames, p.abbreviateMemberNames)
        out.memberNicknames = pick(ID.memberNicknames, p.memberNicknames)
        out.reviewModel = pick(ID.reviewModel, p.reviewModel)
        out.excludedPathPatterns = pick(ID.excludedPathPatterns, p.excludedPathPatterns)
        out.sizeLimits = pick(ID.sizeLimits, p.sizeLimits)
        out.fiveHourTokenCap = pick(ID.fiveHourTokenCap, p.fiveHourTokenCap)
        out.reviewNotifications = pick(ID.reviewNotifications, p.reviewNotifications)
        out.prChangeNotifications = pick(ID.prChangeNotifications, p.prChangeNotifications)
        out.pollSeconds = pick(ID.pollSeconds, p.pollSeconds)
        out.fonts = pick(ID.fonts, p.fonts)
        return out
    }

    public static func encode(_ file: SettingsTransferFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    /// "PRView-설정-riley-2026-10-01.json". 받는 쪽 다운로드 폴더에서 누구 것인지 보이게 로그인을 넣는다.
    public static func suggestedFileName(exportedBy: String?, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let who = exportedBy.flatMap { Check.login($0) ? "-\($0)" : nil } ?? ""
        return "\(AppInfo.displayName)-설정\(who)-\(date).json"
    }

    // MARK: 가져오기

    /// 받은 파일을 읽는다. 남이 만든(또는 손으로 고친) 파일이므로 값마다 화면에서 고를 수 있는 범위로
    /// 다시 확인한다. 범위를 벗어난 숫자는 범위 끝으로 맞추고, 꼴이 틀린 값은 버리고 그 사실을 적는다.
    public static func read(_ data: Data) throws -> ReadResult {
        guard data.count <= maxFileBytes else { throw SettingsTransferError.tooLarge }
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == SettingsTransferFile.formatName else {
            throw SettingsTransferError.notSettingsFile
        }
        if let version = header.version, version > SettingsTransferFile.currentVersion {
            throw SettingsTransferError.newerVersion(version)
        }
        let raw: SettingsTransferFile
        do {
            raw = try decoder.decode(SettingsTransferFile.self, from: data)
        } catch {
            throw SettingsTransferError.notSettingsFile
        }
        var skipped = unreadableMessages(raw.settings.unreadableKeys)
        var file = raw
        file.settings = sanitized(raw.settings, skipped: &skipped)
        file.exportedBy = raw.exportedBy.flatMap { Check.login($0) ? $0 : nil }
        file.appVersion = raw.appVersion.flatMap { Check.version($0) ? $0 : nil }
        guard !file.settings.isEmpty else { throw SettingsTransferError.nothingToImport }
        return ReadResult(file: file, skipped: skipped)
    }

    /// 가져오기 화면에 그릴 목록. 지금 값과 견줘 같으면 고를 수 없게 둔다.
    public static func importSections(_ payload: SettingsTransferPayload, current: Settings,
                                      environment: ImportEnvironment) -> [TransferSection] {
        sections(payload, current: current, environment: environment)
    }

    /// 고른 항목만 반영한 새 설정. 목록(라벨·사람·제외 경로)은 **합친다** — 받은 파일에 없다고
    /// 내 것을 지우지 않는다. 레포도 더하거나 고칠 뿐 빼지 않는다.
    public static func apply(_ p: SettingsTransferPayload, selected: Set<String>, to settings: Settings,
                             environment: ImportEnvironment) -> ApplyResult {
        var s = settings
        var applied: [String] = []
        var addedRepos: [RepoID] = []
        var updatedRepos: [RepoID] = []
        var hostChanged = false

        if selected.contains(ID.githubHost), let host = p.githubHost, host != s.githubHost {
            s.githubHost = host
            hostChanged = true
            applied.append("\(title(forKey: ID.githubHost)) \(host)")
        }

        for repo in p.repos ?? [] where selected.contains(ID.repo(repo.repo)) {
            guard let id = RepoID(full: repo.repo) else { continue }
            if let index = s.repos.firstIndex(where: { sameRepo($0.repo.full, repo.repo) }) {
                let before = s.repos[index]
                s.repos[index].prTargetBranch = repo.prTargetBranch
                // 꺼 둔 레포를 골라 가져오면 켠다(가져오기 화면이 "꺼 둠" 을 바뀜으로 보여 준다).
                s.repos[index].enabled = true
                // GitHub 에서 읽은 값이면 받는 쪽도 다시 읽는다. 내 쪽 숫자를 남의 숫자로 덮지 않는다.
                if !repo.approvalThresholdFromGitHub {
                    s.repos[index].approvalThreshold = repo.approvalThreshold
                    s.repos[index].approvalThresholdFromAPI = false
                }
                if s.repos[index] != before { updatedRepos.append(s.repos[index].repo) }
            } else {
                // 처음 값은 보낸 사람의 것을 쓴다. 브랜치 보호를 못 읽는 사람에게는 그 값이 그대로 남는다.
                s.repos.append(RepoConfig(repo: id, prTargetBranch: repo.prTargetBranch,
                                          approvalThreshold: repo.approvalThreshold,
                                          approvalThresholdFromAPI: false, enabled: true))
                addedRepos.append(id)
            }
        }
        if !addedRepos.isEmpty || !updatedRepos.isEmpty {
            let parts = [addedRepos.isEmpty ? nil : "\(addedRepos.count)개 추가",
                         updatedRepos.isEmpty ? nil : "\(updatedRepos.count)개 변경"].compactMap { $0 }
            applied.append("\(title(forKey: ID.repos)) \(parts.joined(separator: " · "))")
        }

        if selected.contains(ID.hiddenLabels), let labels = p.hiddenLabels {
            let added = additions(labels, to: s.hiddenLabels, caseInsensitive: true)
            if !added.isEmpty {
                s.hiddenLabels += added
                applied.append("\(title(forKey: ID.hiddenLabels)) \(added.count)개 추가")
            }
        }
        if selected.contains(ID.ignoredAuthors), let authors = p.ignoredAuthors {
            let added = additions(authors, to: s.ignoredAuthors, caseInsensitive: true)
            if !added.isEmpty {
                s.ignoredAuthors += added
                applied.append("\(title(forKey: ID.ignoredAuthors)) \(added.count)명 추가")
            }
        }
        if selected.contains(ID.abbreviateMemberNames), let value = p.abbreviateMemberNames,
           value != s.abbreviateMemberNames {
            s.abbreviateMemberNames = value
            applied.append(title(forKey: ID.abbreviateMemberNames))
        }
        if selected.contains(ID.memberNicknames), let names = p.memberNicknames {
            let changed = names.filter { s.memberNicknames[$0.key] != $0.value }
            if !changed.isEmpty {
                s.memberNicknames.merge(changed) { _, new in new }
                applied.append("\(title(forKey: ID.memberNicknames)) \(changed.count)명")
            }
        }

        func set<T: Equatable>(_ id: String, _ value: T?, _ keyPath: WritableKeyPath<Settings, T>) -> Bool {
            guard selected.contains(id), let value, s[keyPath: keyPath] != value else { return false }
            s[keyPath: keyPath] = value
            return true
        }

        if selected.contains(ID.reviewModel), let m = p.reviewModel, m != .init(model: s.model, effort: s.effort) {
            s.model = m.model
            s.effort = m.effort
            applied.append(title(forKey: ID.reviewModel))
        }
        if selected.contains(ID.excludedPathPatterns), let patterns = p.excludedPathPatterns {
            // 경로 패턴은 대소문자를 가린다(`*.Swift` 와 `*.swift` 는 다른 파일을 고른다).
            let added = additions(patterns, to: s.excludedPathPatterns, caseInsensitive: false)
            if !added.isEmpty {
                s.excludedPathPatterns += added
                applied.append("\(title(forKey: ID.excludedPathPatterns)) \(added.count)개 추가")
            }
        }
        if selected.contains(ID.sizeLimits), let l = p.sizeLimits,
           l != .init(largeLines: s.autoSizeCapLines, warnLines: s.manualSizeWarnLines) {
            s.autoSizeCapLines = l.largeLines
            s.manualSizeWarnLines = l.warnLines
            applied.append(title(forKey: ID.sizeLimits))
        }
        if set(ID.fiveHourTokenCap, p.fiveHourTokenCap, \.fiveHourTokenCap) {
            applied.append(title(forKey: ID.fiveHourTokenCap))
        }
        if selected.contains(ID.reviewNotifications), let n = p.reviewNotifications,
           n != .init(done: s.notifyOnReviewDone, failure: s.notifyOnFailure) {
            s.notifyOnReviewDone = n.done
            s.notifyOnFailure = n.failure
            applied.append(title(forKey: ID.reviewNotifications))
        }
        if set(ID.prChangeNotifications, p.prChangeNotifications, \.prChangeNotifications) {
            applied.append(title(forKey: ID.prChangeNotifications))
        }
        if set(ID.pollSeconds, p.pollSeconds, \.pollSeconds) {
            applied.append(title(forKey: ID.pollSeconds))
        }
        if selected.contains(ID.fonts), let f = p.fonts, f != fonts(of: s) {
            s.codeFontName = f.code
            s.codeFontSize = f.codeSize
            // 가져온 글꼴은 고른 것으로 친다. 옛 기본값(Menlo)이어도 다음에 읽을 때 새 기본으로 바꾸지 않는다.
            s.codeFontChosen = true
            s.commentFontName = f.comment
            s.commentFontSize = f.commentSize
            s.uiFontName = f.ui
            s.uiFontSize = f.uiSize
            applied.append(title(forKey: ID.fonts))
        }

        return ApplyResult(settings: s, applied: applied, addedRepos: addedRepos, updatedRepos: updatedRepos,
                           hostChanged: hostChanged)
    }

    // MARK: 경로

    /// 홈 폴더 아래 경로를 `~/…` 로. 받는 맥은 사용자 이름이 달라 그대로는 맞지 않는다.
    public static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func expand(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    // MARK: - 안쪽

    /// 레포 이름은 GitHub 이 대소문자를 가리지 않는다.
    static func sameRepo(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// `extra` 중 `base` 에 아직 없는 것(순서 유지, 중복 제거).
    static func additions(_ extra: [String], to base: [String], caseInsensitive: Bool) -> [String] {
        func key(_ value: String) -> String { caseInsensitive ? value.lowercased() : value }
        var seen = Set(base.map(key))
        var result: [String] = []
        for value in extra where seen.insert(key(value)).inserted {
            result.append(value)
        }
        return result
    }

    static func fonts(of s: Settings) -> SettingsTransferPayload.Fonts {
        .init(code: s.codeFontName, codeSize: s.codeFontSize, comment: s.commentFontName,
              commentSize: s.commentFontSize, ui: s.uiFontName, uiSize: s.uiFontSize)
    }

    static func unreadableMessages(_ keys: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for key in keys {
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.map { key in
            let count = counts[key] ?? 1
            return "\(title(forKey: key)) — 읽을 수 없는 형식" + (count > 1 ? " \(count)건" : "")
        }
    }
}
