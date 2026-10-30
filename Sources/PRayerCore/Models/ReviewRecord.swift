import Foundation

public enum AnchorStatus: String, Sendable, Codable {
    /// 초안의 (path, side, line) 이 diff 와 그대로 일치.
    case ok
    /// anchor_text 로 줄을 다시 찾아 보정함.
    case fixed
    /// diff 에서 줄을 특정할 수 없음 → 인라인 게시 불가. 사용자가 줄을 지정하거나 삭제해야 한다.
    case unresolved
}

public struct DraftCommentState: Sendable, Codable, Hashable, Identifiable {
    public var comment: DraftComment
    public var editedBody: String
    public var include: Bool
    public var anchorStatus: AnchorStatus
    /// 보정 전 모델이 준 줄 번호(기록용).
    public var originalLine: Int?

    public var id: String { comment.issueKey }
    public var isPostable: Bool { include && anchorStatus != .unresolved }

    public init(comment: DraftComment, editedBody: String? = nil, include: Bool = true,
                anchorStatus: AnchorStatus = .ok, originalLine: Int? = nil) {
        self.comment = comment
        self.editedBody = editedBody ?? comment.body
        self.include = include
        self.anchorStatus = anchorStatus
        self.originalLine = originalLine
    }
}

public struct EngineUsage: Sendable, Codable, Hashable {
    public var model: String
    public var inputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var durationMs: Int

    public init(model: String = "", inputTokens: Int = 0, cacheCreationTokens: Int = 0,
                cacheReadTokens: Int = 0, outputTokens: Int = 0, costUSD: Double = 0, durationMs: Int = 0) {
        self.model = model
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.durationMs = durationMs
    }

    /// 사용량 원장에 쌓는 값. 캐시 읽기는 한도 소모가 작아 제외한다.
    public var billableTokens: Int { inputTokens + cacheCreationTokens + outputTokens }
}

public struct PostedInfo: Sendable, Codable, Hashable {
    public var reviewID: Int
    public var htmlURL: String
    public var event: String
    public var postedAt: Date
    public var commentCount: Int

    public init(reviewID: Int, htmlURL: String, event: String, postedAt: Date, commentCount: Int) {
        self.reviewID = reviewID
        self.htmlURL = htmlURL
        self.event = event
        self.postedAt = postedAt
        self.commentCount = commentCount
    }
}

public struct ValidationIssue: Sendable, Codable, Hashable {
    public var issueKey: String?
    public var message: String
    /// 문제 기록에 쌓을 종류. 옛 기록에는 없다(nil).
    public var kind: ProblemKind?

    public init(issueKey: String? = nil, message: String, kind: ProblemKind? = nil) {
        self.issueKey = issueKey
        self.message = message
        self.kind = kind
    }
}

