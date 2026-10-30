import Foundation

/// 슬랙 사람 한 명. "나에게 보내기" 에 쓴다.
public struct SlackPerson: Codable, Hashable, Sendable, Identifiable {
    /// 슬랙 멤버 ID(`U…`·`W…`). 멘션과 DM 이 이것으로 간다 — 이름은 바뀌어도 ID 는 안 바뀐다.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 리뷰 요청을 보낼 곳 — 채널, 또는 사람에게 직접(DM).
public struct SlackDestination: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case channel
        case privateChannel
        /// 나 자신과의 DM. 글을 시험해 볼 때 쓴다(남에게 가지 않는다).
        case me
        case person
    }

    /// 채널 ID(`C…`·`G…`) 또는 사람 ID(`U…`). 사람 ID 를 주면 슬랙이 그 사람과의 DM 으로 보낸다.
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// 화면에 보이는 이름 — `#채널` · `🔒 비공개` · `나에게` · `@사람`.
    public var label: String {
        switch kind {
        case .channel: return "#\(name)"
        case .privateChannel: return "🔒 \(name)"
        case .me: return "나에게 (DM)"
        case .person: return "@\(name)"
        }
    }

    /// 이름 옆에 붙는 꼬리표. 나에게(DM)는 시험용이라는 것을 고르는 자리마다 말한다.
    public var tag: String? { kind == .me ? "테스트용" : nil }

    /// 고르는 자리(메뉴·목록)에 쓰는 이름 — 꼬리표까지.
    public var pickerLabel: String { tag.map { "\(label) · \($0)" } ?? label }

    /// 채널 목록 거르기. `#` 은 빼고, 대소문자는 가리지 않는다.
    public func matches(_ query: String) -> Bool {
        var needle = query.trimmingCharacters(in: .whitespaces)
        while needle.hasPrefix("#") { needle.removeFirst() }
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle) || label.localizedCaseInsensitiveContains(needle)
    }

    public static func me(_ person: SlackPerson) -> SlackDestination {
        SlackDestination(id: person.id, name: person.name, kind: .me)
    }
}

/// 슬랙 리뷰 요청 설정.
///
/// 토큰은 없다 — PRView 는 토큰을 입력받지 않는다. 보내기는 이 맥의 `claude` 에 붙은 claude.ai Slack 커넥터가
/// 하고(`SlackConnector`), 여기에는 그 커넥터에 넘길 값(어디로·어떤 글)만 둔다.
///
/// 아직 설정 공유 파일(`SettingsTransfer`)에 담지 않는다 — 받는 쪽은 처음 쓰는 사람처럼 연동부터 한다.
public struct SlackSettings: Codable, Equatable, Sendable {
    /// 기본으로 보낼 곳. nil 이면 아직 정하지 않았다 — 요청 창이 받는 곳 목록을 펼쳐 고르게 한다.
    public var destination: SlackDestination?
    /// 최근에 고른 곳(가장 최근이 앞). 보내기 창의 받는 곳 메뉴에 그대로 늘어놓는다.
    public var recentDestinations: [SlackDestination]
    /// 연동 확인 때 커넥터가 알려 준 나. "나에게 보내기" 가 이 ID 로 간다.
    public var me: SlackPerson?
    /// 내 채널 — 글을 쓴 채널 먼저, 그다음 들어가 있는 채널(`SlackConnector.postedChannels`·`memberChannels`).
    /// 보낼 곳 판이 처음 열릴 때 받아 두고, 치는 대로 거른다.
    public var myChannels: [SlackDestination]
    public var myChannelsFetchedAt: Date?

    /// 최근 보낸 곳을 몇 개까지 기억하는가. 메뉴가 길어지면 고르기 어렵다.
    public static let recentLimit = 5

    public static let `default` = SlackSettings(destination: nil,
                                                recentDestinations: [],
                                                me: nil,
                                                myChannels: [],
                                                myChannelsFetchedAt: nil)

