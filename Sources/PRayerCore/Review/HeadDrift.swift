import Foundation

/// 게시하려는데 PR 에 새 커밋이 올라와 있다 — 그 사이 무엇이 들어왔는지.
///
/// 예전에는 head 가 바뀌면 무조건 게시를 막았다. 리뷰가 끝나고 10초 뒤 문서·스타일 커밋 둘이
/// 올라온 것까지 막았는데, 화면은 폴링 전이라 옛 head 를 그리고 있어서 사용자는 "커밋이 없는데
/// 막혔다" 고 느꼈다(2026-10-02 실측). 무엇이 올라왔는지 보여 주고, 그대로 올릴지는 사람이 정한다.
public struct HeadDrift: Sendable, Equatable, Identifiable {
    public struct Commit: Sendable, Equatable, Identifiable {
        public var oid: String
        public var headline: String

        public var id: String { oid }
        public var shortOid: String { String(oid.prefix(7)) }

        public init(oid: String, headline: String) {
            self.oid = oid
            self.headline = headline
        }
    }

    /// 견준 기준 커밋 — 리뷰한 커밋, 리뷰 없이 Approve 면 화면에 보이던 커밋.
    public var baseSha: String
    /// 지금 PR 의 head.
    public var headSha: String
    /// 그 사이 커밋(오래된 순). 목록을 못 받았거나 강제 푸시로 이어지지 않으면 비어 있다.
    public var commits: [Commit]
    /// 그 사이 커밋 수. 받은 목록이 잘렸어도 전체 수다. 모르면 nil.
    public var totalCount: Int?
    /// 기준 커밋이 지금 head 의 조상이 아니다 — 강제 푸시로 PR 에서 빠졌다.
    public var baseRewritten: Bool

    public var id: String { headSha }
    public var shortBase: String { String(baseSha.prefix(7)) }
    public var shortHead: String { String(headSha.prefix(7)) }

    public init(baseSha: String, headSha: String, commits: [Commit] = [],
                totalCount: Int? = nil, baseRewritten: Bool = false) {
        self.baseSha = baseSha
        self.headSha = headSha
        self.commits = commits
        self.totalCount = totalCount
        self.baseRewritten = baseRewritten
    }

    /// compare API 결과로 만든다. 비교를 못 했으면(`.failed`) 목록 없이 "새 커밋이 있다" 만 안다.
    public static func make(base: String, head: String, outcome: CommitComparison.Outcome) -> HeadDrift {
        switch outcome {
        case .compared(let comparison) where comparison.baseIsAncestor:
            return HeadDrift(baseSha: base, headSha: head,
                             commits: comparison.commits.map { Commit(oid: $0.oid, headline: $0.headline) },
                             totalCount: comparison.totalCommits)
        case .compared, .baseMissing:
            // diverged 의 commits 는 "갈라진 뒤 head 쪽 커밋" 이라 "리뷰 뒤에 올라온 것" 이 아니다. 보이지 않는다.
            return HeadDrift(baseSha: base, headSha: head, baseRewritten: true)
        case .failed:
            return HeadDrift(baseSha: base, headSha: head)
        }
    }

    /// 그대로 올릴 때 리뷰를 어느 커밋에 남기나.
    ///
    /// 인라인 코멘트의 줄 번호는 리뷰한 커밋의 diff 기준이라 그 커밋에 붙여야 제자리에 달린다
    /// (GitHub 은 PR 안의 앞 커밋을 받아 주고, 그 뒤 바뀐 줄은 Outdated 로 보인다).
    /// 인라인이 없으면 지금 head 에 남겨야 Approve 가 지금 커밋 기준으로 집계된다.
    public static func postingCommit(reviewed: String, acceptedHead: String?, postsInlineComments: Bool) -> String {
        guard let acceptedHead, !postsInlineComments else { return reviewed }
        return acceptedHead
    }

    /// 묻지 않고 막아야 하는가. 리뷰한 커밋이 PR 에서 빠졌으면 인라인 코멘트를 붙일 곳이 없다.
    public func blocksPosting(inlineCount: Int) -> Bool {
        baseRewritten && inlineCount > 0
    }
}

