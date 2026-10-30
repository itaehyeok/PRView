import Foundation

enum GraphQL {
    /// PR 목록·단건에서 공통으로 쓰는 필드. 전부 스키마 인트로스펙션으로 존재를 확인한 것들이다.
    static let prFields = """
        id
        number
        title
        body
        isDraft
        state
        createdAt
        updatedAt
        mergedAt
        mergedBy { login }
        closedAt
        headRefOid
        headRefName
        baseRefName
        additions
        deletions
        changedFiles
        mergeable
        mergeStateStatus
        reviewDecision
        viewerDidAuthor
        # base 브랜치를 바꿀 수 있는가(작성자이거나 쓰기 권한). 헤더의 base 칩을 누를 수 있게 할지 이걸로 가른다.
        viewerCanUpdate
        repository { name owner { login } }
        author { login }
        viewerLatestReviewRequest { id asCodeOwner }
        viewerLatestReview { state submittedAt commit { oid } }
        # 요청 객체(viewerLatestReviewRequest)에는 시각이 없다. 나에게 걸린 요청이 **언제** 걸렸는지는
        # 타임라인 사건으로만 알 수 있다. 게시 직후 아직 안 지워진 요청과 진짜 재요청을 이 시각으로 가른다
        # (PullRequestInfo.isReRequested). 한 번에 열 명 넘게 요청하는 PR 이 있어(실측 11명) 넉넉히 받는다.
        reviewRequestEvents: timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 30) {
          nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer {
            __typename ... on User { isViewer } } } }
        }
        labels(first: 20) { nodes { name } }
        reviewRequests(first: 20) { nodes { requestedReviewer {
          __typename ... on User { login } ... on Team { slug } } } }
        latestOpinionatedReviews(first: 20) { nodes { state author { login } commit { oid } } }
        commits(last: 30) {
          totalCount
          nodes {
            commit {
              oid abbreviatedOid messageHeadline committedDate
              author { user { login } name }
              statusCheckRollup { state }
            }
          }
        }
        # 합쳐진 값(FAILURE) 만으로는 무엇이 왜 실패했는지 알 수 없다. head 커밋의
        # 개별 체크만 따로 받는다 — 위 commits 안에 넣으면 30커밋 × 체크 수가 되어
        # 목록 한 페이지가 통째로 무거워진다(실측: 이 별칭은 페이지당 cost 1 → 2).
        headChecks: commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(last: 20) {
                  nodes {
                    __typename
                    ... on CheckRun { name conclusion }
                    ... on StatusContext { context state }
                  }
                }
              }
            }
          }
        }
        reviews(last: 20) { nodes { state submittedAt author { login } body } }
        comments(last: 20) { nodes { createdAt author { login } body } }
        reviewThreads(last: 30) {
          nodes {
            id isResolved isOutdated path line
            comments(first: 10) { nodes { body createdAt author { login } } }
          }
        }
    """

    static let prList = """
    query PRList($q: String!, $n: Int!, $after: String) {
      rateLimit { cost remaining resetAt }
      search(query: $q, type: ISSUE, first: $n, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
    \(prFields)
          }
        }
      }
    }
    """

    static let singlePR = """
    query SinglePR($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
    \(prFields)
        }
      }
    }
    """

    /// 본문·대화를 GitHub 이 그린 HTML 로. 첨부 그림의 서명 주소만 여기 실린다(GitHubAttachment).
    /// 받는 개수는 prFields 와 같다 — 화면에 보이는 코멘트가 그만큼이다.
    static let attachmentHTML = """
    query AttachmentHTML($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          bodyHTML
          reviews(last: 20) { nodes { bodyHTML } }
          comments(last: 20) { nodes { bodyHTML } }
          reviewThreads(last: 30) { nodes { comments(first: 10) { nodes { bodyHTML } } } }
        }
      }
    }
    """

