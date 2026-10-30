import Foundation

/// 팀 통계가 세는 네 가지. 순서가 곧 화면 순서다(내 순위 카드·순위표).
public enum TeamStatMetric: String, CaseIterable, Identifiable, Sendable {
    case commits, pullRequests, approvals, comments

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .commits: return "커밋"
        case .pullRequests: return "PR"
        case .approvals: return "Approve"
        case .comments: return "코멘트"
        }
    }

    public var symbol: String {
        switch self {
        case .commits: return "smallcircle.filled.circle"
        case .pullRequests: return "arrow.triangle.pull"
        case .approvals: return "checkmark.circle"
        case .comments: return "text.bubble"
        }
    }

    /// 무엇을 어떻게 셌는지. 같은 "커밋 수" 라도 기준에 따라 순위가 뒤집혀서(develop 기준이면 머지 전
    /// 브랜치 커밋이 통째로 빠진다) 순위표마다 기준을 적어 둔다.
    public var note: String {
        switch self {
        case .commits: return "원격 모든 브랜치 · 같은 커밋은 1번 · 머지 커밋 제외"
        case .pullRequests: return "만든 PR · 만든 날 기준"
        case .approvals: return "Approve 한 PR 수 · 같은 PR 여러 번은 1"
        case .comments: return "줄 코멘트 + PR 대화 코멘트"
        }
    }
}

public enum TeamStatPeriodKind: String, CaseIterable, Identifiable, Sendable {
    case week, month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: return "주간"
        case .month: return "월간"
        }
    }

    /// 내 순위 카드의 "지난주 3위" 앞말.
    public var previousLabel: String {
        switch self {
        case .week: return "지난주"
        case .month: return "지난달"
        }
    }
}

/// 통계를 세는 한 기간. 끝은 포함하지 않는다(`start <= t < end`).
public struct TeamStatPeriod: Hashable, Sendable {
    public let kind: TeamStatPeriodKind
    public let start: Date
    public let end: Date

    /// 주는 월요일부터 — 팀이 주간 보고를 월~일로 끊는다. 시간대는 이 맥의 것(팀이 같은 시간대에 있다).
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    public static func containing(_ date: Date, kind: TeamStatPeriodKind, calendar: Calendar) -> TeamStatPeriod {
        let component: Calendar.Component = kind == .week ? .weekOfYear : .month
        let interval = calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
        return TeamStatPeriod(kind: kind, start: interval.start, end: interval.end)
    }

    /// 앞뒤 기간. 음수면 과거.
    public func shifted(by count: Int, calendar: Calendar) -> TeamStatPeriod {
        let component: Calendar.Component = kind == .week ? .weekOfYear : .month
        let moved = calendar.date(byAdding: component, value: count, to: start) ?? start
        return TeamStatPeriod.containing(moved, kind: kind, calendar: calendar)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// "10월 26일 – 11월 1일" · "2026년 10월".
    public func label(calendar: Calendar) -> String {
        switch kind {
        case .week:
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            let from = calendar.dateComponents([.month, .day], from: start)
            let to = calendar.dateComponents([.month, .day], from: last)
            return "\(from.month ?? 0)월 \(from.day ?? 0)일 – \(to.month ?? 0)월 \(to.day ?? 0)일"
        case .month:
            let parts = calendar.dateComponents([.year, .month], from: start)
            return "\(parts.year ?? 0)년 \(parts.month ?? 0)월"
        }
    }
}

/// 누가 언제 한 일 하나(커밋 하나, Approve 하나 …). `person` 은 GitHub 로그인이거나, 로그인을 못 찾은
/// 커밋이면 메일 주소 앞부분이다.
public struct TeamStatEvent: Hashable, Sendable {
    public let person: String
    public let at: Date

    public init(person: String, at: Date) {
        self.person = person
        self.at = at
    }
}

public struct TeamStatRow: Hashable, Sendable, Identifiable, Codable {
    public let person: String
    public let count: Int
    /// 같은 수면 같은 순위(1, 2, 2, 4 …).
    public let rank: Int

    public init(person: String, count: Int, rank: Int) {
        self.person = person
        self.count = count
        self.rank = rank
    }

    public var id: String { person }
}

/// 브랜치 기록에서 읽은 커밋 하나(`TeamStatsCommitSource`).
public struct TeamStatCommit: Hashable, Sendable {
    public let oid: String
    public let email: String
    public let authoredAt: Date
    public let subject: String

