import Foundation

/// 앱에서 난 경고·실패의 종류. 모아서 무엇부터 고칠지 보려고 쌓는다(사용자 요청).
///
/// 보고서(ProblemReport)에는 이 종류와 횟수만 들어간다. 그래서 종류에는 회사 코드 정보가 없다 —
/// 파일 이름·PR 번호 같은 것은 이 맥에만 남는 `ProblemEntry.detail` 에만 적는다.
public enum ProblemKind: String, Codable, Sendable, CaseIterable {
    // 리뷰 결과 검사(DraftValidator) — 모델 출력이 그대로는 게시되지 않아 앱이 손본 것
    case multiLineRangeDropped
    case anchorUnresolved
    case duplicateLocation
    case duplicateIssueKey
    case commentLimit
    case commentTooLong
    case commentTooShort
    case summaryTooLong
    case verdictWithoutReason
    // 실행 중 실패
    case reviewFailed
    case claudeAuthExpired
    case usageLimit
    case diffTooLarge
    case diffLoadFailed
    case refreshFailed
    case postFailed
    case mergeFailed
    case baseChangeFailed
    case updateFailed
    case appMoveFailed
    case storeFailed
    case other

    /// 모르는 종류(새 버전이 쓴 기록을 옛 버전이 읽을 때)는 "기타" 로 읽는다.
    /// 그대로 두면 기록 파일 전체가 안 읽혀 모아 둔 것이 통째로 사라진다.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProblemKind(rawValue: raw) ?? .other
    }

    public var label: String {
        switch self {
        case .multiLineRangeDropped: return "여러 줄 범위를 떼고 한 줄로 게시"
        case .anchorUnresolved: return "코멘트 줄을 diff 에서 찾지 못함"
        case .duplicateLocation: return "같은 줄 코멘트가 겹쳐 하나만 남김"
        case .duplicateIssueKey: return "같은 사안이 겹쳐 하나만 남김"
        case .commentLimit: return "코멘트 개수 상한을 넘어 제외"
        case .commentTooLong: return "코멘트가 길이 상한을 넘음"
        case .commentTooShort: return "코멘트가 너무 짧음"
        case .summaryTooLong: return "요약이 길이 상한을 넘음"
        case .verdictWithoutReason: return "Approve 가 아닌데 지적이 없음"
        case .reviewFailed: return "리뷰 실패"
        case .claudeAuthExpired: return "Claude 로그인 만료"
        case .usageLimit: return "Claude 사용 한도 도달"
        case .diffTooLarge: return "diff 가 너무 커서 GitHub 가 거절"
        case .diffLoadFailed: return "diff 받기 실패"
        case .refreshFailed: return "PR 목록 갱신 실패"
        case .postFailed: return "게시 실패"
        case .mergeFailed: return "머지 실패"
        case .baseChangeFailed: return "base 브랜치 바꾸기 실패"
        case .updateFailed: return "앱 업데이트 실패"
        case .appMoveFailed: return "응용 프로그램 폴더로 옮기기 실패"
        case .storeFailed: return "저장 실패"
        case .other: return "기타 오류"
        }
    }

    /// 리뷰 결과 검사에서 나온 것인가(보고서에서 실행 중 실패와 나눠 보인다).
    public var isReviewCheck: Bool {
        switch self {
        case .multiLineRangeDropped, .anchorUnresolved, .duplicateLocation, .duplicateIssueKey,
             .commentLimit, .commentTooLong, .commentTooShort, .summaryTooLong, .verdictWithoutReason:
            return true
        default:
            return false
        }
    }

    /// 부르는 쪽은 넓은 종류(리뷰 실패 등)만 안다. 메시지로 알려진 원인이면 좁힌다.
    public static func refine(_ kind: ProblemKind, message: String) -> ProblemKind {
        // 실측: "Sorry, the diff exceeded the maximum number of files (300)" — 리뷰·diff 어느 쪽에서도 난다.
        if message.contains("exceeded the maximum number") { return .diffTooLarge }
        // 로그인 만료 표식에는 gh 의 "not logged in" 도 있다. 그래서 리뷰(Claude) 실패에만 적용한다.
        if kind == .reviewFailed {
            if AuthFailure.isExpired(message) { return .claudeAuthExpired }
            if message.contains("사용 한도") || message.localizedCaseInsensitiveContains("usage limit") { return .usageLimit }
        }
        return kind
    }
}

public struct ProblemEntry: Codable, Sendable, Equatable {
    public var at: Date
    public var kind: ProblemKind
    public var appVersion: String
    /// 이 맥에서만 보는 설명. 파일 이름·PR 번호가 들어갈 수 있어 보고서에는 넣지 않는다.
    public var detail: String?

    public init(at: Date, kind: ProblemKind, appVersion: String, detail: String? = nil) {
        self.at = at
        self.kind = kind
        self.appVersion = appVersion
        self.detail = detail
    }
}

