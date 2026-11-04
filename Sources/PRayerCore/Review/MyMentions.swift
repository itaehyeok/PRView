import Foundation

/// 글에서 나(@내 아이디)를 부른 자리 — 개요 탭의 형광펜·"@me" 표시와 목록 활동 줄의 @me 가 쓴다.
///
/// 내 로그인만 본다. GitHub 멘션처럼 대소문자를 가리지 않고, 코드 블록·인라인 코드 안과 메일 주소·팀 멘션(`@org/team`)은
/// 뺀다 — 답글 판별(MyCommentReplies)과 같은 정규식이다. 답글 판별은 PR 에 나온 사람 이름만 멘션으로 치지만 여기서는 그
/// 거름이 필요 없다: 찾는 이름이 내 로그인 하나라 `@MainActor` 같은 말과 겹칠 일이 없다.
///
/// 내가 쓴 글은 세지 않는다 — 나를 부를 일이 없고, 불렀어도 내가 확인할 것이 아니다.
/// 읽음은 따로 두지 않는다. 멘션 표시는 "누가 언제 나를 불렀나" 라는 기록이라 열어 봐도 남는다.
public enum MyMentions {
    /// 이 글이 나를 불렀나. 코드 안의 것은 치지 않는다.
    public static func mentions(_ body: String, viewer: String?) -> Bool {
        // 목록이 그릴 때마다 활동 글을 다 훑는다 — 내 아이디가 아예 없는 글(대부분)은 정규식 전에 끝낸다.
        guard let viewer, !viewer.isEmpty, body.range(of: viewer, options: .caseInsensitive) != nil else { return false }
        return !ranges(in: MyCommentReplies.withoutCode(body), viewer: viewer).isEmpty
    }

    /// 글에서 `@내아이디` 자리(@ 포함). 코드를 걸러 주지 않는다 — 화면은 코드 조각을 따로 알고 있어 거기서 거른다.
    public static func ranges(in text: String, viewer: String) -> [Range<String.Index>] {
        guard let pattern = MyCommentReplies.mentionPattern, !viewer.isEmpty else { return [] }
        let me = viewer.lowercased()
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let login = Range(match.range(at: 1), in: text), text[login].lowercased() == me else { return nil }
            return Range(match.range, in: text)
        }
    }

    /// 접힌 상자의 미리보기 한 줄 — 글 첫머리 대신 나를 부른 자리부터 보인다. 접힌 상자는 첫 줄만 보여서, 멘션이 글
    /// 가운데 있으면 펼치기 전에는 왜 "@me" 가 붙었는지 알 수 없었다. 멘션 앞 `lead` 글자는 남겨 무슨 말 끝에 불렀는지 보이게 한다.
    /// 멘션이 없으면 nil.
    public static func preview(of body: String, viewer: String?, lead: Int = 24) -> String? {
        guard let viewer, mentions(body, viewer: viewer) else { return nil }
        // 미리보기 기본 길이(280자)에서 자르면 긴 글 뒤쪽의 멘션이 잘려 나간다.
        let plain = MarkdownPreview.text(body, maxLength: 4_000)
        guard let first = ranges(in: plain, viewer: viewer).first else { return nil }
        guard plain.distance(from: plain.startIndex, to: first.lowerBound) > lead else { return plain }
        var start = plain.index(first.lowerBound, offsetBy: -lead)
        // 낱말 가운데서 자르지 않는다 — 앞쪽 빈칸 바로 뒤로 물린다. 빈칸이 없으면(긴 낱말) 그 자리 그대로.
        if let space = plain[start..<first.lowerBound].firstIndex(where: \.isWhitespace) {
            start = plain.index(after: space)
        }
        return "… " + plain[start...]
    }

    /// 대화 한 줄에서 나를 부른 첫 글. 스레드는 답글까지 본다. 내가 쓴 글·커밋은 보지 않는다.
    public static func firstMentioningBody(in entry: PRTimelineEntry, viewer: String?) -> String? {
        guard let viewer, !viewer.isEmpty else { return nil }
        let me = viewer.lowercased()
        let posts: [(author: String, body: String)]
        switch entry {
        case .thread(let thread, _): posts = thread.comments.map { ($0.author, $0.body) }
        case .review(let review): posts = [(review.author, review.body)]
        case .comment(let comment): posts = [(comment.author, comment.body)]
        case .commit: return nil
        }
        return posts.first { $0.author.lowercased() != me && mentions($0.body, viewer: viewer) }?.body
    }

    /// PR 본문이 나를 불렀나. 내 PR 본문은 보지 않는다.
    public static func bodyMentions(_ pr: PullRequestInfo, viewer: String?) -> Bool {
        guard let viewer, pr.author.lowercased() != viewer.lowercased() else { return false }
        return mentions(pr.bodyText, viewer: viewer)
    }
}
