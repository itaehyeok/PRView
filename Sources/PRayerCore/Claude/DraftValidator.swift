import Foundation

public struct ReviewLimits: Sendable {
    public var maxComments: Int
    public var minBodyChars: Int
    public var maxBodyChars: Int
    public var maxSummaryChars: Int

    public init(maxComments: Int, minBodyChars: Int, maxBodyChars: Int, maxSummaryChars: Int) {
        self.maxComments = maxComments
        self.minBodyChars = minBodyChars
        self.maxBodyChars = maxBodyChars
        self.maxSummaryChars = maxSummaryChars
    }

    /// 리뷰 하나에 담는 코멘트 수 상한과 코멘트 하나의 길이 상한. 응답 스키마(`Resources/schema.json` 의
    /// `code_comments.maxItems`·`body.maxLength`)와 같은 값이다 — 모델은 스키마 밖으로 못 나간다.
    /// 8개: 우려사항(5)·질문(3)·초안(6)이 한 목록으로 합쳐졌다(2026-10-20).
    /// 예전에는 설정으로 바꿀 수 있었는데, 올리면 그대로였고 낮추면 모델은 모른 채 다 쓰고 뒤에서 잘렸다.
    /// 두 값이 스키마와 같은지는 PromptContractTests 가 본다.
    public static let schemaMaxComments = 8
    public static let schemaMaxBodyChars = 400

    public init(settings: Settings) {
        self.init(maxComments: Self.schemaMaxComments,
                  minBodyChars: settings.minCommentBodyChars,
                  maxBodyChars: Self.schemaMaxBodyChars,
                  maxSummaryChars: settings.maxSummaryChars)
    }
}

public struct ValidatedReview: Sendable {
    public var comments: [DraftCommentState]
    public var issues: [ValidationIssue]

    public var hasUnresolvedAnchors: Bool { comments.contains { $0.anchorStatus == .unresolved } }
}

