import Foundation
import CryptoKit

/// 사용 통계 — 기능별 하루 사용 횟수를 이 맥에 모았다가, 지난 날의 것을 하루에 한 번 TelemetryDeck 으로 보낸다.
///
/// 보내는 것은 앱 버전·베타 번호·macOS 버전과 `Event` 의 날짜별 횟수뿐이다. 이벤트 이름이 enum 이라 레포·PR·사람·
/// 코멘트·경로가 끼어들 자리가 없다 — 공개 앱이고, 쓰는 사람들이 회사 PR 을 본다.
///
/// TelemetryDeck SDK 를 쓰지 않고 HTTP 로 직접 보낸다. SDK 는 신호마다 기기 모델·지역·언어·화면 크기 같은 값을
/// 스스로 붙이는데, 사용자가 열 명 안팎이면 그 조합만으로 누군지 갈린다. 하루 한 번 숫자 묶음이면 요청 한 번이다.
public struct UsageStats: Codable, Sendable, Equatable {
    /// 세는 동작. 이름(raw 값)이 대시보드의 칸 이름이 되므로 한 번 내보낸 이름은 바꾸지 않는다.
    public enum Event: String, CaseIterable, Codable, Sendable {
        case appLaunch = "app.launch"
        case reviewManual = "review.manual"
        case reviewAuto = "review.auto"
        case reviewDeep = "review.deep"
        case reviewPost = "review.post"
        case approve = "pr.approve"
        case merge = "pr.merge"
        case chat = "review.chat"
        case explain = "comment.explain"
        case searchAllPRs = "search.allPRs"
        case byCommit = "diff.byCommit"
        case slackRequest = "slack.request"
        case teamStats = "teamStats.open"
        case notificationOpen = "notification.open"
        case onlyLabel = "list.onlyLabel"
        /// 리뷰 전 확인 창에서 일부 파일의 체크를 풀고 리뷰했다.
        case reviewSkipFiles = "review.skipFiles"
        /// 리뷰 전 확인 창에서 전부 풀고 목록만으로 리뷰했다.
        case reviewListOnly = "review.listOnly"
        /// 리뷰 전 확인 창에서 확인 창 기준을 바꿨다.
        case reviewSizeThreshold = "review.sizeThreshold"
        /// 목록 행에 마우스를 올려 뜬 [전체 리뷰]·[diff] 버튼으로 리뷰를 걸었다.
        case reviewFromRow = "list.rowReview"
        /// 도는·기다리는 리뷰를 취소했다(행 버튼·우클릭·AI 리뷰 탭 어디서든, 한 번 누른 것을 하나로).
        case reviewCancel = "review.cancel"
        /// 목록 활동 줄의 @me 를 눌러 개요 탭의 그 글로 갔다(나를 멘션한 글).
        case mentionJump = "list.mentionJump"
        /// 개요 대화 머리의 "@me N ↓" 으로 다음 멘션으로 갔다.
        case mentionNext = "overview.mentionNext"
        /// 목록 머리 줄의 "All · @me · Replies" 에서 @me 나 Replies 를 골랐다.
        case whoFilter = "list.who"
        /// 목록 머리 줄의 라벨 단추에서 라벨을 더했다(행의 라벨을 누른 것은 `onlyLabel`).
        case labelPick = "list.labelPick"
    }

    /// 마지막으로 보낸 것. 설정의 "보낸 내용 보기" 가 본문을 글자 그대로 보인다.
    public struct Sent: Codable, Sendable, Equatable {
        public var day: String
        public var sentAt: Date
        public var body: String

        public init(day: String, sentAt: Date, body: String) {
            self.day = day
            self.sentAt = sentAt
            self.body = body
        }
    }

    /// 보내지 못한 날을 며칠까지 들고 있나. 막힌 네트워크에서 파일이 끝없이 자라지 않게 한다.
    public static let maxStoredDays = 14
    public static let signalType = "PRView.dailyUsage"

