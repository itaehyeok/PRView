import Foundation

public struct LedgerEntry: Codable, Sendable, Identifiable {
    /// 무엇에 쓴 토큰인가. 옛 기록은 전부 리뷰로 읽는다.
    public enum Kind: String, Codable, Sendable {
        case review
        /// 남의 코멘트를 쉬운 말로 푸는 보조 호출.
        case explain
        /// 이미 언급된 사안이 어디서 어떻게 오갔는지 대조하는 보조 호출.
        case relevance
        /// 리뷰 이후 커밋·코멘트로 그 지적이 처리됐는지 다시 확인하는 보조 호출.
        case recheck
    }

    public var id: UUID
    public var date: Date
    public var repo: String
    public var number: Int
    public var tokens: Int
    /// Claude Code 가 알려 준 정가 환산치. 남기기만 하고 화면에는 보이지 않는다(사용자 결정 — 앱에 가격을 두지 않는다).
    public var costUSD: Double
    public var model: String
    public var kind: Kind

    public init(id: UUID = UUID(), date: Date = Date(), repo: String, number: Int,
                tokens: Int, costUSD: Double, model: String, kind: Kind = .review) {
        self.id = id
        self.date = date
        self.repo = repo
        self.number = number
        self.tokens = tokens
        self.costUSD = costUSD
        self.model = model
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, date, repo, number, tokens, costUSD, model, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        repo = (try? c.decode(String.self, forKey: .repo)) ?? ""
        number = (try? c.decode(Int.self, forKey: .number)) ?? 0
        tokens = (try? c.decode(Int.self, forKey: .tokens)) ?? 0
        costUSD = (try? c.decode(Double.self, forKey: .costUSD)) ?? 0
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .review
    }
}

/// 구독(Team 좌석)은 토큰 과금이 아니라 5시간 롤링 한도를 소모한다. 잔여 한도를 읽는 공개 API 가 없으므로
/// 앱이 쓴 양만 기록해 보수적으로 방어한다.
public struct TokenLedger: Codable, Sendable {
    public var entries: [LedgerEntry]

    public init(entries: [LedgerEntry] = []) {
        self.entries = entries
    }

    public mutating func add(_ entry: LedgerEntry) {
        entries.append(entry)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        entries.removeAll { $0.date < cutoff }
    }

    public func tokens(inLast interval: TimeInterval, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-interval)
        return entries.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.tokens }
    }

    /// 종류별 사용량. 요약이 리뷰 예산을 잠식하지 않는지 보는 데 쓴다.
    public func tokens(ofKind kind: LedgerEntry.Kind, inLast interval: TimeInterval, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-interval)
        return entries.filter { $0.date >= cutoff && $0.kind == kind }.reduce(0) { $0 + $1.tokens }
    }

    public static let fiveHours: TimeInterval = 5 * 3600
}
