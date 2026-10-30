import Foundation

public struct GitHubAccount: Sendable, Equatable {
    public var login: String
    public var scopes: [String]

    /// fine-grained PAT·GitHub App 토큰은 x-oauth-scopes 헤더가 없어 스코프를 알 수 없다.
    /// 이때는 경고하지 않고 실제 조회 성공 여부로 판단한다.
    public var scopesUnknown: Bool { scopes.isEmpty }

    public var hasRequiredScopes: Bool {
        guard !scopes.isEmpty else { return true }
        let hasRepo = scopes.contains("repo")
        let hasOrgRead = scopes.contains("read:org") || scopes.contains("admin:org") || scopes.contains("write:org")
        return hasRepo && hasOrgRead
    }

    public init(login: String, scopes: [String]) {
        self.login = login
        self.scopes = scopes
    }
}

public struct RepoOption: Sendable, Hashable, Identifiable {
    public var repo: RepoID
    public var isPrivate: Bool
    public var isArchived: Bool
    public var isFork: Bool
    public var defaultBranch: String?
    public var permission: String?

    public var id: String { repo.full }

    public init(repo: RepoID, isPrivate: Bool, isArchived: Bool, isFork: Bool,
                defaultBranch: String?, permission: String?) {
        self.repo = repo
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.isFork = isFork
        self.defaultBranch = defaultBranch
        self.permission = permission
    }
}

public struct ViewerRepositories: Sendable {
    public var login: String
    public var repos: [RepoOption]
    public var organizations: [String]
    public var totalCount: Int?
    /// 목록이 잘렸는지. 조직 레포가 많으면 페이지 상한에 걸린다.
    public var truncated: Bool
}

/// GitHub 리뷰 게시 payload. `event` 는 항상 명시한다(생략하면 PENDING 리뷰가 생긴다).
public struct ReviewPayload: Sendable, Codable {
    public struct Comment: Sendable, Codable {
        public var path: String
        public var line: Int
        public var side: String
        public var start_line: Int?
        public var start_side: String?
        public var body: String

        public init(path: String, line: Int, side: String, start_line: Int? = nil,
                    start_side: String? = nil, body: String) {
            self.path = path
            self.line = line
            self.side = side
            self.start_line = start_line
            self.start_side = start_side
            self.body = body
        }
    }

    public var commit_id: String
    public var event: String
    public var body: String
    public var comments: [Comment]

    public init(commitID: String, event: String, body: String, comments: [Comment]) {
        self.commit_id = commitID
        self.event = event
        self.body = body
        self.comments = comments
    }
}

public enum GitHubError: Error, LocalizedError, Sendable {
    case ghMissing(String)
    case notLoggedIn(String)
    case cli(String)
    case graphQL([String])
    case decode(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .ghMissing(let path):
            return "gh CLI 를 찾을 수 없습니다: \(path)\n터미널에서 `brew install gh` 후 설정에서 경로를 확인하세요."
        case .notLoggedIn(let detail):
            return "GitHub 로그인이 필요합니다. 터미널에서 `gh auth login` 을 실행하세요.\n\(detail)"
        case .cli(let message):
            return "gh 호출 실패: \(message)"
        case .graphQL(let messages):
            return "GitHub API 오류: \(messages.joined(separator: " / "))"
        case .decode(let raw):
            return "GitHub 응답을 해석할 수 없습니다: \(raw)"
        case .notFound:
            return "대상을 찾을 수 없습니다."
        }
    }
}

enum GQLValue: Sendable {
    case string(String)
    case int(Int)
}

/// 모든 GitHub 호출은 `gh` 서브프로세스를 경유한다. 앱은 토큰을 직접 보관하지 않는다.
public struct GitHubClient: Sendable {
    public let ghPath: String
    /// 물어볼 GitHub 호스트. 엔터프라이즈면 `github.mycorp.com` 같은 이름이 온다.
    public let host: String
    private let runner = ProcessRunner()

    public init(ghPath: String, host: String = GitHubHost.dotCom) {
        self.ghPath = ghPath
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        self.host = trimmed.isEmpty ? GitHubHost.dotCom : trimmed
    }

    /// 사람이 웹에서 볼 주소. 엔터프라이즈는 도메인이 다르다.
    public var webBase: String { "https://\(host)" }

    // MARK: - 저수준