    /// 커밋 탭 — PR 브랜치의 커밋과 부모. 최신 쪽부터 뒤로 받는다(`last`·`before`) — 앞으로 받으면(`first`) 커밋이 많은
    /// PR 에서 오래된 것만 오고 head 쪽이 빠진다(실측: 849개 PR 에서 앞 250개만).
    static let branchCommits = """
    query BranchCommits($owner: String!, $name: String!, $number: Int!, $before: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          baseRefName headRefName
          commits(last: 100, before: $before) {
            totalCount
            pageInfo { hasPreviousPage startCursor }
            nodes {
              commit {
                oid abbreviatedOid messageHeadline committedDate
                additions deletions changedFilesIfAvailable
                author { name user { login } }
                parents(first: 4) { nodes { oid } }
              }
            }
          }
        }
      }
    }
    """

    static let headState = """
    query HeadState($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { headRefOid state mergeable }
      }
    }
    """

    static let viewerRepos = """
    query ViewerRepos($after: String) {
      viewer {
        login
        repositories(first: 30, after: $after,
                     affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     orderBy: { field: PUSHED_AT, direction: DESC }) {
          totalCount
          nodes { nameWithOwner isArchived isPrivate isFork viewerPermission defaultBranchRef { name } }
          pageInfo { hasNextPage endCursor }
        }
        organizations(first: 30) { nodes { login } }
      }
    }
    """

    /// 접근 가능한 레포가 수천 개인 계정에서는 전량 열거가 502 로 끊긴다(실측: first:100×6 → HTTP 502).
    /// 이름으로 찾는 경로는 검색 API 를 쓴다.
    static let searchRepos = """
    query SearchRepos($q: String!, $n: Int!) {
      search(query: $q, type: REPOSITORY, first: $n) {
        repositoryCount
        nodes {
          ... on Repository {
            nameWithOwner isArchived isPrivate isFork viewerPermission defaultBranchRef { name }
          }
        }
      }
    }
    """

    /// 목록에 없는 레포(조직 레포가 많아 잘린 경우 등)를 이름으로 직접 확인한다.
    /// 최근 PR 마다 바뀐 파일 — 제외 규칙 자동완성이 "PR 에서 자주 바뀐 것" 을 위로 올릴 때 쓴다(ExclusionCatalog).
    /// PR 50개 × 파일 100개를 한 번에 받는다(실측: 3초, rate limit 비용 1). 파일이 100개 넘는 PR 은 앞 100개만 센다.
    static let recentPRFiles = """
    query RecentPRFiles($owner: String!, $name: String!, $n: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: $n, states: [OPEN, MERGED], orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { files(first: 100) { nodes { path additions deletions } } }
        }
      }
    }
    """

    static let singleRepo = """
    query SingleRepo($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner isArchived isPrivate isFork viewerPermission defaultBranchRef { name }
      }
    }
    """

    /// 브랜치 보호 규칙(패턴별 Approve 수)과 기본 브랜치. 설정의 "Approve N명 필요" 가 여기서 나온다.
    /// `requiresApprovingReviews` 가 꺼진 규칙은 수가 남아 있어도 머지 조건이 아니라서 같이 받는다.
    static let approvalRules = """
    query ApprovalRules($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        branchProtectionRules(first: 50) {
          nodes { pattern requiresApprovingReviews requiredApprovingReviewCount }
        }
      }
    }
    """

    static let branchProtection = """
    query Protection($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        branchProtectionRules(first: 30) {
          nodes { pattern requiredApprovingReviewCount dismissesStaleReviews }
        }
      }
    }
    """

    /// 머지 확인 줄의 방식 메뉴. `viewerDefaultMergeMethod` 는 내가 이 레포에서 마지막에 쓴 방식이다.
    static let mergeOptions = """
    query MergeOptions($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerDefaultMergeMethod
      }
    }
    """

    /// base 브랜치 고르기 칸. `query` 는 GitHub 이 이름 **어디에든** 든 것으로 찾는다("main" → "domain-…" 도 온다).
    /// 최근 커밋 순으로 받는다 — 레포에 브랜치가 수천 개라 다 받을 수 없고, base 로 고를 브랜치는 대개 살아 있는 것이다.
    static let branchSearch = """
    query BranchSearch($owner: String!, $name: String!, $q: String!, $n: Int!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        refs(refPrefix: "refs/heads/", first: $n, query: $q,
             orderBy: { field: TAG_COMMIT_DATE, direction: DESC }) {
          totalCount
          nodes { name }
        }
      }
    }
    """
}