/// 문제 기록. 이 맥의 데이터 폴더에 JSON 으로 쌓는다(최근 60일 · 최대 2000건).
public final class ProblemLog: @unchecked Sendable {
    /// 테스트 중에는 쓰지 않는다 — 실제 데이터 폴더에 테스트가 만든 가짜 실패가 쌓인다.
    public static let shared = ProblemLog(fileURL: AppPaths.problemsFile, enabled: !RuntimeEnvironment.isRunningTests)
    /// 새로 쌓이거나 지워질 때. 기록을 보여 주는 창이 다시 읽는다(어느 스레드에서든 온다).
    public static let didChangeNotification = Notification.Name("PRayerProblemLogDidChange")

    static let keepDays = 60
    static let maxEntries = 2000

    private let fileURL: URL
    private let enabled: Bool
    private let lock = NSLock()
    private var cache: [ProblemEntry]?

    public init(fileURL: URL, enabled: Bool = true) {
        self.fileURL = fileURL
        self.enabled = enabled
    }

    public func record(_ kind: ProblemKind, detail: String? = nil,
                       at date: Date = Date(), appVersion: String = UpdateCheck.currentVersion()) {
        guard enabled else { return }
        lock.lock()
        var entries = loadLocked()
        // 설명은 한 줄 요약이면 된다. 긴 오류 출력을 통째로 쌓으면 파일만 커진다.
        entries.append(ProblemEntry(at: date, kind: kind, appVersion: appVersion,
                                    detail: detail.map { String($0.prefix(400)) }))
        entries = Self.trimmed(entries, now: date)
        cache = entries
        saveLocked(entries)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    public func entries(since: Date? = nil) -> [ProblemEntry] {
        lock.lock()
        defer { lock.unlock() }
        let all = loadLocked()
        guard let since else { return all }
        return all.filter { $0.at >= since }
    }

    public func clear() {
        lock.lock()
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    static func trimmed(_ entries: [ProblemEntry], now: Date) -> [ProblemEntry] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return Array(entries.filter { $0.at >= cutoff }.suffix(maxEntries))
    }

    private func loadLocked() -> [ProblemEntry] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([ProblemEntry].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    private func saveLocked(_ entries: [ProblemEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 팀원이 슬랙·메신저로 보내 줄 문제 보고 글. 사람이 "문제 보고 복사" 를 누를 때만 만든다.
///
/// 종류·횟수·마지막 날짜·앱 버전만 쓴다. detail(파일 이름·PR 번호가 들어갈 수 있다)은 넣지 않는다 —
/// 회사 코드 정보가 이 맥 밖으로 나가지 않게 하는 것이 이 글의 조건이다.
public enum ProblemReport {
    public struct Context: Sendable {
        public var appVersion: String
        public var build: String
        public var channel: String?
        public var osVersion: String
        public var claudeVersion: String?
        public var reviewModel: String?

        public init(appVersion: String, build: String, channel: String?, osVersion: String,
                    claudeVersion: String?, reviewModel: String?) {
            self.appVersion = appVersion
            self.build = build
            self.channel = channel
            self.osVersion = osVersion
            self.claudeVersion = claudeVersion
            self.reviewModel = reviewModel
        }
    }

    public static func text(entries: [ProblemEntry], context: Context, days: Int, now: Date = Date()) -> String {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = entries.filter { $0.at >= cutoff }
        var app = "앱 v\(context.appVersion) (build \(context.build))"
        if let channel = context.channel { app += " \(channel)" }
        var environment = [app, "macOS \(context.osVersion)"]
        if let version = context.claudeVersion { environment.append("Claude Code \(version)") }
        if let model = context.reviewModel { environment.append("리뷰 모델 \(model)") }

        var lines = ["\(AppInfo.displayName) 문제 보고 (최근 \(days)일)", environment.joined(separator: " · ")]
        if recent.isEmpty {
            lines.append("- 기록된 문제가 없습니다.")
            return lines.joined(separator: "\n")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        for (title, isReviewCheck) in [("리뷰 결과 검사(앱이 손본 것)", true), ("실행 중 실패", false)] {
            let rows = ProblemKind.allCases
                .filter { $0.isReviewCheck == isReviewCheck }
                .compactMap { kind -> (count: Int, line: String)? in
                    let hits = recent.filter { $0.kind == kind }
                    guard let last = hits.map(\.at).max() else { return nil }
                    let versions = Array(Set(hits.map(\.appVersion))).sorted().map { "v\($0)" }.joined(separator: "·")
                    return (hits.count, "  · \(kind.label) — \(hits.count)회 (마지막 \(formatter.string(from: last)), \(versions))")
                }
                .sorted { $0.count > $1.count }
            guard !rows.isEmpty else { continue }
            lines.append("- \(title)")
            lines.append(contentsOf: rows.map(\.line))
        }
        lines.append("※ 종류·횟수·버전만 담았습니다. 파일·PR·레포 이름은 넣지 않았습니다.")
        return lines.joined(separator: "\n")
    }
}

public enum RuntimeEnvironment {
    /// 테스트 중인가. 테스트가 실제 데이터 폴더의 로그·문제 기록에 쓰지 않게 한다 — 재시도 테스트가
    /// 돌 때마다 앱 로그에 "테스트 일시 오류" 가 쌓였다(실측 223줄). 실제 초안을 읽는 테스트가 있어
    /// 데이터 폴더 자체는 바꾸지 않는다.
    public static let isRunningTests: Bool = NSClassFromString("XCTestCase") != nil
}
