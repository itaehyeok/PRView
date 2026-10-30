import Foundation

/// 커밋 탭의 커밋 한 개.
///
/// PR 에 들어간 커밋만 받는다. GitHub 의 PR 커밋 목록은 base 브랜치에서 닿지 않는 커밋이라, develop 을 받아온
/// 머지가 있어도 develop 쪽 커밋은 들어오지 않는다 — 머지 커밋 한 줄만 남는다(사용자가 고른 "이 브랜치 것만").
public struct BranchCommit: Sendable, Hashable, Identifiable {
    public var oid: String
    public var abbreviatedOid: String
    public var headline: String
    public var authorName: String
    public var authorLogin: String?
    public var date: Date
    /// 부모 커밋 oid. 첫 번째가 첫 부모다.
    public var parents: [String]
    public var additions: Int
    public var deletions: Int
    /// 큰 커밋은 GitHub 이 세지 않아 nil 이다(`changedFilesIfAvailable`).
    public var changedFiles: Int?

    public var id: String { oid }
    public var isMerge: Bool { parents.count > 1 }

    public init(oid: String, abbreviatedOid: String, headline: String, authorName: String,
                authorLogin: String? = nil, date: Date, parents: [String],
                additions: Int = 0, deletions: Int = 0, changedFiles: Int? = nil) {
        self.oid = oid
        self.abbreviatedOid = abbreviatedOid
        self.headline = headline
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.date = date
        self.parents = parents
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
    }
}

/// PR 브랜치의 커밋 목록. `commits` 는 GitHub 이 준 순서(오래된 것 → 새 것)다.
public struct BranchCommits: Sendable, Hashable {
    public var baseRefName: String
    public var headRefName: String
    public var commits: [BranchCommit]
    /// GitHub 이 아는 전체 수. 250개를 넘는 PR 은 GitHub 이 최신 250개만 준다(뒤에서부터 받아도 250개에서 끊긴다, 실측).
    public var totalCount: Int

    public var isTruncated: Bool { commits.count < totalCount }

    public init(baseRefName: String, headRefName: String, commits: [BranchCommit], totalCount: Int) {
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.commits = commits
        self.totalCount = totalCount
    }
}

/// 커밋 탭 아래쪽 diff 의 범위.
public enum CommitDiffSpec: Sendable, Hashable {
    /// 커밋 하나. 머지 커밋은 GitHub 이 첫 부모 기준으로 준다(실측: `commits/{머지}` diff == `compare/첫부모...머지`).
    case commit(String)
    /// 여러 커밋을 합친 것 — base 의 다음부터 head 까지.
    case range(base: String, head: String)

    /// 커밋 oid 는 바뀌지 않으니 diff 도 바뀌지 않는다. 캐시 파일 이름에 쓴다.
    public var cacheKey: String {
        switch self {
        case .commit(let oid): return String(oid.prefix(12))
        case .range(let base, let head): return "\(base.prefix(12))..\(head.prefix(12))"
        }
    }
}