    public init(destination: SlackDestination?, recentDestinations: [SlackDestination],
                me: SlackPerson?, myChannels: [SlackDestination] = [], myChannelsFetchedAt: Date? = nil) {
        self.destination = destination
        self.recentDestinations = recentDestinations
        self.me = me
        self.myChannels = myChannels
        self.myChannelsFetchedAt = myChannelsFetchedAt
    }

    /// 연동·보낼 곳을 다 정했는가. 아니면 보내기 전에 차례대로 묻는다.
    public var isReady: Bool { me != nil && destination != nil }

    /// 보낼 곳을 고른다 — 기본으로 삼고 최근 목록 맨 앞에 둔다.
    public mutating func choose(_ destination: SlackDestination) {
        self.destination = destination
        recentDestinations.removeAll { $0.id == destination.id }
        recentDestinations.insert(destination, at: 0)
        if recentDestinations.count > Self.recentLimit {
            recentDestinations.removeLast(recentDestinations.count - Self.recentLimit)
        }
    }

    /// 두 갈래로 받은 채널을 하나로 — 글을 쓴 채널을 앞에, 같은 채널은 한 번만.
    public static func mergedChannels(posted: [SlackDestination], member: [SlackDestination]) -> [SlackDestination] {
        var seen = Set<String>()
        return (posted + member).filter { seen.insert($0.id).inserted }
    }

    /// 글 틀(`messageTemplate`·`lineTemplate`)·멘션·링크 미리보기 칸은 뺐다 — 글 형식이 고정이다(`SlackTemplate`).
    /// 옛 설정 파일에 남은 그 칸은 읽을 때 버려지고, 다음 저장 때 빠진다.
    enum CodingKeys: String, CodingKey {
        case destination, recentDestinations, me
        case myChannels, myChannelsFetchedAt
    }

    /// 칸이 늘어도 옛 설정 파일이 읽히게 모든 칸에 기본값을 준다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SlackSettings.default
        // 나에게(DM)는 받는 곳이 아니게 됐다(0.6.1 베타 8~, 보내기 옆 "나에게 테스트로 보내기" 가 맡는다).
        // 예전에 받는 곳으로 골라 둔 나에게는 비운다 — 그러면 요청 창이 받는 곳 목록을 펼쳐 채널을 고르게 한다.
        let savedDestination = try? c.decodeIfPresent(SlackDestination.self, forKey: .destination)
        destination = savedDestination?.kind == .me ? nil : savedDestination
        recentDestinations = ((try? c.decodeIfPresent([SlackDestination].self, forKey: .recentDestinations)) ?? d.recentDestinations)
            .filter { $0.kind != .me }
        me = try? c.decodeIfPresent(SlackPerson.self, forKey: .me)
        myChannels = (try? c.decodeIfPresent([SlackDestination].self, forKey: .myChannels)) ?? []
        myChannelsFetchedAt = try? c.decodeIfPresent(Date.self, forKey: .myChannelsFetchedAt)
    }
}

/// 슬랙 화면의 지난 시각 — "방금" · "3분 전" · "2시간 전" · "어제" · "5일 전".
/// 시스템 상대 시각은 앱 언어(영어)를 따라 "47 seconds ago 받음" 처럼 섞였다. 슬랙 화면은 한국어 문장 안에 들어간다.
public enum SlackAgo {
    public static func text(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "방금"
        case ..<3600: return "\(Int(seconds / 60))분 전"
        case ..<86_400: return "\(Int(seconds / 3600))시간 전"
        case ..<(2 * 86_400): return "어제"
        default: return "\(Int(seconds / 86_400))일 전"
        }
    }
}

/// PR 마다 마지막으로 슬랙에 리뷰를 요청한 기록. 같은 PR 을 또 요청하려 할 때 "어제 #채널 에 보냄" 을 보여 준다.
public struct SlackRequestEntry: Codable, Equatable, Sendable {
    public var sentAt: Date
    public var destination: SlackDestination
    /// 슬랙 메시지 주소. 커넥터가 돌려준 것이다.
    public var link: String?

    public init(sentAt: Date, destination: SlackDestination, link: String?) {
        self.sentAt = sentAt
        self.destination = destination
        self.link = link
    }
}