    func gh(_ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 60) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: ghPath) else {
            throw GitHubError.ghMissing(ghPath)
        }
        let spec = ProcessSpec(executable: ghPath,
                               arguments: GitHubClient.hostArguments(arguments, host: host),
                               stdin: stdin,
                               environment: ProcessEnvironment.base(),
                               timeout: timeout)
        let result = try await runner.run(spec)
        // 화면을 바꾸면 진행 중이던 요청이 취소된다. 이건 오류가 아니다.
        if result.cancelled || Task.isCancelled {
            throw CancellationError()
        }
        return result
    }

    /// 모든 호출이 `gh api` 다. `--hostname` 을 **여기 한 자리에서** 붙여야, 호출 하나를
    /// 빠뜨려 엔터프라이즈 계정으로 github.com 에 물어보는 일이 생기지 않는다.
    /// github.com 이면 붙이지 않는다 — `gh` 의 기본값이라 붙여도 같고, 로그가 짧아진다.
    static func hostArguments(_ arguments: [String], host: String) -> [String] {
        guard arguments.first == "api",
              host.caseInsensitiveCompare(GitHubHost.dotCom) != .orderedSame else { return arguments }
        var arguments = arguments
        arguments.insert(contentsOf: ["--hostname", host], at: 1)
        return arguments
    }

    /// 흔한 설치 자리. Homebrew 는 Apple Silicon 과 Intel 이 다르다.
    public static let candidatePaths: [String] = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        "\(NSHomeDirectory())/.local/bin/gh",
    ]

    /// `gh` 실행 파일을 찾는다. 설정에 경로 칸을 두지 않는 대신 앱이 찾아 준다 —
    /// 사용자가 경로를 직접 적을 일은 거의 없는데, 칸이 있으면 오타로 망가지기만 한다.
    ///
    /// 못 찾으면 사용자의 셸(`~/.zshrc` 까지 읽는)에 묻는다 — `ExecutableLocator` 참고.
    public static func discoverPath() async -> String? {
        await ExecutableLocator.find("gh", preferred: candidatePaths,
                                     fallback: ExecutableLocator.userToolDirectories().map { "\($0)/gh" })
    }

    /// `gh` 에 로그인돼 있는 호스트 목록. 회사·개인 계정을 같이 쓰는 맥이 흔하다.
    public static func loggedInHosts(ghPath: String) async -> [GitHubHost] {
        guard FileManager.default.isExecutableFile(atPath: ghPath) else { return [] }
        let spec = ProcessSpec(executable: ghPath,
                               arguments: ["auth", "status"],
                               stdin: nil,
                               environment: ProcessEnvironment.base(),
                               timeout: 20)
        // 로그인된 호스트가 하나도 없으면 gh 는 0 이 아닌 코드로 끝난다. 그것도 답이다.
        guard let result = try? await ProcessRunner().run(spec) else { return [] }
        return GHAuthStatus.parse(result.stdout + "\n" + result.stderr)
    }

    /// 실패 메시지가 비어 있으면 사용자가 원인을 알 수 없다. 종료 코드라도 남긴다.
    static func failureMessage(_ result: ProcessResult, context: String) -> String {
        let detail = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let detail { return String(detail.prefix(300)) }
        if result.timedOut { return "\(context): 제한 시간을 넘겼습니다." }
        return "\(context): gh 가 종료 코드 \(result.exitCode) 로 끝났고 출력이 없습니다."
    }

    /// `gh api graphql` 에 넘길 인자와 표준 입력.
    ///
    /// Foundation `Process` 는 인자를 NFD 로 바꿔 넘긴다 — 한글 검색어가 자모로 풀려 GitHub 검색이 0건이 됐다
    /// (2026-10-29 실측: 같은 쿼리를 터미널의 gh 로 치면 수백 건). 영문·숫자뿐인 변수는 지금처럼 인자로 두고,
    /// 그 밖의 글자가 든 요청만 본문(JSON)을 표준 입력으로 넘긴다 — 표준 입력은 바이트 그대로 간다.
    static func graphQLRequest(_ query: String, variables: [String: GQLValue]) -> (arguments: [String], stdin: String?) {
        let needsBody = variables.values.contains { value in
            if case .string(let s) = value { return !s.unicodeScalars.allSatisfy(\.isASCII) }
            return false
        }
        if needsBody {
            var values: [String: Any] = [:]
            for (key, value) in variables {
                switch value {
                case .string(let s): values[key] = s
                case .int(let i): values[key] = i
                }
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["query": query, "variables": values]))
                .flatMap { String(data: $0, encoding: .utf8) }
            if let body { return (["api", "graphql", "--input", "-"], body) }
        }
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables {
            switch value {
            case .string(let s): args += ["-f", "\(key)=\(s)"]
            case .int(let i): args += ["-F", "\(key)=\(i)"]
            }
        }
        return (args, nil)
    }

    func graphQL<T: Decodable>(_ query: String,
                                       variables: [String: GQLValue],
                                       as type: T.Type,
                                       timeout: TimeInterval = 60) async throws -> T {
        let request = GitHubClient.graphQLRequest(query, variables: variables)
        let result = try await gh(request.arguments, stdin: request.stdin, timeout: timeout)
        if result.timedOut {
            throw GitHubError.cli("GitHub 조회가 제한 시간(\(Int(timeout))초)을 넘겼습니다.")
        }
        let data = Data(result.stdout.utf8)
        if let envelope = try? JSONDecoder().decode(GQLEnvelope<T>.self, from: data) {
            // errors 가 있으면 data 가 있어도 던진다. 모든 DTO 필드가 optional 이라
            // RATE_LIMITED·권한 오류 응답도 "정상 디코드된 빈 결과" 로 통과해 버린다.
            if let errors = envelope.errors, !errors.isEmpty {
                throw GitHubError.graphQL(errors.map(\.message))
            }
            if let payload = envelope.data, result.succeeded {
                return payload
            }
        }
        if !result.succeeded {
            let message = GitHubClient.failureMessage(result, context: "GraphQL 조회")
            if message.lowercased().contains("not logged") || message.contains("gh auth login") {
                throw GitHubError.notLoggedIn(message)
            }
            throw GitHubError.cli(message)
        }
        throw GitHubError.decode(String(result.stdout.prefix(400)))
    }

    // MARK: - 인증

    public func account() async throws -> GitHubAccount {
        let result = try await gh(["api", "-i", "user"], timeout: 30)
        guard result.succeeded else {
            throw GitHubError.notLoggedIn(GitHubClient.failureMessage(result, context: "계정 조회"))
        }
        guard let account = GitHubClient.parseAccount(from: result.stdout) else {
            throw GitHubError.decode(String(result.stdout.suffix(200)))
        }
        return account
    }

    /// `gh api -i user` 응답(헤더 + JSON 본문)에서 계정과 토큰 스코프를 뽑는다.
    /// 주의: HTTP 헤더는 CRLF 로 끝나고 Swift 에서 "\r\n" 은 **단일 Character** 다.
    /// `split(separator: "\n")` 으로는 줄이 나뉘지 않으므로 `isNewline` 으로 나눠야 한다.
    public static func parseAccount(from response: String) -> GitHubAccount? {
        var bodyStart: String.Index?
        for separator in ["\r\n\r\n", "\n\n", "\r\r"] {
            if let range = response.range(of: separator) {
                bodyStart = range.upperBound
                break
            }
        }
        let headerText = bodyStart.map { String(response[response.startIndex..<$0]) } ?? ""
        var scopes: [String] = []
        for line in headerText.split(whereSeparator: \.isNewline) {
            guard line.lowercased().hasPrefix("x-oauth-scopes:") else { continue }
            let value = line.drop(while: { $0 != ":" }).dropFirst()
            scopes = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let body = bodyStart.map { String(response[$0...]) } ?? response
        struct User: Decodable { let login: String }
        guard let user = try? JSONDecoder().decode(User.self, from: Data(body.utf8)) else { return nil }
        return GitHubAccount(login: user.login, scopes: scopes)
    }

    // MARK: - 조회

    /// R4: 닫힌 PR 은 서버에서(`is:open`) 걸러 포인트와 전송량을 아낀다.
    /// 게이트웨이 오류(502·503·504)는 잠깐 뒤 사라지는 일이 많다. 백오프로 다시 물어본다.
    /// 그 밖의 오류(권한·rate limit·잘못된 쿼리)는 재시도해도 같으므로 그대로 던진다.
    func withGatewayRetry<T>(context: String,
                             delays: [Duration] = [.milliseconds(1500), .seconds(4)],
                             operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                let text = "\(error) \(error.localizedDescription)"
                let transient = ["502", "503", "504", "timeout", "Bad Gateway"].contains { text.contains($0) }
                guard transient, attempt < delays.count else { throw error }
                Log.info("\(context) 일시 오류 — \(delays[attempt]) 뒤 재시도 (\(attempt + 1)/\(delays.count))", "github")
                try await Task.sleep(for: delays[attempt])
                attempt += 1
            }
        }
    }

    public static func searchQuery(repos: [RepoID], includeClosed: Bool) -> String {
        var parts = repos.map { "repo:\($0.full)" }
        parts.append("is:pr")
        if !includeClosed { parts.append("is:open") }
        // 앱은 목록을 **올린 시각** 순으로 그린다(AppModel.refresh). 서버를 활동 순으로 두면
        // 두 기준이 어긋나, 페이지를 나눠 받을 때 뒷 페이지의 PR 이 앞 페이지 위로 끼어든다
        // (오래전에 올렸지만 방금 활동한 PR ↔ 어제 올렸지만 조용한 PR). 읽던 자리를 잃는다.
        // 서버도 올린 시각 순으로 두면 뒷 페이지는 항상 아래에만 붙는다.
        parts.append("sort:created-desc")
        return parts.joined(separator: " ")
    }

    /// 탭(스코프)별 검색 쿼리. 닫힘을 포함할 때는 반드시 기간을 함께 건다
    /// (조건 없이 긁으면 결과가 수천 건이라 GitHub 이 502 로 끊는다 — 실측).
    public static func searchQuery(repos: [RepoID],
                                   scope: PRListScope,
                                   viewerLogin: String?,
                                   now: Date = Date()) -> String {
        var parts = repos.map { "repo:\($0.full)" }
        parts.append("is:pr")
        if !scope.includesClosed { parts.append("is:open") }
        if let hours = scope.windowHours {
            let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
            // ISO8601Format() 은 2027-01-14T10:13:20Z 형태를 준다.
            // `.formatted(.iso8601...)` 는 타임존 조각만 뱉는 함정이 있어 쓰지 않는다.
            parts.append("updated:>=\(cutoff.ISO8601Format())")
        }
        if scope.requiresMyApproval, let viewerLogin, !viewerLogin.isEmpty {
            parts.append("reviewed-by:\(viewerLogin)")
        }
        parts.append("sort:created-desc")  // 위 주석 참고
        return parts.joined(separator: " ")
    }



    public struct PullRequestPage: Sendable {
        public var prs: [PullRequestInfo]
        public var rateRemaining: Int?
        /// 서버가 알려준 전체 건수. 받은 개수보다 크면 일부만 표시된 것이다.
        public var totalCount: Int?
        public var truncated: Bool
    }

    /// 한 요청에서 몇 건 이하로 줄이면 포기하는가. 이 밑으로 내려가면 페이지 수만 늘고 의미가 없다.
    static let minSearchPageSize = 12
    /// 페이지를 무한히 넘기지 않게 두는 뒷문. 건수 상한(`maxResults`)이 먼저 걸리는 게 정상이다.
    public static let searchPageCeiling = 24

    /// 검색 한 페이지. 요청이 GitHub 의 실행 예산을 넘기면 페이지 크기를 절반으로 줄여 다시 받는다.
    ///
    /// 이 오류(`RESOURCE_LIMITS_EXCEEDED`)는 502 처럼 기다렸다 다시 물어봐도 그대로다 —
    /// 같은 크기로 재시도하면 똑같이 거절당한다. 줄여서 다시 받는 것만이 통한다.
    /// 줄어든 크기는 돌려주고, 다음 페이지도 그 크기로 이어 간다(한 번 넘겼으면 다음도 넘긴다).
    private func searchPage(query: String,
                            cursor: String?,
                            pageSize: Int) async throws -> (data: PRListData, pageSize: Int) {
        var size = max(GitHubClient.minSearchPageSize, pageSize)
        while true {
            var variables: [String: GQLValue] = ["q": .string(query), "n": .int(size)]
            if let cursor { variables["after"] = .string(cursor) }
            do {
                // GitHub 검색은 간헐적으로 502·503·504 를 낸다(실측: 13초간 연속 502 후 자연 회복).
                // 한 번만 재시도하면 부족해서 백오프로 세 번까지 물어본다.
                let data = try await withGatewayRetry(context: "PR 검색") {
                    try await graphQL(GraphQL.prList, variables: variables, as: PRListData.self)
                }
                return (data, size)
            } catch {
                let text = "\(error) \(error.localizedDescription)"
                let overBudget = ["RESOURCE_LIMITS_EXCEEDED", "Resource limits for this query exceeded"]
                    .contains { text.contains($0) }
                guard overBudget, size > GitHubClient.minSearchPageSize else { throw error }
                let next = max(GitHubClient.minSearchPageSize, size / 2)
                Log.info("PR 검색이 한 요청 예산을 넘겼다 — 페이지 크기 \(size) → \(next) 로 줄여 다시 받는다", "github")
                size = next
            }
        }
    }

    /// 열린 PR 은 전량 확보한다(닫힌 PR 이 최근 갱신 순 자리를 차지해 열린 PR 을 밀어내지 않도록).
    ///
    /// 페이지 수가 아니라 **건수**로 멈춘다. 요청이 예산을 넘겨 페이지 크기가 절반으로 줄어들면
    /// 같은 건수를 받는 데 페이지가 두 배 필요해지는데, 페이지 수로 끊으면 그때 목록이 잘린다.
    /// 검색 결과 한 페이지. 화면이 첫 페이지만 받고 먼저 그린 뒤 나머지를 이어 받을 수 있게
    /// 커서를 그대로 돌려준다. 30일 탭은 전부 받는 데 40초가 넘게 걸려서(실측),
    /// 다 받고 나서야 그리면 그동안 빈 화면을 본다.
    public struct PullRequestSlice: Sendable {
        public var prs: [PullRequestInfo]
        public var rateRemaining: Int?
        public var totalCount: Int?
        public var endCursor: String?
        public var hasNextPage: Bool
        /// 다음 요청에 이어 쓸 페이지 크기. GitHub 이 실행 예산 초과를 내면 절반으로 줄어 있다.
        public var nextPageSize: Int
    }

    /// 기본 페이지 크기. 닫힘을 포함하면 한 건당 받아 오는 것이 많아 절반으로 잡는다.
    public static func defaultPageSize(scope: PRListScope?, includeClosed: Bool) -> Int {
        scope?.pageSize ?? (includeClosed ? 50 : 100)
    }

    public static func listQuery(repos: [RepoID],
                                 includeClosed: Bool,
                                 scope: PRListScope?,
                                 viewerLogin: String?) -> String {
        scope.map { searchQuery(repos: repos, scope: $0, viewerLogin: viewerLogin) }
            ?? searchQuery(repos: repos, includeClosed: includeClosed)
    }

    public func pullRequestSlice(repos: [RepoID],
                                 includeClosed: Bool = false,
                                 scope: PRListScope? = nil,
                                 viewerLogin: String? = nil,
                                 cursor: String? = nil,
                                 pageSize: Int? = nil) async throws -> PullRequestSlice {
        guard !repos.isEmpty else {
            return PullRequestSlice(prs: [], rateRemaining: nil, totalCount: 0,
                                    endCursor: nil, hasNextPage: false, nextPageSize: 0)
        }
        let query = GitHubClient.listQuery(repos: repos, includeClosed: includeClosed,
                                           scope: scope, viewerLogin: viewerLogin)
        let requested = pageSize ?? GitHubClient.defaultPageSize(scope: scope, includeClosed: includeClosed)
        return try await searchSlice(query: query, cursor: cursor, pageSize: requested)
    }

    /// 쿼리를 그대로 받아 한 페이지. 목록 검색칸의 전체 PR 검색(`PRSearchPlan`)이 쓴다.
    /// 닫힌 PR 이 섞이므로 기본 크기는 닫힘 포함 탭과 같은 50 이다(`PRListScope.pageSize` 실측 주석).
    public func searchSlice(query: String, cursor: String? = nil, pageSize: Int = 50) async throws -> PullRequestSlice {
        let (data, usedSize) = try await searchPage(query: query, cursor: cursor, pageSize: pageSize)
        guard let search = data.search else {
            throw GitHubError.graphQL(["검색 결과가 비어 있습니다(권한 또는 rate limit 확인)."])
        }
        return PullRequestSlice(prs: (search.nodes ?? []).compactMap { $0.toInfo() },
                                rateRemaining: data.rateLimit?.remaining,
                                totalCount: search.issueCount,
                                endCursor: search.pageInfo?.endCursor,
                                hasNextPage: search.pageInfo?.hasNextPage == true,
                                nextPageSize: usedSize)
    }

    public func pullRequests(repos: [RepoID],
                             includeClosed: Bool = false,
                             scope: PRListScope? = nil,
                             viewerLogin: String? = nil,
                             maxResults: Int? = nil) async throws -> PullRequestPage {
        guard !repos.isEmpty else { return PullRequestPage(prs: [], rateRemaining: nil, totalCount: 0, truncated: false) }
        let limit = maxResults ?? scope?.maxResults ?? 400
        var pageSize = GitHubClient.defaultPageSize(scope: scope, includeClosed: includeClosed)
        var cursor: String?
        var collected: [PullRequestInfo] = []
        var remaining: Int?
        var total: Int?
        var truncated = false
        for _ in 0..<GitHubClient.searchPageCeiling {
            let slice = try await pullRequestSlice(repos: repos, includeClosed: includeClosed,
                                                   scope: scope, viewerLogin: viewerLogin,
                                                   cursor: cursor, pageSize: pageSize)
            pageSize = slice.nextPageSize
            remaining = slice.rateRemaining ?? remaining
            total = slice.totalCount ?? total
            collected.append(contentsOf: slice.prs)
            guard slice.hasNextPage, let end = slice.endCursor else { break }
            cursor = end
            if collected.count >= limit {
                truncated = true
                break
            }
        }
        if let total, collected.count < total { truncated = true }
        return PullRequestPage(prs: GitHubClient.deduped(collected), rateRemaining: remaining,
                               totalCount: total, truncated: truncated)
    }

    /// 검색 커서는 실시간으로 재정렬되는 결과 위의 오프셋이다. 페이지 사이에 PR 이 갱신되면
    /// 경계 항목이 두 페이지에 모두 나온다. 여기서 한 번 걸러 낸다.
    public static func deduped(_ prs: [PullRequestInfo]) -> [PullRequestInfo] {
        var seen = Set<String>()
        return prs.filter { seen.insert($0.id).inserted }
    }

    /// 파일 하나의 실제 내용. 이미지처럼 diff 로는 볼 수 없는 파일을 보여줄 때만 쓴다.
    /// 1MB 를 넘으면 contents API 가 본문을 비워 보내므로 blob API 로 한 번 더 간다.
    public func fileContent(repo: RepoID, path: String, ref: String) async throws -> Data {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let result = try await gh(["api", "repos/\(repo.full)/contents/\(escaped)?ref=\(ref)"], timeout: 60)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.cli(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        if let encoded = json["content"] as? String, !encoded.isEmpty {
            let cleaned = encoded.replacingOccurrences(of: "\n", with: "")
            if let decoded = Data(base64Encoded: cleaned) { return decoded }
        }
        // 큰 파일: blob 으로 다시 받는다.
        guard let sha = json["sha"] as? String else {
            throw GitHubError.cli("파일 내용을 받지 못했습니다: \(path)")
        }
        let blob = try await gh(["api", "repos/\(repo.full)/git/blobs/\(sha)"], timeout: 120)
        guard blob.succeeded, let blobData = blob.stdout.data(using: .utf8),
              let blobJSON = try? JSONSerialization.jsonObject(with: blobData) as? [String: Any],
              let encoded = blobJSON["content"] as? String,
              let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubError.cli("blob 을 받지 못했습니다: \(path)")
        }
        return decoded
    }

    /// 그 커밋의 파일 수와 크기 합 — PR 스냅샷 확인창에 "받을 코드 약 120MB" 로 보인다.
    /// 파일 목록은 수 MB 라 앱으로 가져오지 않고 gh 안에서(`--jq`) 세어 숫자만 받는다.
    public func codeSize(_ repo: RepoID, ref: String) async throws -> CodeSize {
        let jq = #"{t: .truncated, n: ([.tree[] | select(.type == "blob")] | length), b: ([.tree[] | select(.type == "blob") | .size] | add)}"#
        let result = try await gh(["api", "repos/\(repo.full)/git/trees/\(ref)?recursive=1", "--jq", jq], timeout: 60)
        guard result.succeeded, let size = Self.parseCodeSize(result.stdout) else {
            throw GitHubError.cli(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return size
    }

    static func parseCodeSize(_ output: String) -> CodeSize? {
        struct Payload: Decodable {
            let t: Bool?
            let n: Int?
            let b: Int64?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(output.utf8)),
              let files = payload.n else { return nil }
        return CodeSize(files: files, bytes: payload.b ?? 0, truncated: payload.t ?? false)
    }

    /// 레포 전체 크기(바이트) — "레포 전체(2.3GB)를 다 받지는 않습니다" 에 쓴다. GitHub 는 KB 로 준다.
    public func repositorySize(_ repo: RepoID) async throws -> Int64 {
        let result = try await gh(["api", "repos/\(repo.full)", "--jq", ".size"], timeout: 30)
        guard result.succeeded,
              let kilobytes = Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitHubError.cli(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return kilobytes * 1024
    }

    /// 기본 브랜치에 있는 파일 경로 전부 — 제외 규칙 자동완성의 재료(ExclusionCatalog). 큰 레포에서 1만여 개·
    /// 2초 남짓(실측). 파일이 10만 개를 넘으면 GitHub 가 잘라 보낸다(`truncated`) — 그래도 받은 만큼 쓴다.
    public func repositoryFilePaths(_ repo: RepoID) async throws -> (paths: [String], truncated: Bool) {
        let jq = #"{t: .truncated, p: [.tree[] | select(.type == "blob") | .path]}"#
        let result = try await gh(["api", "repos/\(repo.full)/git/trees/HEAD?recursive=1", "--jq", jq], timeout: 60)
        struct Payload: Decodable {
            let t: Bool?
            let p: [String]?
        }
        guard result.succeeded, let payload = try? JSONDecoder().decode(Payload.self, from: Data(result.stdout.utf8)) else {
            throw GitHubError.cli(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return (payload.p ?? [], payload.t ?? false)
    }

    /// 최근 PR(열림·머지, 갱신 순) 마다 바뀐 파일.
    public func recentPullRequestFiles(_ repo: RepoID, count: Int = 50) async throws -> [[ExclusionCatalog.PRFile]] {
        let data = try await graphQL(GraphQL.recentPRFiles,
                                     variables: ["owner": .string(repo.owner), "name": .string(repo.name), "n": .int(count)],
                                     as: RecentPRFilesData.self,
                                     timeout: 60)
        return (data.repository?.pullRequests?.nodes ?? []).map { $0?.files?.nodes?.compactMap { $0 } ?? [] }
    }

    /// 레포 목록에 없는 이름을 직접 찾는다(조직 레포가 많아 목록이 잘리는 경우 대비).
    /// 검색어 조립은 `RepoQuery.searchTerms` 가 한다 — 한 칸에 오너와 이름이 같이 들어온다.
    public func searchRepositories(terms: [String], limit: Int = 20) async throws -> [RepoOption] {
        guard !terms.isEmpty else { return [] }
        let data = try await graphQL(GraphQL.searchRepos,
                                    variables: ["q": .string(terms.joined(separator: " ")), "n": .int(limit)],
                                    as: SearchReposData.self,
                                    timeout: 30)
        return (data.search?.nodes ?? []).compactMap { node in
            guard let full = node.nameWithOwner, let repo = RepoID(full: full) else { return nil }
            return RepoOption(repo: repo,
                              isPrivate: node.isPrivate ?? false,
                              isArchived: node.isArchived ?? false,
                              isFork: node.isFork ?? false,
                              defaultBranch: node.defaultBranchRef?.name,
                              permission: node.viewerPermission)
        }
    }

    /// 목록에 없는 레포를 이름으로 직접 확인한다.
    public func repository(_ repo: RepoID) async throws -> RepoOption? {
        let data = try await graphQL(GraphQL.singleRepo,
                                    variables: ["owner": .string(repo.owner), "name": .string(repo.name)],
                                    as: SingleRepoData.self,
                                    timeout: 30)
        guard let node = data.repository,
              let full = node.nameWithOwner,
              let parsed = RepoID(full: full) else { return nil }
        return RepoOption(repo: parsed,
                          isPrivate: node.isPrivate ?? false,
                          isArchived: node.isArchived ?? false,
                          isFork: node.isFork ?? false,
                          defaultBranch: node.defaultBranchRef?.name,
                          permission: node.viewerPermission)
    }

    public func pullRequest(_ repo: RepoID, number: Int) async throws -> PullRequestInfo? {
        let data = try await graphQL(GraphQL.singlePR,
                                     variables: ["owner": .string(repo.owner),
                                                 "name": .string(repo.name),
                                                 "number": .int(number)],
                                     as: SinglePRData.self)
        return data.repository?.pullRequest?.toInfo()
    }

    /// PR 본문·대화에 붙은 첨부 그림의 서명 주소(자산 ID → 주소). 5분 뒤 만료된다(GitHubAttachment 주석).
    public func attachmentImageURLs(_ repo: RepoID, number: Int) async throws -> [String: URL] {
        let data = try await graphQL(GraphQL.attachmentHTML,
                                     variables: ["owner": .string(repo.owner),
                                                 "name": .string(repo.name),
                                                 "number": .int(number)],
                                     as: AttachmentHTMLData.self)
        return data.html.reduce(into: [:]) { found, html in
            found.merge(GitHubAttachment.signedURLs(inHTML: html)) { first, _ in first }
        }
    }

    /// 게시 직전 확인용 경량 조회.
    public func headState(_ repo: RepoID, number: Int) async throws -> (sha: String, state: String, mergeable: MergeableState) {
        let data = try await graphQL(GraphQL.headState,
                                     variables: ["owner": .string(repo.owner),
                                                 "name": .string(repo.name),
                                                 "number": .int(number)],
                                     as: HeadStateData.self,
                                     timeout: 30)
        guard let pr = data.repository?.pullRequest, let sha = pr.headRefOid else {
            throw GitHubError.notFound
        }
        return (sha, pr.state ?? "OPEN", MergeableState(rawValue: pr.mergeable ?? "UNKNOWN") ?? .unknown)
    }

    /// unified diff 전체. 요청 1회로 받고 headSha 키로 캐시한다.
    public func diff(_ repo: RepoID, number: Int) async throws -> String {
        let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)",
                                  "-H", "Accept: application/vnd.github.diff"],
                                 timeout: 120)
        if result.timedOut {
            throw GitHubError.cli("diff 조회가 제한 시간을 넘겼습니다.")
        }
        guard result.succeeded else {
            let message = GitHubClient.failureMessage(result, context: "diff 조회")
            // 파일 300개·2만 줄이 넘으면 통째로는 안 준다. 파일 목록으로 받아 같은 모양으로 다시 짠다(PRFilesDiff).
            if PRFilesDiff.isTooLargeError(message) {
                return try await diffFromFileList(repo, number: number)
            }
            throw GitHubError.cli(message)
        }
        return result.stdout
    }

    /// 큰 PR 의 diff 를 파일 목록 API 로 받는다(100개씩, 최대 3,000개).
    func diffFromFileList(_ repo: RepoID, number: Int) async throws -> String {
        var files: [PRFilesDiff.File] = []
        for page in 1...PRFilesDiff.maxPages {
            let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)/files?per_page=\(PRFilesDiff.pageSize)&page=\(page)"],
                                      timeout: 60)
            guard result.succeeded else {
                throw GitHubError.cli(GitHubClient.failureMessage(result, context: "PR 파일 목록 조회"))
            }
            let batch = try JSONDecoder().decode([PRFilesDiff.File].self, from: Data(result.stdout.utf8))
            files += batch
            if batch.count < PRFilesDiff.pageSize { break }
            // 마지막 쪽까지 꽉 찼으면 뒤에 더 있을 수 있다. 일부만 보고 리뷰하면 빠진 파일을 모른 채 넘어간다.
            if page == PRFilesDiff.maxPages {
                throw GitHubError.cli("파일이 \(PRFilesDiff.maxPages * PRFilesDiff.pageSize)개를 넘어 GitHub 이 목록을 다 주지 않습니다. 전체 리뷰(로컬 클론)로 보세요.")
            }
        }
        Log.info("diff 가 너무 커 파일 목록으로 받았다 \(repo.full)#\(number): 파일 \(files.count)개", "github")
        return PRFilesDiff.unifiedDiff(from: files)
    }

    /// 두 커밋 사이의 diff. "리뷰한 뒤로 무엇이 바뀌었나" 를 보는 데 쓴다.
    ///
    /// PR 전체 diff 로는 답할 수 없다 — 리뷰 당시에도 있던 변경과 그 뒤에 생긴 변경이
    /// 섞여 있어서, 새 커밋이 이 지적을 고쳤는지 가릴 수 없다.
    public func compareDiff(_ repo: RepoID, base: String, head: String) async throws -> String {
        let result = try await gh(["api", "repos/\(repo.full)/compare/\(base)...\(head)",
                                  "-H", "Accept: application/vnd.github.diff"],
                                 timeout: 120)
        if result.timedOut {
            throw GitHubError.cli("커밋 비교가 제한 시간을 넘겼습니다.")
        }
        guard result.succeeded else {
            throw GitHubError.cli(GitHubClient.failureMessage(result, context: "커밋 비교"))
        }
        return result.stdout
    }

    /// 커밋 탭 — PR 브랜치의 커밋과 부모. PR 단건 조회의 커밋(최근 30개)에는 부모가 없어 그래프를 못 그린다.
    /// 최신 쪽부터 100개씩 받는다. GitHub 이 250개에서 끊으니 3쪽이면 끝난다(넘으면 `isTruncated` — 오래된 쪽이 빠진다).
    public func branchCommits(_ repo: RepoID, number: Int) async throws -> BranchCommits {
        var commits: [BranchCommit] = []
        var cursor: String?
        var base = "", head = ""
        var total = 0
        for _ in 0..<3 {
            var variables: [String: GQLValue] = ["owner": .string(repo.owner),
                                                 "name": .string(repo.name),
                                                 "number": .int(number)]
            if let cursor { variables["before"] = .string(cursor) }
            let data = try await graphQL(GraphQL.branchCommits, variables: variables, as: BranchCommitsData.self)
            guard let pr = data.repository?.pullRequest else { throw GitHubError.notFound }
            base = pr.baseRefName ?? base
            head = pr.headRefName ?? head
            total = pr.commits?.totalCount ?? total
            // 쪽 안은 오래된 → 새 순서다. 뒤에서부터 받으니 앞에 붙인다.
            commits = data.commits + commits
            guard pr.commits?.pageInfo?.hasPreviousPage == true, let previous = pr.commits?.pageInfo?.startCursor else { break }
            cursor = previous
        }
        return BranchCommits(baseRefName: base, headRefName: head, commits: commits,
                             totalCount: max(total, commits.count))
    }

    /// 커밋 하나의 unified diff. 머지 커밋은 GitHub 이 첫 부모 기준으로 준다.
    /// 너무 커서 통째로 안 주면 파일 목록(커밋 JSON 의 files)으로 받아 같은 모양으로 다시 짠다.
    public func commitDiff(_ repo: RepoID, sha: String) async throws -> String {
        let result = try await gh(["api", "repos/\(repo.full)/commits/\(sha)",
                                  "-H", "Accept: application/vnd.github.diff"],
                                 timeout: 120)
        if result.timedOut {
            throw GitHubError.cli("커밋 diff 조회가 제한 시간을 넘겼습니다.")
        }
        guard result.succeeded else {
            let message = GitHubClient.failureMessage(result, context: "커밋 diff 조회")
            guard PRFilesDiff.isTooLargeError(message) else { throw GitHubError.cli(message) }
            let files = try await gh(["api", "repos/\(repo.full)/commits/\(sha)?per_page=300", "--jq", ".files"],
                                     timeout: 120)
            guard files.succeeded else {
                throw GitHubError.cli(GitHubClient.failureMessage(files, context: "커밋 파일 목록 조회"))
            }
            let decoded = try JSONDecoder().decode([PRFilesDiff.File].self, from: Data(files.stdout.utf8))
            return PRFilesDiff.unifiedDiff(from: decoded)
        }
        return result.stdout
    }

    /// 커밋 탭 diff — 커밋 하나든 범위든.
    public func diff(_ repo: RepoID, spec: CommitDiffSpec) async throws -> String {
        switch spec {
        case .commit(let sha): return try await commitDiff(repo, sha: sha)
        case .range(let base, let head): return try await compareDiff(repo, base: base, head: head)
        }
    }

    /// 두 커밋 사이 커밋 목록. 게시 직전에 "리뷰한 뒤로 무엇이 올라왔나" 를 보여 주는 데 쓴다.
    ///
    /// PR 단건 조회의 커밋 목록(최근 30개)으로는 모자라다 — 거기에 리뷰한 커밋이 없을 때 30개 넘게
    /// 올라온 것인지 강제 푸시로 빠진 것인지 가릴 수 없다. compare 는 그 둘을 status 로 말해 준다.
    /// 응답에 파일 목록까지 실려 커지므로 필요한 칸만 `--jq` 로 추린다.
    public func compareCommits(_ repo: RepoID, base: String, head: String) async throws -> CommitComparison.Outcome {
        let result = try await gh(["api", "repos/\(repo.full)/compare/\(base)...\(head)?per_page=100",
                                   "--jq", "{status: .status, total: .total_commits, commits: [.commits[] | {oid: .sha, message: .commit.message}]}"],
                                  timeout: 60)
        guard result.succeeded else {
            let output = result.stderr + result.stdout
            if CommitComparison.isMissingBase(output) { return .baseMissing }
            throw GitHubError.cli(GitHubClient.failureMessage(result, context: "커밋 비교"))
        }
        return .compared(try JSONDecoder().decode(CommitComparison.self, from: Data(result.stdout.utf8)))
    }

    /// 최근 push 순으로 일부만 받는다. 페이지를 키우면 레포가 많은 계정에서 GitHub 이 502 를 낸다.
    public func viewerRepositories(maxPages: Int = 2) async throws -> ViewerRepositories {
        var cursor: String?
        var options: [RepoOption] = []
        var login = ""
        var orgs: [String] = []
        var total: Int?
        for _ in 0..<maxPages {
            var variables: [String: GQLValue] = [:]
            if let cursor { variables["after"] = .string(cursor) }
            let data = try await graphQL(GraphQL.viewerRepos, variables: variables, as: ViewerReposData.self)
            guard let viewer = data.viewer else { break }
            login = viewer.login ?? login
            total = viewer.repositories?.totalCount ?? total
            if orgs.isEmpty {
                orgs = (viewer.organizations?.nodes ?? []).compactMap(\.login)
            }
            for node in viewer.repositories?.nodes ?? [] {
                guard let full = node.nameWithOwner, let repo = RepoID(full: full) else { continue }
                options.append(RepoOption(repo: repo,
                                          isPrivate: node.isPrivate ?? false,
                                          isArchived: node.isArchived ?? false,
                                          isFork: node.isFork ?? false,
                                          defaultBranch: node.defaultBranchRef?.name,
                                          permission: node.viewerPermission))
            }
            guard let page = viewer.repositories?.pageInfo, page.hasNextPage == true, let end = page.endCursor else { break }
            cursor = end
        }
        return ViewerRepositories(login: login,
                                  repos: options,
                                  organizations: orgs.sorted(),
                                  totalCount: total,
                                  truncated: total.map { options.count < $0 } ?? false)
    }

    /// 승인 임계값. 룰셋 → 클래식 보호 → GraphQL 순으로 시도하고 못 읽으면 nil.
    /// 이 레포의 브랜치별 Approve 규칙과 기본 브랜치. 아무것도 못 읽으면 nil, 읽었는데 규칙이 없으면 빈 배열.
    ///
    /// 두 군데를 본다. ① 옛 브랜치 보호 규칙 — 패턴과 수가 한 번에 온다. ② 새 규칙(ruleset) — 레포 전체 목록은
    /// 관리자만 볼 수 있어서, 이름을 아는 브랜치(기본 브랜치 · 옛 규칙의 이름 · 열린 PR 의 대상)마다 물어본다.
    /// 옛 규칙만 쓰는 레포(main 2명, release/* 1명)도, 새 규칙만 쓰는 레포(main 1명)도 있다.
    public func approvalRules(_ repo: RepoID, candidates: [String]) async -> (defaultBranch: String?, rules: [ApprovalRule])? {
        let data = try? await graphQL(GraphQL.approvalRules,
                                      variables: ["owner": .string(repo.owner), "name": .string(repo.name)],
                                      as: ApprovalRulesData.self,
                                      timeout: 30)
        let defaultBranch = data?.repository?.defaultBranchRef?.name
        let legacy = (data?.repository?.branchProtectionRules?.nodes ?? []).compactMap { node -> ApprovalRule? in
            guard let pattern = node.pattern, node.requiresApprovingReviews == true,
                  let count = node.requiredApprovingReviewCount, count > 0 else { return nil }
            return ApprovalRule(branch: pattern, count: count)
        }
        var names: [String] = []
        for name in [defaultBranch].compactMap({ $0 }) + candidates + legacy.map(\.branch)
        where !name.isEmpty && !ApprovalGroups.isPattern(name) && !names.contains(name) {
            names.append(name)
        }
        var rulesets: [ApprovalRule] = []
        // 브랜치마다 한 번씩 부르므로 몇 개로 끊는다. 앱을 켤 때·⌘R·레포를 켤 때만 돈다.
        for name in names.prefix(8) {
            if let count = await rulesetApprovals(repo, branch: name) {
                rulesets.append(ApprovalRule(branch: name, count: count))
            }
        }
        // 옛 규칙 조회가 실패했는데 새 규칙도 없으면 "규칙 없음" 인지 "못 읽음" 인지 모른다 — 모른다고 돌려준다.
        if data == nil, rulesets.isEmpty { return nil }
        return (defaultBranch, ApprovalGroups.merge(legacy: legacy, rulesets: rulesets))
    }

    /// 새 규칙(ruleset)에서 이 브랜치에 걸린 Approve 수. 여러 규칙이 걸리면 가장 큰 값이 조건이다. 없으면 nil.
    private func rulesetApprovals(_ repo: RepoID, branch: String) async -> Int? {
        struct Rule: Decodable {
            let type: String?
            let parameters: Parameters?
            struct Parameters: Decodable { let required_approving_review_count: Int? }
        }
        guard let result = try? await gh(["api", "repos/\(repo.full)/rules/branches/\(branch)"], timeout: 30),
              result.succeeded,
              let rules = try? JSONDecoder().decode([Rule].self, from: Data(result.stdout.utf8)) else { return nil }
        return rules.filter { $0.type == "pull_request" }
            .compactMap { $0.parameters?.required_approving_review_count }
            .filter { $0 > 0 }
            .max()
    }

    public func requiredApprovals(_ repo: RepoID, branch: String) async throws -> Int? {
        struct Rule: Decodable {
            let type: String?
            let parameters: Parameters?
            struct Parameters: Decodable { let required_approving_review_count: Int? }
        }
        if let result = try? await gh(["api", "repos/\(repo.full)/rules/branches/\(branch)"], timeout: 30),
           result.succeeded,
           let rules = try? JSONDecoder().decode([Rule].self, from: Data(result.stdout.utf8)),
           let count = rules.first(where: { $0.type == "pull_request" })?.parameters?.required_approving_review_count {
            return count
        }

        struct Protection: Decodable {
            let required_pull_request_reviews: Reviews?
            struct Reviews: Decodable { let required_approving_review_count: Int? }
        }
        if let result = try? await gh(["api", "repos/\(repo.full)/branches/\(branch)/protection"], timeout: 30),
           result.succeeded,
           let protection = try? JSONDecoder().decode(Protection.self, from: Data(result.stdout.utf8)),
           let count = protection.required_pull_request_reviews?.required_approving_review_count {
            return count
        }

        if let data = try? await graphQL(GraphQL.branchProtection,
                                        variables: ["owner": .string(repo.owner), "name": .string(repo.name)],
                                        as: ProtectionData.self),
           let rules = data.repository?.branchProtectionRules?.nodes {
            if let exact = rules.first(where: { $0.pattern == branch })?.requiredApprovingReviewCount {
                return exact
            }
            let matching = rules.first { rule in
                guard let pattern = rule.pattern else { return false }
                return Glob.matches(path: branch, pattern: pattern)
            }
            if let count = matching?.requiredApprovingReviewCount { return count }
        }
        return nil
    }

    // MARK: - 게시 (사용자가 "게시" 를 눌렀을 때만 호출된다)

    public func postReview(_ repo: RepoID, number: Int, payload: ReviewPayload) async throws -> PostedInfo {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try encoder.encode(payload)
        guard let json = String(data: body, encoding: .utf8) else {
            throw GitHubError.decode("payload 인코딩 실패")
        }
        let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)/reviews",
                                  "-X", "POST", "--input", "-"],
                                 stdin: json,
                                 timeout: 60)
        struct Response: Decodable { let id: Int; let html_url: String? }
        if result.succeeded, let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) {
            return PostedInfo(reviewID: response.id,
                              htmlURL: response.html_url ?? "\(webBase)/\(repo.full)/pull/\(number)",
                              event: payload.event,
                              postedAt: Date(),
                              commentCount: payload.comments.count)
        }
        let message = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw GitHubError.cli(String(message.prefix(800)))
    }
}


