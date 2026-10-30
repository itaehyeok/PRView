import Foundation

/// 조직 GitHub 로그인은 `riley-park-acme` 처럼 길다. 화면에서는 짧게 보여준다.
public enum MemberNames {
    /// 기본 규칙: 첫 하이픈 앞까지. (`riley-park-acme` → `riley`)
    public static func defaultShort(_ login: String) -> String {
        let head = login.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first
        let candidate = head.map(String.init) ?? login
        return candidate.isEmpty ? login : candidate
    }

    /// 설정의 개별 별명이 있으면 그것을, 없으면 기본 규칙을 쓴다.
    public static func short(_ login: String, overrides: [String: String], enabled: Bool) -> String {
        guard enabled else { return login }
        if let override = overrides[login]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return override
        }
        return defaultShort(login)
    }
}