/// 모델 출력이 GitHub 인라인 코멘트로 실제 게시될 수 있는지 검사한다.
/// 존재하지 않는 줄에 코멘트를 달면 리뷰 전체가 422 로 거부되므로 여기서 걸러야 한다.
public enum DraftValidator {
    public static func validate(output: ReviewOutput, diff: ParsedDiff, limits: ReviewLimits) -> ValidatedReview {
        var issues: [ValidationIssue] = []
        var seenKeys = Set<String>()
        var seenLocations = Set<String>()
        var states: [DraftCommentState] = []

        // 사안 1개 = 코멘트 1개. 심각도 높은 것부터 남긴다.
        let ordered = output.draftComments.enumerated().sorted { lhs, rhs in
            if lhs.element.severity.rank != rhs.element.severity.rank {
                return lhs.element.severity.rank < rhs.element.severity.rank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for comment in ordered {
            if !seenKeys.insert(comment.issueKey).inserted {
                issues.append(ValidationIssue(issueKey: comment.issueKey, message: "issue_key 가 중복돼 하나만 남겼습니다.", kind: .duplicateIssueKey))
                continue
            }
            let resolved = resolveAnchor(comment: comment, diff: diff)
            let location = "\(resolved.path)#\(resolved.side.rawValue)#\(resolved.line)"
            if resolved.status != .unresolved, !seenLocations.insert(location).inserted {
                issues.append(ValidationIssue(issueKey: comment.issueKey, message: "같은 줄에 코멘트가 겹쳐 하나만 남겼습니다.", kind: .duplicateLocation))
                continue
            }
            // 상한은 실제로 게시될 코멘트만 센다. 앵커 불명 코멘트가 자리를 차지하면
            // 게시 가능한 지적이 밀려난다.
            if states.filter(\.isPostable).count >= limits.maxComments {
                issues.append(ValidationIssue(issueKey: comment.issueKey,
                                              message: "코멘트 상한(\(limits.maxComments)개)을 넘어 제외했습니다.", kind: .commentLimit))
                continue
            }

            var fixed = comment
            fixed.line = resolved.line
            fixed.side = resolved.side
            // 접미 일치로 찾은 경우 모델이 준 경로는 GitHub 에 없는 문자열이다. diff 의 경로로 바꾼다.
            fixed.path = resolved.path
            fixed.startLine = validStartLine(comment: comment, resolved: resolved, diff: diff)
            // 시작 줄이 끝 줄과 같으면 한 줄 코멘트와 같다. 범위를 떼어도 잃는 것이 없으니 알리지 않는다
            // (실측: 모델이 start_line 113 · line 113 을 줘서, 게시엔 아무 차이가 없는데 경고가 떴다).
            if let start = comment.startLine, start != comment.line, fixed.startLine == nil {
                // 어느 코멘트인지 적는다. "여러 줄 범위를 확인할 수 없어" 만으로는 무엇이 문제인지 알 수 없었다.
                let fileName = (resolved.path as NSString).lastPathComponent
                issues.append(ValidationIssue(issueKey: comment.issueKey,
                                              message: "\(fileName):\(resolved.line) 코멘트 — 여러 줄 범위(\(start)~\(comment.line)줄)를 diff 에서 확인할 수 없어 \(resolved.line)번째 줄 하나에만 답니다.", kind: .multiLineRangeDropped))
            }

            let length = comment.body.count
            if length > limits.maxBodyChars {
                issues.append(ValidationIssue(issueKey: comment.issueKey,
                                              message: "코멘트가 \(length)자로 상한(\(limits.maxBodyChars)자)을 넘습니다. 게시 전 줄여주세요.", kind: .commentTooLong))
            } else if length < limits.minBodyChars {
                issues.append(ValidationIssue(issueKey: comment.issueKey,
                                              message: "코멘트가 \(length)자로 너무 짧습니다.", kind: .commentTooShort))
            }
            if resolved.status == .unresolved {
                issues.append(ValidationIssue(issueKey: comment.issueKey,
                                              message: "diff 에서 줄을 특정할 수 없습니다(앵커 불명). 줄을 지정하거나 삭제해야 게시됩니다.", kind: .anchorUnresolved))
            }

            states.append(DraftCommentState(comment: fixed,
                                            include: resolved.status != .unresolved,
                                            anchorStatus: resolved.status,
                                            originalLine: resolved.status == .fixed ? comment.line : nil))
        }

        if output.summaryKo.count > limits.maxSummaryChars {
            issues.append(ValidationIssue(message: "요약이 \(output.summaryKo.count)자로 상한(\(limits.maxSummaryChars)자)을 넘습니다.", kind: .summaryTooLong))
        }
        // 승인하지 않았으면 이유가 있어야 한다. 작성자에게 남긴 질문도 어엿한 이유다 —
        // 이걸 빼고 세면 "질문 하나 때문에 approve 하지 않은" 정상적인 리뷰가 경고로 찍힌다(실측).
        let hasSomethingToSay = !output.draftComments.isEmpty
            || !output.concerns.isEmpty
            || !(output.questionsForAuthor ?? []).isEmpty
        if output.verdict != .approve, !hasSomethingToSay {
            issues.append(ValidationIssue(message: "verdict 가 approve 가 아닌데 코멘트·우려사항·질문이 모두 비어 있습니다.", kind: .verdictWithoutReason))
        }

        states.sort { lhs, rhs in
            if lhs.comment.path != rhs.comment.path { return lhs.comment.path < rhs.comment.path }
            return lhs.comment.line < rhs.comment.line
        }
        return ValidatedReview(comments: states, issues: issues)
    }

    /// 멀티라인 코멘트의 시작 줄은 같은 파일·같은 side 에 실제로 있고 `line` 보다 앞서야 한다.
    /// 조건을 못 맞추면 nil 로 떨어뜨려 한 줄 코멘트로 게시한다(잘못된 범위는 리뷰 전체가 422 로 거부된다).
    static func validStartLine(comment: DraftComment,
                               resolved: (path: String, line: Int, side: DiffSide, status: AnchorStatus),
                               diff: ParsedDiff) -> Int? {
        guard let start = comment.startLine, start < resolved.line else { return nil }
        // 앵커가 옮겨졌으면 모델이 준 시작 줄은 더 이상 신뢰할 수 없다.
        guard resolved.status == .ok else { return nil }
        guard let file = diff.file(matching: resolved.path) else { return nil }
        let exists = file.lines.contains { line in
            switch resolved.side {
            case .right: return (line.kind == .addition || line.kind == .context) && line.newLine == start
            case .left: return (line.kind == .deletion || line.kind == .context) && line.oldLine == start
            }
        }
        return exists ? start : nil
    }

    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripSign(_ raw: String) -> String {
        guard let first = raw.first, first == "+" || first == "-" || first == " " else { return raw }
        return String(raw.dropFirst())
    }

    /// (path, side, line) 이 diff 에 실제로 있는지 확인하고, 어긋나면 anchor_text 로 줄을 다시 찾는다.
    static func resolveAnchor(comment: DraftComment, diff: ParsedDiff) -> (path: String, line: Int, side: DiffSide, status: AnchorStatus) {
        guard let file = diff.file(matching: comment.path) else {
            return (comment.path, comment.line, comment.side, .unresolved)
        }
        let anchor = normalize(comment.anchorText)

        func matches(_ line: DiffLine) -> Bool {
            let text = normalize(line.text)
            if anchor.isEmpty || text.isEmpty { return false }
            if text == anchor { return true }
            // 부분 일치는 양쪽이 충분히 길 때만 허용한다. 그렇지 않으면 "}" 같은 줄이
            // anchor 에 포함된다는 이유로 전부 매치돼 후보가 여러 개가 된다.
            guard anchor.count >= 12, text.count >= 12 else { return false }
            return text.contains(anchor) || anchor.contains(text)
        }

        func candidates(for side: DiffSide) -> [DiffLine] {
            switch side {
            case .right:
                return file.lines.filter { $0.kind == .addition || $0.kind == .context }
            case .left:
                return file.lines.filter { $0.kind == .deletion || $0.kind == .context }
            }
        }

        // 1) 모델이 준 줄이 그대로 맞는가
        let sameSide = candidates(for: comment.side)
        if let exact = sameSide.first(where: { line in
            (comment.side == .right ? line.newLine : line.oldLine) == comment.line
        }) {
            if anchor.isEmpty || matches(exact) {
                return (file.path, comment.line, comment.side, .ok)
            }
        }

        // 2) anchor_text 로 같은 side 에서 유일하게 찾히는가
        let sameSideMatches = sameSide.filter(matches)
        if sameSideMatches.count == 1,
           let line = comment.side == .right ? sameSideMatches[0].newLine : sameSideMatches[0].oldLine {
            return (file.path, line, comment.side, .fixed)
        }

        // 3) 반대 side 에서 유일하게 찾히는가 (삭제 줄에 RIGHT 를 붙인 경우 등)
        let otherSide: DiffSide = comment.side == .right ? .left : .right
        let otherMatches = candidates(for: otherSide).filter(matches)
        if otherMatches.count == 1,
           let line = otherSide == .right ? otherMatches[0].newLine : otherMatches[0].oldLine {
            return (file.path, line, otherSide, .fixed)
        }

        return (file.path, comment.line, comment.side, .unresolved)
    }
}