extension GitHubClient {
    /// 줄 코멘트 하나를 바로 단다(리뷰로 묶지 않는다). 지적 목록의 "코드 옆에 코멘트 달기" 가 쓴다.
    ///
    /// 리뷰(`pulls/N/reviews`)로 보내면 COMMENT 에 본문이 필수라 "인라인 코멘트를 남겼습니다." 같은 빈 리뷰 글이
    /// 코멘트마다 하나씩 생긴다. `pulls/N/comments` 는 그 줄의 코멘트만 남긴다.
    public func postReviewComment(_ repo: RepoID, number: Int, commitID: String,
                                  comment: ReviewPayload.Comment) async throws -> PostedComment {
        struct Body: Encodable {
            let body: String; let commit_id: String; let path: String; let line: Int; let side: String
            let start_line: Int?; let start_side: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(Body(body: comment.body, commit_id: commitID, path: comment.path,
                                           line: comment.line, side: comment.side,
                                           start_line: comment.start_line, start_side: comment.start_side))
        guard let json = String(data: data, encoding: .utf8) else { throw GitHubError.decode("payload 인코딩 실패") }
        let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)/comments", "-X", "POST", "--input", "-"],
                                  stdin: json, timeout: 60)
        struct Response: Decodable { let id: Int; let html_url: String? }
        if result.succeeded, let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) {
            return PostedComment(commentID: response.id,
                                 htmlURL: response.html_url ?? "\(webBase)/\(repo.full)/pull/\(number)",
                                 postedAt: Date())
        }
        let message = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        throw GitHubError.cli(String(message.prefix(800)))
    }

    /// 리뷰 하나에 실린 줄 코멘트들. 리뷰 게시 응답에는 줄 코멘트 ID 가 없어서, 담아 올린 코멘트를 카드와
    /// 짝지으려고 다시 받는다(`ReviewBasket.match`).
    ///
    /// 리뷰 하나의 코멘트 목록(`pulls/N/reviews/ID/comments`)은 쓰지 않는다 — 옛 형식으로 답해서 `line`·`original_line`
    /// 이 없고 `position` 만 온다. 그걸로는 자리로 짝을 못 지어 카드가 모두 리뷰 링크로만 달렸다(2026-10-27 실제 게시로 확인).
    /// PR 의 줄 코멘트를 새것부터 받아 이 리뷰 것만 고른다. 방금 올린 리뷰라 첫 쪽(100개)에 다 들어 있다.
    public func reviewComments(_ repo: RepoID, number: Int, reviewID: Int) async throws -> [ReviewCommentRef] {
        let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)/comments?sort=created&direction=desc&per_page=100"],
                                  timeout: 30)
        guard result.succeeded,
              let refs = GitHubClient.parseReviewComments(Data(result.stdout.utf8), reviewID: reviewID,
                                                          fallbackURL: "\(webBase)/\(repo.full)/pull/\(number)") else {
            throw GitHubError.cli(GitHubClient.failureMessage(result, context: "리뷰 코멘트 조회"))
        }
        return refs
    }

    /// `pulls/N/comments` 응답에서 그 리뷰의 줄 코멘트만 뽑는다. 디코드에 실패하면 nil.
    static func parseReviewComments(_ data: Data, reviewID: Int, fallbackURL: String) -> [ReviewCommentRef]? {
        struct Item: Decodable {
            let id: Int; let pull_request_review_id: Int?; let html_url: String?; let path: String
            let line: Int?; let original_line: Int?; let body: String; let created_at: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let items = try? decoder.decode([Item].self, from: data) else { return nil }
        return items.filter { $0.pull_request_review_id == reviewID }.map { item in
            ReviewCommentRef(path: item.path, line: item.line ?? item.original_line, body: item.body,
                             posted: PostedComment(commentID: item.id,
                                                   htmlURL: item.html_url ?? fallbackURL,
                                                   postedAt: item.created_at ?? Date()))
        }
    }
}

