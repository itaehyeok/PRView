import Foundation

/// 이 계정이 접근할 수 있는 레포 **전부**. 레포 고르기 목록과 검색은 이 안에서만 돈다.
///
/// 예전에는 최근 push 순으로 60개만 받고, 목록 밖은 GitHub 검색으로 찾았다. 검색은 어느 쪽으로도 틀렸다.
/// 오너를 안 걸면 GitHub 전체 공개 레포가 후보에 섞이고, 걸면 남의 개인 계정에 협업자로 든 레포·포크·
/// 상위 N개 밖의 레포가 빠진다. 고를 레포가 빠지는 것도, 관계없는 레포가 끼는 것도 안 된다.
/// 그래서 GitHub 이 "이 계정이 접근할 수 있다" 고 주는 목록(`GET /user/repos`)을 끝까지 받아 그 안에서만 고른다.
///
/// 실측(레포 2,150개 계정): 100개씩 차례로 받으면 22번에 33초, 6개씩 동시에 받으면 6초. 같은 목록을 GraphQL
/// (`viewer.repositories` + `viewerPermission`)로 받으면 105초라 REST 를 쓴다. 받은 목록은 저장해 두고
/// 다음에 먼저 보여 준 뒤 뒤에서 새로 받는다(`Store.loadRepoCatalog`).
public struct RepoCatalog: Codable, Sendable, Equatable {
    /// 받은 호스트·계정. 지금 호스트·계정과 다르면 이 목록을 쓰지 않는다(남의 목록이다).
    public var host: String
    public var login: String
    /// 최근 push 순.
    public var repos: [RepoOption]
    public var fetchedAt: Date

    public init(host: String, login: String, repos: [RepoOption], fetchedAt: Date) {
        self.host = host
        self.login = login
        self.repos = repos
        self.fetchedAt = fetchedAt
    }

    /// 한 쪽에 받는 수(GitHub 상한).
    public static let pageSize = 100

    /// 한 쪽의 주소. 내 레포·협업자로 든 레포·조직 멤버로 접근하는 레포를 다 받는다.
    ///
    /// **생성 순으로 받는다.** 쪽을 여러 번 나눠 받는 몇 초 사이에도 순서가 바뀌지 않아야 레포가 쪽 사이로
    /// 빠지지 않는다. push 순으로 받으면 받는 도중 누가 push 한 레포가 이미 받은 1쪽으로 올라가고, 그 바람에
    /// 밀린 레포 하나가 아직 안 받은 쪽에서 사라진다. 생성 순은 새 레포가 맨 뒤에 붙을 뿐 앞 순서를 흔들지 않는다.
    /// 화면의 최근 push 순은 다 받은 뒤 `pushed_at` 으로 다시 세운다(`ordered`).
    public static func pagePath(_ page: Int) -> String {
        "user/repos?per_page=\(pageSize)&page=\(page)&affiliation=owner,collaborator,organization_member&sort=created&direction=asc"
    }

    /// 받는 중 한 쪽을 끝낼 때마다 알린다. `repos` 는 지금까지 받은 것을 최근 push 순으로 이은 것이다.
    public struct Progress: Sendable {
        public var loadedPages: Int
        public var totalPages: Int
        public var repos: [RepoOption]
    }

    /// 첫 쪽에서 마지막 쪽 번호를 알아낸 뒤, 나머지를 `concurrency` 개씩 동시에 받는다.
    ///
    /// 한 쪽이라도 끝내 못 받으면 던진다 — 빠진 쪽이 있는 목록을 "전부" 라고 내놓지 않는다.
    /// 받은 데까지는 `onProgress` 로 이미 넘어가 있으니, 부른 쪽이 그걸 보여 주며 "다 받지 못했다" 고 알린다.
    public static func fetchAll(concurrency: Int = 6,
                                page fetch: @escaping @Sendable (Int) async throws -> RepoPage,
                                onProgress: @Sendable (Progress) async -> Void = { _ in }) async throws -> [RepoOption] {
        let first = try await fetch(1)
        let last = max(first.lastPage ?? 1, 1)
        var pages: [Int: [RepoPage.Entry]] = [1: first.entries]
        await onProgress(Progress(loadedPages: 1, totalPages: last, repos: ordered(pages)))
        guard last > 1 else { return ordered(pages) }

        try await withThrowingTaskGroup(of: (Int, RepoPage).self) { group in
            var next = 2
            func startNext() {
                let number = next
                group.addTask {
                    let page = try await fetch(number)
                    return (number, page)
                }
                next += 1
            }
            while next <= last, next - 2 < max(concurrency, 1) { startNext() }
            for try await (number, page) in group {
                pages[number] = page.entries
                await onProgress(Progress(loadedPages: pages.count, totalPages: last, repos: ordered(pages)))
                if next <= last { startNext() }
            }
        }
        return ordered(pages)
    }

