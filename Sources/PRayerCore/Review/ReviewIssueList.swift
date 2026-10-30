import Foundation

/// 지적 하나를 어디에 올릴지.
public enum IssuePlacement: String, Sendable, CaseIterable, Identifiable {
    /// 그 줄의 인라인 코멘트로.
    case code
    /// 리뷰 본문에 한 줄로.
    case body
    /// 올리지 않는다.
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .code: return "코드 옆에 달기"
        case .body: return "본문에"
        case .off: return "안 올림"
        }
    }
}

/// 코드 코멘트의 중요도 — 필수 · 권장 · 참고(사용자 결정, 2026-10-20).
///
/// 작성자가 할 일 기준이다: 필수 = 머지 전에 고쳐야 함(머지를 막는 이슈, 블로커), 권장 = 고치면 좋음(비블로커),
/// 참고 = 알아 두거나 답하면 됨. 지금 모델은 이 세 값(code_comments.importance)을 바로 낸다. 옛 기록은 심각도 네 단계와
/// 질문에서 옮긴다 — "높음" 과 "보통" 은 경계가 흔들리고 작성자가 할 일은 같아서 권장 하나로 묶었다.
public enum ReviewImportance: Int, Sendable, Comparable, CaseIterable {
    case required
    case recommended
    case informational

    public var label: String {
        switch self {
        case .required: return "필수"
        case .recommended: return "권장"
        case .informational: return "참고"
        }
    }

    /// 카드 맨 위 띠에 이름 뒤로 붙는 짧은 뜻 — "필수 · 머지 전에 고쳐야 함".
    public var meaning: String {
        switch self {
        case .required: return "머지 전에 고쳐야 함"
        case .recommended: return "고치면 좋음"
        case .informational: return "알아 두면 됨"
        }
    }

    /// 태그에 마우스를 올렸을 때. 안내 줄의 "머지를 막는 이슈" 와 이어 준다.
    public var help: String {
        switch self {
        case .required: return "필수 — 머지를 막는 이슈. 고쳐지기 전에는 Approve 하지 않습니다"
        case .recommended: return "권장 — 고치면 좋지만 머지를 막지는 않습니다"
        case .informational: return "참고 — 알아 두거나 답하면 됩니다. 머지를 막지 않습니다"
        }
    }