// MARK: - 머지 (사용자가 확인 줄에서 "머지하기" 를 눌렀을 때만 호출된다)

extension GitHubClient {
    /// 이 레포가 허용하는 머지 방식. 못 받으면 부르는 쪽이 `MergeOptions.fallback` 을 쓴다.
    public func mergeOptions(_ repo: RepoID) async throws -> MergeOptions {
        let data = try await graphQL(GraphQL.mergeOptions,
                                     variables: ["owner": .string(repo.owner), "name": .string(repo.name)],
                                     as: MergeOptionsData.self)
        guard let repository = data.repository else { return .fallback }
        var allowed: [MergeMethod] = []
        if repository.mergeCommitAllowed == true { allowed.append(.merge) }
        if repository.squashMergeAllowed == true { allowed.append(.squash) }
        if repository.rebaseMergeAllowed == true { allowed.append(.rebase) }
        return MergeOptions(allowed: allowed, preferred: MergeMethod(graphQL: repository.viewerDefaultMergeMethod))
    }

    /// PR 을 머지한다. `expectedHead` 를 같이 보내 **화면에서 본 커밋 그대로**일 때만 머지되게 한다 —
    /// 그 사이 새 커밋이 올라왔으면 GitHub 이 409 로 거절한다(`MergeError.headChanged`).
    /// - Returns: 머지 커밋 SHA.
    public func mergePullRequest(_ repo: RepoID, number: Int, method: MergeMethod,
                                 expectedHead: String) async throws -> String {
        struct Body: Encodable { let merge_method: String; let sha: String }
        let data = try JSONEncoder().encode(Body(merge_method: method.rawValue, sha: expectedHead))
        guard let json = String(data: data, encoding: .utf8) else { throw GitHubError.decode("payload 인코딩 실패") }
        let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)/merge", "-X", "PUT", "--input", "-"],
                                  stdin: json, timeout: 60)
        struct Response: Decodable { let sha: String?; let merged: Bool?; let message: String? }
        let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8))
        if result.succeeded, response?.merged == true {
            return response?.sha ?? ""
        }
        // 실패해도 gh 는 GitHub 의 JSON 본문을 stdout 에 낸다. 그 message 가 가장 사람 말에 가깝다.
        let message = response?.message ?? GitHubClient.failureMessage(result, context: "머지")
        throw MergeError(githubMessage: message)
    }
}