    public init(oid: String, email: String, authoredAt: Date, subject: String) {
        self.oid = oid
        self.email = email
        self.authoredAt = authoredAt
        self.subject = subject
    }
}

public enum TeamStats {
    /// 봇은 순위에서 뺀다. 리뷰 봇이 코멘트 순위 1위를 차지하는 일이 흔하다.
    public static func isBot(_ person: String) -> Bool {
        person.lowercased().hasSuffix("[bot]")
    }

    /// 기간 안의 일을 사람별로 세어 많은 순으로. 같은 수는 이름순으로 늘어놓되 순위는 같다.
    public static func ranking(_ events: [TeamStatEvent], in period: TeamStatPeriod) -> [TeamStatRow] {
        var counts: [String: Int] = [:]
        for event in events where period.contains(event.at) && !isBot(event.person) {
            counts[event.person, default: 0] += 1
        }
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return sorted.map { entry in
            TeamStatRow(person: entry.key, count: entry.value,
                        rank: 1 + sorted.filter { $0.value > entry.value }.count)
        }
    }

    // MARK: - 커밋

    /// `git log` 한 줄의 꼴. 제목에 탭이 있어도 마지막 칸으로 남게 맨 뒤에 둔다.
    public static let commitLogFormat = "%H%x09%ae%x09%aI%x09%s"

    public static func parseCommitLog(_ text: String) -> [TeamStatCommit] {
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, let date = formatter.date(from: String(fields[2])) else { return nil }
            return TeamStatCommit(oid: String(fields[0]), email: String(fields[1]), authoredAt: date,
                                  subject: fields.count > 3 ? String(fields[3]) : "")
        }
    }

    /// 커밋 메일을 GitHub 로그인으로 잇는다. git 기록에는 로그인이 없어서, 같은 사람이 PR·리뷰·코멘트
    /// 순위에서는 `riley-c`, 커밋 순위에서는 `riley.c` 로 따로 서게 된다.
    ///
    /// - GitHub 이 준 noreply 주소(`123+login@users.noreply.github.com`)는 로그인이 들어 있다.
    /// - 회사 메일은 앞부분의 `.`·`_` 를 `-` 로 바꿔, 아는 로그인과 같거나 그 뒤에 `-` 로 이어지는 것이
    ///   **하나뿐일 때만** 잇는다(`alex.k` → `alex-k-acme`). 둘 이상이면 아무에게도 붙이지 않는다 — 남의
    ///   순위에 커밋을 얹느니 따로 서는 게 낫다. 도메인은 보지 않는다(회사 도메인을 둘 쓰는 사람이 있다).
    public static func person(forEmail email: String, knownLogins: Set<String>) -> String {
        let lower = email.lowercased()
        let parts = lower.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return lower }
        var local = String(parts[0])
        if parts[1] == "users.noreply.github.com", let plus = local.firstIndex(of: "+") {
            local = String(local[local.index(after: plus)...])
        }
        let dashed = local.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        let matches = knownLogins.filter { login in
            let candidate = login.lowercased()
            return candidate == dashed || candidate.hasPrefix(dashed + "-")
        }
        if matches.count == 1, let only = matches.first { return only }
        return local
    }

    /// 커밋 메일을 이을 후보 — `since` 뒤에 실제로 활동한 로그인만. 갱신일로 찾은 PR 에는 오래전에 만든 PR 의
    /// 작성자·Approve 도 섞여 오는데, 그중에 같은 사람의 예전 계정이 있다(실측: 2025년의 `casey-h` 과 지금의
    /// `casey-h-acme`). 그 둘이 같이 후보에 들면 `casey.h` 메일이 둘 다에 들어맞아 아무에게도 안 이어졌다.
    public static func activeLogins(_ events: [TeamStatEvent], since: Date) -> Set<String> {
        Set(events.filter { $0.at >= since && !isBot($0.person) }.map(\.person))
    }

    /// 같은 커밋은 한 번만 센다. 여러 브랜치에 같이 있는 커밋은 해시가 같고, 리베이스·체리픽으로 해시만
    /// 달라진 복사본은 작성자·작성 시각·제목이 같다(실측: 두 달 1,796개 중 12개).
    public static func commitEvents(_ commits: [TeamStatCommit], knownLogins: Set<String>) -> [TeamStatEvent] {
        var seenOIDs = Set<String>()
        var seenCopies = Set<String>()
        var events: [TeamStatEvent] = []
        for commit in commits {
            guard seenOIDs.insert(commit.oid).inserted else { continue }
            let person = person(forEmail: commit.email, knownLogins: knownLogins)
            let copyKey = "\(person)\t\(commit.authoredAt.timeIntervalSince1970)\t\(commit.subject)"
            guard seenCopies.insert(copyKey).inserted else { continue }
            events.append(TeamStatEvent(person: person, at: commit.authoredAt))
        }
        return events
    }
}