    public init(severity: Severity?) {
        switch severity {
        case .blocker: self = .required
        case .major, .minor: self = .recommended
        case .nit, nil: self = .informational
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// AI 리뷰 탭 오른쪽 "지적" 목록의 한 줄. 우려사항·질문·인라인 초안을 하나로 합친 것이다.
///
/// 모델은 같은 사안을 우려사항(본문용 한 줄)과 인라인 초안(코드 옆에 달 글)에 같은 issue_key 로
/// 두 번 적는다(실측: 저장된 리뷰 122건의 우려사항 54건 중 40건). 예전 화면은 둘을 다른 상자에 그려
/// 같은 얘기를 두 번 읽게 했고, 질문은 또 다른 절에 있었다 — 셋 다 "작성자에게 남길 말 하나" 다(사용자 피드백).
/// 모델 출력의 구분(우려사항·질문·초안)은 그대로 두고 화면과 게시 본문에서만 하나로 본다.
public struct ReviewIssue: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// 우려사항. 같은 issue_key 의 초안이 있으면 `draftIssueKey` 에 그 키가 있다.
        case concern
        /// 작성자에게 묻는 것. 심각도가 없어 변경 요청·blocker 로 세지 않는다.
        case question
        /// 짝이 되는 우려사항 없이 초안만 있는 것.
        case draftOnly
    }

    /// 우려사항·질문은 그 `ReviewItemKey`, 초안만 있는 것은 초안의 키.
    public var key: String
    public var kind: Kind
    /// 목록에 보일 한 줄. 우려사항은 제목, 질문은 질문, 초안만 있으면 초안 첫 문장.
    public var title: String
    public var severity: Severity?
    public var path: String?
    public var line: Int?
    /// 그 줄이 새 코드 쪽인가 옛 코드 쪽인가. 코드 조각을 그릴 때 쓴다. 질문 근거에는 없어 새 코드 쪽으로 본다.
    public var side: DiffSide = .right
    /// 붙어 있는 인라인 초안(`DraftComment.issueKey`). 같은 issue_key 의 초안이거나 옮겨 만든 초안.
    public var draftIssueKey: String?

    public var id: String { key }
    /// 중요도. 질문은 심각도가 없어 참고다.
    public var importance: ReviewImportance { ReviewImportance(severity: severity) }
    /// 머지를 막는 이슈인가(필수).
    public var isBlocking: Bool { importance == .required }
    public var place: String? {
        guard let path, let line else { return nil }
        return "\((path as NSString).lastPathComponent):\(line)"
    }
}

extension ReviewRecord {
    /// 지적 목록. 우려사항(심각도 순 그대로 모델 순서) → 짝 없는 초안 → 질문.
    public var issues: [ReviewIssue] {
        var result: [ReviewIssue] = []
        var claimedDrafts = Set<String>()
        for concern in output.concerns {
            let key = ReviewItemKey.concern(concern)
            let draft = linkedDraftKey(itemKey: key, sameKey: concern.issueKey)
            if let draft { claimedDrafts.insert(draft) }
            result.append(ReviewIssue(key: key, kind: .concern, title: text(for: concern),
                                      severity: concern.severity, path: concern.path.isEmpty ? nil : concern.path,
                                      line: concern.line, side: concern.side ?? .right, draftIssueKey: draft))
        }
        var questionIssues: [ReviewIssue] = []
        for question in output.questionsForAuthor ?? [] {
            let key = ReviewItemKey.question(question)
            let draft = movedToInline?[key]
            if let draft { claimedDrafts.insert(draft) }
            let evidence = (question.evidence ?? []).first { $0.line != nil } ?? question.evidence?.first
            questionIssues.append(ReviewIssue(key: key, kind: .question, title: text(for: question), severity: nil,
                                              path: evidence?.path, line: evidence?.line, draftIssueKey: draft))
        }
        for state in comments where !claimedDrafts.contains(state.comment.issueKey) {
            result.append(ReviewIssue(key: ReviewItemKey.draft(state.comment), kind: .draftOnly,
                                      title: Self.firstSentence(state.editedBody), severity: state.comment.severity,
                                      path: state.comment.path, line: state.comment.line,
                                      side: state.comment.side, draftIssueKey: state.comment.issueKey))
        }
        return result + questionIssues
    }

    /// 같은 issue_key 의 초안이 먼저, 없으면 옮겨 만든 초안.
    private func linkedDraftKey(itemKey: String, sameKey: String) -> String? {
        if comments.contains(where: { $0.comment.issueKey == sameKey }) { return sameKey }
        return movedToInline?[itemKey]
    }

    public func draftIndex(for issue: ReviewIssue) -> Int? {
        guard let key = issue.draftIssueKey else { return nil }
        return comments.firstIndex { $0.comment.issueKey == key }
    }

    /// 지금 어디에 올라가는가. 코드 옆이 먼저다 — 옛 기록에서 같은 사안이 본문과 인라인 양쪽에 켜져 있으면
    /// 코드 옆으로 보고, 본문 쪽은 고를 때 정리된다.
    public func placement(of issue: ReviewIssue) -> IssuePlacement {
        if let index = draftIndex(for: issue), comments[index].include { return .code }
        switch issue.kind {
        case .concern: return bodyConcerns.contains { ReviewItemKey.concern($0) == issue.key } && bodyIncludesConcerns ? .body : .off
        case .question: return bodyQuestions.contains { ReviewItemKey.question($0) == issue.key } && bodyIncludesQuestions ? .body : .off
        case .draftOnly: return .off
        }
    }

    /// 고를 수 있는 자리. 초안만 있는 것은 본문용 한 줄이 없어 "본문에" 가 없다.
    public func placements(for issue: ReviewIssue) -> [IssuePlacement] {
        issue.kind == .draftOnly ? [.code, .off] : IssuePlacement.allCases
    }

    /// 코드 옆에 달 수 없는 이유. nil 이면 달 수 있다.
    public func codeBlockedReason(for issue: ReviewIssue, diff: ParsedDiff?) -> String? {
        if let index = draftIndex(for: issue) {
            return comments[index].anchorStatus == .unresolved ? "diff 에서 줄을 찾지 못해 코드 옆에 달 수 없습니다." : nil
        }
        guard let diff else { return "변경 내용을 아직 받지 못했습니다." }
        guard let spot = inlineSpot(for: issue.key, diff: diff) else { return "가리키는 줄이 없어 코드 옆에 달 수 없습니다." }
        return spot.locationIndex == nil ? "이번 변경(diff) 밖의 줄이라 GitHub 이 코드 옆 코멘트를 받지 않습니다." : nil
    }