// MARK: - base 브랜치 바꾸기 (사용자가 확인 칸에서 "base 바꾸기" 를 눌렀을 때만 호출된다)

/// base 고르기 칸에 보일 브랜치. `names` 는 최근 커밋 순.
public struct BranchSearchResult: Sendable, Equatable {
    public var defaultBranch: String?
    public var names: [String]
    /// 찾은 것 전체 수. `names` 보다 많으면 칸에 "더 있음" 을 보인다.
    public var totalCount: Int

    public init(defaultBranch: String?, names: [String], totalCount: Int) {
        self.defaultBranch = defaultBranch
        self.names = names
        self.totalCount = totalCount
    }
}

extension GitHubClient {
    /// 이름에 `query` 가 든 브랜치(빈 글이면 전부)를 최근 커밋 순으로 `limit` 개.
    public func searchBranches(_ repo: RepoID, matching query: String, limit: Int = 30) async throws -> BranchSearchResult {
        let data = try await graphQL(GraphQL.branchSearch,
                                     variables: ["owner": .string(repo.owner), "name": .string(repo.name),
                                                 "q": .string(query), "n": .int(limit)],
                                     as: BranchSearchData.self, timeout: 20)
        guard let repository = data.repository else { return BranchSearchResult(defaultBranch: nil, names: [], totalCount: 0) }
        return BranchSearchResult(defaultBranch: repository.defaultBranchRef?.name,
                                  names: (repository.refs?.nodes ?? []).compactMap(\.name),
                                  totalCount: repository.refs?.totalCount ?? 0)
    }

