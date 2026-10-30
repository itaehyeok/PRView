import Foundation

/// 코멘트에 끌어다 붙인 그림(첨부).
///
/// 마크다운 원문에는 `https://github.com/user-attachments/assets/<uuid>` 가 들어가는데, 비공개 레포면 이 주소는
/// 토큰을 줘도 못 받는다(토큰 없이 404, `Authorization` 을 붙이면 로그인 화면 HTML — 2026-10-28 실측).
/// GitHub 이 HTML 로 그린 본문(`bodyHTML`)에만 `private-user-images.githubusercontent.com/…/<번호>-<uuid>.png?jwt=…`
/// 서명 주소가 실린다. 서명은 5분짜리라(jwt 의 exp − nbf = 300초) 받자마자 그림을 내려받아야 한다.
public enum GitHubAttachment {
    /// 첨부 주소의 자산 ID(uuid, 소문자). `…/user-attachments/assets/<uuid>` 와 옛 `…/<owner>/<repo>/assets/<번호>/<uuid>`.
    /// 첨부가 아니면 nil — 그런 그림(외부 그림 주소)은 그냥 받는다.
    public static func assetID(of url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.contains("assets"), let last = parts.last, let id = uuid(in: last) else {
            return nil
        }
        return id
    }

    /// `bodyHTML` 들에 든 서명 주소를 자산 ID 로 찾게 모은다. 같은 그림이 `<a href>`·`<img src>` 에 두 번 나온다.
    public static func signedURLs(inHTML html: String) -> [String: URL] {
        var found: [String: URL] = [:]
        var searchRange = html.startIndex..<html.endIndex
        while let range = html.range(of: #"https?://[^"'\s<>]+[?&](amp;)?jwt=[^"'\s<>]+"#,
                                     options: .regularExpression, range: searchRange) {
            searchRange = range.upperBound..<html.endIndex
            let raw = html[range].replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw), let id = uuid(in: url.lastPathComponent) else {
                continue
            }
            found[id] = url
        }
        return found
    }

    private static func uuid(in text: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        return text.range(of: pattern, options: .regularExpression).map { text[$0].lowercased() }
    }
}