/// `compare/{base}...{head}` 결과에서 쓰는 것만.
public struct CommitComparison: Sendable, Equatable, Decodable {
    public struct Entry: Sendable, Equatable, Decodable {
        public var oid: String
        public var message: String

        public init(oid: String, message: String) {
            self.oid = oid
            self.message = message
        }

        /// 커밋 메시지 첫 줄. 본문까지 보이면 확인 창이 길어져 무엇이 올라왔는지 오히려 안 읽힌다.
        public var headline: String {
            message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    public enum Outcome: Sendable, Equatable {
        case compared(CommitComparison)
        /// 기준 커밋이 저장소에 없다(강제 푸시 뒤 지워졌다). GitHub 이 404 를 준다.
        case baseMissing
        /// 연결 끊김 등으로 비교하지 못했다.
        case failed
    }

    /// ahead · behind · diverged · identical
    public var status: String
    public var totalCommits: Int
    public var commits: [Entry]

    public init(status: String, totalCommits: Int, commits: [Entry]) {
        self.status = status
        self.totalCommits = totalCommits
        self.commits = commits
    }

    enum CodingKeys: String, CodingKey {
        case status
        case totalCommits = "total"
        case commits
    }

    /// 기준이 head 의 조상인가 — 그래야 commits 가 "그 뒤에 올라온 커밋" 이다.
    public var baseIsAncestor: Bool { status == "ahead" || status == "identical" }

    /// `gh api` 실패 출력이 "기준 커밋이 없다" 는 뜻인가. 그 밖의 실패(연결 등)와 할 일이 다르다.
    public static func isMissingBase(_ output: String) -> Bool {
        output.contains("HTTP 404") || output.contains("No common ancestor")
    }
}

/// 새 커밋 확인 창에 그릴 글. 경우마다 문구가 달라 화면 밖에서 정하고 테스트로 지킨다.
public struct HeadDriftPrompt: Sendable, Equatable {
    /// 무엇을 올리려다 멈췄나.
    public enum Subject: Sendable, Equatable {
        /// AI 리뷰 초안을 올린다. `label` 은 누른 버튼 이름("코멘트+Approve 게시").
        case review(event: ReviewEvent, label: String, inlineCount: Int)
        /// AI 리뷰 없이 Approve 만.
        case plainApprove
    }

    /// 창이 길어지면 무엇이 올라왔는지 오히려 안 읽힌다. 최근 것만 보이고 나머지는 수로 말한다.
    public static let maxShown = 5

    public var title: String
    public var subtitle: String
    /// 보일 커밋(오래된 순). 제목 앞에 모두 같은 태그가 붙어 있으면 뗀 것이다.
    public var commits: [HeadDrift.Commit]
    /// 목록에서 뺀 커밋 수("외 N개").
    public var hiddenCount: Int
    /// 목록이 비었을 때 대신 보일 말.
    public var emptyListText: String?
    public var note: String
    public var confirmLabel: String
    public var isDestructive: Bool