    /// PR 의 base 브랜치를 바꾼다(GitHub 웹 제목 옆 "Edit" 와 같은 일). 바뀐 base 이름을 돌려준다.
    public func changeBase(_ repo: RepoID, number: Int, to base: String) async throws -> String {
        struct Body: Encodable { let base: String }
        let data = try JSONEncoder().encode(Body(base: base))
        guard let json = String(data: data, encoding: .utf8) else { throw GitHubError.decode("payload 인코딩 실패") }
        let result = try await gh(["api", "repos/\(repo.full)/pulls/\(number)", "-X", "PATCH", "--input", "-"],
                                  stdin: json, timeout: 30)
        if let response = GitHubClient.parseBaseChange(result.stdout), let ref = response.ref, result.succeeded {
            return ref
        }
        // 실패해도 gh 는 GitHub 의 JSON 본문을 stdout 에 낸다. 422 는 쓸 말이 `errors[].message` 에 있다
        // (`message` 는 "Validation Failed" 뿐이다).
        let response = GitHubClient.parseBaseChange(result.stdout)
        throw BaseChangeError(githubMessage: response?.reason ?? GitHubClient.failureMessage(result, context: "base 바꾸기"))
    }

    /// `PATCH pulls/N` 응답에서 바뀐 base 이름 또는 거절 이유를 뽑는다. JSON 이 아니면 nil.
    static func parseBaseChange(_ stdout: String) -> (ref: String?, reason: String?)? {
        struct Response: Decodable {
            struct Ref: Decodable { let ref: String? }
            struct Detail: Decodable { let message: String? }
            let base: Ref?
            let message: String?
            let errors: [Detail]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(stdout.utf8)) else { return nil }
        let details = (response.errors ?? []).compactMap(\.message).filter { !$0.isEmpty }
        let reason = details.isEmpty ? response.message : details.joined(separator: " · ")
        return (response.base?.ref, reason)
    }
}

