import Foundation

/// 팀 통계의 PR·Approve·코멘트 재료. GitHub 은 사람별 순위를 주는 API 가 없어서(조직 통계도, 레포 통계도
/// 커밋 수뿐이고 그마저 계정과 이어진 메일만 센다) 기간 안의 PR·리뷰·코멘트를 받아 앱이 센다.
extension GitHubClient {
    public struct TeamPRActivity: Sendable {
        public var pullRequests: [TeamStatEvent]
        public var approvals: [TeamStatEvent]
        /// GitHub 검색은 1,000건에서 끊는다. 넘으면 오래된 쪽 Approve 가 빠진다.
        public var truncated: Bool
    }

    /// `since` 뒤로 갱신된 PR 의 작성자·만든 때와 Approve. Approve 는 PR 을 만든 지 한참 뒤에도 달리므로
    /// 만든 날이 아니라 갱신일로 찾는다(Approve 하면 PR 이 갱신된다).
    public func teamPRActivity(_ repo: RepoID, since: Date) async throws -> TeamPRActivity {
        let query = "repo:\(repo.full) is:pr updated:>=\(GitHubClient.searchDay(since))"
        let formatter = ISO8601DateFormatter()
        var pullRequests: [TeamStatEvent] = []
        var approvals: [TeamStatEvent] = []
        var cursor: String?
        var fetched = 0
        var total = 0
        // 50개씩 20쪽이면 검색 상한(1,000건)이다.
        for _ in 0..<20 {
            var variables: [String: GQLValue] = ["q": .string(query), "n": .int(50)]
            if let cursor { variables["after"] = .string(cursor) }
            let data = try await withGatewayRetry(context: "통계 PR 검색") {
                try await graphQL(GraphQL.teamStatsPRs, variables: variables, as: TeamStatsPRData.self, timeout: 90)
            }
            total = data.search.issueCount ?? total
            for node in data.search.nodes ?? [] {
                guard let node else { continue }
                fetched += 1
                if let author = node.author, author.isPerson, let created = node.createdAt.flatMap(formatter.date) {
                    pullRequests.append(TeamStatEvent(person: author.login, at: created))
                }
                // 같은 사람이 같은 PR 을 여러 번 Approve 하면(새 커밋 뒤 다시) 처음 한 번만 센다.
                var approvers = Set<String>()
                for review in node.reviews?.nodes ?? [] {
                    guard let review, let author = review.author, author.isPerson,
                          let submitted = review.submittedAt.flatMap(formatter.date),
                          approvers.insert(author.login).inserted else { continue }
                    approvals.append(TeamStatEvent(person: author.login, at: submitted))
                }
            }
            guard data.search.pageInfo.hasNextPage, let next = data.search.pageInfo.endCursor else { break }
            cursor = next
        }
        return TeamPRActivity(pullRequests: pullRequests, approvals: approvals, truncated: total > fetched)
    }

    /// `since` 뒤로 달린 PR 코멘트 — 코드 줄 코멘트와 PR 대화 코멘트. 리뷰를 제출할 때 쓰는 본문은 넣지 않는다
    /// (Approve 와 함께 남기는 한 줄까지 세면 Approve 를 두 번 세는 셈이다).
    public func teamComments(_ repo: RepoID, since: Date) async throws -> [TeamStatEvent] {
        let stamp = ISO8601DateFormatter().string(from: since)
        // 이슈 코멘트 API 는 이슈와 PR 의 대화를 같이 준다. 주소로 PR 것만 남긴다.
        let sources = [
            ("pulls/comments", ""),
            ("issues/comments", #"select(.html_url | contains("/pull/")) | "#),
        ]
        var events: [TeamStatEvent] = []
        for (path, filter) in sources {
            // 사용자가 지워진 계정(ghost)이면 user 가 null 이다.
            let jq = #".[] | \#(filter)[(.user.login // "ghost"), (.user.type // ""), .created_at] | @tsv"#
            let result = try await gh(["api", "--paginate", "repos/\(repo.full)/\(path)?since=\(stamp)&per_page=100",
                                       "--jq", jq], timeout: 180)
            guard result.succeeded else {
                throw GitHubError.cli(GitHubClient.failureMessage(result, context: "코멘트 조회"))
            }
            events += GitHubClient.parseCommentLines(result.stdout, since: since)
        }
        return events
    }

    /// `since` 는 **수정** 시각 기준이라, 예전에 달고 요즘 고친 코멘트도 온다. 만든 시각으로 다시 거른다.
    static func parseCommentLines(_ text: String, since: Date) -> [TeamStatEvent] {
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[1] != "Bot",
                  let created = formatter.date(from: fields[2]), created >= since else { return nil }
            return TeamStatEvent(person: fields[0], at: created)
        }
    }

    /// 검색어의 날짜는 UTC 날짜로 읽힌다. 하루 앞당겨 시간대 차이로 첫날이 빠지지 않게 한다 — 더 받은 건
    /// 기간으로 다시 거른다.
    static func searchDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension GraphQL {
    static let teamStatsPRs = """
    query($q: String!, $n: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $n, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            createdAt
            author { __typename login }
            reviews(states: APPROVED, first: 100) {
              nodes { submittedAt author { __typename login } }
            }
          }
        }
      }
    }
    """
}

struct TeamStatsPRData: Decodable {
    struct Actor: Decodable {
        let __typename: String?
        let login: String

        /// dependabot 같은 봇은 GraphQL 에서 `[bot]` 꼬리 없이 온다. 종류로 거른다.
        var isPerson: Bool { __typename != "Bot" && !TeamStats.isBot(login) }
    }
    struct Review: Decodable {
        let submittedAt: String?
        let author: Actor?
    }
    struct Reviews: Decodable {
        let nodes: [Review?]?
    }
    struct Node: Decodable {
        let createdAt: String?
        let author: Actor?
        let reviews: Reviews?
    }
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
    struct Search: Decodable {
        let issueCount: Int?
        let pageInfo: PageInfo
        let nodes: [Node?]?
    }
    let search: TeamStatsPRData.Search
}