// MARK: - 응답 DTO

struct GQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GQLErrorItem]?
}

struct GQLErrorItem: Decodable {
    let message: String
}

struct GQLRateLimit: Decodable {
    let cost: Int?
    let remaining: Int?
    let resetAt: String?
}

struct PRNodeDTO: Decodable {
    struct Login: Decodable { let login: String? }
    struct Repo: Decodable { let name: String?; let owner: Login? }
    struct Commit: Decodable { let oid: String? }
    struct ReviewNode: Decodable { let state: String?; let author: Login?; let commit: Commit? }
    struct ReviewsConn: Decodable { let nodes: [ReviewNode]? }
    struct LabelNode: Decodable { let name: String? }
    struct ReviewRequestsConn: Decodable {
    struct Node: Decodable {
        struct Reviewer: Decodable {
            let login: String?
            let slug: String?
        }
        let requestedReviewer: Reviewer?
    }
    let nodes: [Node]?
}

struct LabelsConn: Decodable { let nodes: [LabelNode]? }
    struct StatusRollup: Decodable { let state: String? }
    struct CommitAuthorUser: Decodable { let login: String? }
    struct CommitAuthor: Decodable { let user: CommitAuthorUser?; let name: String? }
    struct CommitInner: Decodable {
        let oid: String?
        let abbreviatedOid: String?
        let messageHeadline: String?
        let committedDate: String?
        let author: CommitAuthor?
        let statusCheckRollup: StatusRollup?
    }
    struct CommitNode: Decodable { let commit: CommitInner? }
    /// head 커밋의 개별 체크. CheckRun 이면 name/conclusion, StatusContext 면 context/state 로 온다.
    struct CheckContext: Decodable {
        let __typename: String?
        let name: String?
        let conclusion: String?
        let context: String?
        let state: String?
    }
    struct CheckContextsConn: Decodable { let nodes: [CheckContext]? }
    struct HeadRollup: Decodable { let contexts: CheckContextsConn? }
    struct HeadCommitInner: Decodable { let statusCheckRollup: HeadRollup? }
    struct HeadCommitNode: Decodable { let commit: HeadCommitInner? }
    struct HeadChecksConn: Decodable { let nodes: [HeadCommitNode]? }
    struct CommitsConn: Decodable { let totalCount: Int?; let nodes: [CommitNode]? }
    struct ThreadComment: Decodable { let body: String?; let createdAt: String?; let author: Login? }
    struct ThreadCommentsConn: Decodable { let nodes: [ThreadComment]? }
    struct ThreadNode: Decodable {
        let id: String?
        let isResolved: Bool?
        let isOutdated: Bool?
        let path: String?
        let line: Int?
        let comments: ThreadCommentsConn?
    }
    struct ThreadsConn: Decodable { let nodes: [ThreadNode]? }
    struct SubmittedReview: Decodable {
        let state: String?
        let submittedAt: String?
        let author: Login?
        let body: String?
    }
    struct SubmittedReviewsConn: Decodable { let nodes: [SubmittedReview]? }
    struct IssueComment: Decodable { let createdAt: String?; let author: Login?; let body: String? }
    struct IssueCommentsConn: Decodable { let nodes: [IssueComment]? }
    struct RequestRef: Decodable { let id: String?; let asCodeOwner: Bool? }
    /// 리뷰 요청 사건. 요청받은 쪽이 사람이면 `isViewer` 로 나인지 가르고, 팀이면 `__typename` 만 온다.
    struct RequestEvent: Decodable {
        struct Reviewer: Decodable { let __typename: String?; let isViewer: Bool? }
        let createdAt: String?
        let requestedReviewer: Reviewer?
    }
    struct RequestEventsConn: Decodable { let nodes: [RequestEvent]? }
    struct ViewerReview: Decodable { let state: String?; let submittedAt: String?; let commit: Commit? }

