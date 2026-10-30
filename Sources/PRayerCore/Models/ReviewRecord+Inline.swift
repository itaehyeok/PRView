import Foundation

/// 우려사항·질문을 그 줄의 인라인 코멘트 초안으로 옮기기.
///
/// 리뷰 본문의 "- [높음] 제목" 한 줄보다 코드 옆에 달린 코멘트가 작성자에게 잘 읽히는 지적이 있다.
/// 변경 파일 탭에서 그 줄을 보면서 옮길지 정한다. 옮기면 본문에서는 빠진다 — 같은 말이 본문과
/// 인라인에 두 번 올라가면 작성자는 지적이 두 개인 줄 안다.
extension ReviewRecord {
    /// 본문에 실을 우려사항(인라인으로 옮긴 것은 뺀다). 지적 목록에서 고른 적이 있으면 고른 것만.
    public var bodyConcerns: [Concern] {
        output.concerns.filter { concern in
            let key = ReviewItemKey.concern(concern)
            if let bodyIssueKeys { return bodyIssueKeys.contains(key) }
            return !isMovedToInline(key)
        }
    }

    /// 본문에 실을 작성자 질문(인라인으로 옮긴 것은 뺀다). 지적 목록에서 고른 적이 있으면 고른 것만.
    public var bodyQuestions: [AuthorQuestion] {
        (output.questionsForAuthor ?? []).filter { question in
            let key = ReviewItemKey.question(question)
            if let bodyIssueKeys { return bodyIssueKeys.contains(key) }
            return !isMovedToInline(key)
        }
    }

    /// 줄에서 바로 옮길 자리. 질문은 근거가 여럿일 수 있어 인라인을 달 수 있는 첫 자리를 고른다.
    /// 줄을 모르는 항목은 nil, 자리는 있지만 전부 diff 밖이면 `locationIndex` 가 nil 이다.
    public func inlineSpot(for key: String, diff: ParsedDiff) -> InlineSpot? {
        guard let item = ReviewFollowList.items(in: output).first(where: { $0.key == key }) else { return nil }
        let index = item.locations.firstIndex { Self.canAttachInline(at: $0, diff: diff) }
        return InlineSpot(item: item, locationIndex: index)
    }

    /// 변경 파일 탭으로 가지 않고 키만으로 옮긴다. 자리 고르기는 `inlineSpot` 과 같다.
    @discardableResult
    public mutating func moveToInline(key: String, diff: ParsedDiff) -> Bool {
        guard let spot = inlineSpot(for: key, diff: diff), let index = spot.locationIndex else { return false }
        return moveToInline(spot.item, locationIndex: index, diff: diff)
    }

    public func isMovedToInline(_ key: String) -> Bool { movedToInline?[key] != nil }

    /// 옮겨서 만든 초안. 옮기지 않았거나 초안이 사라졌으면 nil.
    public func movedDraft(for key: String) -> DraftCommentState? {
        guard let draftKey = movedToInline?[key] else { return nil }
        return comments.first { $0.comment.issueKey == draftKey }
    }

    /// 그 자리에 인라인 코멘트를 달 수 있는가. GitHub 은 diff 밖의 줄에 단 코멘트가 하나라도 있으면
    /// 리뷰 전체를 422 로 거부하므로, 옮기기 전에 막는다.
    public static func canAttachInline(at location: FollowableItem.Location, diff: ParsedDiff) -> Bool {
        diffLine(at: location, diff: diff) != nil
    }

    /// 항목을 그 자리의 인라인 초안으로 옮긴다. 옮겼으면 true.
    @discardableResult
    public mutating func moveToInline(_ item: FollowableItem, locationIndex: Int, diff: ParsedDiff) -> Bool {
        guard !isPosted, !isMovedToInline(item.key), item.locations.indices.contains(locationIndex),
              // 본문에서 문장을 고쳐 뒀으면 그 문장으로 옮긴다 — 다듬은 글이 원문으로 돌아가면 안 된다.
              let comment = Self.inlineDraft(for: item, at: item.locations[locationIndex], diff: diff,
                                             body: textEdits?.items[item.key]) else {
            return false
        }
        comments.append(DraftCommentState(comment: comment))
        var moved = movedToInline ?? [:]
        moved[item.key] = comment.issueKey
        movedToInline = moved
        // 정리해 둔 항목을 옮기면 본문의 "확인했고 문제없던 것" 과 같은 자리의 지적이 같이 나간다.
        // 옮기기가 나중에 내린 결정이라 정리를 푼다.
        setCleared(nil, for: item.key)
        return true
    }

    /// 옮긴 것을 되돌린다. 만든 초안을 지우고 항목을 본문으로 돌려놓는다.
    public mutating func undoMoveToInline(_ key: String) {
        guard !isPosted, let draftKey = movedToInline?[key] else { return }
        if let index = comments.firstIndex(where: { $0.comment.issueKey == draftKey }) {
            setCleared(nil, for: ReviewItemKey.draft(comments[index].comment))
            comments.remove(at: index)
        }
        movedToInline?.removeValue(forKey: key)
        if movedToInline?.isEmpty == true { movedToInline = nil }
    }

    /// 옮길 때 만드는 초안. 그 줄이 diff 에 없으면 nil.
    ///
    /// 본문은 항목 글 그대로다(우려사항은 제목, 질문은 질문). 모델이 인라인용으로 쓴 글이 아니라서
    /// 사용자가 다듬는 것이 전제다 — 그래서 옮긴 자리에서 바로 고칠 수 있게 편집기를 띄운다.
    static func inlineDraft(for item: FollowableItem, at location: FollowableItem.Location,
                            diff: ParsedDiff, body: String? = nil) -> DraftComment? {
        guard let found = diffLine(at: location, diff: diff) else { return nil }
        let questionEvidence = item.kind == .question
            ? item.locations.map { CodeEvidence(path: $0.path, line: $0.line, note: $0.note ?? "") }
            : nil
        return DraftComment(issueKey: "moved:\(item.key)",
                            path: found.path,
                            line: location.line,
                            side: location.side,
                            body: (body ?? item.title).trimmingCharacters(in: .whitespacesAndNewlines),
                            // 질문은 결함 지적이 아니다. 머지를 막는 심각도로 세지 않게 보통으로 둔다.
                            severity: item.severity ?? .minor,
                            anchorText: found.line.text,
                            duplicatesExisting: item.isDuplicate ? true : nil,
                            existingNote: item.existingNote,
                            rationaleKo: item.rationale,
                            evidence: questionEvidence)
    }

    /// 그 자리의 diff 줄과 diff 쪽 경로. 모델이 앞 디렉터리를 빼먹은 경로도 diff 의 경로로 바꾼다
    /// (GitHub 에는 diff 의 경로로 보내야 한다).
    private static func diffLine(at location: FollowableItem.Location, diff: ParsedDiff) -> (path: String, line: DiffLine)? {
        guard let file = diff.file(matching: location.path) else { return nil }
        let match = file.lines.first { line in
            switch location.side {
            case .right: return (line.kind == .addition || line.kind == .context) && line.newLine == location.line
            case .left: return (line.kind == .deletion || line.kind == .context) && line.oldLine == location.line
            }
        }
        return match.map { (file.path, $0) }
    }
}

/// 항목 하나를 인라인으로 옮길 자리. `locationIndex` 가 nil 이면 자리가 모두 diff 밖이다.
public struct InlineSpot: Sendable, Equatable {
    public var item: FollowableItem
    public var locationIndex: Int?
}