/// base 바꾸기 거절. 자주 나오는 것만 사람 말로 바꾸고, 나머지는 GitHub 의 말을 그대로 보인다.
public enum BaseChangeError: Error, LocalizedError, Equatable, Sendable {
    /// 새 base 에 head 의 커밋이 이미 다 들어 있다 — PR 이 빈 PR 이 된다.
    case noNewCommits
    case rejected(String)

    public init(githubMessage: String) {
        if githubMessage.localizedCaseInsensitiveContains("no new commits") {
            self = .noNewCommits
        } else {
            self = .rejected(githubMessage)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noNewCommits: return "그 브랜치에는 이 PR 의 커밋이 이미 다 들어 있어 base 로 쓸 수 없습니다."
        case .rejected(let message): return "GitHub 이 base 바꾸기를 거절했습니다: \(message)"
        }
    }
}

struct BranchSearchData: Decodable {
    struct Repository: Decodable {
        struct Ref: Decodable { let name: String? }
        struct Refs: Decodable { let totalCount: Int?; let nodes: [Ref]? }
        let defaultBranchRef: Ref?
        let refs: Refs?
    }
    let repository: Repository?
}

/// 머지 거절. GitHub 이 준 말을 그대로 들고, 알려진 것만 무엇을 하면 되는지로 바꿔 말한다.
public enum MergeError: Error, LocalizedError, Equatable, Sendable {
    /// 화면에서 본 뒤로 새 커밋이 올라왔다(409 "Head branch was modified").
    case headChanged
    case rejected(String)