    /// 쪽들을 이어 최근 push 순으로 세운다. 받는 도중 새 레포가 생겨 쪽 경계가 밀리면 같은 레포가
    /// 두 쪽에 걸쳐 오므로 한 번만 남긴다. push 시각이 같으면 이름순(매번 같은 순서로 보이게).
    static func ordered(_ pages: [Int: [RepoPage.Entry]]) -> [RepoOption] {
        var seen = Set<RepoID>()
        let entries = pages.keys.sorted()
            .flatMap { pages[$0] ?? [] }
            .filter { seen.insert($0.option.repo).inserted }
        return entries
            .sorted {
                let left = $0.pushedAt ?? .distantPast
                let right = $1.pushedAt ?? .distantPast
                return left != right ? left > right : $0.option.repo.full < $1.option.repo.full
            }
            .map(\.option)
    }

    /// `gh api -i` 응답(헤더 + JSON 배열)을 한 쪽으로 읽는다.
    public static func parsePage(_ response: String) throws -> RepoPage {
        let (headers, body) = GitHubClient.splitHTTPResponse(response)
        struct Item: Decodable {
            struct Permissions: Decodable {
                let admin: Bool?
                let maintain: Bool?
                let push: Bool?
                let triage: Bool?
                let pull: Bool?
            }
            let full_name: String
            let `private`: Bool?
            let archived: Bool?
            let fork: Bool?
            let default_branch: String?
            let pushed_at: Date?
            let permissions: Permissions?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items: [Item]
        do {
            items = try decoder.decode([Item].self, from: Data(body.utf8))
        } catch {
            throw GitHubError.decode(String(body.prefix(400)))
        }
        let entries = items.compactMap { item -> RepoPage.Entry? in
            guard let repo = RepoID(full: item.full_name) else { return nil }
            // GraphQL `viewerPermission` 과 같은 이름으로 맞춘다(가장 센 권한 하나).
            let permission: String? = item.permissions.flatMap { p in
                if p.admin == true { return "ADMIN" }
                if p.maintain == true { return "MAINTAIN" }
                if p.push == true { return "WRITE" }
                if p.triage == true { return "TRIAGE" }
                if p.pull == true { return "READ" }
                return nil
            }
            return RepoPage.Entry(option: RepoOption(repo: repo,
                                                     isPrivate: item.private ?? false,
                                                     isArchived: item.archived ?? false,
                                                     isFork: item.fork ?? false,
                                                     defaultBranch: item.default_branch,
                                                     permission: permission),
                                  pushedAt: item.pushed_at)
        }
        return RepoPage(entries: entries, lastPage: lastPage(headers))
    }

    /// `Link` 헤더의 `rel="last"` 주소에서 쪽 번호를 읽는다. `per_page=100` 에도 `page=` 가 들어 있어
    /// 글자로 찾으면 100 을 집는다 — 주소를 풀어 `page` 칸만 본다.
    static func lastPage(_ headers: [Substring]) -> Int? {
        guard let link = headers.first(where: { $0.lowercased().hasPrefix("link:") }) else { return nil }
        for part in link.dropFirst("link:".count).split(separator: ",") where part.contains("rel=\"last\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close,
                  let url = URLComponents(string: String(part[part.index(after: open)..<close])),
                  let value = url.queryItems?.first(where: { $0.name == "page" })?.value else { continue }
            return Int(value)
        }
        return nil
    }
}

/// `GET /user/repos` 한 쪽.
public struct RepoPage: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var option: RepoOption
        /// 빈 레포는 push 한 적이 없어 nil 이다.
        public var pushedAt: Date?

        public init(option: RepoOption, pushedAt: Date?) {
            self.option = option
            self.pushedAt = pushedAt
        }
    }

    public var entries: [Entry]
    /// 마지막 쪽 번호. 첫 쪽에서 이걸 알아야 나머지를 한꺼번에 부를 수 있다.
    /// 쪽이 하나뿐이거나 이 쪽이 마지막이면 응답에 없다(nil).
    public var lastPage: Int?

    public init(entries: [Entry], lastPage: Int?) {
        self.entries = entries
        self.lastPage = lastPage
    }
}