/// 리뷰 1건의 로컬 기록. 게시 전에는 이 파일이 유일한 초안 저장소다(GitHub PENDING 리뷰를 쓰지 않는다).
public struct ReviewRecord: Sendable, Codable, Identifiable {
    public var repo: RepoID
    public var number: Int
    public var headSha: String
    public var baseRefName: String
    public var promptVersion: String
    public var model: String
    public var createdAt: Date
    /// 리뷰가 본 PR 스냅샷의 GitHub 활동 시각.
    ///
    /// "리뷰 이후에 올라온 것" 을 셀 때 `createdAt`(로컬 맥 시계로, 모델이 **끝난 뒤** 찍힌다)
    /// 을 쓰면 안 된다. 리뷰가 도는 몇 분 사이에 달린 코멘트는 리뷰 입력에도 없고 그 경계에도
    /// 안 걸려 영영 보이지 않는다. 앱이 죽어 다음 실행에서 수확한 리뷰는 그 구멍이 하룻밤이 된다.
    /// 옛 기록에는 없어 optional 이다.
    public var snapshotUpdatedAt: Date?
    public var trigger: Trigger
    /// 워크트리를 붙인 전체 리뷰였는가. 옛 기록에는 없다(= diff 리뷰).
    public var deep: Bool?
    /// 리뷰한 시점의 변경 줄 수(추가 + 삭제). 다음 리뷰의 "Claude 가 읽고 판단" 예상 범위를 잡는 근거다
    /// (`ClaudeStepEstimate`). 옛 기록에는 없다.
    public var changedLines: Int?
    /// 게시 본문에 무엇을 넣을지. 미리보기와 게시 시트가 같은 값을 쓴다(옛 기록에는 없다).
    public var includeSummary: Bool?
    public var includeConcerns: Bool?
    public var includeQuestions: Bool?
    /// 읽어 보고 "문제 아님" 으로 정리한 항목들. `ReviewItemKey` → 게시 본문에 들어갈 한 줄.
    ///
    /// 체크를 끄는 것과 다르다. 체크를 끄면 그냥 사라지지만, 여기 담기면 본문의
    /// "확인했고 문제없던 것" 절에 남아 **내가 보고 넘겼다는 사실**이 작성자에게 전달된다.
    /// 옛 기록에는 없으므로 optional.
    public var clearedItems: [String: String]?
    public var includeCleared: Bool?
    /// 게시할 리뷰 종류. 비어 있으면 설정·판정으로 제안값을 쓴다.
    public var plannedEvent: String?
    /// 사용자가 고른 게시 방식(`PostAction`). 비어 있으면 상황에 맞는 권장값을 쓴다.
    /// 옛 기록에는 없다.
    public var plannedAction: String?
    public var output: ReviewOutput
    public var comments: [DraftCommentState]
    public var includeStrengths: Bool
    public var bodyDraft: String
    public var usage: EngineUsage
    public var validationIssues: [ValidationIssue]
    public var posted: PostedInfo?
    public var discarded: Bool
    /// 이 리뷰를 만든 대화의 ID. `claude --resume`·`codex resume` 으로 이어 갈 때 쓴다(`ClaudeSession`).
    /// 대화를 남기기 시작한 0.5.1 전의 기록에는 없다.
    public var sessionID: String?
    /// 이 리뷰를 돌린 CLI. Codex 를 붙이기 전의 기록에는 없다 — 그때는 늘 Claude 였다(`engineKind`).
    /// (그보다 더 전, Codex 를 대체 엔진으로 두던 때의 기록에 남은 `"engine":"claude"` 도 같은 값으로 읽힌다.)
    public var engine: ReviewEngineKind?

    public var engineKind: ReviewEngineKind { engine ?? .claude }
    /// 사용자가 본문에서 고친 글(`ReviewTextEdits`). 원문은 `output` 에 그대로 있다. 옛 기록에는 없다.
    public var textEdits: ReviewTextEdits?
    /// 변경 파일 탭에서 "이 줄에 코멘트로 달기" 로 인라인 초안이 된 우려사항·질문.
    /// `ReviewItemKey` → 그때 만든 초안의 issue_key. 옮긴 항목은 본문에서 빠진다(`bodyConcerns`).
    /// 옛 기록에는 없다.
    public var movedToInline: [String: String]?
    /// 지적 목록에서 "본문에" 를 고른 우려사항·질문(`ReviewItemKey`). 한 번이라도 고르면 생기고, 그때부터는
    /// 절 체크(`includeConcerns`·`includeQuestions`) 대신 이것이 본문에 실을 항목을 정한다. 옛 기록에는 없다.
    public var bodyIssueKeys: [String]?
    /// 지적 목록에서 바로 단 줄 코멘트. 지적 키(`ReviewIssue.key`) → 단 코멘트. 왼쪽 리뷰 게시와는 따로 간다. 옛 기록에는 없다.
    public var postedInline: [String: PostedComment]?
    /// 코드 코멘트 카드에서 "리뷰에 담기" 한 지적(`ReviewIssue.key`, 담은 순서). 왼쪽 리뷰를 게시할 때 그 리뷰의 줄 코멘트로
    /// 함께 올라간다(`ReviewBasket`). 바로 달기와 달리 리뷰 하나로 묶여 작성자 알림도 한 번이다. 옛 기록에는 없다.
    public var basketIssueKeys: [String]?

    public enum Trigger: String, Sendable, Codable {
        case manual
        case auto
    }

