import Foundation

/// 목록 검색칸의 글로 **지금 탭 밖** PR 까지 찾는 계획(2026-10-29 사용자 기획).
///
/// 위 구역은 지금처럼 받아 둔 탭 목록을 글자 일부로 거르고, 아래 구역은 이 계획대로 서버에 묻는다.
/// GitHub 검색은 단어 단위라 글자 일부(`appl` → `apple`)로는 안 걸린다 — 그 몫은 다른 탭에 받아 둔
/// 목록을 위 구역과 같은 규칙(`matchesLocally`)으로 걸러 메운다.
public struct PRSearchPlan: Equatable, Sendable {
    /// 숫자만 쳤으면 그 번호. 레포마다 그 번호의 PR 을 바로 받는다 — 검색 색인을 거치지 않는다.
    public var number: Int?
    /// 제목·본문 단어 검색에 넣을 말. 숫자만 친 것도 넣는다 — 제목의 `PROJ-1234` 같은 이슈 키가 걸린다.
    public var words: String
    /// 공백 없는 영문 한 단어면 작성자로도 찾는다(`author:`). 단어 검색은 작성자를 보지 않는다.
    public var author: String?
    /// `/` 가 든 한 단어면 브랜치 이름으로도 찾는다(`head:`). 서버는 이름이 정확히 같을 때만 찾는다.
    public var branch: String?