    public static func make(drift: HeadDrift, subject: Subject) -> HeadDriftPrompt {
        let isReview: Bool
        if case .review = subject { isReview = true } else { isReview = false }
        let total = drift.totalCount ?? drift.commits.count

        let title: String
        if drift.baseRewritten {
            title = isReview ? "리뷰한 뒤 PR 커밋이 바뀌었습니다" : "보고 있던 뒤로 PR 커밋이 바뀌었습니다"
        } else {
            let what = total > 0 ? "새 커밋 \(total)개가" : "새 커밋이"
            title = isReview ? "리뷰한 뒤 \(what) 올라왔습니다" : "보고 있던 커밋 이후 \(what) 올라왔습니다"
        }

        let subtitle: String
        if drift.baseRewritten {
            subtitle = isReview
                ? "리뷰한 커밋(\(drift.shortBase))이 강제 푸시로 PR 에서 빠졌습니다."
                : "화면에 보이던 커밋(\(drift.shortBase))이 강제 푸시로 PR 에서 빠졌습니다."
        } else {
            subtitle = isReview
                ? "리뷰한 커밋 \(drift.shortBase) 이후에 올라왔고, 리뷰에는 들어가지 않았습니다."
                : "화면에 보이던 커밋 \(drift.shortBase) 이후에 올라왔습니다."
        }

        let shown = Array(drift.commits.suffix(maxShown))
        let headlines = strippingSharedTag(shown.map(\.headline))
        let commits = zip(shown, headlines).map { HeadDrift.Commit(oid: $0.oid, headline: $1) }
        let hidden = max(0, total - commits.count)

        let emptyListText: String?
        if !commits.isEmpty {
            emptyListText = nil
        } else if drift.baseRewritten {
            emptyListText = "커밋이 이어지지 않아 무엇이 새로 들어왔는지 가려낼 수 없습니다."
        } else {
            emptyListText = "새 커밋 목록을 받지 못했습니다. 지금 커밋은 \(drift.shortHead) 입니다."
        }

        switch subject {
        case .plainApprove:
            return HeadDriftPrompt(title: title, subtitle: subtitle, commits: commits, hiddenCount: hidden,
                                   emptyListText: emptyListText,
                                   note: "Approve 는 최신 커밋(\(drift.shortHead))에 남습니다.",
                                   confirmLabel: "그대로 Approve", isDestructive: false)
        case .review(let event, let label, let inlineCount):
            return HeadDriftPrompt(title: title, subtitle: subtitle, commits: commits, hiddenCount: hidden,
                                   emptyListText: emptyListText,
                                   note: noteText(event: event, inlineCount: inlineCount, drift: drift),
                                   confirmLabel: "그대로 \(label)",
                                   isDestructive: event == .requestChanges)
        }
    }

    /// 그대로 올리면 무엇이 어느 커밋에 남는지. 자리는 `HeadDrift.postingCommit` 과 같은 규칙이다.
    static func noteText(event: ReviewEvent, inlineCount: Int, drift: HeadDrift) -> String {
        let outdated = "바뀐 줄의 코멘트는 GitHub 에서 Outdated 로 보일 수 있습니다."
        guard inlineCount == 0 else {
            switch event {
            case .approve:
                return "인라인 코멘트 \(inlineCount)건과 Approve 는 리뷰한 커밋(\(drift.shortBase)) 기준으로 남습니다. \(outdated)"
            case .comment:
                return "인라인 코멘트 \(inlineCount)건은 리뷰한 커밋(\(drift.shortBase)) 줄에 달립니다. \(outdated)"
            case .requestChanges:
                return "인라인 코멘트 \(inlineCount)건과 변경 요청은 리뷰한 커밋(\(drift.shortBase)) 기준으로 남고, 머지를 막습니다. \(outdated)"
            }
        }
        switch event {
        case .approve: return "Approve 는 최신 커밋(\(drift.shortHead))에 남습니다."
        case .comment: return "코멘트는 최신 커밋(\(drift.shortHead))에 남고, Approve 수에는 영향이 없습니다."
        case .requestChanges: return "변경 요청은 최신 커밋(\(drift.shortHead))에 남고, 머지를 막습니다."
        }
    }

    /// 모든 커밋 제목 앞에 같은 `[이슈 키]` 가 붙어 있으면 뗀다.
    /// 브랜치 하나에 올라온 커밋은 대개 같은 키를 달고 있어, 그대로 두면 줄마다 같은 글자가 먼저 읽힌다.
    static func strippingSharedTag(_ headlines: [String]) -> [String] {
        let tags = headlines.map(leadingTag)
        guard let first = tags.first, let tag = first, tags.allSatisfy({ $0 == tag }) else { return headlines }
        return headlines.map { line in
            let rest = line.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? line : rest
        }
    }

    private static func leadingTag(_ line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let tag = String(line[...close])
        return tag.count > 2 ? tag : nil
    }
}
