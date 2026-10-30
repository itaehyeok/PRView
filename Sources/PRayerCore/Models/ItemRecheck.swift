import Foundation

/// 리뷰 지적 하나가 그 뒤에 처리됐는지 다시 확인한 결과.
public struct ItemRecheck: Sendable, Codable, Hashable, Identifiable {
    /// 무엇이 됐는가.
    ///
    /// "고쳐졌다 / 아니다" 둘로만 나누면 흔한 경우가 어디에도 안 맞는다 — 나중 커밋이 그 파일을
    /// 건드리긴 했는데 이 지적은 그대로인 경우다. 모델이 그걸 "고쳐졌다" 로 반올림하지 않도록
    /// 부분 반영을 따로 둔다.
    public enum Status: String, Sendable, Codable, CaseIterable {
        case fixedInCommit = "fixed_in_commit"
        case partiallyFixed = "partially_fixed"
        case answeredInComment = "answered_in_comment"
        case untouched
        /// 근거가 없어 판단할 수 없음. **틀린 확신보다 이쪽이 낫다.**
        case cannotTell = "cannot_tell"

        public var label: String {
            switch self {
            case .fixedInCommit: return "고쳐졌습니다"
            case .partiallyFixed: return "일부만 반영됐습니다"
            case .answeredInComment: return "코멘트로 답이 왔습니다"
            case .untouched: return "그대로입니다"
            case .cannotTell: return "판단할 근거가 없습니다"
            }
        }

        /// 근거가 없으면 "모르겠다" 로 내린다.
        ///
        /// 근거 없이 "고쳐졌습니다" 만 화면에 남으면 사용자가 확인할 방법이 없다.
        /// `untouched`(찾아봤는데 없더라)와 `cannotTell` 은 원래 근거가 없을 수 있으므로 그대로 둔다.
        public func downgradedIfUnsupported(evidenceCount: Int) -> Self {
            guard evidenceCount == 0, self != .untouched, self != .cannotTell else { return self }
            return .cannotTell
        }

        public var symbolName: String {
            switch self {
            case .fixedInCommit: return "checkmark.circle.fill"
            case .partiallyFixed: return "circle.lefthalf.filled"
            case .answeredInComment: return "text.bubble.fill"
            case .untouched: return "exclamationmark.circle"
            case .cannotTell: return "questionmark.circle"
            }
        }
    }

    public struct Evidence: Sendable, Codable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Codable {
            case commit
            case comment
            case code
        }

        public var kind: Kind
        /// 커밋 해시나 코멘트 작성자처럼 가리키는 대상.
        public var ref: String
        public var path: String?
        public var line: Int?
        public var note: String

        /// note 까지 넣는다. 같은 사람이 남긴 코멘트 근거 두 건이 같은 id 를 갖게 되면
        /// ForEach 가 한 줄을 조용히 버린다.
        public var id: String { "\(kind.rawValue)|\(ref)|\(path ?? "")|\(line ?? 0)|\(note)" }

        public init(kind: Kind, ref: String, path: String? = nil, line: Int? = nil, note: String) {
            self.kind = kind
            self.ref = ref
            self.path = path
            self.line = line
            self.note = note
        }
    }

    public var key: String
    public var status: Status
    public var summaryKo: String
    public var evidence: [Evidence]
    /// 어느 커밋을 기준으로 리뷰했었나.
    public var reviewedHeadSha: String
    /// 어느 커밋까지 보고 판단했나. 지금 head 와 다르면 그 뒤로 또 바뀐 것이다.
    public var checkedHeadSha: String
    public var newCommitCount: Int
    public var newCommentCount: Int
    public var createdAt: Date
    public var usage: EngineUsage

    public var id: String { key }

    public init(key: String, status: Status, summaryKo: String, evidence: [Evidence],
                reviewedHeadSha: String, checkedHeadSha: String,
                newCommitCount: Int, newCommentCount: Int,
                createdAt: Date = Date(), usage: EngineUsage = EngineUsage()) {
        self.key = key
        self.status = status
        self.summaryKo = summaryKo
        self.evidence = evidence
        self.reviewedHeadSha = reviewedHeadSha
        self.checkedHeadSha = checkedHeadSha
        self.newCommitCount = newCommitCount
        self.newCommentCount = newCommentCount
        self.createdAt = createdAt
        self.usage = usage
    }

    /// 판단한 뒤로 PR 이 또 움직였는가.
    public func isStale(against headSha: String) -> Bool { checkedHeadSha != headSha }
}

/// 모델이 돌려주는 모양. 저장하는 모양(`ItemRecheck`)과 분리해 둔다.
struct RecheckOutput: Decodable {
    struct Evidence: Decodable {
        var kind: ItemRecheck.Evidence.Kind
        var ref: String
        var path: String?
        var line: Int?
        var note: String
    }

    var status: ItemRecheck.Status
    var summaryKo: String
    var evidence: [Evidence]

    enum CodingKeys: String, CodingKey {
        case status
        case summaryKo = "summary_ko"
        case evidence
    }
}