    /// 서버에 물을 만한 검색어가 아니면 nil — 위 구역만 거른다.
    ///
    /// 한 글자는 묻지 않는다. 결과가 수백 건이라 50건으로는 의미가 없고, 타자 중간에 GitHub 검색 한도만 쓴다.
    /// 숫자는 한 자리여도 묻는다 — 번호 조회는 한 건만 온다.
    public init?(search raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let value = Int(digits) {
            number = value
            words = digits
            return
        }
        // 검색 범위를 넓히는 한정어는 버린다. GitHub 은 `repo:` 를 여럿 쓰면 "또는" 으로 읽어서, 사용자가 친 `repo:` 가
        // 등록하지 않은 레포까지 끌어온다. 나머지 한정어(`label:`·`is:merged` 등)는 좁히기만 하므로 그대로 둔다.
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
            let lower = token.lowercased()
            return !["repo:", "org:", "user:"].contains { lower.hasPrefix($0) }
        }
        let kept = tokens.joined(separator: " ")
        guard kept.count >= 2 else { return nil }
        words = kept
        if tokens.count == 1, let only = tokens.first {
            if only.contains("/"), !only.contains(":") {
                branch = only
            } else if PRSearchPlan.looksLikeLogin(only) {
                author = only
            }
        }
    }

    /// GitHub 아이디 꼴(영문·숫자·하이픈, 39자 이내)이고 글자가 하나라도 있나. 한글 단어로 `author:` 를 물으면
    /// "그런 사용자 없음" 오류만 온다.
    static func looksLikeLogin(_ token: String) -> Bool {
        guard (2...39).contains(token.count), token.first != "-" else { return false }
        let allowed = token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return allowed && token.contains { $0.isLetter }
    }

    // MARK: - 쿼리

    /// 서버에 보낼 검색 쿼리. 순서는 목록과 같은 **올린 시각** 순이다(`GitHubClient.searchQuery` 주석).
    /// - Parameter olderThan: All PRs 탭이면 그 기간 시작 시각. 탭 쿼리의 `updated:>=` 를 뒤집어 위 구역과 겹치지 않게 한다.
    public static func query(repos: [RepoID], terms: String, olderThan: Date?) -> String {
        var parts = repos.map { "repo:\($0.full)" }
        parts.append("is:pr")
        parts.append(terms)
        if let olderThan { parts.append("updated:<\(olderThan.ISO8601Format())") }
        parts.append("sort:created-desc")
        return parts.joined(separator: " ")
    }

    /// 단어 검색. 기본 검색은 코멘트까지 보는데, 코멘트에 한 번 스친 PR 까지 50건 자리를 나눠 먹어서 제목·본문만 본다.
    public func wordsQuery(repos: [RepoID], olderThan: Date?) -> String {
        PRSearchPlan.query(repos: repos, terms: "\(words) in:title,body", olderThan: olderThan)
    }

    public func authorQuery(repos: [RepoID], olderThan: Date?) -> String? {
        author.map { PRSearchPlan.query(repos: repos, terms: "author:\($0)", olderThan: olderThan) }
    }

    public func branchQuery(repos: [RepoID], olderThan: Date?) -> String? {
        branch.map { PRSearchPlan.query(repos: repos, terms: "head:\($0)", olderThan: olderThan) }
    }

    // MARK: - 탭별 아래 구역

    /// 아래 구역이 어디서 찾나. All PRs 탭은 그 기간 안을 이미 다 보이므로 그보다 오래된 것만, 나머지 탭은 전부다.
    public static func olderThan(scope: PRListScope, now: Date = Date()) -> Date? {
        guard scope.kind == .recentAll, let hours = scope.windowHours else { return nil }
        return now.addingTimeInterval(-Double(hours) * 3600)
    }

    /// 아래 구역 이름 — "전체 PR" 또는 "30일 이전 PR". All PRs 탭 이름이 이미 '전체' 라 거기서 '전체 PR' 을 또 쓰면
    /// 같은 말이 두 번 나온다(사용자 지적).
    public static func extraName(scope: PRListScope) -> String {
        guard scope.kind == .recentAll, let hours = scope.windowHours else { return "전체 PR" }
        let span = hours < 48 ? "\(hours)시간" : "\(hours / 24)일"
        return "\(span) 이전 PR"
    }

    /// 같은 결과를 다시 받지 않으려고 쓰는 열쇠. To review·Approved 는 같은 서버 결과를 쓴다(둘 다 기간 없음).
    public static func cacheKey(search raw: String, scope: PRListScope, repos: [RepoID]) -> String {
        let span = scope.kind == .recentAll ? "older:\(scope.windowHours ?? 0)" : "all"
        let repoKey = repos.map { $0.full.lowercased() }.sorted().joined(separator: ",")
        return "\(span)|\(repoKey)|\(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    // MARK: - 합치기

    /// 위 구역(지금 탭)과 같은 규칙 — 번호·제목·작성자·브랜치에 글자 일부가 들어 있나.
    public static func matchesLocally(_ pr: PullRequestInfo, needle: String) -> Bool {
        let needle = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return "\(pr.number) \(pr.title) \(pr.author) \(pr.headRefName)".lowercased().contains(needle)
    }

    /// 아래 구역에 그릴 PR.
    ///
    /// - Parameter candidates: 앞에 둔 것이 이긴다. 서버 결과를 받아 둔 목록보다 앞에 두면 같은 PR 이 둘 다에 있을 때
    ///   더 새 모습이 남는다.
    /// - Parameter top: 위 구역에 이미 보이는 PR id — 두 번 그리지 않는다.
    /// - Parameter hiddenRepoKeys: 레포 탭에서 뺀 레포(`PRFilterState.repoKey`). 레포 고르기만은 아래에도 건다.
    public static func extra(candidates: [PullRequestInfo],
                             excluding top: Set<String>,
                             hiddenRepoKeys: Set<String>,
                             olderThan: Date?) -> [PullRequestInfo] {
        var seen = top
        return candidates
            .filter { pr in
                guard seen.insert(pr.id).inserted else { return false }
                if hiddenRepoKeys.contains(PRFilterState.repoKey(pr.repo)) { return false }
                // 받아 둔 목록에서 온 것도 "30일 이전" 구역에 30일 안의 PR 이 끼지 않게 같은 기준으로 거른다.
                if let olderThan, pr.updatedAt >= olderThan { return false }
                return true
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// GitHub 이 검색 한도로 거절했나 — "실패" 와 따로 알린다(잠시 뒤면 된다).
    public static func isRateLimited(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("rate limit") || text.contains("abuse")
    }
}
