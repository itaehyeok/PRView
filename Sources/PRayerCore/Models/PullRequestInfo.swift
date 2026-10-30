import CryptoKit
import Foundation

public enum MergeableState: String, Sendable, Codable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

public struct ReviewThreadComment: Sendable, Codable, Hashable {
    public var author: String
    public var body: String
    public var createdAt: String

    public init(author: String, body: String, createdAt: String) {
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

public struct PRReviewThread: Sendable, Codable, Hashable, Identifiable {
    /// 첫 코멘트 뒤의 마지막 답글. 답글이 없으면 nil. 개요의 스레드 줄이 "답글 1 · 내가 답함 12m" 으로 쓴다.
    public var latestReply: ReviewThreadComment? { comments.count > 1 ? comments.last : nil }

    public var id: String
    public var path: String?
    public var line: Int?
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [ReviewThreadComment]

    public init(id: String, path: String?, line: Int?, isResolved: Bool, isOutdated: Bool, comments: [ReviewThreadComment]) {
        self.id = id
        self.path = path
        self.line = line
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.comments = comments
    }
}

public struct PRCommit: Sendable, Codable, Hashable, Identifiable {
    public var oid: String
    public var abbreviatedOid: String
    public var messageHeadline: String
    public var committedDate: Date
    public var author: String

    public var id: String { oid }

    public init(oid: String, abbreviatedOid: String, messageHeadline: String,
                committedDate: Date, author: String) {
        self.oid = oid
        self.abbreviatedOid = abbreviatedOid
        self.messageHeadline = messageHeadline
        self.committedDate = committedDate
        self.author = author
    }
}

/// 제출된 리뷰 1건. 최근 활동 목록을 만드는 데 쓴다.
public struct PRReviewEvent: Sendable, Codable, Hashable {
    public var author: String
    /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED
    public var state: String
    public var submittedAt: Date
    public var body: String

    public init(author: String, state: String, submittedAt: Date, body: String) {
        self.author = author
        self.state = state
        self.submittedAt = submittedAt
        self.body = body
    }
}

/// 인라인이 아닌 PR 대화 코멘트 1건.
public struct PRIssueComment: Sendable, Codable, Hashable {
    public var author: String
    public var body: String
    public var createdAt: Date

    public init(author: String, body: String, createdAt: Date) {
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

/// 승인 1건. `dismiss_stale_reviews` 가 꺼진 레포에서는 head 가 아닌 커밋의 승인도 유효하다.
public struct ApprovalInfo: Sendable, Codable, Hashable {
    public var login: String
    public var commitOid: String?

    public init(login: String, commitOid: String?) {
        self.login = login
        self.commitOid = commitOid
    }
}

public struct PullRequestInfo: Sendable, Codable, Hashable, Identifiable {
    public var repo: RepoID
    public var number: Int
    public var nodeID: String
    public var title: String
    public var bodyText: String
    public var author: String
    public var isDraft: Bool
    public var state: String
    /// PR 을 올린 시각.
    public var createdAt: Date
    /// 마지막 활동(커밋·코멘트·라벨 등) 시각.
    public var updatedAt: Date
    public var mergedAt: Date?
    public var mergedBy: String?
    public var closedAt: Date?
    public var headRefOid: String
    public var headRefName: String
    public var baseRefName: String
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var mergeable: MergeableState
    public var mergeStateStatus: String?
    public var reviewDecision: String?
    /// `latestOpinionatedReviews` 에서 state == APPROVED 인 리뷰어별 최신 리뷰.
    public var approvals: [ApprovalInfo]
    public var labels: [String]
    public var viewerDidAuthor: Bool
    /// `viewerLatestReviewRequest != nil` — 내가 리뷰어로 등록돼 있고 아직 리뷰를 제출하지 않은 상태.
    /// 리뷰를 제출하면 GitHub 가 이 값을 없앤다(2026-09-03 실측). 다만 바로는 아니라, 게시 직후에는 리뷰와
    /// 요청이 함께 보일 수 있다(`isReRequested`).
    public var viewerHasReviewRequest: Bool
    public var viewerLatestReviewState: String?
    public var viewerLatestReviewCommit: String?
    /// 내 마지막 리뷰를 낸 시각(GitHub 기준). 게시 직후 GitHub 이 옛 상태를 돌려주는지 가를 때 쓴다(`knowsReview`).
    /// 옛 캐시에는 없다.
    public var viewerLatestReviewAt: Date? = nil
    /// 나에게(또는 팀에) 리뷰 요청이 마지막으로 걸린 시각(GitHub 기준, 타임라인 사건).
    /// 걸려 있는 요청이 내 리뷰보다 **먼저** 걸린 것이면 GitHub 이 아직 안 지운 것이다(`isReRequested`).
    /// 옛 캐시에는 없고, 요청이 아주 많아 받은 사건 안에 없을 때도 nil 이다.
    public var viewerReviewRequestedAt: Date? = nil
    /// 나에게 걸린 리뷰 요청이 CODEOWNERS 로 자동으로 걸린 것인가(`ReviewRequest.asCodeOwner`).
    /// 코드 소유자가 팀 전원인 레포는 모든 PR 에 요청이 걸려(실측: 요청 10건 모두 true) 목록의 "Requested" 가
    /// 뜻을 잃는다 — 그 태그는 직접 지정한 요청에만 붙인다(2026-10-23 사용자 결정). 옛 캐시에는 없다(nil = 모름).
    public var viewerRequestedAsCodeOwner: Bool? = nil
    /// 이 PR 을 고칠 수 있는가(GraphQL `viewerCanUpdate` — 작성자이거나 레포 쓰기 권한). base 브랜치 바꾸기를 열지
    /// 가른다. 옛 캐시에는 없다(nil = 모름 → 닫아 둔다. 다음 갱신에 채워진다).
    public var viewerCanUpdate: Bool? = nil
    public var checkState: String?
    /// head 커밋의 개별 체크. 합쳐진 `checkState` 만으로는 **무엇이 왜** 실패했는지 알 수 없다.
    public var checks: [PRCheck] = []
    /// 리뷰를 요청받았지만 **아직 내지 않은** 사람들. GitHub 은 리뷰를 제출하면 요청을 지우므로
    /// 여기 남아 있는 것이 곧 "아직 안 본 사람" 이다. 내 PR 이 왜 안 나가는지 볼 때 쓴다.
    public var pendingReviewers: [String] = []
    public var threads: [PRReviewThread]
    /// 제출된 리뷰 목록(최근 활동용).
    public var reviewEvents: [PRReviewEvent] = []
    /// PR 대화 코멘트(최근 활동용).
    public var issueComments: [PRIssueComment] = []
    public var commits: [PRCommit]

    public init(repo: RepoID, number: Int, nodeID: String, title: String, bodyText: String, author: String,
                isDraft: Bool, state: String, createdAt: Date = Date(), updatedAt: Date, headRefOid: String, headRefName: String,
                baseRefName: String, additions: Int, deletions: Int, changedFiles: Int,
                mergeable: MergeableState, mergeStateStatus: String?, reviewDecision: String?,
                approvals: [ApprovalInfo], labels: [String], viewerDidAuthor: Bool,
                viewerHasReviewRequest: Bool, viewerLatestReviewState: String?, viewerLatestReviewCommit: String?,
                checkState: String?, checks: [PRCheck] = [],
                threads: [PRReviewThread], commits: [PRCommit] = [],
                reviewEvents: [PRReviewEvent] = [], issueComments: [PRIssueComment] = [],
                mergedAt: Date? = nil, mergedBy: String? = nil, closedAt: Date? = nil) {
        self.repo = repo
        self.number = number
        self.nodeID = nodeID
        self.title = title
        self.bodyText = bodyText
        self.author = author
        self.isDraft = isDraft
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headRefOid = headRefOid
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.approvals = approvals
        self.labels = labels
        self.viewerDidAuthor = viewerDidAuthor
        self.viewerHasReviewRequest = viewerHasReviewRequest
        self.viewerLatestReviewState = viewerLatestReviewState
        self.viewerLatestReviewCommit = viewerLatestReviewCommit
        self.checkState = checkState
        self.checks = checks
        self.threads = threads
        self.reviewEvents = reviewEvents
        self.issueComments = issueComments
        self.mergedAt = mergedAt
        self.mergedBy = mergedBy
        self.closedAt = closedAt
        self.commits = commits
    }

    public var id: String { "\(repo.full)#\(number)" }
    public var isOpen: Bool { state == "OPEN" }
    public var isMerged: Bool { state == "MERGED" }
    public var changedLines: Int { additions + deletions }
    public var approvalCount: Int { Set(approvals.map(\.login)).count }
    public var approvalCountAtHead: Int {
        Set(approvals.filter { $0.commitOid == headRefOid }.map(\.login)).count
    }
    public var viewerHasSubmittedReview: Bool { viewerLatestReviewState != nil }
    /// 헤더의 base 칩을 눌러 바꿀 수 있는가. 닫히거나 머지된 PR 은 GitHub 이 base 바꾸기를 거절한다.
    public var canChangeBase: Bool { isOpen && viewerCanUpdate == true }
    /// 웹에서 볼 주소. 엔터프라이즈는 도메인이 다르므로 호스트를 받는다.
    public func htmlURL(host: String) -> URL? { URL(string: "https://\(host)/\(repo.full)/pull/\(number)") }
    /// 웹의 변경 파일 탭에서 그 파일 자리. GitHub 은 파일 앵커로 경로의 SHA-256 을 쓴다
    /// (`#diff-<64자리>` — 2026-10-22 공개 PR 페이지의 앵커와 맞춰 봄). 앵커가 틀려도 탭은 열린다.
    public func filesURL(host: String, path: String) -> URL? {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://\(host)/\(repo.full)/pull/\(number)/files#diff-\(digest)")
    }
    public var unresolvedThreadCount: Int { threads.filter { !$0.isResolved && !$0.isOutdated }.count }

    /// 내가 리뷰는 했지만 승인하지 않은 상태.
    /// GitHub 은 리뷰를 제출하면 리뷰 요청을 지우기 때문에, 이걸 따로 보지 않으면
    /// "코멘트만 남긴 PR" 이 목록에서 통째로 사라진다(실측).
    public var viewerReviewedWithoutApproval: Bool {
        guard let state = viewerLatestReviewState?.uppercased() else { return false }
        return ["COMMENTED", "CHANGES_REQUESTED", "DISMISSED"].contains(state)
    }

    /// 내가 승인까지 마쳤는가.
    public var viewerApproved: Bool {
        viewerLatestReviewState?.uppercased() == "APPROVED"
    }

    /// GitHub 이 `postedAt` 에 낸 내 리뷰를 벌써 아는가.
    ///
    /// 게시 직후에는 GitHub 이 잠깐 옛 상태 — 그 리뷰가 없고, 리뷰를 내면 지워질 요청이 그대로 남은 상태 — 를
    /// 돌려준다(DismissalTests 참고). 그동안의 요청·리뷰 커밋은 게시 전 것이라 믿으면 안 된다.
    /// 내 시계(게시 시각)와 GitHub 시계(제출 시각)는 조금 어긋날 수 있어 2분을 봐준다.
    public func knowsReview(postedAt: Date) -> Bool {
        guard let latest = viewerLatestReviewAt else { return false }
        return latest >= postedAt.addingTimeInterval(-120)
    }

    /// 내가 리뷰를 낸 **뒤에** 다시 리뷰 요청이 왔는가.
    ///
    /// GitHub 은 리뷰를 받으면 그 사람에게 걸린 요청을 지운다. 그래서 리뷰를 낸 적이 있는데 요청이 걸려 있으면
    /// 그 뒤에 누가 다시 요청한 것이다. 방금 이 앱으로 낸 리뷰가 있으면(`postedAt`) GitHub 이 그 리뷰를 알 때만
    /// 믿는다 — 모르면 걸린 요청은 리뷰를 내기 전 것이다.
    ///
    /// 리뷰는 알면서 요청은 아직 안 지운 순간도 있다(리뷰가 먼저 보이고 요청은 조금 뒤에 지워진다). 그때 "걸려
    /// 있으니 재요청" 으로 읽으면 승인해서 흐려지던 행이 유예가 끝나자 도로 또렷해져 다음 폴링까지 남았다(실측).
    /// 그래서 요청이 걸린 시각을 알면 그것으로 가른다 — 내 리뷰보다 뒤에 걸린 요청만 재요청이다.
    /// 시각을 모르면(옛 캐시·받은 사건 밖) 예전처럼 걸려 있는 것만 본다.
    public func isReRequested(postedAt: Date? = nil) -> Bool {
        guard viewerHasReviewRequest, viewerHasSubmittedReview else { return false }
        if let postedAt, !knowsReview(postedAt: postedAt) { return false }
        guard let requestedAt = viewerReviewRequestedAt, let reviewedAt = viewerLatestReviewAt else { return true }
        return requestedAt > reviewedAt
    }

    /// 이 커밋 뒤로 올라온 커밋 수. 받아 둔 커밋 목록(최근 30개, 오래된 순)에 그 커밋이 없으면
    /// (오래됐거나 강제 푸시로 사라짐) nil — 개수를 지어내지 않는다.
    public func commitCount(after oid: String) -> Int? {
        guard let index = commits.firstIndex(where: { $0.oid == oid }) else { return nil }
        let count = commits.count - index - 1
        return count > 0 ? count : nil
    }

    /// 지금 커밋을 이미 내가 승인했는가.
    /// 새 커밋이 올라온 뒤라면 다시 승인하는 것이 의미가 있으므로 false 다.
    public var viewerApprovedCurrentHead: Bool {
        viewerApproved && viewerLatestReviewCommit == headRefOid
    }

    public var checkFailed: Bool { checkState == "FAILURE" || checkState == "ERROR" }

    /// CI 가 왜 빨간지. 취소와 진짜 실패는 사람이 할 일이 다르다 —
    /// 취소는 다시 돌리면 되고, 실패는 코드를 봐야 한다.
    public var checkOutcome: CheckOutcome {
        guard checkFailed else { return .passing }
        let failed = checks.filter { PRCheck.failureOutcomes.contains($0.outcome) }
        if !failed.isEmpty { return .failed(failed.map(\.name)) }
        let cancelled = checks.filter { $0.outcome == "CANCELLED" }
        if !cancelled.isEmpty { return .cancelled(cancelled.map(\.name)) }
        // 체크 목록을 못 받았으면(옛 기록·조회 실패) 이름 없이 실패로만 말한다.
        return .failed([])
    }
    public var shortHead: String { String(headRefOid.prefix(7)) }
}

/// head 커밋에 붙은 체크 하나.
///
/// GitHub 은 두 가지를 섞어서 준다 — Actions 같은 `CheckRun`(name/conclusion)과
/// 외부 CI 가 쓰는 `StatusContext`(context/state). 앱에서는 구분할 이유가 없어 같은 모양으로 담는다.
public struct PRCheck: Sendable, Equatable, Codable, Hashable {
    public var name: String
    /// SUCCESS · FAILURE · CANCELLED · SKIPPED · NEUTRAL · TIMED_OUT …
    public var outcome: String

    /// "사람이 봐야 하는 실패". 취소(CANCELLED)는 여기 없다 — 코드 문제가 아니다.
    public static let failureOutcomes: Set<String> = [
        "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE",
    ]

    public init(name: String, outcome: String) {
        self.name = name
        self.outcome = outcome
    }
}

/// CI 가 빨간 이유.
public enum CheckOutcome: Sendable, Equatable {
    case passing
    /// 실패로 끝난 것이 **취소뿐**이다. 코드 문제가 아니라 다시 돌리면 되는 경우가 많다.
    case cancelled([String])
    /// 진짜 실패가 하나라도 있다. 이름을 못 받았으면 배열이 비어 있다.
    case failed([String])

    public var isProblem: Bool { self != .passing }

    /// 실패로 끝난 것이 취소뿐인가. 빨강 대신 주황으로 낼지 정한다.
    public var isCancelledOnly: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// 화면에 붙일 한 줄. 이름이 많으면 둘까지만 적고 나머지는 수로 줄인다.
    public var detail: String? {
        switch self {
        case .passing: return nil
        case .cancelled(let names): return Self.join(names, suffix: "취소됨")
        case .failed(let names): return Self.join(names, suffix: "실패")
        }
    }

    private static func join(_ names: [String], suffix: String) -> String? {
        guard !names.isEmpty else { return nil }
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? names
        if unique.count <= 2 { return "\(unique.joined(separator: ", ")) \(suffix)" }
        return "\(unique.prefix(2).joined(separator: ", ")) 외 \(unique.count - 2)건 \(suffix)"
    }
}
