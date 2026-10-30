import Foundation

/// `gh` 에 로그인돼 있는 호스트 하나.
///
/// 회사 계정(GitHub Enterprise)과 개인 계정(github.com)을 같은 맥에서 같이 쓰는 일이 흔하다.
/// `gh` 는 호스트별로 따로 로그인하고, 어느 쪽에 물어볼지는 `--hostname` 으로 정한다.
/// 앱이 이걸 정하지 않으면 `gh` 의 기본 호스트로 조용히 새어, 회사 레포를 골랐는데
/// github.com 에 물어보고 "찾을 수 없습니다" 가 뜬다.
public struct GitHubHost: Sendable, Hashable, Identifiable {
    public static let dotCom = "github.com"

    public let name: String
    public let login: String?
    /// `gh` 가 기본으로 쓰는 계정인가.
    public let isActive: Bool

    public var id: String { name }
    public var isDotCom: Bool { name.caseInsensitiveCompare(GitHubHost.dotCom) == .orderedSame }
    /// 목록에 그릴 한 줄.
    public var label: String { login.map { "\(name) · \($0)" } ?? name }

    public init(name: String, login: String? = nil, isActive: Bool = false) {
        self.name = name
        self.login = login
        self.isActive = isActive
    }
}

/// `gh auth status` 출력에서 로그인된 호스트를 읽는다.
///
/// `gh` 는 이 명령에 JSON 출력을 주지 않는다. 그래서 사람이 읽는 출력을 파싱하는데,
/// 문구가 버전에 따라 다르다(`... as <login>` → `... account <login>`). 둘 다 받고,
/// 그마저 안 맞으면 들여쓰기 없는 줄을 호스트 이름으로 본다 — 이 형태는 안 바뀌었다.
public enum GHAuthStatus {
    public static func parse(_ output: String) -> [GitHubHost] {
        var hosts: [String] = []          // 나온 순서를 지킨다
        var logins: [String: String] = [:]
        var actives: Set<String> = []
        var currentHost: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // 들여쓰기가 없는 줄은 호스트 머리글이다.
            if line.first?.isWhitespace == false, !trimmed.hasPrefix("✓"), !trimmed.hasPrefix("X"),
               !trimmed.hasPrefix("-"), looksLikeHost(trimmed) {
                currentHost = trimmed
                if !hosts.contains(trimmed) { hosts.append(trimmed) }
                continue
            }

            if let (host, login) = loggedInLine(trimmed) {
                currentHost = host
                if !hosts.contains(host) { hosts.append(host) }
                if let login { logins[host] = login }
                continue
            }

            if trimmed.hasPrefix("- Active account: true"), let currentHost {
                actives.insert(currentHost)
            }
        }

        return hosts.map { GitHubHost(name: $0, login: logins[$0], isActive: actives.contains($0)) }
    }

    /// `✓ Logged in to github.com account octo-dev (keyring)` 또는
    /// `✓ Logged in to github.com as octo-dev (keyring)`.
    private static func loggedInLine(_ line: String) -> (host: String, login: String?)? {
        guard let range = line.range(of: "Logged in to ") else { return nil }
        let rest = line[range.upperBound...].split(separator: " ").map(String.init)
        guard let host = rest.first else { return nil }
        var login: String?
        if rest.count >= 3, rest[1] == "account" || rest[1] == "as" {
            login = rest[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return (host, login)
    }

    /// 호스트 이름처럼 보이는가. 설명 문장이 머리글로 잡히는 걸 막는다.
    private static func looksLikeHost(_ text: String) -> Bool {
        guard text.contains("."), !text.contains(" ") else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