    public init(githubMessage: String) {
        if githubMessage.localizedCaseInsensitiveContains("Head branch was modified") {
            self = .headChanged
        } else {
            self = .rejected(githubMessage)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .headChanged: return "그 사이 새 커밋이 올라와 머지하지 않았습니다. 새 커밋을 확인한 뒤 다시 누르세요."
        case .rejected(let message): return "GitHub 이 머지를 거절했습니다: \(message)"
        }
    }
}

struct MergeOptionsData: Decodable {
    struct Repository: Decodable {
        let mergeCommitAllowed: Bool?
        let squashMergeAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let viewerDefaultMergeMethod: String?
    }
    let repository: Repository?
}

/// 바로 단 줄 코멘트 하나.
public struct PostedComment: Sendable, Codable, Hashable {
    public var commentID: Int
    public var htmlURL: String
    public var postedAt: Date

    public init(commentID: Int, htmlURL: String, postedAt: Date) {
        self.commentID = commentID
        self.htmlURL = htmlURL
        self.postedAt = postedAt
    }
}

/// `recentPullRequestFiles` 응답. 모든 칸이 optional 인 건 다른 GraphQL DTO 와 같은 이유(권한 없는 레포·삭제된 PR).
struct RecentPRFilesData: Decodable {
    struct Repository: Decodable {
        struct Connection: Decodable {
            struct PR: Decodable {
                struct Files: Decodable {
                    let nodes: [ExclusionCatalog.PRFile?]?
                }
                let files: Files?
            }
            let nodes: [PR?]?
        }
        let pullRequests: Connection?
    }
    let repository: Repository?
}
