import Foundation

/// 남의 PR 코드 코멘트 스레드에서 **나에게 쓴 답글** 하나.
public struct MyCommentReply: Sendable, Hashable, Identifiable {
    public var threadID: String
    public var comment: ReviewThreadComment
    public var at: Date
    /// 멘션·인용·내가 연 스레드처럼 확실한 것이 아니라 "내 글 바로 다음 글" 이라 어림잡았다.
    public var isGuess: Bool

    public init(threadID: String, comment: ReviewThreadComment, at: Date, isGuess: Bool) {
        self.threadID = threadID
        self.comment = comment
        self.at = at
        self.isGuess = isGuess
    }

    public var id: String { "\(threadID)|\(MyCommentReplies.key(comment))" }
}

/// 내 코멘트에 달린 답글을 가른다.
///
/// GitHub 은 스레드 답글이 누구 글에 단 것인지 저장하지 않는다 — 답글의 `replyTo` 는 늘 스레드 첫 글을 가리킨다
/// (2026-11-02 실측: 공개 레포 스레드 7개의 답글 21개가 전부 그랬다). 그래서 글의 모양과 순서로 가른다.
/// PRView 로 올린 코드 코멘트는 저마다 새 스레드의 첫 글이라, 대부분은 "내가 연 스레드" 규칙 하나로 확실하다.
/// 헷갈리는 것은 남의 스레드에 내가 끼어든 경우뿐이다.
public enum MyCommentReplies {
    /// 답글 하나를 가리키는 키. 목록 조회는 코멘트 id 를 받지 않아서 쓴 사람과 시각(초 단위)으로 대신한다 —
    /// 쿼리에 필드를 더하지 않으려고(목록 한 페이지가 이미 무겁다). 같은 사람이 같은 초에 두 번 다는 일은 없다고 본다.
    public static func key(_ comment: ReviewThreadComment) -> String {
        "\(comment.author.lowercased())|\(comment.createdAt)"
    }

    /// 이 PR 에서 나에게 온 답글 전부(읽음과 상관없이). 내 PR 은 보지 않는다 — 내 PR 에 달린 글은
    /// 전부 나에게 온 것이라 "내 PR 새 코멘트" 가 따로 맡는다.
    public static func replies(in pr: PullRequestInfo, viewer: String?) -> [MyCommentReply] {
        guard let viewer, !viewer.isEmpty, !pr.viewerDidAuthor else { return [] }
        // PR 마다 불리므로, 내가 낀 스레드가 없는 PR(대부분)은 사람 모으기 전에 끝낸다.
        let me = viewer.lowercased()
        let mine = pr.threads.filter { $0.comments.contains { $0.author.lowercased() == me } }
        guard !mine.isEmpty else { return [] }
        let known = participants(of: pr)
        return mine.flatMap { replies(in: $0, viewer: viewer, knownLogins: known) }
    }

    /// 내 마지막 코멘트 뒤에 남이 단 글마다, 위에서부터 먼저 걸리는 규칙으로 가른다.
    ///
    /// 1. 나를 @멘션했다 → 나에게
    /// 2. 내 글을 인용했다(GitHub "Quote reply" 의 `>` 줄) → 나에게
    /// 3. 다른 사람만 @멘션했다 → 나에게 아님
    /// 4. 내가 연 스레드다 → 나에게
    /// 5. 남의 스레드에서 내 글 바로 다음 글이다 → 아마 나에게(`isGuess`)
    /// 6. 그 밖(사이에 이미 다른 사람 글이 있다) → 나에게 아님
    ///
    /// 내가 다시 답하면 그 앞 글들은 내가 처리한 것으로 본다 — "내 마지막 코멘트 뒤" 만 보는 이유다.
    static func replies(in thread: PRReviewThread, viewer: String, knownLogins: Set<String>) -> [MyCommentReply] {
        let me = viewer.lowercased()
        let comments = thread.comments
        guard let lastMine = comments.lastIndex(where: { $0.author.lowercased() == me }) else { return [] }
        let isMyThread = comments.first?.author.lowercased() == me
        let myBodies = comments.filter { $0.author.lowercased() == me }.map(\.body)
        var result: [MyCommentReply] = []
        for index in comments.indices where index > lastMine {
            let comment = comments[index]
            guard !TeamStats.isBot(comment.author),
                  let at = PRActivityBuilder.isoDate(comment.createdAt) else { continue }
            let mentions = mentionedLogins(in: comment.body, known: knownLogins)
            let isGuess: Bool
            if mentions.contains(me) || quotes(comment.body, anyOf: myBodies) {
                isGuess = false
            } else if !mentions.isEmpty {
                continue
            } else if isMyThread {
                isGuess = false
            } else if index == lastMine + 1 {
                isGuess = true
            } else {
                continue
            }
            result.append(MyCommentReply(threadID: thread.id, comment: comment, at: at, isGuess: isGuess))
        }
        return result
    }

