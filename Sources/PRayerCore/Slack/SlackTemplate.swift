import Foundation

/// 슬랙 글에 들어갈 PR 하나의 값. 화면 모델(`PullRequestInfo`)에서 한 번 뽑아 두면 글 만들기는 순수 함수다.
public struct SlackPRItem: Equatable, Sendable {
    public var repoName: String
    public var number: Int
    public var title: String
    public var url: String

    public init(repoName: String, number: Int, title: String, url: String) {
        self.repoName = repoName
        self.number = number
        self.title = title
        self.url = url
    }

    public init(pr: PullRequestInfo, host: String) {
        self.init(repoName: pr.repo.name,
                  number: pr.number,
                  title: pr.title,
                  url: pr.htmlURL(host: host)?.absoluteString ?? "")
    }
}

/// 보낼 글 만들기. **형식은 고정이다** — 사람이 틀을 고치지 않는다(2026-10-23 사용자 결정, 그 전엔 칩으로 고치는 틀).
///
/// 팀 채널에서 사람들이 손으로 올리는 꼴 그대로다(2026-10-23, 사람들이 손으로 올리는 리뷰 요청 글을 보고 정했다):
/// PR 주소를 한 줄에 하나씩, 맨 끝 줄에 "리뷰 부탁드립니다". 주소는 링크 글자로 감싸지 않는다 — 슬랙이 스스로 링크로
/// 만들고, 깔린 GitHub 앱이 PR 미리보기를 붙인다(`unfurlLinks`). 사람이 붙여 넣을 때와 같게.
public enum SlackTemplate {
    /// 맨 끝 줄.
    public static let request = "리뷰 부탁드립니다"

    /// 링크 미리보기를 펼친다 — 사람이 주소를 붙여 넣을 때 슬랙이 하는 그대로다. 주소만 있는 글이라 제목은 미리보기가 보인다.
    public static let unfurlLinks = true

    /// 슬랙 글 하나의 길이 한도. 커넥터가 이보다 긴 글은 받지 않는다(도구 설명: 5000자).
    public static let maxLength = 5000

    /// 보낼 글. PR 이 없으면 빈 글.
    public static func message(items: [SlackPRItem]) -> String {
        guard !items.isEmpty else { return "" }
        return (items.map(line) + [request]).joined(separator: "\n")
    }

    /// PR 한 줄 — 주소만. 주소를 못 만들었으면(호스트 설정이 이상할 때) 무엇인지는 알게 레포·번호·제목을 쓴다.
    static func line(_ item: SlackPRItem) -> String {
        item.url.isEmpty ? "\(item.repoName)#\(item.number) \(item.title)" : item.url
    }

    /// 링크 글자(`[글](주소)` 의 글)로 넣을 글. 고친 글에 링크가 섞이면 쓴다(`SlackMarkdownText.markdown`).
    /// **짝이 맞는 대괄호는 그대로 둔다** — `[PROJ-123][IOS] 고침` 처럼 짝이 맞으면 그대로도 링크가 된다(실측).
    /// 예전처럼 `\[` 로 이스케이프하면 Claude(haiku)가 옮겨 적다 백슬래시를 떼어 훅이 보내기를 막았다(2026-10-23 실측 2/2).
    /// 짝이 안 맞는 것만 전각(［ ］)으로 바꾼다 — 마크다운 글자가 아니라 링크를 깨지 않고, 이스케이프가 없어 그대로 옮겨진다.
    static func linkLabel(_ text: String) -> String {
        var characters = Array(text)
        var open: [Int] = []
        var unmatched: [Int] = []
        for (index, character) in characters.enumerated() {
            switch character {
            case "[":
                open.append(index)
            case "]":
                if open.popLast() == nil { unmatched.append(index) }
            default:
                break
            }
        }
        for index in unmatched + open {
            characters[index] = characters[index] == "[" ? "［" : "］"
        }
        return String(characters)
    }

    /// 화면 미리보기용 — 멘션 `<@ID>` 를 `@이름` 으로, `<!here>` 를 `@here` 로 바꾼다(고친 글에 사람이 넣었을 때).
    /// 보낼 글은 바꾸지 않는다. 미리보기에서만 사람이 읽을 수 있게 한다.
    public static func preview(_ message: String, people: [SlackPerson]) -> String {
        var text = message
        for person in people {
            text = text.replacingOccurrences(of: "<@\(person.id)>", with: "@\(person.name)")
        }
        for special in ["here", "channel", "everyone"] {
            text = text.replacingOccurrences(of: "<!\(special)>", with: "@\(special)")
        }
        // 마크다운 이스케이프는 미리보기에서 걷는다 — 슬랙도 걷어서 보인다(실측).
        return text.replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")
    }

    /// 고른 PR 이 없을 때(연동 실패 화면 시험) 미리보기에 쓰는 가짜 PR.
    public static let sampleItems: [SlackPRItem] = [
        SlackPRItem(repoName: "sample-ios", number: 128, title: "로그인 화면 \"다시 시도\" 버튼 정리",
                    url: "https://github.com/acme/sample-ios/pull/128"),
        SlackPRItem(repoName: "sample-ios", number: 131, title: "목록 새로고침 깜빡임 수정",
                    url: "https://github.com/acme/sample-ios/pull/131")
    ]
}