    let id: String?
    let number: Int?
    let title: String?
    /// GraphQL `body`(마크다운 원문). `bodyText` 는 기호가 지워진 평문이라 화면에 못 쓴다.
    let body: String?
    let isDraft: Bool?
    let state: String?
    let createdAt: String?
    let updatedAt: String?
    let headRefOid: String?
    let headRefName: String?
    let baseRefName: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let viewerDidAuthor: Bool?
    let viewerCanUpdate: Bool?
    let repository: Repo?
    let author: Login?
    let viewerLatestReviewRequest: RequestRef?
    let reviewRequestEvents: RequestEventsConn?
    let viewerLatestReview: ViewerReview?
    let labels: LabelsConn?
    let reviewRequests: ReviewRequestsConn?
    let latestOpinionatedReviews: ReviewsConn?
    let commits: CommitsConn?
    let headChecks: HeadChecksConn?
    let reviewThreads: ThreadsConn?
    let reviews: SubmittedReviewsConn?
    let comments: IssueCommentsConn?
    let mergedAt: String?
    let mergedBy: Login?
    let closedAt: String?

    func toInfo() -> PullRequestInfo? {
        guard let number,
              let nodeID = id,
              let repoName = repository?.name,
              let owner = repository?.owner?.login else { return nil }

        // GitHub 은 리뷰를 제출하면 그 사람을 요청 목록에서 지운다. 그래서 여기 남아 있는
        // 것이 곧 **아직 안 본 사람**이다. 팀으로 요청된 것은 팀 이름(slug)으로 온다.
        //
        // 아래 큰 초기화식 안에 인라인으로 두면 타입 검사기가 시간 안에 못 푼다(실측).
        let pending: [String] = (reviewRequests?.nodes ?? []).compactMap {
            $0.requestedReviewer?.login ?? $0.requestedReviewer?.slug
        }

        let approvals: [ApprovalInfo] = (latestOpinionatedReviews?.nodes ?? []).compactMap { node in
            guard node.state == "APPROVED", let login = node.author?.login else { return nil }
            return ApprovalInfo(login: login, commitOid: node.commit?.oid)
        }

        let threads: [PRReviewThread] = (reviewThreads?.nodes ?? []).compactMap { node in
            guard let id = node.id else { return nil }
            let comments = (node.comments?.nodes ?? []).map {
                ReviewThreadComment(author: $0.author?.login ?? "unknown",
                                    body: $0.body ?? "",
                                    createdAt: $0.createdAt ?? "")
            }
            return PRReviewThread(id: id,
                                  path: node.path,
                                  line: node.line,
                                  isResolved: node.isResolved ?? false,
                                  isOutdated: node.isOutdated ?? false,
                                  comments: comments)
        }

        // 초기화식에 인자를 하나 더 얹으면 타입 검사기가 시간 안에 못 푼다(실측).
        // 만든 뒤에 채운다.
        var info = PullRequestInfo(
            repo: RepoID(owner: owner, name: repoName),
            number: number,
            nodeID: nodeID,
            title: title ?? "",
            bodyText: body ?? "",
            author: author?.login ?? "unknown",
            isDraft: isDraft ?? false,
            state: state ?? "OPEN",
            createdAt: createdAt.flatMap { try? Date($0, strategy: .iso8601) } ?? Date(),
            updatedAt: updatedAt.flatMap { try? Date($0, strategy: .iso8601) } ?? Date(),
            headRefOid: headRefOid ?? "",
            headRefName: headRefName ?? "",
            baseRefName: baseRefName ?? "",
            additions: additions ?? 0,
            deletions: deletions ?? 0,
            changedFiles: changedFiles ?? 0,
            mergeable: MergeableState(rawValue: mergeable ?? "UNKNOWN") ?? .unknown,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            approvals: approvals,
            labels: (labels?.nodes ?? []).compactMap(\.name),
            viewerDidAuthor: viewerDidAuthor ?? false,
            viewerHasReviewRequest: viewerLatestReviewRequest?.id != nil,
            viewerLatestReviewState: viewerLatestReview?.state,
            viewerLatestReviewCommit: viewerLatestReview?.commit?.oid,
            checkState: commits?.nodes?.last?.commit?.statusCheckRollup?.state,
            checks: (headChecks?.nodes?.first?.commit?.statusCheckRollup?.contexts?.nodes ?? [])
                .compactMap { node in
                    guard let name = node.name ?? node.context,
                          let outcome = node.conclusion ?? node.state else { return nil }
                    return PRCheck(name: name, outcome: outcome)
                },
            threads: threads,
            commits: (commits?.nodes ?? []).compactMap { node in
                guard let commit = node.commit, let oid = commit.oid else { return nil }
                return PRCommit(oid: oid,
                                abbreviatedOid: commit.abbreviatedOid ?? String(oid.prefix(7)),
                                messageHeadline: commit.messageHeadline ?? "",
                                committedDate: commit.committedDate.flatMap { try? Date($0, strategy: .iso8601) } ?? Date(),
                                author: commit.author?.user?.login ?? commit.author?.name ?? "unknown")
            },
            reviewEvents: (reviews?.nodes ?? []).compactMap { node in
                guard let state = node.state,
                      let submitted = node.submittedAt.flatMap({ try? Date($0, strategy: .iso8601) })
                else { return nil }
                return PRReviewEvent(author: node.author?.login ?? "unknown",
                                     state: state,
                                     submittedAt: submitted,
                                     body: node.body ?? "")
            },
            issueComments: (comments?.nodes ?? []).compactMap { node in
                guard let created = node.createdAt.flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
                return PRIssueComment(author: node.author?.login ?? "unknown",
                                      body: node.body ?? "",
                                      createdAt: created)
            },
            mergedAt: mergedAt.flatMap { try? Date($0, strategy: .iso8601) },
            mergedBy: mergedBy?.login,
            closedAt: closedAt.flatMap { try? Date($0, strategy: .iso8601) }
        )
        info.pendingReviewers = pending
        info.viewerLatestReviewAt = viewerLatestReview?.submittedAt.flatMap { try? Date($0, strategy: .iso8601) }
        info.viewerReviewRequestedAt = viewerReviewRequestedAt
        info.viewerRequestedAsCodeOwner = viewerLatestReviewRequest?.asCodeOwner
        info.viewerCanUpdate = viewerCanUpdate
        return info
    }