    public init(repo: RepoID, number: Int, headSha: String, baseRefName: String, promptVersion: String,
                model: String, createdAt: Date = Date(),
                snapshotUpdatedAt: Date? = nil,
                trigger: Trigger, deep: Bool? = nil, output: ReviewOutput,
                includeSummary: Bool? = nil, includeConcerns: Bool? = nil,
                includeQuestions: Bool? = nil,
                clearedItems: [String: String]? = nil, includeCleared: Bool? = nil,
                plannedEvent: String? = nil, plannedAction: String? = nil,
                comments: [DraftCommentState], includeStrengths: Bool = true, bodyDraft: String,
                usage: EngineUsage, validationIssues: [ValidationIssue] = [], posted: PostedInfo? = nil,
                discarded: Bool = false) {
        self.repo = repo
        self.number = number
        self.headSha = headSha
        self.baseRefName = baseRefName
        self.promptVersion = promptVersion
        self.model = model
        self.createdAt = createdAt
        self.snapshotUpdatedAt = snapshotUpdatedAt
        self.trigger = trigger
        self.deep = deep
        self.includeSummary = includeSummary
        self.includeConcerns = includeConcerns
        self.includeQuestions = includeQuestions
        self.clearedItems = clearedItems
        self.includeCleared = includeCleared
        self.plannedEvent = plannedEvent
        self.plannedAction = plannedAction
        self.output = output
        self.comments = comments
        self.includeStrengths = includeStrengths
        self.bodyDraft = bodyDraft
        self.usage = usage
        self.validationIssues = validationIssues
        self.posted = posted
        self.discarded = discarded
    }

    public var id: String { "\(repo.full)#\(number)@\(headSha)" }
    public var prKey: String { "\(repo.full)#\(number)" }
    public var isPosted: Bool { posted != nil }
    public var includedComments: [DraftCommentState] { comments.filter(\.isPostable) }
    public var shortHead: String { String(headSha.prefix(7)) }
    /// 리뷰 1건을 가리키는 키. 같은 PR·같은 커밋을 여러 번 리뷰할 수 있으므로 시각까지 넣는다.
    public var storageKey: String { "\(headSha)|\(createdAt.timeIntervalSince1970)" }
    /// 워크트리를 붙인 전체 리뷰로 만든 초안인가.
    public var isDeep: Bool { deep == true }

    /// 본문 구성 기본값: 요약만 넣는다(팀 승인 본문 중앙값이 288자라 길게 쓰지 않는다).
    public var bodyIncludesSummary: Bool { includeSummary ?? true }
    public var bodyIncludesStrengths: Bool { includeStrengths }
    /// 지적 목록에서 항목마다 고른 뒤로는(`bodyIssueKeys`) 절 체크가 아니라 고른 항목이 본문을 정한다.
    public var bodyIncludesConcerns: Bool { bodyIssueKeys != nil || (includeConcerns ?? false) }
    public var bodyIncludesQuestions: Bool { bodyIssueKeys != nil || (includeQuestions ?? false) }
    /// 정리한 항목이 있으면 기본으로 본문에 넣는다 — 넣는 것이 이 기능의 목적이다.
    public var bodyIncludesCleared: Bool { includeCleared ?? true }

    public func clearedNote(for key: String) -> String? {
        guard let note = clearedItems?[key], !note.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return note
    }

    public func isCleared(_ key: String) -> Bool { clearedItems?[key] != nil }

    /// 정리 표시를 켜고 끈다. 코멘트 초안을 정리하면 인라인 게시 대상에서도 빼 준다
    /// (본문에 "확인했다" 고 적으면서 같은 자리에 지적을 또 올리면 말이 안 된다).
    public mutating func setCleared(_ note: String?, for key: String) {
        var items = clearedItems ?? [:]
        if let note {
            items[key] = note
            if let index = comments.firstIndex(where: { ReviewItemKey.draft($0.comment) == key }) {
                comments[index].include = false
            }
        } else {
            items.removeValue(forKey: key)
        }
        clearedItems = items.isEmpty ? nil : items
    }

    /// 정리한 항목을 리뷰 결과에 실린 순서대로 돌려준다 — 사전은 순서가 없어서 본문이 매번 뒤바뀐다.
    public var orderedClearedNotes: [String] {
        guard let clearedItems, !clearedItems.isEmpty else { return [] }
        var keys: [String] = output.concerns.map { ReviewItemKey.concern($0) }
        keys += comments.map { ReviewItemKey.draft($0.comment) }
        keys += (output.questionsForAuthor ?? []).map { ReviewItemKey.question($0) }
        var seen = Set<String>()
        return keys
            .filter { seen.insert($0).inserted }
            .compactMap { clearedItems[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