    /// 기본은 켬. 화면에 안내를 띄우지 않는다(2026-11-02 사용자 결정).
    public var enabled = true
    /// 설치마다 하나. 보낼 때는 SHA-256 으로 바꿔 보낸다(TelemetryDeck 이 받은 값을 다시 소금 쳐 해시한다).
    public var installID = UUID()
    /// 이 기능이 든 버전을 처음 켠 날. 이 날부터 센다.
    public var startDay: String?
    /// 날짜("2026-11-02") → 이벤트 이름 → 횟수. 보낸 날은 지운다.
    public var days: [String: [String: Int]] = [:]
    public var lastSent: Sent?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, installID, startDay, days, lastSent
    }

    /// 칸 하나가 깨져도 켬·끔 선택과 설치 ID 는 살린다 — 끈 사람이 파일이 깨졌다고 다시 켜지면 안 된다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        installID = (try? c.decodeIfPresent(UUID.self, forKey: .installID)) ?? UUID()
        startDay = try? c.decodeIfPresent(String.self, forKey: .startDay)
        days = (try? c.decodeIfPresent([String: [String: Int]].self, forKey: .days)) ?? [:]
        lastSent = try? c.decodeIfPresent(Sent.self, forKey: .lastSent)
    }

    // MARK: - 세기

    /// 날짜 열쇠. 이 맥의 달력·시간대 기준이다 — "하루" 는 사용자가 사는 하루다.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 세기 시작. 처음 한 번만 날짜를 남긴다.
    public mutating func noteStarted(day: String) {
        if startDay == nil { startDay = day }
    }

    public mutating func record(_ event: Event, day: String) {
        guard enabled, startDay != nil else { return }
        days[day, default: [:]][event.rawValue, default: 0] += 1
        let stale = days.keys.sorted().dropLast(Self.maxStoredDays)
        for key in stale { days[key] = nil }
    }

    /// 끄면 아직 안 보낸 것도 버린다 — 다시 켰을 때 꺼 둔 동안의 사용이 섞여 나가지 않게.
    public mutating func setEnabled(_ on: Bool) {
        enabled = on
        if !on { days = [:] }
    }

    /// 보낼 날 — 다 지난 날만, 오래된 날부터. 오늘 것은 하루가 끝나야 보낸다.
    public func pendingDays(today: String) -> [String] {
        guard enabled else { return [] }
        return days.keys.filter { $0 < today }.sorted()
    }

    public mutating func markSent(day: String, body: String, at date: Date) {
        days[day] = nil
        lastSent = Sent(day: day, sentAt: date, body: body)
    }

    // MARK: - 보낼 본문

    /// TelemetryDeck 에 넘기는 사용자 값. 설치 ID 를 그대로 보내지 않는다.
    public var clientUser: String {
        SHA256.hash(data: Data(installID.uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 그 날의 신호 하나를 담은 본문(TelemetryDeck Ingest v2 — 신호 배열). 없는 날이면 nil.
    ///
    /// 모든 이벤트를 0 까지 채워 보낸다. 대시보드에서 "그 날 안 썼다" 와 "값이 없다" 가 갈린다.
    /// 숫자는 숫자로 둔다(v2 는 숫자만 타입을 지키고 나머지는 글자로 저장한다).
    public func body(for day: String, config: UsageStatsConfig, client: UsageStatsClient,
                     calendar: Calendar = .current) -> String? {
        guard let counts = days[day] else { return nil }
        var payload: [String: Any] = [
            "day": day,
            "appVersion": client.appVersion,
            "macOS": client.osVersion,
        ]
        if let beta = client.betaNumber { payload["betaNumber"] = String(beta) }
        for event in Event.allCases {
            payload[event.rawValue] = counts[event.rawValue] ?? 0
        }
        var signal: [String: Any] = [
            "appID": config.appID,
            "clientUser": clientUser,
            "type": Self.signalType,
            "isTestMode": config.isTestMode,
            "payload": payload,
        ]
        // 그 날 정오로 적는다. 다음 날 보내도 그래프에서 그 날에 선다(하루 넘게 지난 값은 서버가 24시간 전으로 당긴다).
        if let noon = Self.noon(of: day, calendar: calendar) {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = calendar.timeZone
            signal["receivedAt"] = formatter.string(from: noon)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [signal],
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func noon(of day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// 어디로 보내나. App ID 가 비어 있으면 nil 이고, 그 빌드는 세지도 보내지도 않는다.
public struct UsageStatsConfig: Sendable, Equatable {
    public var appID: String
    public var namespace: String
    public var isTestMode: Bool

    public init?(appID: String?, namespace: String?, isTestMode: Bool) {
        let id = (appID ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        self.appID = id
        self.namespace = (namespace ?? "").trimmingCharacters(in: .whitespaces)
        self.isTestMode = isTestMode
    }

    /// 조직에 namespace 가 있으면 그 주소로 보낸다(TelemetryDeck Ingest v2).
    public var endpoint: URL? {
        guard !namespace.isEmpty else { return URL(string: "https://nom.telemetrydeck.com/v2/") }
        guard let escaped = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://nom.telemetrydeck.com/v2/namespace/\(escaped)/")
    }
}

/// 본문에 실을 앱·OS 정보. 이 셋 말고는 싣지 않는다.
public struct UsageStatsClient: Sendable, Equatable {
    public var appVersion: String
    public var betaNumber: Int?
    public var osVersion: String

    public init(appVersion: String, betaNumber: Int?, osVersion: String) {
        self.appVersion = appVersion
        self.betaNumber = betaNumber
        self.osVersion = osVersion
    }

    /// macOS 버전은 큰 번호.작은 번호까지만("26.6"). 패치 번호까지는 쓸 데가 없다.
    public static func osVersion(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion)"
    }
}