    /// 나에게 걸린 마지막 리뷰 요청 시각. 팀 요청은 내가 그 팀인지 모르므로 나에게 온 것으로 친다 —
    /// 틀려도 "재요청" 쪽(목록에 남김)으로 틀린다. 받은 사건 안에 없으면 nil.
    private var viewerReviewRequestedAt: Date? {
        (reviewRequestEvents?.nodes ?? [])
            .filter { $0.requestedReviewer?.isViewer == true || $0.requestedReviewer?.__typename == "Team" }
            .compactMap { $0.createdAt.flatMap { try? Date($0, strategy: .iso8601) } }
            .max()
    }
}

struct PRListData: Decodable {
    struct PageInfo: Decodable { let hasNextPage: Bool?; let endCursor: String? }
    struct Search: Decodable {
        let issueCount: Int?
        let pageInfo: PageInfo?
        let nodes: [PRNodeDTO]?
    }
    let rateLimit: GQLRateLimit?
    let search: Search?
}

struct SinglePRData: Decodable {
    struct Repository: Decodable { let pullRequest: PRNodeDTO? }
    let repository: Repository?
}

struct AttachmentHTMLData: Decodable {
    struct HTML: Decodable { let bodyHTML: String? }
    struct HTMLNodes: Decodable { let nodes: [HTML]? }
    struct Thread: Decodable { let comments: HTMLNodes? }
    struct Threads: Decodable { let nodes: [Thread]? }
    struct PullRequest: Decodable {
        let bodyHTML: String?
        let reviews: HTMLNodes?
        let comments: HTMLNodes?
        let reviewThreads: Threads?
    }
    struct Repository: Decodable { let pullRequest: PullRequest? }
    let repository: Repository?

    var html: [String] {
        guard let pr = repository?.pullRequest else { return [] }
        let threads = pr.reviewThreads?.nodes?.flatMap { $0.comments?.nodes ?? [] } ?? []
        let nodes = (pr.reviews?.nodes ?? []) + (pr.comments?.nodes ?? []) + threads
        return ([pr.bodyHTML] + nodes.map(\.bodyHTML)).compactMap { $0 }
    }
}