    /// 이 PR 에 나오는 사람들(소문자). 멘션은 이 안의 이름만 사람으로 친다 — Swift 코드 리뷰에는
    /// `@MainActor`·`@escaping` 처럼 @ 로 시작하는 말이 흔해서, 아무 @단어나 멘션으로 보면 3번 규칙이 오작동한다.
    /// 대가로 이 PR 에 한 번도 안 나온 사람을 부른 글은 멘션으로 못 가른다(내 스레드면 나에게 온 것으로 남는다).
    static func participants(of pr: PullRequestInfo) -> Set<String> {
        var logins: [String] = [pr.author]
        logins += pr.approvals.map(\.login)
        logins += pr.pendingReviewers
        logins += pr.reviewEvents.map(\.author)
        logins += pr.issueComments.map(\.author)
        logins += pr.threads.flatMap { $0.comments.map(\.author) }
        return Set(logins.map { $0.lowercased() })
    }

    /// 글에서 @멘션한 사람(소문자). 코드 블록·인라인 코드 안은 보지 않고, 팀 멘션(`@org/team`)은 사람이 아니라 뺀다.
    static func mentionedLogins(in body: String, known: Set<String>) -> Set<String> {
        guard let mentionPattern else { return [] }
        let text = withoutCode(body)
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        for match in mentionPattern.matches(in: text, range: range) {
            guard let loginRange = Range(match.range(at: 1), in: text) else { continue }
            let login = text[loginRange].lowercased()
            if known.contains(login) { found.insert(login) }
        }
        return found
    }

    /// 앞이 글자·숫자면 메일 주소(`a@b.com`)의 일부다. 뒤에 `/` 가 오면 팀 멘션이다. 내 멘션 표시(MyMentions)도 같은 규칙을 쓴다.
    static let mentionPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_./-])@([A-Za-z0-9][A-Za-z0-9-]*)(?![A-Za-z0-9_/-])"#)

    /// 코드 블록(```…```)과 인라인 코드(`…`).
    private static let codePattern = try? NSRegularExpression(pattern: #"```[\s\S]*?```|`[^`\n]*`"#)

    /// 내 글을 인용했는가. 인용 줄 가운데 다섯 글자 이상인 줄이 하나라도 내 글에 그대로 있으면 그렇다고 본다 —
    /// "네" 처럼 짧은 줄은 아무 글에나 들어 있어 기준으로 삼지 않는다.
    static func quotes(_ body: String, anyOf mine: [String]) -> Bool {
        let quoted = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(">") }
            .map { normalized(String($0.drop(while: { $0 == ">" || $0 == " " }))) }
            .filter { $0.count >= 5 }
        guard !quoted.isEmpty else { return false }
        let targets = mine.map(normalized)
        return quoted.contains { line in targets.contains { $0.contains(line) } }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func withoutCode(_ body: String) -> String {
        guard let codePattern else { return body }
        return codePattern.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body),
                                                    withTemplate: " ")
    }
}