    /// 자리를 바꾼다. 바꿨으면 true. 코드 옆·본문·안 올림은 서로 배타적이다.
    @discardableResult
    public mutating func setPlacement(_ placement: IssuePlacement, for issue: ReviewIssue, diff: ParsedDiff?) -> Bool {
        guard !isPosted else { return false }
        // 처음 고를 때 지금 본문에 실리는 항목으로 목록을 만든다 — 그 뒤로는 이 목록이 본문을 정한다.
        if bodyIssueKeys == nil, issue.kind != .draftOnly {
            var keys: [String] = []
            if bodyIncludesConcerns { keys += bodyConcerns.map { ReviewItemKey.concern($0) } }
            if bodyIncludesQuestions { keys += bodyQuestions.map { ReviewItemKey.question($0) } }
            bodyIssueKeys = keys
        }
        let movedDraft = movedToInline?[issue.key]
        switch placement {
        case .code:
            if let index = draftIndex(for: issue) {
                guard comments[index].anchorStatus != .unresolved else { return false }
                comments[index].include = true
            } else {
                guard let diff, moveToInline(key: issue.key, diff: diff) else { return false }
            }
            bodyIssueKeys?.removeAll { $0 == issue.key }
        case .body, .off:
            if movedDraft != nil {
                // 옮겨 만든 초안은 되돌리면 지운다 — 남겨 두면 짝 없는 초안으로 목록에 한 번 더 뜬다.
                undoMoveToInline(issue.key)
            } else if let index = draftIndex(for: issue) {
                comments[index].include = false
            }
            bodyIssueKeys?.removeAll { $0 == issue.key }
            if placement == .body, issue.kind != .draftOnly { bodyIssueKeys?.append(issue.key) }
        }
        return true
    }

    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 문장 끝은 마침표 **뒤에 빈칸이 올 때만** 본다 — `size.width` 같은 코드 안의 점에서 끊으면 안 된다.
        var cut = Substring(trimmed)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(after: index)
            if trimmed[index] == "\n" || (".?!".contains(trimmed[index]) && (next == trimmed.endIndex || trimmed[next].isWhitespace)) {
                cut = trimmed[...index]
                break
            }
            index = next
        }
        let sentence = String(cut).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count <= 90 ? sentence : String(sentence.prefix(90)) + "…"
    }
}

extension ReviewRecord {
    /// 이 지적을 이미 바로 달았으면 그 코멘트.
    public func postedComment(for issue: ReviewIssue) -> PostedComment? { postedInline?[issue.key] }

    /// 바로 달 줄 코멘트. 붙은 초안이 있으면 그 자리와 고친 글, 없으면 항목의 자리(diff 안 첫 자리)에 `body` 로.
    /// 숨은 마커는 늘 붙인다(`PostBuilder.decorate`) — 없으면 다음 "다시 확인" 에서 남이 쓴 새 코멘트로 잡힌다.
    public func inlineComment(for issue: ReviewIssue, body: String?, diff: ParsedDiff?) -> ReviewPayload.Comment? {
        let draft: DraftComment
        let text: String
        if let index = draftIndex(for: issue) {
            guard comments[index].anchorStatus != .unresolved else { return nil }
            draft = comments[index].comment
            text = body ?? comments[index].editedBody
        } else {
            guard let diff, let spot = inlineSpot(for: issue.key, diff: diff), let at = spot.locationIndex,
                  let made = Self.inlineDraft(for: spot.item, at: spot.item.locations[at], diff: diff, body: body)
            else { return nil }
            draft = made
            text = made.body
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ReviewPayload.Comment(path: draft.path, line: draft.line, side: draft.side.rawValue,
                                     start_line: draft.startLine,
                                     start_side: draft.startLine == nil ? nil : draft.side.rawValue,
                                     body: PostBuilder.decorate(trimmed))
    }

    /// 바로 단 것을 기록한다. 붙은 초안은 꺼서 다른 게시 경로가 같은 코멘트를 또 올리지 않게 한다.
    public mutating func markPostedInline(_ posted: PostedComment, for issue: ReviewIssue) {
        var map = postedInline ?? [:]
        map[issue.key] = posted
        postedInline = map
        if let index = draftIndex(for: issue) { comments[index].include = false }
    }
}