struct BranchCommitsData: Decodable {
    struct Parent: Decodable { let oid: String? }
    struct Parents: Decodable { let nodes: [Parent]? }
    struct User: Decodable { let login: String? }
    struct Author: Decodable { let name: String?; let user: User? }
    struct Commit: Decodable {
        let oid: String?
        let abbreviatedOid: String?
        let messageHeadline: String?
        let committedDate: String?
        let additions: Int?
        let deletions: Int?
        let changedFilesIfAvailable: Int?
        let author: Author?
        let parents: Parents?
    }
    struct Node: Decodable { let commit: Commit? }
    struct PageInfo: Decodable { let hasPreviousPage: Bool?; let startCursor: String? }
    struct Commits: Decodable { let totalCount: Int?; let pageInfo: PageInfo?; let nodes: [Node]? }
    struct PR: Decodable { let baseRefName: String?; let headRefName: String?; let commits: Commits? }
    struct Repository: Decodable { let pullRequest: PR? }
    let repository: Repository?

    var commits: [BranchCommit] {
        (repository?.pullRequest?.commits?.nodes ?? []).compactMap { node in
            guard let commit = node.commit, let oid = commit.oid else { return nil }
            return BranchCommit(oid: oid,
                                abbreviatedOid: commit.abbreviatedOid ?? String(oid.prefix(7)),
                                headline: commit.messageHeadline ?? "",
                                authorName: commit.author?.name ?? "",
                                authorLogin: commit.author?.user?.login,
                                date: commit.committedDate.flatMap { try? Date($0, strategy: .iso8601) } ?? Date(),
                                parents: (commit.parents?.nodes ?? []).compactMap(\.oid),
                                additions: commit.additions ?? 0,
                                deletions: commit.deletions ?? 0,
                                changedFiles: commit.changedFilesIfAvailable)
        }
    }
}

struct HeadStateData: Decodable {
    struct PR: Decodable { let headRefOid: String?; let state: String?; let mergeable: String? }
    struct Repository: Decodable { let pullRequest: PR? }
    let repository: Repository?
}

struct SearchReposData: Decodable {
    struct Search: Decodable {
        let repositoryCount: Int?
        let nodes: [ViewerReposData.RepoNode]?
    }
    let search: Search?
}

struct SingleRepoData: Decodable {
    let repository: ViewerReposData.RepoNode?
}

struct ViewerReposData: Decodable {
    struct RepoNode: Decodable {
        struct BranchRef: Decodable { let name: String? }
        let nameWithOwner: String?
        let isArchived: Bool?
        let isPrivate: Bool?
        let isFork: Bool?
        let viewerPermission: String?
        let defaultBranchRef: BranchRef?
    }
    struct PageInfo: Decodable { let hasNextPage: Bool?; let endCursor: String? }
    struct Repositories: Decodable { let totalCount: Int?; let nodes: [RepoNode]?; let pageInfo: PageInfo? }
    struct OrgNode: Decodable { let login: String? }
    struct Organizations: Decodable { let nodes: [OrgNode]? }
    struct Viewer: Decodable {
        let login: String?
        let repositories: Repositories?
        let organizations: Organizations?
    }
    let viewer: Viewer?
}

struct ApprovalRulesData: Decodable {
    struct Rule: Decodable {
        let pattern: String?
        let requiresApprovingReviews: Bool?
        let requiredApprovingReviewCount: Int?
    }
    struct Rules: Decodable { let nodes: [Rule]? }
    struct BranchRef: Decodable { let name: String? }
    struct Repository: Decodable {
        let defaultBranchRef: BranchRef?
        let branchProtectionRules: Rules?
    }
    let repository: Repository?
}

struct ProtectionData: Decodable {
    struct Rule: Decodable {
        let pattern: String?
        let requiredApprovingReviewCount: Int?
        let dismissesStaleReviews: Bool?
    }
    struct Rules: Decodable { let nodes: [Rule]? }
    struct Repository: Decodable { let branchProtectionRules: Rules? }
    let repository: Repository?
}
